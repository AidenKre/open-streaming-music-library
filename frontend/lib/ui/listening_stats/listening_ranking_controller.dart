import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

/// One page of a ranking, whatever its kind; null when the snapshot expired.
typedef _Page = ({List<RankedEntry<Object>> entries, Object? next});

typedef _PageFetch =
    Future<_Page?> Function(HistorySnapshotToken token, Object? after);

/// A new snapshot of the range and its first page.
typedef _FirstFetch = Future<(HistorySnapshotToken, _Page?)> Function();

_Page? _toPage<E extends Object, K extends Object>(
  SnapshotPageResult<RankedPageEntry<E, K>, RankCursor<K>> result,
) => switch (result) {
  SnapshotPage(:final items, :final nextCursor) => (
    entries: <RankedEntry<Object>>[for (final i in items) i.entry],
    next: nextCursor,
  ),
  SnapshotExpired() => null,
};

(_PageFetch, _FirstFetch) _fetcher<E extends Object, K extends Object>(
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
  (token, after) async => _toPage(
    await pager.page(token, after as RankCursor<K>?, rankingPageSize),
  ),
  () async {
    final (token, result) = await first(range, rankingPageSize);
    return (token, _toPage(result));
  },
);

class ListeningRankingController extends ChangeNotifier
    implements ListeningRankingControls {
  ListeningRankingController(this._ref, this.kind, HistorySnapshotToken token)
    : _token = token,
      range = token.filterKey as StatsRange,
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
    _loadPage(_generation, token, null);
  }

  final Ref _ref;
  final (_PageFetch, _FirstFetch) _fetchers;
  _PageFetch get _fetch => _fetchers.$1;

  @override
  final StatsRankingKind kind;

  @override
  final StatsRange range;

  StreamSubscription<CurrentStatsEntities>? _watch;
  StreamSubscription<SnapshotStaleness>? _freshness;

  /// Bumped by every new snapshot and by dispose; stale continuations return.
  int _generation = 0;
  bool _disposed = false;

  HistorySnapshotToken _token;
  final List<RankedEntry<Object>> _entries = [];
  List<StatsRankedCard>? _cards;

  /// The last catalog read and how many leading entries it was read for;
  /// later entries are not yet known, so they stay available.
  CurrentStatsEntities? _current;
  int _known = 0;
  Object? _cursor;
  bool _hasMore = false;
  bool _failed = false;
  bool _inFlight = false;
  bool _expired = false;
  SnapshotStaleness _notice = SnapshotStaleness.fresh;
  void Function()? _retry;

  @override
  List<StatsRankedCard>? get cards => _cards;

  @override
  bool get hasMore => _hasMore;

  @override
  bool get failed => _failed;

  @override
  bool get expired => _expired;

  @override
  SnapshotStaleness get notice => _notice;

  @override
  int get snapshotEpoch => _generation;

  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) =>
      _ref.read(libraryActionsProvider).playStatsTrack(track);

  @override
  void loadMore() {
    if (!_hasMore || _inFlight || _failed || _expired || _disposed) return;
    _loadPage(_generation, _token, _cursor);
  }

  @override
  void retry() {
    final again = _retry;
    if (_disposed || !_failed || again == null) return;
    _failed = false;
    _retry = null;
    notifyListeners();
    again();
  }

  @override
  void refresh() {
    if (_disposed) return;
    final generation = ++_generation;
    _cancelLive();
    _entries.clear();
    _cards = null;
    _current = null;
    _known = 0;
    _cursor = null;
    _hasMore = false;
    _failed = false;
    _expired = false;
    _inFlight = false;
    _notice = SnapshotStaleness.fresh;
    _retry = null;
    notifyListeners();
    _capture(generation);
  }

  void _capture(int generation) {
    _inFlight = true;
    _fetchers.$2().then(
      (first) {
        if (_stale(generation)) return;
        _token = first.$1;
        _show(generation, first.$1, first.$2);
      },
      onError: (Object _) {
        if (_stale(generation)) return;
        _fail(() => _capture(generation));
      },
    );
  }

  void _loadPage(int generation, HistorySnapshotToken token, Object? after) {
    _inFlight = true;
    _fetch(token, after).then(
      (page) {
        if (_stale(generation)) return;
        _show(generation, token, page);
      },
      onError: (Object _) {
        if (_stale(generation)) return;
        _fail(() => _loadPage(generation, token, after));
      },
    );
  }

  /// Takes a fetched page (null: the snapshot expired).
  void _show(int generation, HistorySnapshotToken token, _Page? page) {
    _inFlight = false;
    if (page == null) {
      _cards ??= const [];
      _hasMore = false;
      _expired = true;
      _notice = SnapshotStaleness.historyChanged;
    } else {
      _entries.addAll(page.entries);
      _cursor = page.next;
      _hasMore = page.next != null;
      _rebuild();
      _startFreshness(generation, token);
      _watchLoaded();
    }
    notifyListeners();
  }

  void _rebuild() {
    final n = _known;
    _cards = [
      ...rankedCards(_entries.sublist(0, n), _current),
      ...rankedCards(_entries.sublist(n), null, firstRank: n + 1),
    ];
  }

  void _startFreshness(int generation, HistorySnapshotToken token) {
    if (_freshness != null) return;
    _freshness = _ref
        .read(snapshotFreshnessProvider)
        .watch(token, kinds: const {'play'})
        .listen((value) {
          if (_stale(generation) || _expired || value == _notice) return;
          _notice = value;
          notifyListeners();
        }, onError: (Object _) {});
  }

  void _watchLoaded() {
    _watch?.cancel();
    _watch = null;
    if (_entries.isEmpty) return;
    final ids = [for (final e in _entries) e.entity];
    // `_watchLoaded` and `_cancelLive` cancel the previous watch before it
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

  void _fail(void Function() again) {
    _inFlight = false;
    _failed = true;
    _retry = again;
    notifyListeners();
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  void _cancelLive() {
    _watch?.cancel();
    _freshness?.cancel();
    _watch = null;
    _freshness = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _cancelLive();
    super.dispose();
  }
}
