import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/edit_sync_mutex.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/server_binding_gate.dart';

EditWriteMode _parseMode(String wire) =>
    wire == 'db_and_master' ? EditWriteMode.dbAndMaster : EditWriteMode.dbOnly;

/// Escalates monotonically: once an edit batch opts into writing the master
/// file, a later DB-only edit must not downgrade it back to db_only.
EditWriteMode _escalate(EditWriteMode a, EditWriteMode b) =>
    (a == EditWriteMode.dbAndMaster || b == EditWriteMode.dbAndMaster)
        ? EditWriteMode.dbAndMaster
        : EditWriteMode.dbOnly;

/// What a Get info save needs before it may be submitted.
enum EditSavePlan { noChanges, confirmMasterWrite, ready }

/// The coalescing outbox for track metadata edits. One row per track; an edit
/// writes optimistically to the local DB and queues here, then flushes via
/// PATCH — online or on reconnect — through one path.
///
/// Every state write is fenced by the session binding (SC-01 rule 4): a
/// user-initiated write captures `local_binding_id` when it starts, a flush
/// uses the token of the verified connection it was sent on, and the write
/// runs in a transaction that asserts the binding row still carries it. An
/// answer or edit that outlives a reset (or a re-bind) changes nothing.
class EditOutbox implements LossReporter {
  EditOutbox({
    required this.db,
    required this.api,
    required this.mutex,
    required this.ref,
    ServerBindingRepository? binding,
  }) : binding = binding ?? ServerBindingRepository(db);

  final AppDatabase db;
  final TracksApi api;
  final AsyncMutex mutex;
  final Ref ref;
  final ServerBindingRepository binding;

  /// The current binding token, captured when a user-initiated write starts
  /// (before waiting on the mutex). No binding row: refused.
  Future<String> _captureToken() async {
    final token = (await binding.current())?.localBindingId;
    if (token == null) throw BindingFencedException('<no binding>');
    return token;
  }

  /// Unresolved edits a reset would discard, by the same definition as the
  /// pending-edits surface (pending + conflicted + rejected: a rejected edit
  /// still holds the user's values).
  @override
  Future<String?> pendingLossSummary() async {
    final counts = await db.pendingEditCounts();
    final n = counts.pending + counts.conflicted + counts.rejected;
    if (n == 0) return null;
    return '$n unsent metadata edit${n == 1 ? '' : 's'}';
  }

  /// What a Get info save must do first. A DB-only save with no edited
  /// field is a no-op. [enqueue] monotonically escalates the write mode
  /// against an already queued master write and never downgrades it, so the
  /// confirmation is gated on that EFFECTIVE mode, not just the requested one:
  /// otherwise a permanent file write could be saved without confirmation.
  Future<EditSavePlan> planSave(
    String uuidId,
    MetadataEdit edit,
    EditWriteMode requested,
  ) async {
    if (edit.isEmpty && requested == EditWriteMode.dbOnly) {
      return EditSavePlan.noChanges;
    }
    final effective = await hasPendingMasterWrite(uuidId)
        ? EditWriteMode.dbAndMaster
        : requested;
    return effective == EditWriteMode.dbAndMaster
        ? EditSavePlan.confirmMasterWrite
        : EditSavePlan.ready;
  }

  /// A queued `db_and_master` edit for the track (Get info reopens with the
  /// master-write toggle on, so re-saving keeps escalating).
  Future<bool> hasPendingMasterWrite(String uuidId) async =>
      await db.pendingWriteMode(uuidId) == EditWriteMode.dbAndMaster.wire;

  /// Autocomplete values for an editable field (empty for free-text fields).
  Future<List<String>> fieldSuggestions(String fieldKey, String prefix) {
    switch (fieldKey) {
      case 'artist':
      case 'album_artist':
        return db.artistSuggestions(prefix);
      case 'album':
        return db.albumSuggestions(prefix);
      case 'genre':
        return db.genreSuggestions(prefix);
      default:
        return Future.value(const []);
    }
  }

  /// Optimistic local write + queue, then a best-effort flush ([flush] is a
  /// no-op offline). `base_revision` is the track's revision at submit (NULL
  /// forces the conflict path).
  Future<void> submit({
    required String uuidId,
    required MetadataEdit edit,
    required EditWriteMode writeMode,
    required int? baseRevision,
  }) async {
    await enqueue(
      uuidId: uuidId,
      edit: edit,
      writeMode: writeMode,
      baseRevision: baseRevision,
    );
    unawaited(flush());
  }

  /// Optimistically apply [edit] locally and queue it, coalescing into any
  /// existing row for [uuidId].
  Future<void> enqueue({
    required String uuidId,
    required MetadataEdit edit,
    required EditWriteMode writeMode,
    required int? baseRevision,
  }) async {
    // An empty edit is still queued when it escalates to a master-file write
    // (re-tag the file from current DB values); only a no-op DB-only edit exits.
    if (edit.isEmpty && writeMode == EditWriteMode.dbOnly) return;
    final token = await _captureToken();
    // Held under the shared mutex so a concurrent `/changes` pull can't land its
    // blind full-row upsert between the optimistic write and the queue write and
    // clobber the just-applied edit. Both writes are one fenced transaction.
    await mutex.run(() => binding.runFenced(token, () async {
      final existing = await (db.select(db.pendingEdits)
            ..where((t) => t.uuidId.equals(uuidId)))
          .getSingleOrNull();

      // A conflicted row is resolved only via resolveKeepMine/resolveTakeServer
      // (explicit, user-driven) — an edit touching no fields must not silently
      // coalesce onto it and clear the conflict as a side effect of
      // re-escalating write mode (e.g. reopening Get Info on a conflicted
      // db_and_master track and saving with no field changes).
      if (edit.isEmpty && existing?.status == 'conflicted') return;

      // Snapshot the pre-edit state on the first edit of a batch — before the
      // optimistic write mutates the columns — and preserve it across
      // coalescing. This is what lets take-server/discard revert locally.
      // Preserving it across a take_server marker matters too: the columns
      // still hold the discarded batch's optimistic values, so re-reading
      // them here would poison a later revert.
      final original = existing?.originalValuesJson ??
          jsonEncode(await db.readEditableColumns(uuidId));

      await db.applyOptimisticTrackEdit(uuidId, edit.toPayload());

      var values = edit.toPayload();
      var mode = writeMode;
      var base = baseRevision;
      // A take_server marker is a batch the user explicitly discarded (its
      // refetch just hasn't run yet) — a fresh edit replaces it outright.
      // A rejected row is a batch the server permanently refused (already
      // reverted locally) — same treatment: coalescing onto either would
      // resurrect discarded/refused values, inherit the dead batch's
      // write-mode escalation, and build on its stale base. Losing the row
      // is fine: this batch's own flush bumps the revision, so the next
      // `/changes` pull re-sends the full row anyway.
      if (existing != null &&
          existing.status != 'take_server' &&
          existing.status != 'rejected') {
        final prev =
            (jsonDecode(existing.valuesJson) as Map).cast<String, Object?>();
        values = {...prev, ...values}; // latest value per touched key wins
        mode = _escalate(_parseMode(existing.writeMode), writeMode);
        // Re-editing a conflicted row rebases onto the server's revision so the
        // next flush builds on server truth instead of 409-ing again on the
        // stale base; otherwise keep the batch's first base.
        base =
            (existing.status == 'conflicted' && existing.serverRevision != null)
                ? existing.serverRevision
                : existing.baseRevision;
      }

      await db.into(db.pendingEdits).insertOnConflictUpdate(
            PendingEditsCompanion(
              uuidId: Value(uuidId),
              valuesJson: Value(jsonEncode(values)),
              writeMode: Value(mode.wire),
              baseRevision: Value(base),
              status: const Value('pending'),
              serverRevision: const Value(null),
              originalValuesJson: Value(original),
              updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
            ),
          );
    }));
  }

  /// Flush all pending rows. Waits for a verified connection first (SC-01
  /// rule 1) WITHOUT holding the edit mutex, so a blocked server can't
  /// freeze editing; then flushes under the shared mutex so a `/changes`
  /// pull cannot interleave (and clobber an in-flight edit).
  Future<void> flush() async {
    if (ref.read(offlineModeProvider)) return;
    final String token;
    try {
      token = await ref.read(serverBindingGateProvider).awaitVerified();
    } on BindingGateClosedException {
      return;
    }
    await mutex.run(() => flushLocked(bindingToken: token));
  }

  /// Flush variant for callers that already hold the mutex (the sync pull path,
  /// which flushes-then-pulls in one critical section). Every write a
  /// response causes is fenced by [bindingToken], the verified connection's
  /// binding token.
  Future<void> flushLocked({required String bindingToken}) async {
    if (ref.read(offlineModeProvider)) return;
    final rows = await (db.select(db.pendingEdits)
          ..where((t) => t.status.equals('pending')))
        .get();
    // Each row is an independent per-uuid PATCH with no shared mutable state
    // or ordering dependency between tracks, so flush them concurrently
    // rather than paying one round trip per row sequentially.
    await Future.wait(rows.map((row) async {
      try {
        await _flushOne(row, bindingToken);
      } catch (e) {
        // Network error / unexpected 5xx after retries: leave this row pending
        // and move on, so one stuck track can't block the rest of the outbox.
        developer.log('flush skipped ${row.uuidId}: $e', name: 'EditOutbox');
      }
    }));
  }

  Future<void> _flushOne(PendingEdit row, String bindingToken) async {
    final values = (jsonDecode(row.valuesJson) as Map).cast<String, dynamic>();
    final body = <String, dynamic>{
      ...values,
      'base_revision': row.baseRevision,
      'write_mode': row.writeMode,
    };
    try {
      final resp = await api.patchTrack(row.uuidId, body);
      // 200: record the revision this edit produced so the next edit's
      // base_revision builds on server truth instead of the stale pre-flush
      // value (which would 409 against this client's own edit), then drop the
      // row. This path holds the shared mutex, so the write can't race a pull.
      final newRevision = resp['revision'];
      await binding.runFenced(bindingToken, () async {
        if (newRevision is int) {
          // A 200 means the server held exactly `base_revision` right before
          // this edit (anything else 409s), so a download current as of that
          // revision differs from server truth only by this user's own edit
          // -- carry it forward rather than flag the user's own save as a
          // stale download. Server-originated changes never pass through
          // here.
          await db.recordOwnEditRevision(
            row.uuidId,
            newRevision,
            currentAsOf: row.baseRevision,
          );
        }
        await _delete(row.uuidId);
      });
    } on ApiException catch (e) {
      switch (e.statusCode) {
        case 409:
          // A 409 can be manufactured by our own transport retry: attempt 1
          // committed server-side but its response was lost, so the retried
          // base_revision was stale. Fetch server truth and value-compare —
          // if every field this batch touched already holds our value, the
          // edit IS applied: reconcile and drop the row instead of prompting
          // the user to resolve a conflict against their own values.
          if (await _resolveIfAlreadyApplied(row, bindingToken)) return;
          await binding.runFenced(
            bindingToken,
            () => (db.update(db.pendingEdits)
                  ..where((t) => t.uuidId.equals(row.uuidId)))
                .write(PendingEditsCompanion(
              status: const Value('conflicted'),
              serverRevision: Value(_serverRevisionFrom(e)),
            )),
          );
        case 404:
        case 410:
          // Track gone server-side: revert the (guarded) optimistic write and
          // keep the row as a visible rejection — the user saw "Saved", so the
          // save silently un-happening needs a surface. The stale local track
          // itself is removed by the next `/changes` pull (the delete
          // tombstone carries a revision above the watermark).
          await binding.runFenced(bindingToken, () async {
            await _revertToSnapshot(row);
            await _markRejected(
              row.uuidId,
              'Track no longer exists on the server',
            );
          });
        case 422:
          // Permanent rejection (capability drift / locked field / validation):
          // revert the optimistic write to the pre-edit snapshot so the local
          // DB doesn't keep a value the server refused, refresh caps, and keep
          // the row as a visible rejection until the user dismisses it.
          await binding.runFenced(bindingToken, () async {
            await _revertToSnapshot(row);
            await _markRejected(row.uuidId, _rejectionReasonFrom(e));
          });
          ref.invalidate(appInfoProvider);
        default:
          rethrow; // 5xx etc. — retry later
      }
    }
  }

  /// True when the server already holds exactly the values this batch wrote —
  /// the "conflict" is against our own committed edit (lost response +
  /// transport retry) or a value-identical concurrent edit. The local base
  /// revision is raised to the server's and the row dropped. Best-effort: any
  /// refetch failure returns false and the normal conflict path proceeds.
  Future<bool> _resolveIfAlreadyApplied(
    PendingEdit row,
    String bindingToken,
  ) async {
    final ClientTrackDto dto;
    try {
      dto = await api.getTrack(row.uuidId);
    } catch (_) {
      return false;
    }
    final edited = (jsonDecode(row.valuesJson) as Map).cast<String, Object?>();
    // An empty batch (the "re-tag master from current DB values" flow with no
    // field edits) has no field to verify equality against, so it can never
    // be soundly self-resolved — always fall through to the conflict path.
    if (edited.isEmpty) return false;
    final m = dto.metadata;
    final server = <String, Object?>{
      'title': m.title,
      'artist': m.artist,
      'album': m.album,
      'album_artist': m.albumArtist,
      'year': m.year,
      'date': m.date,
      'genre': m.genre,
      'track_number': m.trackNumber,
      'disc_number': m.discNumber,
    };
    for (final entry in edited.entries) {
      if (!server.containsKey(entry.key)) return false;
      final serverValue = server[entry.key];
      final editedValue = entry.value;
      // The server NFC-normalizes string fields before storing; compare
      // normalized so a decomposed-vs-composed Unicode value that was
      // successfully applied doesn't read as a false conflict.
      final equal = (serverValue is String && editedValue is String)
          ? unorm.nfc(serverValue) == unorm.nfc(editedValue)
          : serverValue == editedValue;
      if (!equal) return false;
    }
    // Unlike a 200, a 409 can't prove the server's revision moved ONLY by
    // our edit (a conversion or new artwork could have landed too), so only
    // carry a current download forward when the server's audio + artwork
    // still match what's stored locally; otherwise leave it to flag as stale
    // (the safe direction). The local row is only a valid "before" snapshot
    // while no `/changes` pull has applied anything since the edit's base: a
    // pull could already have overwritten it with server truth (e.g. a
    // conversion), which would then trivially "match" the server.
    await binding.runFenced(bindingToken, () async {
      final localRevision = await _localRevision(row.uuidId);
      final carryForward = localRevision == row.baseRevision &&
          await _audioAndArtUnchanged(row.uuidId, dto);
      await db.recordOwnEditRevision(
        row.uuidId,
        dto.revision,
        currentAsOf: carryForward ? row.baseRevision : null,
      );
      await _delete(row.uuidId);
    });
    developer.log('409 was our own applied edit — resolved: ${row.uuidId}',
        name: 'EditOutbox');
    return true;
  }

  Future<int?> _localRevision(String uuidId) async {
    final track = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals(uuidId)))
        .getSingleOrNull();
    return track?.revision;
  }

  /// True when [dto]'s intrinsic audio fields and artwork match the local
  /// `trackmetadata` row -- i.e. nothing a downloaded file embeds besides tags
  /// changed server-side.
  Future<bool> _audioAndArtUnchanged(String uuidId, ClientTrackDto dto) async {
    final local = await (db.select(db.trackmetadata)
          ..where((t) => t.uuidId.equals(uuidId)))
        .getSingleOrNull();
    if (local == null) return false;
    final m = dto.metadata;
    return local.codec == m.codec &&
        local.bitrateKbps == m.bitrateKbps &&
        local.sampleRateHz == m.sampleRateHz &&
        local.channels == m.channels &&
        local.hasAlbumArt == m.hasAlbumArt &&
        local.coverArtId == m.coverArtId;
  }

  /// Revert a track's optimistic write back to the pre-edit snapshot captured
  /// at the first edit of the batch — but only the fields this batch touched,
  /// and only where the current local value is still the batch's optimistic
  /// value. If something newer overwrote a field (a `/changes` pull upserting
  /// server truth while the row sat pending), that value is at/below the
  /// watermark and would never be re-sent, so blindly resurrecting the stale
  /// snapshot over it is unrepairable — leave it in place instead. Pure DB
  /// work — the caller decides whether the shared mutex is held.
  Future<void> _revertToSnapshot(PendingEdit row) async {
    final snapshotJson = row.originalValuesJson;
    if (snapshotJson == null) return;
    final snapshot = (jsonDecode(snapshotJson) as Map).cast<String, Object?>();
    final edited = (jsonDecode(row.valuesJson) as Map).cast<String, Object?>();
    final current = await db.readEditableColumns(row.uuidId);
    if (current.isEmpty) return; // track row already gone locally
    final revert = <String, Object?>{
      for (final entry in edited.entries)
        if (current[entry.key] == entry.value) entry.key: snapshot[entry.key],
    };
    if (revert.isEmpty) return;
    await db.applyOptimisticTrackEdit(row.uuidId, revert);
  }

  /// "Keep my edit": rebase onto the server's current revision and re-queue.
  Future<void> resolveKeepMine(String uuidId) async {
    final token = await _captureToken();
    // Held under the shared mutex so this read-modify-write can't race a
    // concurrent enqueue() reading stale (pre-rebase) row state.
    final rebased = await mutex.run(() => binding.runFenced(token, () async {
      final row = await (db.select(db.pendingEdits)
            ..where((t) => t.uuidId.equals(uuidId))
            ..where((t) => t.status.equals('conflicted')))
          .getSingleOrNull();
      if (row == null) return false;
      await (db.update(db.pendingEdits)..where((t) => t.uuidId.equals(uuidId)))
          .write(PendingEditsCompanion(
        baseRevision: Value(row.serverRevision),
        status: const Value('pending'),
        serverRevision: const Value(null),
      ));
      return true;
    }));
    if (rebased) await flush();
  }

  /// "Take server version": discard the local edit and land on *current*
  /// server truth via the authoritative single-track refetch. A plain pull
  /// can't be trusted here: a prior `/changes` may already have advanced the
  /// watermark past the conflicting revision and would fetch nothing.
  ///
  /// The row is marked `take_server` FIRST and deleted only after the refetch
  /// succeeds. No snapshot revert: the refetch overwrites anyway, and while
  /// the marker is outstanding (offline, transient failure, a sync in flight)
  /// the local row honestly keeps the user's optimistic values instead of
  /// reverting to a third state that nothing would ever repair.
  /// [retryTakeServerResolutions] finishes outstanding markers after each
  /// sync, so a resolution made offline self-heals on reconnect.
  Future<void> resolveTakeServer(String uuidId) async {
    // Held under the shared mutex so this marker write can't race a
    // concurrent enqueue() reading the pre-marker row state — otherwise a
    // fresh edit could coalesce onto the just-discarded batch before this
    // write lands, silently undoing the "take server" choice.
    final token = await _captureToken();
    await mutex.run(
      () => binding.runFenced(
        token,
        () => (db.update(db.pendingEdits)
              ..where((t) => t.uuidId.equals(uuidId)))
            .write(const PendingEditsCompanion(
          status: Value('take_server'),
          serverRevision: Value(null),
        )),
      ),
    );
    await _refetchTakeServer(uuidId);
  }

  /// Refetch server truth for a take-server marker; the row is deleted only
  /// when the refetch actually ran (refreshTrack returns false when offline,
  /// when a sync is in flight, or on failure — the marker then survives for
  /// the next retry).
  Future<void> _refetchTakeServer(
    String uuidId, {
    bool rebuildParentFts = true,
  }) async {
    // The reap is fenced by the binding the refetch started under; a reset
    // in between makes it a no-op (swallowed: nothing left to reap).
    final token = (await binding.current())?.localBindingId;
    if (token == null) return;
    final refreshed = await ref
        .read(trackSyncProvider.notifier)
        .refreshTrack(uuidId, rebuildParentFts: rebuildParentFts);
    if (!refreshed) return;
    // Reap under the shared mutex, and only while the row is still a marker:
    // a re-edit queued behind the refetch replaces the row with a fresh
    // pending batch that must survive (deleting it would silently discard a
    // save the user was already told succeeded).
    try {
      await mutex.run(
        () => binding.runFenced(
          token,
          () => (db.delete(db.pendingEdits)
                ..where((t) => t.uuidId.equals(uuidId))
                ..where((t) => t.status.equals('take_server')))
              .go(),
        ),
      );
    } on BindingFencedException {
      // Reset (or re-bind) since the refetch started: leave the new store be.
    }
  }

  /// Finish take-server resolutions whose refetch couldn't run when the user
  /// made them. Called after each sync completes, outside its critical
  /// section (refreshTrack re-takes the shared guards itself).
  Future<void> retryTakeServerResolutions() async {
    final rows = await (db.select(db.pendingEdits)
          ..where((t) => t.status.equals('take_server')))
        .get();
    if (rows.isEmpty) return;
    // Defer the (small, cheap, but still redundant N times) parent-FTS
    // rebuild to once after the whole batch instead of once per row.
    for (final row in rows) {
      await _refetchTakeServer(row.uuidId, rebuildParentFts: false);
    }
    await db.rebuildParentFtsIndexes();
  }

  /// Mark a permanently rejected edit: the optimistic write is already
  /// reverted, the row stays visible (banner + sheet) with a short reason
  /// until the user dismisses it. Rejected rows are never re-flushed
  /// ([flushLocked] selects only `pending`).
  Future<void> _markRejected(String uuidId, String reason) async {
    await (db.update(db.pendingEdits)..where((t) => t.uuidId.equals(uuidId)))
        .write(PendingEditsCompanion(
      status: const Value('rejected'),
      rejectionReason: Value(reason),
      serverRevision: const Value(null),
    ));
    developer.log('edit rejected: $uuidId — $reason', name: 'EditOutbox');
  }

  /// A short human-readable reason from the server's error body (the string
  /// `detail` FastAPI sends for domain rejections like an empty-track edit);
  /// generic fallback for shapes we can't parse (pydantic's list detail).
  String _rejectionReasonFrom(ApiException e) {
    final detail = e.hasStringDetail ? e.detailMessage : null;
    if (detail != null) return detail;
    return 'Rejected by the server (invalid or locked field)';
  }

  /// Dismiss a rejected edit from the banner/sheet.
  Future<void> dismissRejected(String uuidId) async {
    final token = await _captureToken();
    await binding.runFenced(token, () => _delete(uuidId));
  }

  Stream<List<PendingEdit>> watchConflicts() {
    return (db.select(db.pendingEdits)
          ..where((t) => t.status.equals('conflicted')))
        .watch();
  }

  Stream<List<PendingEdit>> watchRejected() {
    return (db.select(db.pendingEdits)
          ..where((t) => t.status.equals('rejected')))
        .watch();
  }

  Future<void> _delete(String uuidId) =>
      (db.delete(db.pendingEdits)..where((t) => t.uuidId.equals(uuidId))).go();

  int? _serverRevisionFrom(ApiException e) {
    final rev = e.details?['current_revision'];
    return rev is int ? rev : null;
  }
}

final editOutboxProvider = Provider<EditOutbox>((ref) {
  return EditOutbox(
    db: ref.read(databaseProvider),
    api: ref.read(tracksApiProvider),
    mutex: ref.read(editSyncMutexProvider),
    ref: ref,
    binding: ref.read(serverBindingRepositoryProvider),
  );
});

/// Live (pending, conflicted, rejected) counts driving the global
/// pending-edits surface.
final pendingEditCountsProvider =
    StreamProvider<({int pending, int conflicted, int rejected})>((ref) {
  return ref.watch(databaseProvider).watchPendingEditCounts();
});

/// Live list of conflicted edits for the resolution sheet.
final conflictedEditsProvider = StreamProvider<List<PendingEdit>>((ref) {
  return ref.watch(editOutboxProvider).watchConflicts();
});

/// Live list of permanently rejected edits for the banner sheet (visible with
/// their reason until dismissed).
final rejectedEditsProvider = StreamProvider<List<PendingEdit>>((ref) {
  return ref.watch(editOutboxProvider).watchRejected();
});
