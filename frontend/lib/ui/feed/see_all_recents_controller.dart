import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/recently_played_repository.dart';
import 'package:frontend/repositories/recents_snapshot_pager.dart';
import 'package:frontend/ui/browse_filter_controller.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/feed/feed.dart';

/// See all's input and presentation state (Phase 6 §3 See all, §7; SC-09,
/// SC-10, SC-26).
abstract interface class SeeAllRecentsControls implements Listenable {
  /// See all's own Downloaded chip (`manual`), seeded from Home's value.
  BrowseFilters get filters;

  /// The user tapped the chip: an explicit refresh.
  void setDownloaded(bool value);

  /// The loaded rows of the current snapshot, in snapshot order; null until
  /// its first page arrives.
  List<FeedEntity>? get entities;

  /// Another page can be loaded.
  bool get hasMore;

  /// The last page request failed; [retry] repeats it. Loaded rows stay.
  bool get failed;

  /// Which notice to show: [SnapshotStaleness.fresh] shows none.
  SnapshotStaleness get notice;

  /// Bumped for every new snapshot (entry, Refresh, chip change); the view
  /// resets its scroll position when it changes.
  int get snapshotEpoch;

  /// Loads the next page (no-op while one is in flight or none is left).
  void loadMore();

  /// Repeats the failed request.
  void retry();

  /// Captures a new snapshot.
  void refresh();

  /// A track card tap: a new single-track queue and one track click.
  Future<PlaybackOutcome> playTrack(TrackUI track);

  void dispose();
}

typedef SeeAllRecentsFactory =
    SeeAllRecentsControls Function({required bool initialDownloaded});

/// Creates the See all page's controller (page-scoped: the page creates it
/// on entry and disposes it on close). Override in tests.
final seeAllRecentsControllerFactoryProvider = Provider<SeeAllRecentsFactory>(
  (ref) =>
      ({required initialDownloaded}) =>
          SeeAllRecentsController(ref, initialDownloaded: initialDownloaded),
);

class SeeAllRecentsController extends ChangeNotifier
    implements SeeAllRecentsControls {
  static const _pageSize = 50;

  SeeAllRecentsController(this._ref, {required bool initialDownloaded}) {
    _filters = _ref.read(browseFilterControllerFactoryProvider)(
      policy: OfflineFilterPolicy.manual,
      initial: initialDownloaded,
    );
    _filters.addListener(refresh);
    refresh();
  }

  final Ref _ref;
  late final BrowseFilterControls _filters;
  late final RecentsSnapshotPager _pager = _ref.read(
    recentsSnapshotPagerProvider,
  );
  StreamSubscription<List<ResolvedRecent>>? _watch;
  StreamSubscription<SnapshotStaleness>? _freshness;

  /// Bumped by every new snapshot and by dispose; stale continuations return.
  int _generation = 0;
  bool _disposed = false;

  HistorySnapshotToken? _token;
  List<ResolvedRecent>? _rows;
  List<FeedEntity>? _entities;
  RecentRef? _cursor;
  bool _hasMore = false;
  bool _failed = false;
  bool _inFlight = false;
  bool _expired = false;
  SnapshotStaleness _notice = SnapshotStaleness.fresh;
  void Function()? _retry;

  @override
  BrowseFilters get filters => _filters.filters;

  @override
  void setDownloaded(bool value) => _filters.setDownloaded(value);

  @override
  List<FeedEntity>? get entities => _entities;

  @override
  bool get hasMore => _hasMore;

  @override
  bool get failed => _failed;

  @override
  SnapshotStaleness get notice => _notice;

  @override
  int get snapshotEpoch => _generation;

  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) =>
      _ref.read(libraryActionsProvider).playRecentTrack(track);

  @override
  void refresh() {
    if (_disposed) return;
    final generation = ++_generation;
    _cancelLive();
    _token = null;
    _rows = null;
    _entities = null;
    _cursor = null;
    _hasMore = false;
    _failed = false;
    _expired = false;
    _notice = SnapshotStaleness.fresh;
    _retry = null;
    notifyListeners();
    _capture(generation);
  }

  @override
  void loadMore() {
    final token = _token;
    if (token == null || !_hasMore || _inFlight || _failed) return;
    _loadPage(_generation, token, _cursor);
  }

  @override
  void retry() {
    final again = _retry;
    if (!_failed || again == null) return;
    _failed = false;
    _retry = null;
    notifyListeners();
    again();
  }

  void _capture(int generation) {
    _inFlight = true;
    _pager
        .capture(downloadedOnly: filters.downloaded)
        .then(
          (token) {
            if (_stale(generation)) return;
            _token = token;
            _freshness = _pager
                .watchFreshness(token)
                .listen(
                  (value) => _onFreshness(generation, value),
                  // A failed freshness check leaves the notice as it was.
                  onError: (Object _) {},
                );
            _loadPage(generation, token, null);
          },
          onError: (Object _) {
            if (_stale(generation)) return;
            _fail(() => _capture(generation));
          },
        );
  }

  void _loadPage(int generation, HistorySnapshotToken token, RecentRef? after) {
    _inFlight = true;
    _pager
        .page(token, after, _pageSize)
        .then(
          (result) {
            if (_stale(generation)) return;
            _inFlight = false;
            switch (result) {
              case SnapshotPage(:final items, :final nextCursor, :final hasMore):
                _rows = [...?_rows, ...items];
                _entities = _toEntities(_rows!);
                _cursor = nextCursor;
                _hasMore = hasMore;
                _watchLoaded(generation, token);
              case SnapshotExpired():
                _rows ??= const [];
                _entities ??= const [];
                _hasMore = false;
                _expired = true;
                _notice = SnapshotStaleness.historyChanged;
            }
            notifyListeners();
          },
          onError: (Object _) {
            if (_stale(generation)) return;
            _fail(() => _loadPage(generation, token, after));
          },
        );
  }

  void _watchLoaded(int generation, HistorySnapshotToken token) {
    _watch?.cancel();
    late final StreamSubscription<List<ResolvedRecent>> sub;
    final refs = [for (final r in _rows!) r.ref];
    sub = _pager.watchLoaded(token, refs).listen((rows) {
      // Emissions of a replaced watch are ignored even if they arrive.
      if (_stale(generation) || !identical(_watch, sub)) return;
      _rows = rows;
      _entities = _toEntities(rows);
      notifyListeners();
    }, onError: (Object _) {});
    _watch = sub;
  }

  void _onFreshness(int generation, SnapshotStaleness value) {
    if (_stale(generation) || _expired || value == _notice) return;
    _notice = value;
    notifyListeners();
  }

  void _fail(void Function() again) {
    _inFlight = false;
    _failed = true;
    _retry = again;
    notifyListeners();
  }

  List<FeedEntity> _toEntities(List<ResolvedRecent> rows) => [
    for (final r in rows) ?feedEntityOf(r.entity),
  ];

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
    _filters.removeListener(refresh);
    _filters.dispose();
    super.dispose();
  }
}
