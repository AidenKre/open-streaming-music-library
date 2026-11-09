// SC-02: Drift sync-cursor store, and the one-time move of the catalog
// watermark out of SharedPreferences (`lastRevision`) into stream `catalog`
// (5-T20 unit form). The row is written durably before the pref is removed;
// a kill in between leaves both, and the row wins on the next run.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppDatabase db;
  late SyncCursorStore store;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = SyncCursorStore(db);
  });

  tearDown(() => db.close());

  Future<SharedPreferences> prefs(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('an unknown stream reads 0', () async {
    expect(await store.read(SyncStream.catalog), 0);
  });

  test('write then read, per stream', () async {
    await db.transaction(() => store.write(SyncStream.catalog, 42));
    await db.transaction(() => store.write(SyncStream.history, 7));
    expect(await store.read(SyncStream.catalog), 42);
    expect(await store.read(SyncStream.history), 7);
    await db.transaction(() => store.write(SyncStream.catalog, 43));
    expect(await store.read(SyncStream.catalog), 43);
  });

  test('write rolls back with its transaction', () async {
    await expectLater(
      db.transaction(() async {
        await store.write(SyncStream.catalog, 42);
        throw StateError('page apply failed');
      }),
      throwsStateError,
    );
    expect(await store.read(SyncStream.catalog), 0);
  });

  group('legacy catalog watermark', () {
    test('moves lastRevision into the catalog row, then removes the pref',
        () async {
      final p = await prefs({'lastRevision': 42, 'other': 'kept'});
      await store.migrateLegacyCatalogCursor(p);
      expect(await store.read(SyncStream.catalog), 42);
      expect(p.containsKey('lastRevision'), isFalse);
      expect(p.getString('other'), 'kept');
    });

    test('a row written before a kill wins over the leftover pref', () async {
      await db.transaction(() => store.write(SyncStream.catalog, 50));
      final p = await prefs({'lastRevision': 42});
      await store.migrateLegacyCatalogCursor(p);
      expect(await store.read(SyncStream.catalog), 50);
      expect(p.containsKey('lastRevision'), isFalse);
    });

    test('no pref: no row is created', () async {
      final p = await prefs({});
      await store.migrateLegacyCatalogCursor(p);
      final rows = await db.customSelect('SELECT * FROM sync_cursors').get();
      expect(rows, isEmpty);
      expect(await store.read(SyncStream.catalog), 0);
    });

    test('running it twice is harmless', () async {
      final p = await prefs({'lastRevision': 42});
      await store.migrateLegacyCatalogCursor(p);
      await store.migrateLegacyCatalogCursor(p);
      expect(await store.read(SyncStream.catalog), 42);
    });

    test('the pref survives when the durable write fails', () async {
      final p = await prefs({'lastRevision': 42});
      // Open the database first: drift silently reopens a never-opened
      // in-memory database after close(), which would hide the failure.
      await store.read(SyncStream.catalog);
      await db.close();
      await expectLater(store.migrateLegacyCatalogCursor(p), throwsA(anything));
      expect(p.getInt('lastRevision'), 42);
      db = AppDatabase(NativeDatabase.memory()); // for tearDown
    });
  });
}
