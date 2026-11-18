import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/home_suggestions_service.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/home/home_controller.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/library_actions.dart';

/// The queue source of a track tapped in a Home suggestion rail.
const suggestionsQueueSource = 'suggestions';

/// What one Home suggestion rail shows (Phase 9 §5).
sealed class SuggestionRailState {
  const SuggestionRailState();
}

/// The first snapshot for this rail (or for the current filter) is not in.
final class SuggestionRailLoading extends SuggestionRailState {
  const SuggestionRailLoading();
}

/// The first snapshot failed; the rail offers Retry.
final class SuggestionRailFailed extends SuggestionRailState {
  const SuggestionRailFailed();
}

/// The frozen picks. Empty: the rail collapses, or says the filter emptied
/// it when [emptiedByFilter]. A new [resetToken] = a new snapshot: the rail
/// starts at its beginning. [showNotice]: newer history is waiting while the
/// user is scrolled into the rail.
final class SuggestionRailReady extends SuggestionRailState {
  const SuggestionRailReady({
    required this.tracks,
    required this.emptiedByFilter,
    required this.resetToken,
    required this.showNotice,
  });

  final List<TrackUI> tracks;
  final bool emptiedByFilter;
  final Object resetToken;
  final bool showNotice;
}

/// Home's suggestion rails: input and presentation state (SC-26).
abstract interface class HomeSuggestionsControls implements Listenable {
  SuggestionRailState stateOf(SuggestionRail rail);

  /// The shell: Home's root is (or is no longer) what the user sees.
  void setHomeVisible(bool visible);

  /// The rail view: where the user is in the rail and whether a pointer is
  /// down on it.
  void setRailEngagement(SuggestionRail rail, RailEngagement engagement);

  /// The notice tap: take a new snapshot for this rail now.
  void refreshRail(SuggestionRail rail);

  /// Retry after a failed load.
  void retry(SuggestionRail rail);

  /// A suggestion tap: a new single-track queue and one track click.
  Future<PlaybackOutcome> playTrack(TrackUI track);
}

/// Scope-bound: one per session `ProviderScope`, disposed with it.
final homeSuggestionsControlsProvider = Provider<HomeSuggestionsControls>((
  ref,
) {
  final controller = HomeSuggestionsController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

enum _Cause { first, unhide, retry, filter, noticeTap, homeVisible, ambient }

/// Causes that show the rail as loading while the snapshot is taken.
const _loadingCauses = {
  _Cause.first,
  _Cause.unhide,
  _Cause.retry,
  _Cause.filter,
};

const _rest = RailEngagement(atStart: true, pointerDown: false);

class _Rail {
  SuggestionRailState state = const SuggestionRailLoading();
  SuggestionSnapshot? snapshot;
  int generation = 0;
  int pickSequence = 0;
  RailEngagement engagement = _rest;
  bool pending = false;

  /// Bumped on every engagement report: "has the user done anything since".
  int engagementReports = 0;

  /// A download change arrived while this rail was loading: refresh once it
  /// lands (downloads have no snapshot boundary to catch it later).
  bool downloadsChanged = false;
  StreamSubscription<SnapshotStaleness>? subscription;
}

String _sectionId(SuggestionRail rail) => switch (rail) {
  SuggestionRail.rediscover => HomeSectionIds.rediscover,
  SuggestionRail.moreFromArtists => HomeSectionIds.moreFromArtists,
};

/// Holds one frozen snapshot per rail and decides, from what each rail
/// reports, when a newer snapshot may replace the picks on screen (Phase 9
/// §5). No I/O and no selection rules: those are the service's. Every async
/// step is generation-guarded; a late result is dropped.
class HomeSuggestionsController extends ChangeNotifier
    implements HomeSuggestionsControls {
  HomeSuggestionsController(this._ref) {
    _home = _ref.read(homeControlsProvider);
    _downloadedFilter = _home.filters.downloaded;
    _home.addListener(_onHomeChanged);
    // Container-level subscriptions: a provider nobody listens to is paused,
    // and a paused `ref.listen` would miss these inputs.
    final container = _ref.container;
    _inputs.add(container.listen<AsyncValue<HomeLayoutPreferences>>(
      homeLayoutPreferencesProvider,
      (_, next) => _onPreferences(next),
      fireImmediately: true,
    ));
    _inputs.add(container.listen<String?>(
      currentTrackProvider.select((t) => t?.uuidId),
      (_, _) => _onCurrentTrack(),
    ));
    _inputs.add(container.listen<AsyncValue<({int count, int totalBytes})>>(downloadedStatsProvider, (_, next) {
      if (!next.hasValue) return;
      final first = !_hasStats;
      final changed = _hasStats && next.value != _stats;
      _hasStats = true;
      _stats = next.value;
      if (first || !changed) return; // the first value is the baseline
      _onAmbient(_visibleRails.toList());
    }));
  }

  final Ref _ref;
  final _inputs = <ProviderSubscription<dynamic>>[];
  late final HomeControls _home;
  final _rails = {for (final r in SuggestionRail.values) r: _Rail()};
  late bool _downloadedFilter;
  Set<String>? _hidden; // null until the stored preference is known
  bool _homeVisible = true;
  bool _disposed = false;
  bool _hasStats = false;
  Object? _stats;

  BrowseFilters get _filters => _home.filters;
  String? get _currentUuid => _ref.read(currentTrackProvider)?.uuidId;
  HomeSuggestionsService get _service =>
      _ref.read(homeSuggestionsServiceProvider);

  bool _isHidden(SuggestionRail r) => _hidden?.contains(_sectionId(r)) ?? true;
  Iterable<SuggestionRail> get _visibleRails =>
      SuggestionRail.values.where((r) => !_isHidden(r));

  @override
  SuggestionRailState stateOf(SuggestionRail rail) => _rails[rail]!.state;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _live(SuggestionRail r, int generation) =>
      !_disposed && !_isHidden(r) && _rails[r]!.generation == generation;

  // --- Inputs -------------------------------------------------------------

  @override
  void setHomeVisible(bool visible) {
    if (visible == _homeVisible) return;
    _homeVisible = visible;
    if (!visible) return;
    _refresh([
      for (final r in _visibleRails)
        if (_rails[r]!.state is! SuggestionRailLoading) r,
    ], _Cause.homeVisible);
  }

  @override
  void setRailEngagement(SuggestionRail rail, RailEngagement engagement) {
    final st = _rails[rail]!;
    st.engagement = engagement;
    st.engagementReports++;
    if (_homeVisible &&
        st.pending &&
        _atRest(st) &&
        st.state is SuggestionRailReady &&
        !_isHidden(rail)) {
      _refresh([rail], _Cause.ambient);
    }
    _syncNotice(rail);
  }

  @override
  void refreshRail(SuggestionRail rail) => _refresh([rail], _Cause.noticeTap);

  @override
  void retry(SuggestionRail rail) => _refresh([rail], _Cause.retry);

  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) => _ref
      .read(libraryActionsProvider)
      .playFromList([track], 0, source: suggestionsQueueSource);

  void _onHomeChanged() {
    if (_home.filters.downloaded == _downloadedFilter) return;
    _downloadedFilter = _home.filters.downloaded;
    _refresh(_visibleRails.toList(), _Cause.filter);
  }

  void _onPreferences(AsyncValue<HomeLayoutPreferences> next) {
    if (_disposed || (next.isLoading && !next.hasValue && !next.hasError)) {
      return;
    }
    final now = next.value?.hidden ?? const <String>{};
    final before = _hidden;
    _hidden = {...now};
    if (before == null) {
      _refresh(_visibleRails.toList(), _Cause.first);
      return;
    }
    final unhidden = <SuggestionRail>[];
    for (final r in SuggestionRail.values) {
      final id = _sectionId(r);
      if (now.contains(id) && !before.contains(id)) {
        final st = _rails[r]!;
        st.generation++;
        st.subscription?.cancel();
        st.subscription = null;
        st.snapshot = null;
        st.pending = false;
        st.state = const SuggestionRailLoading();
        _notify();
      } else if (!now.contains(id) && before.contains(id)) {
        unhidden.add(r);
      }
    }
    _refresh(unhidden, _Cause.unhide);
  }

  // --- New history --------------------------------------------------------

  void _onFreshness(SuggestionRail rail, SnapshotStaleness staleness) {
    if (staleness == SnapshotStaleness.fresh) return;
    final snapshot = _rails[rail]!.snapshot;
    // Rails that share a snapshot hear the same event: the first handles all.
    final sharing = [
      for (final r in SuggestionRail.values)
        if (identical(_rails[r]!.snapshot, snapshot)) r,
    ];
    if (sharing.first == rail) _onAmbient(sharing);
  }

  /// New history or a download change for [rails]: refresh the ones at rest,
  /// flag the others so their notice (when scrolled in) or a later rest picks
  /// it up.
  void _onAmbient(List<SuggestionRail> rails) {
    if (_disposed || !_homeVisible) return;
    final atRest = <SuggestionRail>[];
    for (final r in rails) {
      final st = _rails[r]!;
      if (_isHidden(r)) continue;
      if (st.state is SuggestionRailLoading) {
        st.downloadsChanged = true;
        continue;
      }
      if (st.state is! SuggestionRailReady) continue;
      if (_atRest(st)) {
        atRest.add(r);
      } else {
        st.pending = true;
        _syncNotice(r);
      }
    }
    _refresh(atRest, _Cause.ambient);
  }

  void _syncNotice(SuggestionRail rail) {
    final st = _rails[rail]!;
    final state = st.state;
    if (state is! SuggestionRailReady) return;
    final show = st.pending && !_atStart(st, empty: state.tracks.isEmpty);
    if (state.showNotice == show) return;
    st.state = SuggestionRailReady(
      tracks: state.tracks,
      emptiedByFilter: state.emptiedByFilter,
      resetToken: state.resetToken,
      showNotice: show,
    );
    _notify();
  }

  // A ready rail with no tracks (collapsed, or the filter message) has no
  // widget reporting engagement: nothing on screen can move, so it is at rest.
  bool _empty(_Rail st) {
    final state = st.state;
    return state is SuggestionRailReady && state.tracks.isEmpty;
  }

  RailEngagement _effective(_Rail st) => _empty(st) ? _rest : st.engagement;

  bool _atRest(_Rail st) => _effective(st).atRest;

  bool _atStart(_Rail st, {required bool empty}) =>
      empty || st.engagement.atStart;

  /// The kept snapshot's picks are incomplete (a refill was dropped).
  void _refillIfIncomplete(SuggestionRail rail) {
    final st = _rails[rail]!;
    final snapshot = st.snapshot;
    if (snapshot == null || st.state is! SuggestionRailReady) return;
    final now = _service.pickNow(
      snapshot,
      currentUuid: _currentUuid,
      filter: _filters,
    );
    if (!now.complete) _repick(rail);
  }

  // --- Snapshots ----------------------------------------------------------

  Future<void> _refresh(List<SuggestionRail> rails, _Cause cause) async {
    if (rails.isEmpty || _disposed) return;
    final started = {for (final r in rails) r: ++_rails[r]!.generation};
    // A visible-refresh lands on a rail the user is not at rest on only if the
    // rail has reported nothing since the trigger.
    final reportsAtTrigger = {
      for (final r in rails) r: _rails[r]!.engagementReports,
    };
    for (final r in rails) {
      _rails[r]!.downloadsChanged = false;
    }
    if (_loadingCauses.contains(cause)) {
      for (final r in rails) {
        _rails[r]!.state = const SuggestionRailLoading();
      }
      _notify();
    }
    final uuid = _currentUuid;
    final SuggestionSnapshot snapshot;
    final SuggestionView view;
    try {
      snapshot = await _service.capture();
      view = await _service.resolve(
        snapshot,
        currentUuid: uuid,
        filter: _filters,
      );
    } catch (_) {
      for (final r in rails) {
        if (!_live(r, started[r]!)) continue;
        final st = _rails[r]!;
        if (st.state is! SuggestionRailReady) {
          st.state = const SuggestionRailFailed();
          _notify();
        } else {
          // Keep the frozen items and retry at the next rest: the freshness
          // stream will not repeat what it already reported.
          st.pending = true;
          _syncNotice(r);
          _refillIfIncomplete(r);
        }
      }
      return;
    }
    for (final r in rails) {
      if (!_live(r, started[r]!)) continue;
      final st = _rails[r]!;
      final e = _effective(st);
      final apply = st.state is! SuggestionRailReady ||
          switch (cause) {
            _Cause.homeVisible =>
              e.atRest ||
                  (!e.pointerDown &&
                      st.engagementReports == reportsAtTrigger[r]),
            _Cause.ambient => e.atRest,
            _ => true,
          };
      if (!apply) {
        st.pending = true;
        _syncNotice(r);
        _refillIfIncomplete(r);
        continue;
      }
      st.snapshot = snapshot;
      st.pending = false;
      st.state = _ready(st, view.of(r), Object());
      st.subscription?.cancel();
      st.subscription = _service
          .watch(snapshot)
          .listen((s) => _onFreshness(r, s), onError: (_) {});
      _notify();
      if (uuid != _currentUuid) _repick(r);
    }
    final changed = [
      for (final r in rails)
        if (_rails[r]!.downloadsChanged && _rails[r]!.state is SuggestionRailReady)
          r,
    ];
    _onAmbient(changed);
  }

  SuggestionRailReady _ready(_Rail st, RailPicks picks, Object token) =>
      SuggestionRailReady(
        tracks: picks.tracks,
        emptiedByFilter: picks.emptiedByFilter,
        resetToken: token,
        showNotice:
            st.pending && !_atStart(st, empty: picks.tracks.isEmpty),
      );

  // --- Current track (same frozen snapshot) -------------------------------

  void _onCurrentTrack() {
    if (_disposed) return;
    for (final r in _visibleRails) {
      if (_rails[r]!.snapshot != null) _repick(r);
    }
  }

  Future<void> _repick(SuggestionRail rail) async {
    final st = _rails[rail]!;
    final snapshot = st.snapshot!;
    final sequence = ++st.pickSequence;
    final generation = st.generation;
    final uuid = _currentUuid;
    final filter = _filters;
    bool current() =>
        _live(rail, generation) &&
        st.pickSequence == sequence &&
        identical(st.snapshot, snapshot);
    void show(SuggestionView view) {
      final state = st.state;
      if (state is! SuggestionRailReady) return;
      st.state = _ready(st, view.of(rail), state.resetToken);
      _notify();
    }

    final now = _service.pickNow(snapshot, currentUuid: uuid, filter: filter);
    show(now);
    if (now.complete) return;
    try {
      final full = await _service.resolve(
        snapshot,
        currentUuid: uuid,
        filter: filter,
      );
      if (current()) show(full);
    } catch (_) {
      // Keep what is shown; the next change tries again.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _home.removeListener(_onHomeChanged);
    for (final sub in _inputs) {
      sub.close();
    }
    for (final st in _rails.values) {
      st.subscription?.cancel();
    }
    super.dispose();
  }
}
