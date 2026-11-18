import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';
import 'package:frontend/services/listening_stats_service.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card.dart';

/// What the statistics page shows for the chosen range.
sealed class ListeningStatsState {
  const ListeningStatsState();
}

/// A snapshot is being captured and loaded.
final class StatsLoading extends ListeningStatsState {
  const StatsLoading();
}

/// One loaded snapshot. [hasHistory] is false when there is no listening
/// history at all (the empty copy); true with zero totals means the range
/// has none.
final class StatsReady extends ListeningStatsState {
  const StatsReady(
    this.stats, {
    required this.hasHistory,
    required this.pendingListens,
  });
  final ListeningStats stats;
  final bool hasHistory;

  /// Counted listens in this snapshot not uploaded yet (from this device).
  final int pendingListens;
}

/// The load failed; the chosen range is kept and Retry repeats it.
final class StatsFailed extends ListeningStatsState {
  const StatsFailed();
}

/// The statistics page's input and presentation state (spec §3 paras 3–4,
/// §4; SC-10, SC-26).
abstract interface class ListeningStatsControls implements Listenable {
  /// The range presets, in selector order.
  List<StatsRange> get ranges;

  /// The chosen range (kept across failures).
  StatsRange get range;

  ListeningStatsState get state;

  /// Which freshness notice to show: [SnapshotStaleness.fresh] shows none.
  SnapshotStaleness get notice;

  /// Chooses a range: a new snapshot; results of the old one are dropped.
  void setRange(StatsRange range);

  /// Captures a new snapshot of the chosen range.
  void refresh();

  /// After a failure: loads the chosen range again.
  void retry();

  /// The ready snapshot's top lists (null unless ready).
  StatsTopLists? get topLists;

  /// The ready snapshot's token: See all pages the same snapshot (null
  /// unless ready).
  HistorySnapshotToken? get token;

  /// A top-track card tap: that single track, through `LibraryActions`.
  Future<PlaybackOutcome> playTrack(TrackUI track);

  void dispose();
}

typedef ListeningStatsFactory = ListeningStatsControls Function();

/// Creates the page's controller (page-scoped: created on entry, disposed on
/// close). Override in tests.
final listeningStatsControllerFactoryProvider = Provider<ListeningStatsFactory>(
  (ref) => () => ListeningStatsController(ref),
);

class ListeningStatsController extends ChangeNotifier
    implements ListeningStatsControls {
  ListeningStatsController(this._ref) {
    _snapshot();
  }

  final Ref _ref;

  @override
  final List<StatsRange> ranges = const [
    StatsRange.last7Days,
    StatsRange.last30Days,
    StatsRange.thisUtcYear,
    StatsRange.allTime,
  ];

  StatsRange _range = StatsRange.last7Days;
  ListeningStatsState _state = const StatsLoading();
  SnapshotStaleness _notice = SnapshotStaleness.fresh;
  StreamSubscription<SnapshotStaleness>? _freshness;
  StreamSubscription<CurrentStatsEntities>? _watch;

  HistorySnapshotToken? _token;
  StatsTopLists? _topLists;

  /// Bumped by every new snapshot and by dispose; stale continuations return.
  int _generation = 0;
  bool _disposed = false;

  @override
  StatsRange get range => _range;

  @override
  ListeningStatsState get state => _state;

  @override
  SnapshotStaleness get notice => _notice;

  @override
  StatsTopLists? get topLists => _topLists;

  @override
  HistorySnapshotToken? get token => _state is StatsReady ? _token : null;

  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) =>
      _ref.read(libraryActionsProvider).playStatsTrack(track);

  StatsTopLists _build(ListeningStats stats, CurrentStatsEntities? current) =>
      StatsTopLists(
        tracks: rankedCards(stats.topTracks, current),
        artists: rankedCards(stats.topArtists, current),
        albums: rankedCards(stats.topAlbums, current),
      );

  @override
  void setRange(StatsRange range) {
    if (range == _range) return;
    _range = range;
    _snapshot();
  }

  @override
  void refresh() => _snapshot();

  @override
  void retry() {
    if (_state is StatsFailed) _snapshot();
  }

  void _snapshot() {
    if (_disposed) return;
    final generation = ++_generation;
    final range = _range;
    _freshness?.cancel();
    _freshness = null;
    _watch?.cancel();
    _watch = null;
    _token = null;
    _topLists = null;
    _notice = SnapshotStaleness.fresh;
    _state = const StatsLoading();
    notifyListeners();
    _load(generation, range);
  }

  Future<void> _load(int generation, StatsRange range) async {
    ListeningStatsState next;
    HistorySnapshotToken? token;
    try {
      final snapshot = await _ref
          .read(listeningStatsServiceProvider)
          .snapshot(range);
      token = snapshot.token;
      next = StatsReady(
        snapshot.stats,
        hasHistory: snapshot.hasHistory,
        pendingListens: snapshot.pendingListens,
      );
    } catch (_) {
      next = const StatsFailed();
    }
    if (_stale(generation)) return;
    _state = next;
    if (next is StatsReady && token != null) {
      _token = token;
      _topLists = _build(next.stats, null);
      _watchShown(next.stats);
      _freshness = _ref
          .read(snapshotFreshnessProvider)
          .watch(token, kinds: const {HistoryKind.play})
          .listen((value) {
            if (_stale(generation) || value == _notice) return;
            _notice = value;
            notifyListeners();
          }, onError: (Object _) {});
    }
    notifyListeners();
  }

  void _watchShown(ListeningStats stats) {
    if (stats.topTracks.isEmpty &&
        stats.topArtists.isEmpty &&
        stats.topAlbums.isEmpty) {
      return;
    }
    _watch = _ref
        .read(listeningStatsRepositoryProvider)
        .watchCurrent(
          trackUuids: [for (final e in stats.topTracks) e.entity.uuidId],
          artistIds: [for (final e in stats.topArtists) e.entity.id],
          albumIds: [for (final e in stats.topAlbums) e.entity.id],
        )
        // Every refresh, range change and dispose cancels this watch
        // first, and a cancelled subscription delivers nothing
        // (DR-332-STATS-B-01): no generation check is needed here.
        .listen((current) {
          _topLists = _build(stats, current);
          notifyListeners();
        }, onError: (Object _) {});
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  @override
  void dispose() {
    if (_disposed) return;
    _generation++;
    _disposed = true;
    _freshness?.cancel();
    _watch?.cancel();
    super.dispose();
  }
}
