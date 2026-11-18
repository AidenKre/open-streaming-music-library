import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_rank_pagers.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card.dart';
import 'package:frontend/ui/snapshot_paging_controller.dart';

/// Which statistics ranking a "See all" page shows.
enum StatsRankingKind { tracks, artists, albums }

/// A "See all" ranking page's input and presentation state (spec §3 paras
/// 1, 3, 5; SC-10, SC-26): keyset pages of one snapshot.
abstract interface class ListeningRankingControls implements Listenable {
  StatsRankingKind get kind;

  /// The snapshot's range.
  StatsRange get range;

  /// The loaded cards of the current snapshot, in rank order; null until
  /// its first page arrives (or while it failed).
  List<StatsRankedCard>? get cards;

  /// Another page can be loaded.
  bool get hasMore;

  /// The last request failed; [retry] repeats it. Loaded cards stay.
  bool get failed;

  /// The snapshot changed under the ranking: paging stopped; [refresh].
  bool get expired;

  /// Which notice to show: [SnapshotStaleness.fresh] shows none.
  SnapshotStaleness get notice;

  /// Bumped for every new snapshot; the view resets its scroll position.
  int get snapshotEpoch;

  /// Loads the next page (no-op while one is in flight, failed or none is
  /// left).
  void loadMore();

  /// Repeats the failed request once.
  void retry();

  /// Captures a new snapshot of the same range and starts at page 1.
  void refresh();

  /// A track card tap: that single track, through `LibraryActions`.
  Future<PlaybackOutcome> playTrack(TrackUI track);

  void dispose();
}

typedef ListeningRankingFactory =
    ListeningRankingControls Function(
      StatsRankingKind kind,
      HistorySnapshotToken token,
    );

/// Creates a "See all" page's controller over [token] (page-scoped: the
/// page creates it on entry and disposes it on close). Override in tests.
final listeningRankingControllerFactoryProvider =
    Provider<ListeningRankingFactory>(
      (ref) =>
          (kind, token) => ListeningRankingController(ref, kind, token),
    );

/// One page of a ranking, whatever its kind.
typedef _PageResult = SnapshotPageResult<RankedEntry<Object>, Object>;

/// A ranking's two reads: a page of a snapshot, and a new snapshot of the
/// range with its first page (one transaction).
typedef _Fetchers = ({
  Future<_PageResult> Function(HistorySnapshotToken token, Object? after) page,
  Future<(HistorySnapshotToken, _PageResult)> Function() first,
});

_PageResult _toPage<E extends Object, K extends Object>(
  SnapshotPageResult<RankedPageEntry<E, K>, RankCursor<K>> result,
) => switch (result) {
  SnapshotPage(:final items, :final nextCursor) => SnapshotPage(
    <RankedEntry<Object>>[for (final i in items) i.entry],
    nextCursor,
  ),
  SnapshotExpired() => const SnapshotExpired(),
};

_Fetchers _fetcher<E extends Object, K extends Object>(
  SnapshotPager<RankedPageEntry<E, K>, RankCursor<K>> pager,
  StatsRange range,
  Future<
    (
      HistorySnapshotToken,
      SnapshotPageResult<RankedPageEntry<E, K>, RankCursor<K>>,
    )
  >
  Function(StatsRange range, int limit)
  first,
) => (
  page: (token, after) async => _toPage(
    await pager.page(token, after as RankCursor<K>?, rankingPageSize),
  ),
  first: () async {
    final (token, result) = await first(range, rankingPageSize);
    return (token, _toPage(result));
  },
);

class ListeningRankingController
    extends SnapshotPagingController<RankedEntry<Object>, Object>
    implements ListeningRankingControls {
  ListeningRankingController(this._ref, this.kind, HistorySnapshotToken token)
    : range = token.filterKey as StatsRange,
      _fetchers = switch (kind) {
        StatsRankingKind.tracks => _fetcher(
          _ref.read(topTracksPagerProvider),
          token.filterKey as StatsRange,
          _ref.read(topTracksPagerProvider).first,
        ),
        StatsRankingKind.artists => _fetcher(
          _ref.read(topArtistsPagerProvider),
          token.filterKey as StatsRange,
          _ref.read(topArtistsPagerProvider).first,
        ),
        StatsRankingKind.albums => _fetcher(
          _ref.read(topAlbumsPagerProvider),
          token.filterKey as StatsRange,
          _ref.read(topAlbumsPagerProvider).first,
        ),
      } {
    startOn(token);
  }

  final Ref _ref;
  final _Fetchers _fetchers;

  @override
  final StatsRankingKind kind;

  @override
  final StatsRange range;

  StreamSubscription<CurrentStatsEntities>? _watch;

  final List<RankedEntry<Object>> _entries = [];
  List<StatsRankedCard>? _cards;

  /// The last catalog read and how many leading entries it was read for;
  /// later entries are not yet known, so they stay available.
  CurrentStatsEntities? _current;
  int _known = 0;

  @override
  List<StatsRankedCard>? get cards => _cards;

  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) =>
      _ref.read(libraryActionsProvider).playStatsTrack(track);

  @override
  Future<SnapshotPageResult<RankedEntry<Object>, Object>> fetchPage(
    HistorySnapshotToken token,
    Object? after,
  ) => _fetchers.page(token, after);

  @override
  Future<
    (HistorySnapshotToken, SnapshotPageResult<RankedEntry<Object>, Object>?)
  >
  captureSnapshot() => _fetchers.first();

  @override
  Stream<SnapshotStaleness> watchFreshness(HistorySnapshotToken token) => _ref
      .read(snapshotFreshnessProvider)
      .watch(token, kinds: const {HistoryKind.play});

  @override
  void onPage(
    List<RankedEntry<Object>> rows,
    int generation,
    HistorySnapshotToken token,
  ) {
    _entries.addAll(rows);
    _rebuild();
    _watchLoaded();
  }

  @override
  void onExpired() {
    _cards ??= const [];
  }

  @override
  void resetRows() {
    _entries.clear();
    _cards = null;
    _current = null;
    _known = 0;
  }

  void _rebuild() {
    final n = _known;
    _cards = [
      ...rankedCards(_entries.sublist(0, n), _current),
      ...rankedCards(_entries.sublist(n), null, firstRank: n + 1),
    ];
  }

  void _watchLoaded() {
    _watch?.cancel();
    _watch = null;
    if (_entries.isEmpty) return;
    final ids = [for (final e in _entries) e.entity];
    // `_watchLoaded` and `cancelLoaded` cancel the previous watch before it
    // is replaced, and a cancelled subscription delivers nothing
    // (DR-332-STATS-B-01): no staleness check is needed in the listener.
    _watch = _ref
        .read(listeningStatsRepositoryProvider)
        .watchCurrent(
          trackUuids: [for (final e in ids) if (e is TrackUI) e.uuidId],
          artistIds: [for (final e in ids) if (e is ArtistUI) e.id],
          albumIds: [for (final e in ids) if (e is AlbumUI) e.id],
        )
        .listen((current) {
          _current = current;
          _known = _entries.length;
          _rebuild();
          notifyListeners();
        }, onError: (Object _) {});
  }

  @override
  void cancelLoaded() {
    _watch?.cancel();
    _watch = null;
  }
}
