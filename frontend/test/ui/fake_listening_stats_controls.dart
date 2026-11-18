import 'package:flutter/foundation.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card.dart';

/// A scripted statistics controller for widget tests: the test sets the
/// state and reads back every input the view forwarded.
class FakeListeningStatsControls extends ChangeNotifier
    implements ListeningStatsControls {
  StatsRange _range = StatsRange.last30Days;
  ListeningStatsState _state = const StatsLoading();
  SnapshotStaleness _notice = SnapshotStaleness.fresh;

  final rangeTaps = <StatsRange>[];

  /// What [topLists] and [token] answer; set by the test.
  StatsTopLists? lists;
  HistorySnapshotToken? snapshotToken;

  /// Every track [playTrack] was asked to play, by uuid.
  final played = <String>[];
  int refreshes = 0;
  int retries = 0;
  bool disposed = false;

  /// Sets the visible state in one notification.
  void show(
    ListeningStatsState state, {
    StatsRange? range,
    SnapshotStaleness notice = SnapshotStaleness.fresh,
  }) {
    _state = state;
    if (range != null) _range = range;
    _notice = notice;
    notifyListeners();
  }

  @override
  List<StatsRange> get ranges => const [
    StatsRange.last7Days,
    StatsRange.last30Days,
    StatsRange.thisUtcYear,
    StatsRange.allTime,
  ];

  @override
  StatsRange get range => _range;

  @override
  ListeningStatsState get state => _state;

  @override
  SnapshotStaleness get notice => _notice;

  @override
  StatsTopLists? get topLists => lists;

  @override
  HistorySnapshotToken? get token => snapshotToken;

  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) async {
    played.add(track.uuidId);
    return const Accepted(1);
  }

  @override
  void setRange(StatsRange range) => rangeTaps.add(range);

  @override
  void refresh() => refreshes++;

  @override
  void retry() => retries++;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
