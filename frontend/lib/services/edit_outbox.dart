import 'dart:convert';
import 'dart:developer' as developer;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
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
      final original = existing?.originalValuesJson ??
          jsonEncode(await db.readEditableColumns(uuidId));

      await db.applyOptimisticTrackEdit(uuidId, edit.toPayload());

      var values = edit.toPayload();
      var mode = writeMode;
      var base = baseRevision;
      if (existing != null) {
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
    for (final row in rows) {
      try {
        await _flushOne(row);
      } catch (e) {
        // Network error / unexpected 5xx after retries: leave this row pending
        // and move on, so one stuck track can't block the rest of the outbox.
        developer.log('flush skipped ${row.uuidId}: $e', name: 'EditOutbox');
        continue;
      }
    }
  }

  Future<void> _flushOne(PendingEdit row) async {
    final values = (jsonDecode(row.valuesJson) as Map).cast<String, dynamic>();
    final body = <String, dynamic>{
      ...values,
      'base_revision': row.baseRevision,
      'write_mode': row.writeMode,
    };
    try {
      await api.patchTrack(row.uuidId, body);
      await _delete(row.uuidId); // 200: applied, drop the row
    } on ApiException catch (e) {
      switch (e.statusCode) {
        case 409:
          await (db.update(db.pendingEdits)
                ..where((t) => t.uuidId.equals(row.uuidId)))
              .write(PendingEditsCompanion(
            status: const Value('conflicted'),
            serverRevision: Value(_serverRevisionFrom(e)),
          ));
        case 404:
        case 410:
          await _delete(row.uuidId); // track gone server-side
          developer.log('edit dropped — track gone: ${row.uuidId}',
              name: 'EditOutbox');
        case 422:
          // Capability drift / locked field: refresh caps and drop the edit.
          ref.invalidate(appInfoProvider);
          await _delete(row.uuidId);
          developer.log('edit rejected (422): ${row.uuidId}', name: 'EditOutbox');
        default:
          rethrow; // 5xx etc. — retry later
      }
    }
  }

  /// "Keep my edit": rebase onto the server's current revision and re-queue.
  Future<void> resolveKeepMine(String uuidId) async {
    final row = await (db.select(db.pendingEdits)
          ..where((t) => t.uuidId.equals(uuidId)))
        .getSingleOrNull();
    if (row == null) return;
    await (db.update(db.pendingEdits)..where((t) => t.uuidId.equals(uuidId)))
        .write(PendingEditsCompanion(
      baseRevision: Value(row.serverRevision),
      status: const Value('pending'),
      serverRevision: const Value(null),
    ));
    await flush();
  }

  /// "Take server version": discard the local edit. Revert the optimistic write
  /// to the captured pre-edit snapshot (so the already-synced server truth shows
  /// immediately — `/changes` won't re-send a track at/below the watermark),
  /// then pull to catch any not-yet-seen newer revision.
  Future<void> resolveTakeServer(String uuidId) async {
    final row = await (db.select(db.pendingEdits)
          ..where((t) => t.uuidId.equals(uuidId)))
        .getSingleOrNull();
    final snapshot = row?.originalValuesJson;
    if (snapshot != null) {
      final original = (jsonDecode(snapshot) as Map).cast<String, Object?>();
      await mutex.run(() => db.applyOptimisticTrackEdit(uuidId, original));
    }
    await _delete(uuidId);
    await ref.read(trackSyncProvider.notifier).sync();
  }

  Stream<List<PendingEdit>> watchConflicts() {
    return (db.select(db.pendingEdits)
          ..where((t) => t.status.equals('conflicted')))
        .watch();
  }

  Future<void> _delete(String uuidId) =>
      (db.delete(db.pendingEdits)..where((t) => t.uuidId.equals(uuidId))).go();

  int? _serverRevisionFrom(ApiException e) {
    try {
      final body = jsonDecode(e.message);
      final detail = body is Map ? body['detail'] : null;
      final rev = detail is Map ? detail['current_revision'] : null;
      return rev is int ? rev : null;
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

/// Live (pending, conflicted) counts driving the global pending-edits surface.
final pendingEditCountsProvider =
    StreamProvider<({int pending, int conflicted})>((ref) {
  return ref.watch(databaseProvider).watchPendingEditCounts();
});

/// Live list of conflicted edits for the resolution sheet.
final conflictedEditsProvider = StreamProvider<List<PendingEdit>>((ref) {
  return ref.watch(editOutboxProvider).watchConflicts();
});
