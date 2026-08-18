import 'dart:convert';
import 'dart:developer' as developer;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/edit_sync_mutex.dart';

EditWriteMode _parseMode(String wire) =>
    wire == 'db_and_master' ? EditWriteMode.dbAndMaster : EditWriteMode.dbOnly;

/// Escalates monotonically: once an edit batch opts into writing the master
/// file, a later DB-only edit must not downgrade it back to db_only.
EditWriteMode _escalate(EditWriteMode a, EditWriteMode b) =>
    (a == EditWriteMode.dbAndMaster || b == EditWriteMode.dbAndMaster)
        ? EditWriteMode.dbAndMaster
        : EditWriteMode.dbOnly;

/// The coalescing outbox for track metadata edits. One row per track; an edit
/// writes optimistically to the local DB and queues here, then flushes via
/// PATCH — online or on reconnect — through one path.
class EditOutbox {
  EditOutbox({
    required this.db,
    required this.api,
    required this.mutex,
    required this.ref,
  });

  final AppDatabase db;
  final TracksApi api;
  final AsyncMutex mutex;
  final Ref ref;

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
    // Held under the shared mutex so a concurrent `/changes` pull can't land its
    // blind full-row upsert between the optimistic write and the queue write and
    // clobber the just-applied edit.
    await mutex.run(() async {
      final existing = await (db.select(db.pendingEdits)
            ..where((t) => t.uuidId.equals(uuidId)))
          .getSingleOrNull();

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
    });
  }

  /// Flush all pending rows. Held under the shared mutex so a `/changes` pull
  /// cannot interleave (and clobber an in-flight edit).
  Future<void> flush() => mutex.run(flushLocked);

  /// Flush variant for callers that already hold the mutex (the sync pull path,
  /// which flushes-then-pulls in one critical section).
  Future<void> flushLocked() async {
    if (ref.read(offlineModeProvider)) return;
    final rows = await (db.select(db.pendingEdits)
          ..where((t) => t.status.equals('pending')))
        .get();
    // Each row is an independent per-uuid PATCH with no shared mutable state
    // or ordering dependency between tracks, so flush them concurrently
    // rather than paying one round trip per row sequentially.
    await Future.wait(rows.map((row) async {
      try {
        await _flushOne(row);
      } catch (e) {
        // Network error / unexpected 5xx after retries: leave this row pending
        // and move on, so one stuck track can't block the rest of the outbox.
        developer.log('flush skipped ${row.uuidId}: $e', name: 'EditOutbox');
      }
    }));
  }

  Future<void> _flushOne(PendingEdit row) async {
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
      if (newRevision is int) {
        await db.updateTrackRevision(row.uuidId, newRevision);
      }
      await _delete(row.uuidId);
    } on ApiException catch (e) {
      switch (e.statusCode) {
        case 409:
          // A 409 can be manufactured by our own transport retry: attempt 1
          // committed server-side but its response was lost, so the retried
          // base_revision was stale. Fetch server truth and value-compare —
          // if every field this batch touched already holds our value, the
          // edit IS applied: reconcile and drop the row instead of prompting
          // the user to resolve a conflict against their own values.
          if (await _resolveIfAlreadyApplied(row)) return;
          await (db.update(db.pendingEdits)
                ..where((t) => t.uuidId.equals(row.uuidId)))
              .write(PendingEditsCompanion(
            status: const Value('conflicted'),
            serverRevision: Value(_serverRevisionFrom(e)),
          ));
        case 404:
        case 410:
          // Track gone server-side: revert the (guarded) optimistic write and
          // keep the row as a visible rejection — the user saw "Saved", so the
          // save silently un-happening needs a surface. The stale local track
          // itself is removed by the next `/changes` pull (the delete
          // tombstone carries a revision above the watermark).
          await _revertToSnapshot(row);
          await _markRejected(row.uuidId, 'Track no longer exists on the server');
        case 422:
          // Permanent rejection (capability drift / locked field / validation):
          // revert the optimistic write to the pre-edit snapshot so the local
          // DB doesn't keep a value the server refused, refresh caps, and keep
          // the row as a visible rejection until the user dismisses it.
          await _revertToSnapshot(row);
          ref.invalidate(appInfoProvider);
          await _markRejected(row.uuidId, _rejectionReasonFrom(e));
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
  Future<bool> _resolveIfAlreadyApplied(PendingEdit row) async {
    final ClientTrackDto dto;
    try {
      dto = await api.getTrack(row.uuidId);
    } catch (_) {
      return false;
    }
    final edited = (jsonDecode(row.valuesJson) as Map).cast<String, Object?>();
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
      if (!server.containsKey(entry.key) ||
          server[entry.key] != entry.value) {
        return false;
      }
    }
    await db.updateTrackRevision(row.uuidId, dto.revision);
    await _delete(row.uuidId);
    developer.log('409 was our own applied edit — resolved: ${row.uuidId}',
        name: 'EditOutbox');
    return true;
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
    // Held under the shared mutex so this read-modify-write can't race a
    // concurrent enqueue() reading stale (pre-rebase) row state.
    final rebased = await mutex.run(() async {
      final row = await (db.select(db.pendingEdits)
            ..where((t) => t.uuidId.equals(uuidId)))
          .getSingleOrNull();
      if (row == null) return false;
      await (db.update(db.pendingEdits)..where((t) => t.uuidId.equals(uuidId)))
          .write(PendingEditsCompanion(
        baseRevision: Value(row.serverRevision),
        status: const Value('pending'),
        serverRevision: const Value(null),
      ));
      return true;
    });
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
    await mutex.run(
      () => (db.update(db.pendingEdits)..where((t) => t.uuidId.equals(uuidId)))
          .write(const PendingEditsCompanion(
        status: Value('take_server'),
        serverRevision: Value(null),
      )),
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
    final refreshed = await ref
        .read(trackSyncProvider.notifier)
        .refreshTrack(uuidId, rebuildParentFts: rebuildParentFts);
    if (!refreshed) return;
    // Reap under the shared mutex, and only while the row is still a marker:
    // a re-edit queued behind the refetch replaces the row with a fresh
    // pending batch that must survive (deleting it would silently discard a
    // save the user was already told succeeded).
    await mutex.run(
      () => (db.delete(db.pendingEdits)
            ..where((t) => t.uuidId.equals(uuidId))
            ..where((t) => t.status.equals('take_server')))
          .go(),
    );
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
    final detail = _parseErrorBody(e)?['detail'];
    if (detail is String && detail.isNotEmpty) return detail;
    return 'Rejected by the server (invalid or locked field)';
  }

  /// Dismiss a rejected edit from the banner/sheet.
  Future<void> dismissRejected(String uuidId) => _delete(uuidId);

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
    final detail = _parseErrorBody(e)?['detail'];
    final rev = detail is Map ? detail['current_revision'] : null;
    return rev is int ? rev : null;
  }

  /// Decodes `e.message` as a JSON object, or null if it isn't valid JSON /
  /// isn't a JSON object.
  Map<String, dynamic>? _parseErrorBody(ApiException e) {
    try {
      final body = jsonDecode(e.message);
      return body is Map ? body.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }
}

final editOutboxProvider = Provider<EditOutbox>((ref) {
  return EditOutbox(
    db: ref.read(databaseProvider),
    api: ref.read(tracksApiProvider),
    mutex: ref.read(editSyncMutexProvider),
    ref: ref,
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
