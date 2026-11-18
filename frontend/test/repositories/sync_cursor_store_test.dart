// SC-02: Drift sync-cursor store.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';

void main() {
  late AppDatabase db;
  late SyncCursorStore store;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = SyncCursorStore(db);
  });

  tearDown(() => db.close());

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
}
