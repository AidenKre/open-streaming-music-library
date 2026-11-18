import 'package:flutter/foundation.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/ui/home/home_controller.dart';

/// Home's controller as a test sets it: the recents state, the Downloaded
/// chip (recorded, and applied to [filters]), retries and plays (moved here
/// from home_recents_section_test.dart, APP-TEST stage 2).
class FakeHomeControls extends ChangeNotifier implements HomeControls {
  FakeHomeControls(this._recents);

  HomeRecentsState _recents;
  BrowseFilters _filters = const BrowseFilters(
    policy: OfflineFilterPolicy.manual,
  );
  final chipTaps = <bool>[];
  final played = <String>[];
  int retries = 0;

  /// What [playTrack] answers.
  PlaybackOutcome playOutcome = const Accepted(1);

  set recentsState(HomeRecentsState value) {
    _recents = value;
    notifyListeners();
  }

  @override
  HomeRecentsState get recents => _recents;

  @override
  BrowseFilters get filters => _filters;

  @override
  void setDownloaded(bool value) {
    chipTaps.add(value);
    _filters = _filters.userSetDownloaded(value);
    notifyListeners();
  }

  @override
  void retryRecents() => retries++;

  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) async {
    played.add(track.uuidId);
    return playOutcome;
  }
}
