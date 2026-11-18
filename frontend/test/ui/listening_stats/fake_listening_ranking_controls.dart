import 'package:flutter/foundation.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/listening_stats/listening_ranking_controller.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card.dart';

/// A scripted See all ranking controller for widget tests: the test sets
/// what it shows and reads back every input the view forwarded.
class FakeListeningRankingControls extends ChangeNotifier
    implements ListeningRankingControls {
  FakeListeningRankingControls(this.kind, this.token);

  @override
  final StatsRankingKind kind;

  /// The token the page was opened with.
  final HistorySnapshotToken token;

  List<StatsRankedCard>? _cards;
  bool _hasMore = false;
  bool _failed = false;
  bool _expired = false;
  SnapshotStaleness _notice = SnapshotStaleness.fresh;
  int _epoch = 0;

  int loadMores = 0;
  int retries = 0;
  int refreshes = 0;
  final played = <String>[];

  /// What [playTrack] answers.
  PlaybackOutcome playOutcome = const Accepted(1);
  bool disposed = false;

  /// Sets the visible state in one notification.
  void show({
    List<StatsRankedCard>? cards,
    bool hasMore = false,
    bool failed = false,
    bool expired = false,
    SnapshotStaleness notice = SnapshotStaleness.fresh,
    int? epoch,
  }) {
    _cards = cards;
    _hasMore = hasMore;
    _failed = failed;
    _expired = expired;
    _notice = notice;
    if (epoch != null) _epoch = epoch;
    notifyListeners();
  }

  @override
  StatsRange get range => token.filterKey as StatsRange;

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
  int get snapshotEpoch => _epoch;

  @override
  void loadMore() => loadMores++;

  @override
  void retry() => retries++;

  @override
  void refresh() => refreshes++;

  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) async {
    played.add(track.uuidId);
    return playOutcome;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
