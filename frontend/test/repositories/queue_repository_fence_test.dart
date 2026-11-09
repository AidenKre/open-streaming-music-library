// SC-01 rule 4 / SC-27 5A.0: binding checks for every queue writer.
//
// A QueueRepository belongs to one session scope. It captures the binding
// token (`local_binding_id`) on its first write and every write after that
// runs in a transaction that asserts the row still carries it (D16). A reset
// deletes the row (SC-15 fence), so queue work that outlives the reset is a
// no-op instead of resurrecting a queue in the wiped (or re-bound) store.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

import '../helpers/server_binding.dart';
import '../ui/browse_harness.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(
        uuid: 'a',
        title: 'A',
        artistId: 1,
        artist: 'X',
        albumId: 1,
        album: 'Y',
      ),
      SeedTrack(
        uuid: 'b',
        title: 'B',
        artistId: 1,
        artist: 'X',
        albumId: 1,
        album: 'Y',
      ),
      SeedTrack(
        uuid: 'c',
        title: 'C',
        artistId: 1,
        artist: 'X',
        albumId: 1,
        album: 'Y',
      ),
    ]);
  });

  tearDown(() => db.close());

  /// Every queue table's rows, to prove a refused write changed nothing.
  Future<String> queueTables() async {
    final out = StringBuffer();
    for (final table in [
      'queue_sessions',
      'queue_session_items',
      'queue_session_play_order',
    ]) {
      final rows = await db.customSelect('SELECT * FROM $table').get();
      out.writeln('$table ${rows.map((r) => r.data).toList()}');
    }
    return out.toString();
  }

  Future<int> session(QueueRepository repo) =>
      repo.createSessionFromExplicitList(
        sourceType: 'tracks',
        trackUuids: ['a', 'b', 'c'],
      );

  /// One call per public writer, against [sessionId] (item ids from it).
  Future<Map<String, Future<Object?> Function()>> writers(
    QueueRepository repo,
    int sessionId,
  ) async {
    final items = await repo.getCanonicalItemIds(sessionId);
    return {
      'createSessionFromQuery': () => repo.createSessionFromQuery(
        sourceType: 'album',
        sourceArtistId: 1,
        sourceAlbumId: 1,
        currentUuid: 'a',
      ),
      'createSessionFromExplicitList': () => session(repo),
      'updatePlaybackCursor': () => repo.updatePlaybackCursor(
        sessionId: sessionId,
        currentItemId: items[1],
        positionMs: 42,
      ),
      'updateRepeatMode': () => repo.updateRepeatMode(sessionId, 'all'),
      'updateShuffleEnabled': () => repo.updateShuffleEnabled(sessionId, true),
      'replacePlayOrder': () =>
          repo.replacePlayOrder(sessionId, items.reversed.toList()),
      'rebuildFutureSuffix': () => repo.rebuildFutureSuffix(
        sessionId,
        currentItemId: items[0],
        mainFutureItemIds: [items[2], items[1]],
      ),
      'prependManualItems': () => repo.prependManualItems(sessionId, ['c']),
      'appendManualItems': () => repo.appendManualItems(sessionId, ['c']),
      'removeItem': () => repo.removeItem(sessionId, items[2]),
      'removeTrackUuidsFromQueues': () =>
          repo.removeTrackUuidsFromQueues(['b']),
      'deactivateAll': () => repo.deactivateAll(),
    };
  }

  test('with the binding in place every writer works (control)', () async {
    await seedTestBinding(db);
    final repo = QueueRepository(db);
    final names = (await writers(repo, await session(repo))).keys.toList();
    for (final name in names) {
      // Each writer against a fresh session, so writers don't interact.
      final calls = await writers(repo, await session(repo));
      await expectLater(calls[name]!(), completes, reason: name);
    }
  });

  test(
    'after the reset fence every writer is refused and changes nothing',
    () async {
      await seedTestBinding(db);
      final repo = QueueRepository(db);
      final id = await session(repo);
      final calls = await writers(repo, id);
      await ServerBindingRepository(db).fence();
      final before = await queueTables();
      for (final entry in calls.entries) {
        await expectLater(
          entry.value(),
          throwsA(isA<BindingFencedException>()),
          reason: entry.key,
        );
      }
      expect(await queueTables(), before);
    },
  );

  test(
    'a re-bound store is not written by the old scope\'s repository',
    () async {
      await seedTestBinding(db);
      final old = QueueRepository(db);
      final id = await session(old);
      final calls = await writers(old, id);
      await ServerBindingRepository(db).fence();
      await seedTestBinding(db); // the rebuilt scope's provisional row
      final before = await queueTables();
      for (final entry in calls.entries) {
        await expectLater(
          entry.value(),
          throwsA(isA<BindingFencedException>()),
          reason: entry.key,
        );
      }
      expect(await queueTables(), before);

      // The new scope's repository writes normally.
      await expectLater(session(QueueRepository(db)), completes);
    },
  );

  test('no binding row (no session): the first write is refused', () async {
    final repo = QueueRepository(db);
    await expectLater(session(repo), throwsA(isA<BindingFencedException>()));
    expect(await db.select(db.queueSessions).get(), isEmpty);
  });

  // Audit 5A.0(a) #5: a lane step that outlives the reset must not pin the
  // NEXT session's token on its first write: the scope's repository refuses
  // every write once its scope is disposed.
  test('a disposed scope\'s repository refuses writes', () async {
    await seedTestBinding(db);
    final scope = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    final repo = scope.read(queueRepositoryProvider);
    scope.dispose();
    await ServerBindingRepository(db).fence();
    await seedTestBinding(db); // the next scope's row
    await expectLater(session(repo), throwsA(isA<BindingFencedException>()));
    expect(await db.select(db.queueSessions).get(), isEmpty);
  });
}
