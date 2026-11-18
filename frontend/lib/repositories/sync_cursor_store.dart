import 'package:frontend/database/database.dart';

/// The server answered with a `latestRevision` below the `after` this client
/// requested: it was restored from an older backup (SC-01 rule 5). Nothing
/// from that response was applied.
class ServerRegressedException implements Exception {
  ServerRegressedException({
    required this.requestedAfter,
    required this.latestRevision,
  });
  final int requestedAfter;
  final int latestRevision;

  @override
  String toString() =>
      'ServerRegressedException(requested after $requestedAfter, '
      'server latest $latestRevision)';
}

/// A server change stream with its own watermark; [name] is the stored
/// `sync_cursors.stream` key.
enum SyncStream { catalog, history }

/// Durable per-stream sync cursors (SC-02), kept in Drift so a page's
/// application and its cursor advance commit in one transaction.
class SyncCursorStore {
  SyncCursorStore(this._db);

  final AppDatabase _db;

  /// The stream's cursor; 0 when none has been stored.
  Future<int> read(SyncStream stream) async {
    final row = await (_db.select(
      _db.syncCursors,
    )..where((c) => c.stream.equals(stream.name))).getSingleOrNull();
    return row?.value ?? 0;
  }

  /// Must run inside the caller's Drift transaction (page apply + cursor).
  Future<void> write(SyncStream stream, int value) async {
    await _db
        .into(_db.syncCursors)
        .insertOnConflictUpdate(
          SyncCursorsCompanion.insert(stream: stream.name, value: value),
        );
  }
}
