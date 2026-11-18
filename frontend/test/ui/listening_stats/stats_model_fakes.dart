// Hand-released fakes of the model seams the listening-stats controller
// uses: the snapshot service (capture), the statistics repository (load,
// hasListens) and the freshness watcher. Every call is recorded and
// completes only when the test says so, so generation races are scripted.
import 'dart:async';

import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

HistorySnapshotToken tokenFor(
  StatsRange range, {
  int boundary = 42,
  int now = 1800000000000,
  int? attribution,
}) => HistorySnapshotToken(
  boundaryLocalId: boundary,
  historyContentVersion: 0,
  catalogAttributionVersion: attribution,
  capturedNowUtcMs: now,
  filterKey: range,
);

/// A minimal snapshot of [range] with [seconds] of listening.
ListeningStats statsFor(
  StatsRange range, {
  double seconds = 0,
  int now = 1800000000000,
  int boundary = 42,
}) => ListeningStats(
  range: range,
  window: range.resolve(now),
  boundaryLocalId: boundary,
  totals: ListeningTotals(
    listeningSeconds: seconds,
    qualifiedPlays: 0,
    uniqueTracks: 0,
    activeDays: 0,
  ),
  unavailable: const ListeningSubtotal(listeningSeconds: 0, qualifiedPlays: 0),
  futureTimestampCount: 0,
  overlongListenCount: 0,
  buckets: const [],
  chartCapped: false,
  topTracks: const [],
  topArtists: const [],
  topAlbums: const [],
);

class CaptureCall {
  CaptureCall(this.filterKey, {this.attribution = false});
  final Object filterKey;
  final bool attribution;
  final done = Completer<HistorySnapshotToken>();
}

/// One `readPage` call: answered by the test with a page result (or an
/// error). [fetch] is the pager's own fetch, so a test can see which cursor
/// it would read after (through [FakeStatsRepository.rankingCalls]).
class PageReadCall {
  PageReadCall(this.token, this.limit, this.fetch);
  final HistorySnapshotToken token;
  final int limit;
  final Future<List<Object?>> Function(int) fetch;
  final done = Completer<Object>();
}

class FakeSnapshotService implements HistorySnapshotService {
  final captures = <CaptureCall>[];
  final pageReads = <PageReadCall>[];

  @override
  Future<SnapshotPageResult<T, K>> readPage<T, K>(
    HistorySnapshotToken token, {
    required int limit,
    required Future<List<T>> Function(int fetchLimit) fetch,
    required K Function(T item) cursorOf,
  }) {
    final call = PageReadCall(token, limit, (n) => fetch(n));
    pageReads.add(call);
    return call.done.future.then((r) => r as SnapshotPageResult<T, K>);
  }

  @override
  Future<HistorySnapshotToken> capture(
    Object filterKey, {
    bool attribution = false,
  }) {
    final call = CaptureCall(filterKey, attribution: attribution);
    captures.add(call);
    return call.done.future;
  }

  /// The scripted capture, then [read] under its token (the real service
  /// runs both in one read transaction; the scripted calls keep their
  /// order).
  @override
  Future<(HistorySnapshotToken, T)> captureWith<T>(
    Object filterKey,
    Future<T> Function(HistorySnapshotToken token) read, {
    bool attribution = false,
  }) async {
    final token = await capture(filterKey, attribution: attribution);
    return (token, await read(token));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class LoadCall {
  LoadCall(this.range, this.boundary, this.now);
  final StatsRange range;
  final int boundary;
  final int now;
  final done = Completer<ListeningStats>();
}

class HasListensCall {
  HasListensCall(this.boundary);
  final int boundary;
  final done = Completer<bool>();
}

/// One `watchCurrent` subscription: the ids asked for, emitted by the test.
class CurrentWatchCall {
  CurrentWatchCall(this.trackUuids, this.artistIds, this.albumIds) {
    controller = StreamController<CurrentStatsEntities>(
      onCancel: () => cancelled = true,
    );
  }
  final List<String> trackUuids;
  final List<int> artistIds;
  final List<int> albumIds;
  late final StreamController<CurrentStatsEntities> controller;
  bool cancelled = false;

  void emit(CurrentStatsEntities value) {
    if (!controller.isClosed && controller.hasListener) controller.add(value);
  }

  void fail(Object error) {
    if (!controller.isClosed && controller.hasListener) {
      controller.addError(error);
    }
  }
}

class FakeStatsRepository implements ListeningStatsRepository {
  final loads = <LoadCall>[];

  /// Every `watchCurrent` call, in order.
  final currentWatches = <CurrentWatchCall>[];

  /// Every ranking read (`trackRanking` / `artistRanking` / `albumRanking`),
  /// as (kind, after cursor, limit); each answers an empty list.
  final rankingCalls = <(String, Object?, int)>[];

  @override
  Future<List<RankedPageEntry<TrackUI, String>>> trackRanking(
    StatsRange range,
    int boundaryLocalId,
    int capturedNowUtcMs, {
    RankCursor<String>? after,
    required int limit,
  }) async {
    rankingCalls.add(('tracks', after, limit));
    return const [];
  }

  @override
  Future<List<RankedPageEntry<ArtistUI, int>>> artistRanking(
    StatsRange range,
    int boundaryLocalId,
    int capturedNowUtcMs, {
    RankCursor<int>? after,
    required int limit,
  }) async {
    rankingCalls.add(('artists', after, limit));
    return const [];
  }

  @override
  Future<List<RankedPageEntry<AlbumUI, int>>> albumRanking(
    StatsRange range,
    int boundaryLocalId,
    int capturedNowUtcMs, {
    RankCursor<int>? after,
    required int limit,
  }) async {
    rankingCalls.add(('albums', after, limit));
    return const [];
  }

  @override
  Stream<CurrentStatsEntities> watchCurrent({
    List<String> trackUuids = const [],
    List<int> artistIds = const [],
    List<int> albumIds = const [],
  }) {
    final call = CurrentWatchCall(trackUuids, artistIds, albumIds);
    currentWatches.add(call);
    return call.controller.stream;
  }
  final hasListensCalls = <HasListensCall>[];

  /// What [pendingListens] answers (immediately); the boundaries asked.
  int pendingResult = 0;
  final pendingBoundaries = <int>[];

  @override
  Future<int> pendingListens(int boundaryLocalId) {
    pendingBoundaries.add(boundaryLocalId);
    return Future.value(pendingResult);
  }

  @override
  Future<ListeningStats> load(
    StatsRange range,
    int boundaryLocalId,
    int capturedNowUtcMs,
  ) {
    final call = LoadCall(range, boundaryLocalId, capturedNowUtcMs);
    loads.add(call);
    return call.done.future;
  }

  @override
  Future<bool> hasListens(int boundaryLocalId) {
    final call = HasListensCall(boundaryLocalId);
    hasListensCalls.add(call);
    return call.done.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class WatchCall {
  WatchCall(this.token, this.kinds) {
    controller = StreamController<SnapshotStaleness>(
      onCancel: () => cancelled = true,
    );
  }
  final HistorySnapshotToken token;
  final Set<String>? kinds;
  late final StreamController<SnapshotStaleness> controller;
  bool cancelled = false;

  /// Emits even after the subscription was cancelled would be impossible
  /// on a real StreamController, so a late value is modelled by [emit]
  /// before cancellation and by checking the controller ignores it.
  void emit(SnapshotStaleness value) {
    if (!controller.isClosed && controller.hasListener) controller.add(value);
  }
}

class FakeFreshness implements SnapshotFreshness {
  final watches = <WatchCall>[];

  @override
  Stream<SnapshotStaleness> watch(
    HistorySnapshotToken token, {
    Set<String>? kinds,
  }) {
    final call = WatchCall(token, kinds);
    watches.add(call);
    return call.controller.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}
