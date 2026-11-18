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
import 'package:frontend/ui/snapshot_paging_controller.dart';

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

class SeeAllRecentsController
    extends SnapshotPagingController<ResolvedRecent, RecentRef>
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

  List<ResolvedRecent>? _rows;
  List<FeedEntity>? _entities;

  @override
  BrowseFilters get filters => _filters.filters;

  @override
  void setDownloaded(bool value) => _filters.setDownloaded(value);

  @override
  List<FeedEntity>? get entities => _entities;

  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) =>
      _ref.read(libraryActionsProvider).playRecentTrack(track);

  @override
  Future<SnapshotPageResult<ResolvedRecent, RecentRef>> fetchPage(
    HistorySnapshotToken token,
    RecentRef? after,
  ) => _pager.page(token, after, _pageSize);

  @override
  Future<
    (HistorySnapshotToken, SnapshotPageResult<ResolvedRecent, RecentRef>?)
  >
  captureSnapshot() async =>
      (await _pager.capture(downloadedOnly: filters.downloaded), null);

  @override
  Stream<SnapshotStaleness> watchFreshness(HistorySnapshotToken token) =>
      _pager.watchFreshness(token);

  @override
  void onPage(
    List<ResolvedRecent> rows,
    int generation,
    HistorySnapshotToken token,
  ) {
    _rows = [...?_rows, ...rows];
    _entities = _toEntities(_rows!);
    _watchLoaded(generation, token);
  }

  @override
  void onExpired() {
    _rows ??= const [];
    _entities ??= const [];
  }

  @override
  void resetRows() {
    _rows = null;
    _entities = null;
  }

  void _watchLoaded(int generation, HistorySnapshotToken token) {
    _watch?.cancel();
    late final StreamSubscription<List<ResolvedRecent>> sub;
    final refs = [for (final r in _rows!) r.ref];
    sub = _pager.watchLoaded(token, refs).listen((rows) {
      // Emissions of a replaced watch are ignored even if they arrive.
      if (isStale(generation) || !identical(_watch, sub)) return;
      _rows = rows;
      _entities = _toEntities(rows);
      notifyListeners();
    }, onError: (Object _) {});
    _watch = sub;
  }

  List<FeedEntity> _toEntities(List<ResolvedRecent> rows) => [
    for (final r in rows) ?feedEntityOf(r.entity),
  ];

  @override
  void cancelLoaded() {
    _watch?.cancel();
    _watch = null;
  }

  @override
  void onDispose() {
    _filters.removeListener(refresh);
    _filters.dispose();
  }
}
