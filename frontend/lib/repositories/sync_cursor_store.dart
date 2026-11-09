import 'package:frontend/database/database.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A server change stream with its own watermark; [name] is the stored
/// `sync_cursors.stream` key.
enum SyncStream { catalog, history }

/// Durable per-stream sync cursors (SC-02), kept in Drift so a page's
/// application and its cursor advance commit in one transaction.
class SyncCursorStore {
  SyncCursorStore(this._db);

  final AppDatabase _db;

  /// The SharedPreferences key that held the catalog watermark before SC-02.
  static const legacyCatalogPrefKey = 'lastRevision';

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

  /// One-time move of the legacy catalog watermark into stream `catalog`.
  /// The row is written durably before the pref is removed; an existing row
  /// wins (a kill between the two steps leaves both). No pref: no row.
  /// [transaction] runs the row write (default: a plain Drift transaction;
  /// sync passes its binding fence).
  Future<void> migrateLegacyCatalogCursor(
    SharedPreferences prefs, {
    Future<void> Function(Future<void> Function() body)? transaction,
  }) async {
    final legacy = prefs.getInt(legacyCatalogPrefKey);
    if (legacy == null) return;
    await (transaction ?? _db.transaction)(() async {
      final existing = await (_db.select(_db.syncCursors)
            ..where((c) => c.stream.equals(SyncStream.catalog.name)))
          .getSingleOrNull();
      if (existing == null) await write(SyncStream.catalog, legacy);
    });
    await prefs.remove(legacyCatalogPrefKey);
  }
}
