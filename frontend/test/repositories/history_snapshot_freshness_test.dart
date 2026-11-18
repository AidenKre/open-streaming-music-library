// Phase 6B.3a (SC-10): SnapshotFreshness and the scope-bound providers.
//
//  * watch(token) compares MAX(local_id) and the carried counters against
//    the token: newer local_id -> newActivity (insertion boundary, not
//    occurred_at), counter change -> historyChanged (wins), else fresh.
//  * It compares values, not emissions: every history_events write wakes a
//    local_counters watcher (streamUpdateRules), and unrelated writes must
//    not flip it.
//  * The providers live in the container (no process-global state).
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/clock.dart';

import '../helpers/fake_clock.dart';
import '../helpers/server_binding.dart';
import 'history_snapshot_fixtures.dart';

void main() {
  late AppDatabase db;
  late HistoryRepository history;
  late String token;
  late HistorySnapshotService service;
  late SnapshotFreshness freshness;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db);
    history = HistoryRepository(db);
    service = HistorySnapshotService(db, clock: FakeClock());
    freshness = SnapshotFreshness(db);
  });

  tearDown(() => db.close());

  Future<void> insert(String uuid, {int at = 1000}) =>
      history.insertLocal(token, historyEvent(uuid, at: at));

  /// Subscribes to [t]'s staleness and records every emission.
  Future<List<SnapshotStaleness>> watching(HistorySnapshotToken t) async {
    final seen = <SnapshotStaleness>[];
    final sub = freshness.watch(t).listen(seen.add);
    addTearDown(sub.cancel);
    await pumpEventQueue();
    return seen;
  }

  group('SnapshotFreshness.watch', () {
    // U26-A-15: the documented guard (an empty scope would watch nothing).
    test('an empty kinds set throws ArgumentError', () async {
      final t = await service.capture('k');
      expect(
        () => freshness.watch(t, kinds: const {}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('starts fresh for a current token', () async {
      await insert('a');
      final seen = await watching(await service.capture('k'));
      expect(seen, [SnapshotStaleness.fresh]);
    });

    test('a newer local event is new activity', () async {
      await insert('a', at: 5000);
      final seen = await watching(await service.capture('k'));
      await insert('b', at: 6000);
      await pumpEventQueue();
      expect(seen, [SnapshotStaleness.fresh, SnapshotStaleness.newActivity]);
    });

    test('a pulled event with an old timestamp is new activity', () async {
      await insert('a', at: 5000);
      final seen = await watching(await service.capture('k'));
      await history.applyPage(
        token,
        requestedAfter: 0,
        page: pulledPage([serverEvent(historyEvent('old', at: 10), 1)]),
      );
      await pumpEventQueue();
      expect(seen, [SnapshotStaleness.fresh, SnapshotStaleness.newActivity],
          reason: 'the insertion boundary moved; occurred_at is older');
    });

    test('a history_content bump is history changed, and wins over new activity',
        () async {
      await insert('a', at: 5000);
      final seen = await watching(await service.capture('k'));
      await keepServerVersion(history, token, 'a', at: 4000);
      await pumpEventQueue();
      expect(seen, [SnapshotStaleness.fresh, SnapshotStaleness.historyChanged]);
      await insert('b');
      await pumpEventQueue();
      expect(seen, [SnapshotStaleness.fresh, SnapshotStaleness.historyChanged],
          reason: 'no duplicate or weaker emission after history changed');
    });

    test('new activity then a counter bump moves on to history changed',
        () async {
      await insert('a');
      final seen = await watching(await service.capture('k'));
      await insert('b');
      await pumpEventQueue();
      await keepServerVersion(history, token, 'a', at: 4000);
      await pumpEventQueue();
      expect(seen, [
        SnapshotStaleness.fresh,
        SnapshotStaleness.newActivity,
        SnapshotStaleness.historyChanged,
      ]);
    });

    test('writes that move neither the boundary nor a carried counter do not flip',
        () async {
      await insert('a');
      await insert('b');
      final seen = await watching(await service.capture('k'));
      await history.applyAck(token, ['a'], ['a']);
      await history.recordFailure(token, 'b', reason: 'rejected');
      await history.keepServerVersion(
          token, serverEvent(historyEvent('a', at: 1000), 1)); // same payload
      await SyncCursorStore(db).write(SyncStream.catalog, 42);
      await db.customInsert(
          "INSERT INTO local_counters (key, value) VALUES ('catalog_attribution', 9)",
          updates: {db.localCounters});
      await pumpEventQueue();
      expect(seen, [SnapshotStaleness.fresh]);
    });

    test('a carried catalogAttributionVersion change is history changed',
        () async {
      await db.customStatement(
          "INSERT INTO local_counters (key, value) VALUES ('catalog_attribution', 3)");
      final c = await service.capture('k');
      final seen = await watching(HistorySnapshotToken(
        boundaryLocalId: c.boundaryLocalId,
        historyContentVersion: c.historyContentVersion,
        catalogAttributionVersion: 3,
        capturedNowUtcMs: c.capturedNowUtcMs,
        filterKey: 'k',
      ));
      // A notifying write (Phase 9's writers will be trigger-driven with
      // their own propagation rule; a bare customStatement notifies nothing).
      await db.customUpdate(
          "UPDATE local_counters SET value = 4 WHERE key = 'catalog_attribution'",
          updates: {db.localCounters});
      await pumpEventQueue();
      expect(seen, [SnapshotStaleness.fresh, SnapshotStaleness.historyChanged]);
    });

    test('a token already behind reports it on the first emission', () async {
      final t = await service.capture('k');
      await insert('a');
      expect(await watching(t), [SnapshotStaleness.newActivity]);
    });
  });

  // 6-R1-02 / DEV-6-04 (refines SC-10): a surface can scope the insertion
  // boundary to the history kinds it shows; counters stay global.
  group('SnapshotFreshness.watch with a kind scope', () {
    Future<void> insertKind(String uuid, String kind, {int at = 1000}) =>
        history.insertLocal(token, historyEvent(uuid, kind: kind, at: at));

    Future<List<SnapshotStaleness>> watchingKinds(
        HistorySnapshotToken t, Set<String> kinds) async {
      final seen = <SnapshotStaleness>[];
      final sub = freshness.watch(t, kinds: kinds).listen(seen.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      return seen;
    }

    test('a new local event of another kind leaves the scope fresh',
        () async {
      await insertKind('a', 'clicked');
      final seen =
          await watchingKinds(await service.capture('k'), {'clicked'});
      await insertKind('p', 'play', at: 9000);
      await pumpEventQueue();
      expect(seen, [SnapshotStaleness.fresh]);
    });

    test('a pulled event of another kind leaves the scope fresh', () async {
      await insertKind('a', 'clicked');
      final seen =
          await watchingKinds(await service.capture('k'), {'clicked'});
      await history.applyPage(
        token,
        requestedAfter: 0,
        page: pulledPage([serverEvent(historyEvent('old', at: 10), 1)]),
      );
      await pumpEventQueue();
      expect(seen, [SnapshotStaleness.fresh]);
    });

    test('a new event of a watched kind is new activity, even pulled with an '
        'old timestamp', () async {
      await insertKind('a', 'clicked', at: 5000);
      final t = await service.capture('k');
      final seen = await watchingKinds(t, {'clicked'});
      await history.applyPage(
        token,
        requestedAfter: 0,
        page: pulledPage([
          serverEvent(historyEvent('old', kind: 'clicked', at: 10), 1),
        ]),
      );
      await pumpEventQueue();
      expect(seen, [SnapshotStaleness.fresh, SnapshotStaleness.newActivity]);
    });

    test('a watched event already present at capture is not new activity, '
        'with newer events of other kinds before it', () async {
      await insertKind('a', 'clicked');
      await insertKind('p', 'play');
      final seen =
          await watchingKinds(await service.capture('k'), {'clicked'});
      expect(seen, [SnapshotStaleness.fresh]);
    });

    test('a counter bump is still history changed under a scope', () async {
      await insertKind('a', 'clicked');
      await insertKind('p', 'play', at: 5000);
      final seen =
          await watchingKinds(await service.capture('k'), {'clicked'});
      await keepServerVersion(history, token, 'p', at: 4000);
      await pumpEventQueue();
      expect(seen, [SnapshotStaleness.fresh, SnapshotStaleness.historyChanged]);
    });

    test('several kinds: a new event of any of them counts', () async {
      await insertKind('a', 'clicked');
      final seen = await watchingKinds(
          await service.capture('k'), {'clicked', 'play'});
      await insertKind('p', 'play');
      await pumpEventQueue();
      expect(seen, [SnapshotStaleness.fresh, SnapshotStaleness.newActivity]);
    });

    test('unscoped, every kind still counts (unchanged)', () async {
      await insertKind('a', 'clicked');
      final seen = await watching(await service.capture('k'));
      await insertKind('p', 'play');
      await pumpEventQueue();
      expect(seen, [SnapshotStaleness.fresh, SnapshotStaleness.newActivity]);
    });
  });

  group('providers', () {
    late ProviderContainer container;
    late FakeClock clock;

    setUp(() {
      clock = FakeClock(startUtcMs: 1234);
      container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
      ]);
      addTearDown(container.dispose);
    });

    test('capture reads the scope clock', () async {
      final t = await container.read(historySnapshotServiceProvider).capture('k');
      expect(t.capturedNowUtcMs, 1234);
    });

    test('each scope builds its own service', () async {
      final other = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FakeClock(startUtcMs: 99)),
      ]);
      addTearDown(other.dispose);
      expect(
        identical(container.read(historySnapshotServiceProvider),
            other.read(historySnapshotServiceProvider)),
        isFalse,
      );
      expect((await other.read(historySnapshotServiceProvider).capture('k'))
          .capturedNowUtcMs, 99);
    });
  });
}
