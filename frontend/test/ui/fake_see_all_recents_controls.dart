import 'package:flutter/foundation.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/see_all_recents_controller.dart';

/// A scripted See all controller for widget tests: the test sets the state
/// and reads back every input the view forwarded.
class FakeSeeAllRecentsControls extends ChangeNotifier
    implements SeeAllRecentsControls {
  FakeSeeAllRecentsControls({bool initialDownloaded = false})
    : _filters = const BrowseFilters(
        policy: OfflineFilterPolicy.manual,
      ).userSetDownloaded(initialDownloaded);

  BrowseFilters _filters;
  List<FeedEntity>? _entities;
  bool _hasMore = false;
  bool _failed = false;
  SnapshotStaleness _notice = SnapshotStaleness.fresh;
  int _epoch = 0;

  final chipTaps = <bool>[];
  final played = <String>[];
  int loadMores = 0;
  int retries = 0;
  int refreshes = 0;
  bool disposed = false;

  /// Sets the visible state in one notification.
  void show({
    List<FeedEntity>? entities,
    bool hasMore = false,
    bool failed = false,
    SnapshotStaleness notice = SnapshotStaleness.fresh,
    bool newSnapshot = false,
  }) {
    _entities = entities;
    _hasMore = hasMore;
    _failed = failed;
    _notice = notice;
    if (newSnapshot) _epoch++;
    notifyListeners();
  }

  @override
  BrowseFilters get filters => _filters;

  @override
  void setDownloaded(bool value) {
    chipTaps.add(value);
    _filters = _filters.userSetDownloaded(value);
    notifyListeners();
  }

  @override
  List<FeedEntity>? get entities => _entities;

  @override
  bool get hasMore => _hasMore;

  @override
  bool get failed => _failed;

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
    return const Accepted(1);
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
