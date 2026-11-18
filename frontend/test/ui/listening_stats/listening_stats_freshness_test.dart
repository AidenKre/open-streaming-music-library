// Phase 9A.2a (spec §3 para 3; SC-10): once a snapshot is shown the
// controller watches it with `SnapshotFreshness.watch(token, kinds:
// {'play'})`. New play events raise "new listening activity", a changed
// counter raises "history changed"; neither replaces, reloads or reorders
// what is shown: only Refresh does. A replaced snapshot's watch is
// cancelled and its values are ignored.
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
  });

  tearDown(() {
    c.dispose();
    container.dispose();
  });

  Future<void> settle() => pumpEventQueue();

  /// Completes the latest capture, load and history check.
  Future<HistorySnapshotToken> showLatest({int boundary = 42}) async {
    final cap = snapshots.captures.last;
    final token = tokenFor(cap.filterKey as StatsRange, boundary: boundary);
    cap.done.complete(token);
    await settle();
    repo.loads.last.done.complete(statsFor(cap.filterKey as StatsRange));
    repo.hasListensCalls.last.done.complete(true);
    await settle();
    return token;
  }

  // 9A.1b review F1 (spec §3 para 1: the token has every field filled):
  // the stats token carries the catalog_attribution counter, so a catalog
  // change (rename, tombstone) reaches the history-changed notice.
  test('every snapshot is captured with the catalog attribution counter',
      () async {
    expect(snapshots.captures.single.attribution, isTrue);
    await showLatest();
    c.refresh();
    c.setRange(StatsRange.allTime);
    expect(snapshots.captures.map((s) => s.attribution), everyElement(isTrue));
  });

  test('a shown snapshot is watched for new plays with its own token',
      () async {
    expect(freshness.watches, isEmpty, reason: 'nothing shown yet');
    final token = await showLatest(boundary: 9);
    expect(freshness.watches, hasLength(1));
    expect(freshness.watches.single.token, token);
    expect(freshness.watches.single.kinds, {'play'});
  });

  test('new plays raise the notice and leave the shown snapshot as it is',
      () async {
    await showLatest();
    final shown = c.state;
    var notified = 0;
    c.addListener(() => notified++);
    freshness.watches.single.emit(SnapshotStaleness.newActivity);
    await settle();
    expect(c.notice, SnapshotStaleness.newActivity);
    expect(identical(c.state, shown), isTrue);
    expect(notified, 1);
    expect(snapshots.captures, hasLength(1), reason: 'no automatic reload');
    expect(repo.loads, hasLength(1));
  });

  test('a changed history counter raises the history-changed notice',
      () async {
    await showLatest();
    final shown = c.state;
    freshness.watches.single.emit(SnapshotStaleness.historyChanged);
    await settle();
    expect(c.notice, SnapshotStaleness.historyChanged);
    expect(identical(c.state, shown), isTrue);
  });

  test('refresh clears the notice, cancels the old watch and ignores it',
      () async {
    await showLatest();
    final old = freshness.watches.single;
    old.emit(SnapshotStaleness.newActivity);
    await settle();
    c.refresh();
    expect(c.notice, SnapshotStaleness.fresh);
    expect(old.cancelled, isTrue);
    await showLatest(boundary: 50);
    expect(freshness.watches, hasLength(2));
    expect(freshness.watches.last.token.boundaryLocalId, 50);
    expect(c.notice, SnapshotStaleness.fresh);
  });

  test('a range change cancels the shown snapshot\'s watch', () async {
    await showLatest();
    final old = freshness.watches.single;
    c.setRange(StatsRange.allTime);
    expect(old.cancelled, isTrue);
    expect(c.notice, SnapshotStaleness.fresh);
  });

  test('dispose cancels the watch', () async {
    await showLatest();
    final old = freshness.watches.single;
    c.dispose();
    expect(old.cancelled, isTrue);
  });

  test('a freshness error leaves the notice as it was', () async {
    await showLatest();
    final w = freshness.watches.single;
    w.emit(SnapshotStaleness.newActivity);
    await settle();
    w.controller.addError(StateError('db'));
    await settle();
    expect(c.notice, SnapshotStaleness.newActivity);
    expect(c.state, isA<StatsReady>());
  });

  test('a watch is not started for a failed snapshot', () async {
    snapshots.captures.last.done.completeError(StateError('db'));
    await settle();
    expect(c.state, isA<StatsFailed>());
    expect(freshness.watches, isEmpty);
  });
}
