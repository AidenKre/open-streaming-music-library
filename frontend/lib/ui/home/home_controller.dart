import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/browse_filter_controller.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/recently_played_repository.dart';
import 'package:frontend/ui/feed/feed.dart';

/// What Home's recents section shows (Phase 6 §3).
sealed class HomeRecentsState {
  const HomeRecentsState();
}

/// The first result for the current chip is not in yet.
final class HomeRecentsLoading extends HomeRecentsState {
  const HomeRecentsLoading();
}

/// The recents query failed; the section offers Retry.
final class HomeRecentsFailed extends HomeRecentsState {
  const HomeRecentsFailed();
}

/// Up to 20 entities, newest first. Never empty.
final class HomeRecentsReady extends HomeRecentsState {
  const HomeRecentsReady(this.entities);
  final List<FeedEntity> entities;
}

/// Nothing to show. [filtered]: the Downloaded chip removed every eligible
/// entry (the section keeps its title and says so); otherwise there is no
/// eligible history at all (the section is hidden).
final class HomeRecentsEmpty extends HomeRecentsState {
  const HomeRecentsEmpty({required this.filtered});
  final bool filtered;
}

/// Home's input and presentation state (SC-07, SC-09, SC-26).
abstract interface class HomeControls implements Listenable {
  /// The Home Downloaded chip (session-only, `manual`: starts OFF, never
  /// follows connectivity).
  BrowseFilters get filters;

  /// The user tapped the chip.
  void setDownloaded(bool value);

  HomeRecentsState get recents;

  /// Re-subscribe after a failure.
  void retryRecents();

  /// A recent track tap: a new single-track queue and one track click.
  Future<PlaybackOutcome> playTrack(TrackUI track);
}

/// Scope-bound: one per session `ProviderScope`, disposed with it.
final homeControlsProvider = Provider<HomeControls>((ref) {
  final controller = HomeController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

/// Owns Home's one `manual` Downloaded chip and the live recents for it.
/// Every (re)subscribe bumps a generation; callbacks from an older one (or
/// after dispose) are ignored, so a late result never overwrites a newer
/// chip state.
class HomeController extends ChangeNotifier implements HomeControls {
  HomeController(this._ref) {
    _filters = _ref.read(browseFilterControllerFactoryProvider)(
      policy: OfflineFilterPolicy.manual,
    );
    _filters.addListener(_subscribe);
    _subscribe();
  }

  final Ref _ref;
  late final BrowseFilterControls _filters;
  StreamSubscription<List<ResolvedRecent>>? _mainSub;
  StreamSubscription<bool>? _probeSub;
  int _generation = 0;
  bool _disposed = false;

  List<FeedEntity>? _main;
  bool? _hasHistory; // the unfiltered probe; only used while the chip is ON
  bool _probeFailed = false;
  bool _failed = false;
  HomeRecentsState _recents = const HomeRecentsLoading();

  @override
  BrowseFilters get filters => _filters.filters;

  @override
  void setDownloaded(bool value) => _filters.setDownloaded(value);

  @override
  HomeRecentsState get recents => _recents;

  @override
  void retryRecents() => _subscribe();

  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) =>
      _ref.read(libraryActionsProvider).playRecentTrack(track);

  void _subscribe() {
    if (_disposed) return;
    _cancel();
    final generation = ++_generation;
    _main = null;
    _hasHistory = null;
    _probeFailed = false;
    _failed = false;
    final downloaded = filters.downloaded;
    final repo = _ref.read(recentlyPlayedRepositoryProvider);
    // The chip or a retry changed the input: tell listeners even when the
    // state was already `loading`.
    _recents = const HomeRecentsLoading();
    notifyListeners();
    _mainSub = repo
        .watchRecent(limit: 20, downloadedOnly: downloaded)
        .listen(
          (list) {
            if (_stale(generation)) return;
            _failed = false;
            _main = [for (final r in list) ?feedEntityOf(r.entity)];
            _publish();
          },
          onError: (Object _) {
            if (_stale(generation)) return;
            _failed = true;
            _publish();
          },
        );
    if (downloaded) {
      _probeSub = repo
          .watchHasEligibleHistory()
          .listen(
            (has) {
              if (_stale(generation)) return;
              _hasHistory = has;
              _probeFailed = false;
              _publish();
            },
            // A failed probe is unknown, never "no history": with nothing
            // downloaded to show, the section shows its failed state.
            onError: (Object _) {
              if (_stale(generation)) return;
              _probeFailed = true;
              _publish();
            },
          );
    }
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  void _cancel() {
    _mainSub?.cancel();
    _probeSub?.cancel();
    _mainSub = null;
    _probeSub = null;
  }

  void _publish() {
    final main = _main;
    final HomeRecentsState next;
    if (_failed) {
      next = const HomeRecentsFailed();
    } else if (main == null) {
      next = const HomeRecentsLoading();
    } else if (main.isNotEmpty) {
      next = HomeRecentsReady(main);
    } else if (!filters.downloaded) {
      next = const HomeRecentsEmpty(filtered: false);
    } else if (_probeFailed) {
      next = const HomeRecentsFailed();
    } else if (_hasHistory == null) {
      next = const HomeRecentsLoading();
    } else {
      next = HomeRecentsEmpty(filtered: _hasHistory!);
    }
    final prev = _recents;
    _recents = next;
    final same = switch ((prev, next)) {
      (HomeRecentsLoading(), HomeRecentsLoading()) => true,
      (HomeRecentsFailed(), HomeRecentsFailed()) => true,
      (HomeRecentsEmpty(:final filtered), HomeRecentsEmpty(filtered: final f)) =>
        filtered == f,
      _ => false,
    };
    if (!same) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancel();
    _filters.removeListener(_subscribe);
    _filters.dispose();
    super.dispose();
  }
}
