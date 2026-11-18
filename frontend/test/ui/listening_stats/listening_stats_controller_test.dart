// Phase 9A.2a (spec §3 paras 3–4; SC-10, SC-20, SC-26; review 9-U04
// "range change/late-result generation"): the statistics page controller
// against hand-released model fakes.
//
//  * Each snapshot captures one token for the range, then loads with that
//    token's boundary and captured now (never a clock of its own).
//  * Three distinct results: ready with history, ready without any history,
//    failed (range kept, Retry repeats it).
//  * Every range change, refresh, retry and dispose starts a new
//    generation; a capture, load or hasListens result of an older one is
//    dropped.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';

import 'stats_model_fakes.dart';

void main() {
  late FakeSnapshotService snapshots;
  late FakeStatsRepository repo;
  late FakeFreshness freshness;
  late ProviderContainer container;
  late ListeningStatsControls c;
  late int notifications;

  setUp(() {
    snapshots = FakeSnapshotService();
    repo = FakeStatsRepository();
    freshness = FakeFreshness();
    container = ProviderContainer(
      overrides: [
        historySnapshotServiceProvider.overrideWithValue(snapshots),
        listeningStatsRepositoryProvider.overrideWithValue(repo),
        snapshotFreshnessProvider.overrideWithValue(freshness),
      ],
    );
    c = container.read(listeningStatsControllerFactoryProvider)();
    notifications = 0;
    c.addListener(() => notifications++);
  });

  tearDown(() {
    c.dispose();
    container.dispose();
  });

  /// Lets completed futures deliver.
  Future<void> settle() => pumpEventQueue();

  /// Completes capture [i] with a token, then load and hasListens.
  Future<ListeningStats> complete(
    int i, {
    bool hasListens = true,
    int boundary = 42,
    int now = 1800000000000,
  }) async {
    final cap = snapshots.captures[i];
    final range = cap.filterKey as StatsRange;
    cap.done.complete(tokenFor(range, boundary: boundary, now: now));
    await settle();
    final stats = statsFor(range, now: now, boundary: boundary);
    repo.loads.last.done.complete(stats);
    repo.hasListensCalls.last.done.complete(hasListens);
    await settle();
    return stats;
  }

  group('entry', () {
    test('starts loading the 7-day range (DEV-9-15 item 9), with the four presets', () {
      expect(c.ranges, [
        StatsRange.last7Days,
        StatsRange.last30Days,
        StatsRange.thisUtcYear,
        StatsRange.allTime,
      ]);
      expect(c.range, StatsRange.last7Days);
      expect(c.state, isA<StatsLoading>());
      expect(c.notice, SnapshotStaleness.fresh);
      expect(snapshots.captures, hasLength(1));
      expect(snapshots.captures.single.filterKey, StatsRange.last7Days);
      expect(repo.loads, isEmpty, reason: 'load waits for the token');
    });

    test('loads with the token\'s boundary and captured now', () async {
      snapshots.captures.single.done.complete(
        tokenFor(StatsRange.last7Days, boundary: 77, now: 1234567),
      );
      await settle();
      expect(repo.loads, hasLength(1));
      final load = repo.loads.single;
      expect(load.range, StatsRange.last7Days);
      expect(load.boundary, 77);
      expect(load.now, 1234567);
      expect(repo.hasListensCalls.single.boundary, 77);
    });

    test('ready with history carries the loaded snapshot itself', () async {
      final stats = await complete(0);
      final state = c.state;
      expect(state, isA<StatsReady>());
      state as StatsReady;
      expect(identical(state.stats, stats), isTrue);
      expect(state.hasHistory, isTrue);
      expect(notifications, greaterThan(0));
    });

    test('ready carries the snapshot\'s pending listens, counted at the '
        'token\'s boundary (review r1 F2)', () async {
      repo.pendingResult = 4;
      await complete(0, boundary: 77);
      expect((c.state as StatsReady).pendingListens, 4);
      expect(repo.pendingBoundaries, [77]);
    });

    test('ready without any history says so (the empty state)', () async {
      await complete(0, hasListens: false);
      final state = c.state as StatsReady;
      expect(state.hasHistory, isFalse);
    });

    test('a failed capture is an error, not zeros, and keeps the range',
        () async {
      c.setRange(StatsRange.allTime);
      snapshots.captures.last.done.completeError(StateError('db'));
      await settle();
      expect(c.state, isA<StatsFailed>());
      expect(c.range, StatsRange.allTime);
    });

    test('a failed load is an error', () async {
      snapshots.captures.single.done.complete(tokenFor(StatsRange.last7Days));
      await settle();
      repo.loads.single.done.completeError(StateError('db'));
      repo.hasListensCalls.single.done.complete(true);
      await settle();
      expect(c.state, isA<StatsFailed>());
    });

    test('a failed history check is an error', () async {
      snapshots.captures.single.done.complete(tokenFor(StatsRange.last7Days));
      await settle();
      repo.loads.single.done.complete(statsFor(StatsRange.last7Days));
      repo.hasListensCalls.single.done.completeError(StateError('db'));
      await settle();
      expect(c.state, isA<StatsFailed>());
    });

    test('retry after a failure reloads the same range', () async {
      c.setRange(StatsRange.thisUtcYear);
      snapshots.captures.last.done.completeError(StateError('db'));
      await settle();
      c.retry();
      expect(c.state, isA<StatsLoading>());
      expect(c.range, StatsRange.thisUtcYear);
      expect(snapshots.captures.last.filterKey, StatsRange.thisUtcYear);
      await complete(snapshots.captures.length - 1);
      expect(c.state, isA<StatsReady>());
      expect((c.state as StatsReady).stats.range, StatsRange.thisUtcYear);
    });

    test('retry without a failure does nothing', () async {
      await complete(0);
      final before = snapshots.captures.length;
      c.retry();
      expect(snapshots.captures, hasLength(before));
      expect(c.state, isA<StatsReady>());
    });

    test('choosing the range already shown does nothing', () async {
      await complete(0);
      c.setRange(StatsRange.last7Days);
      expect(snapshots.captures, hasLength(1));
      expect(c.state, isA<StatsReady>());
    });

    test('refresh captures a new snapshot of the same range', () async {
      await complete(0);
      c.refresh();
      expect(c.state, isA<StatsLoading>());
      expect(snapshots.captures, hasLength(2));
      expect(snapshots.captures.last.filterKey, StatsRange.last7Days);
    });
  });

  group('generations', () {
    test('a range change while capturing drops the old capture', () async {
      c.setRange(StatsRange.last30Days);
      expect(c.range, StatsRange.last30Days);
      expect(c.state, isA<StatsLoading>());
      expect(snapshots.captures.last.filterKey, StatsRange.last30Days);
      // The old capture lands late. Since 9-R1-09 its reads run inside the
      // capture's own transaction, so they may run; their result is dropped.
      snapshots.captures[0].done.complete(tokenFor(StatsRange.last7Days));
      await settle();
      final oldLoad = repo.loads.single;
      final oldHas = repo.hasListensCalls.single;
      expect(oldLoad.range, StatsRange.last7Days);
      oldLoad.done.complete(statsFor(StatsRange.last7Days, seconds: 99));
      oldHas.done.complete(true);
      await settle();
      expect(c.state, isA<StatsLoading>(), reason: 'the stale result is dropped');
      await complete(1);
      expect((c.state as StatsReady).stats.range, StatsRange.last30Days);
      expect(repo.loads.last.range, StatsRange.last30Days);
    });

    test('a range change while loading drops the old load', () async {
      snapshots.captures[0].done.complete(tokenFor(StatsRange.last7Days));
      await settle();
      final oldLoad = repo.loads.single;
      final oldHas = repo.hasListensCalls.single;
      c.setRange(StatsRange.allTime);
      await complete(1);
      expect((c.state as StatsReady).stats.range, StatsRange.allTime);
      // The overtaken 7-day load lands after the all-time one.
      oldLoad.done.complete(statsFor(StatsRange.last7Days, seconds: 99));
      oldHas.done.complete(false);
      await settle();
      final state = c.state as StatsReady;
      expect(state.stats.range, StatsRange.allTime);
      expect(state.hasHistory, isTrue);
    });

    test('an overtaken load failing late does not fail the new one',
        () async {
      snapshots.captures[0].done.complete(tokenFor(StatsRange.last7Days));
      await settle();
      final oldLoad = repo.loads.single;
      final oldHas = repo.hasListensCalls.single;
      c.setRange(StatsRange.last30Days);
      await complete(1);
      oldLoad.done.completeError(StateError('late'));
      oldHas.done.completeError(StateError('late'));
      await settle();
      expect(c.state, isA<StatsReady>());
    });

    test('an overtaken load landing while the new one is still loading is '
        'not shown', () async {
      snapshots.captures[0].done.complete(tokenFor(StatsRange.last7Days));
      await settle();
      final oldLoad = repo.loads.single;
      final oldHas = repo.hasListensCalls.single;
      c.refresh();
      oldLoad.done.complete(statsFor(StatsRange.last7Days));
      oldHas.done.complete(true);
      await settle();
      expect(c.state, isA<StatsLoading>());
    });

    test('a retry overtakes the failed generation', () async {
      snapshots.captures[0].done.complete(tokenFor(StatsRange.last7Days));
      await settle();
      final firstHas = repo.hasListensCalls.single;
      repo.loads.single.done.completeError(StateError('db'));
      await settle();
      expect(c.state, isA<StatsFailed>());
      c.retry();
      // The failed generation's other half lands after the retry started.
      firstHas.done.complete(false);
      await settle();
      expect(c.state, isA<StatsLoading>());
      await complete(1);
      expect((c.state as StatsReady).hasHistory, isTrue);
    });

    test('results after dispose change nothing and notify nobody', () async {
      final local = container.read(listeningStatsControllerFactoryProvider)();
      var calls = 0;
      local.addListener(() => calls++);
      final cap = snapshots.captures.last;
      local.dispose();
      cap.done.complete(tokenFor(StatsRange.last7Days));
      await settle();
      // Since 9-R1-09 the reads run inside the capture's transaction; what
      // they return is dropped and nobody is notified.
      for (final l in repo.loads.where((l) => !l.done.isCompleted)) {
        l.done.complete(statsFor(l.range));
      }
      for (final h in repo.hasListensCalls.where((h) => !h.done.isCompleted)) {
        h.done.complete(true);
      }
      await settle();
      expect(calls, 0);
    });
  });
}
