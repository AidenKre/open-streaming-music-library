// Phase 9 §5 paras 3–4 (refresh policy, user decision 2026-10-31) / SC-10 /
// SC-26 / SC-27 / 9-U05 (stable snapshot, current-track exclusion, hide),
// 9-R02 and 9-R03 (unit halves): the Home suggestions controller holds one
// frozen snapshot per rail and decides, from what the rail reports, when a
// new snapshot may replace what is on screen.
//
// - A rail the user is not looking into (at its start, no pointer down)
//   re-snapshots silently on new history; a rail scrolled into or touched
//   never changes under the user: it shows the notice (only while scrolled
//   in) and waits.
// - Home becoming visible and a filter change re-snapshot.
// - The current track is excluded at once from the same frozen snapshot.
// - Every asynchronous step is generation-guarded: a late result is dropped.
//
// The model service is faked here (its rules are tested in
// test/repositories/home_suggestions_service_test.dart); the fake applies a
// trivial stand-in selection so expected lists stay readable.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/suggestions.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/home_suggestions_service.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/home/home_controller.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/home/home_suggestions_controller.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../helpers/fake_home_controls.dart';

TrackUI track(String uuid) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: 'Song $uuid',
  artist: 'A',
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

/// A capture the test completes. Snapshot n's rails are `R<n>-0..` and
/// `M<n>-0..` (five candidates each); uuids containing "d" are downloaded.
class _Capture {
  _Capture(this.n);
  final int n;
  final completer = Completer<SuggestionSnapshot>();
  final staleness = StreamController<SnapshotStaleness>.broadcast();

  late final snapshot = SuggestionSnapshot(
    token: HistorySnapshotToken(
      boundaryLocalId: n,
      historyContentVersion: 0,
      catalogAttributionVersion: 0,
      capturedNowUtcMs: n,
      filterKey: HomeSuggestionsService.filterKey,
    ),
    pools: SuggestionPools(
      boundaryLocalId: n,
      capturedNowUtcMs: n,
      rediscover: const [],
      artists: const [],
    ),
  );

  void complete() => completer.complete(snapshot);
  void fail() => completer.completeError(StateError('load failed'));
}

/// Stand-in selection: the candidates minus the current track, Downloaded
/// filter first, then a cap of 3. pickNow returns only tracks resolve has
/// "hydrated" for that snapshot.
class _FakeService implements HomeSuggestionsService {
  final captures = <_Capture>[];
  final candidates = <int, Map<SuggestionRail, List<String>>>{};
  final hydrated = <int, Set<String>>{};
  Completer<void>? resolveGate;
  int resolveCalls = 0;

  _Capture get last => captures.last;

  List<String> base(int n, SuggestionRail rail) =>
      candidates[n]?[rail] ??
      [
        for (var i = 0; i < 5; i++)
          '${rail == SuggestionRail.rediscover ? 'R' : 'M'}$n-$i',
      ];

  int _n(SuggestionSnapshot s) => s.token.boundaryLocalId;

  List<String> _pick(int n, SuggestionRail rail, String? current, bool dl) => [
    for (final u in base(n, rail))
      if (u != current && (!dl || u.contains('d'))) u,
  ].take(3).toList();

  SuggestionView _view(int n, String? current, BrowseFilters filter,
      {required bool onlyHydrated}) {
    var complete = true;
    RailPicks rail(SuggestionRail r) {
      final picks = _pick(n, r, current, filter.downloaded);
      final have = hydrated[n] ?? const {};
      final tracks = [
        for (final u in picks)
          if (!onlyHydrated || have.contains(u)) track(u),
      ];
      if (tracks.length != picks.length) complete = false;
      return RailPicks(
        tracks: tracks,
        emptiedByFilter: picks.isEmpty &&
            filter.downloaded &&
            _pick(n, r, current, false).isNotEmpty,
      );
    }

    return SuggestionView(
      rediscover: rail(SuggestionRail.rediscover),
      moreFromArtists: rail(SuggestionRail.moreFromArtists),
      complete: complete,
    );
  }

  @override
  Future<SuggestionSnapshot> capture() {
    final c = _Capture(captures.length + 1);
    captures.add(c);
    return c.completer.future;
  }

  @override
  Stream<SnapshotStaleness> watch(SuggestionSnapshot snapshot) =>
      captures[_n(snapshot) - 1].staleness.stream;

  @override
  SuggestionView pickNow(
    SuggestionSnapshot snapshot, {
    String? currentUuid,
    required BrowseFilters filter,
  }) => _view(_n(snapshot), currentUuid, filter, onlyHydrated: true);

  @override
  Future<SuggestionView> resolve(
    SuggestionSnapshot snapshot, {
    String? currentUuid,
    required BrowseFilters filter,
  }) async {
    resolveCalls++;
    final n = _n(snapshot);
    final gate = resolveGate;
    if (gate != null) await gate.future;
    for (final r in SuggestionRail.values) {
      (hydrated[n] ??= {}).addAll(_pick(n, r, currentUuid, filter.downloaded));
    }
    return _view(n, currentUuid, filter, onlyHydrated: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingActions implements LibraryActionControls {
  final lists = <(List<String>, int, String)>[];

  @override
  Future<PlaybackOutcome> playFromList(
    List<TrackUI> tracks,
    int startIndex, {
    required String source,
  }) async {
    lists.add(([for (final t in tracks) t.uuidId], startIndex, source));
    return const Accepted(7);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _current = StateProvider<TrackUI?>((ref) => null);

const _rd = SuggestionRail.rediscover;
const _more = SuggestionRail.moreFromArtists;
const _atRest = RailEngagement(atStart: true, pointerDown: false);
const _scrolledIn = RailEngagement(atStart: false, pointerDown: false);
const _touchedAtStart = RailEngagement(atStart: true, pointerDown: true);
const _scrolledTouched = RailEngagement(atStart: false, pointerDown: true);

void main() {
  late _FakeService service;
  late FakeHomeControls home;
  late _RecordingActions actions;
  late StreamController<({int count, int totalBytes})> downloads;
  late ProviderContainer container;
  late HomeSuggestionsControls controls;
  late int notifications;

  ProviderContainer makeContainer([List<Override> extra = const []]) {
    final c = ProviderContainer(
      overrides: [
        homeSuggestionsServiceProvider.overrideWithValue(service),
        homeControlsProvider.overrideWithValue(home),
        libraryActionsProvider.overrideWithValue(actions),
        currentTrackProvider.overrideWith((ref) => ref.watch(_current)),
        downloadedStatsProvider.overrideWith((ref) => downloads.stream),
        ...extra,
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> settle() => pumpEventQueue();

  /// Builds the controller and lets the stored hide preference load.
  Future<void> start() async {
    container = makeContainer();
    final prefsSub = container.listen(homeLayoutPreferencesProvider, (_, _) {});
    addTearDown(prefsSub.close);
    await container.read(homeLayoutPreferencesProvider.future);
    controls = container.read(homeSuggestionsControlsProvider);
    notifications = 0;
    controls.addListener(() => notifications++);
    await settle();
  }

  /// Completes the pending capture and lets resolve land.
  Future<void> land([_Capture? c]) async {
    (c ?? service.last).complete();
    await settle();
  }

  SuggestionRailState stateOf(SuggestionRail r) => controls.stateOf(r);

  List<String> shown(SuggestionRail r) => switch (stateOf(r)) {
    SuggestionRailReady(:final tracks) => [for (final t in tracks) t.uuidId],
    final s => fail('not ready: $s'),
  };

  SuggestionRailReady ready(SuggestionRail r) =>
      stateOf(r) as SuggestionRailReady;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = _FakeService();
    home = FakeHomeControls(const HomeRecentsEmpty(filtered: false));
    actions = _RecordingActions();
    downloads = StreamController.broadcast();
    addTearDown(downloads.close);
  });

  group('first snapshot', () {
    test('both rails load from one capture, then show its picks', () async {
      await start();
      expect(stateOf(_rd), isA<SuggestionRailLoading>());
      expect(stateOf(_more), isA<SuggestionRailLoading>());
      expect(service.captures, hasLength(1));
      await land();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      expect(shown(_more), ['M1-0', 'M1-1', 'M1-2']);
      expect(ready(_rd).showNotice, isFalse);
      expect(ready(_rd).emptiedByFilter, isFalse);
    });

    test('an empty rail is ready and empty (the view collapses it); a '
        'filter-emptied one says so', () async {
      service.candidates[1] = {_rd: const [], _more: const ['M1-x']};
      home.setDownloaded(true);
      await start();
      await land();
      expect(shown(_rd), isEmpty);
      expect(ready(_rd).emptiedByFilter, isFalse);
      expect(shown(_more), isEmpty);
      expect(ready(_more).emptiedByFilter, isTrue);
    });

    test('a failed first load shows the error; Retry captures again',
        () async {
      await start();
      service.last.fail();
      await settle();
      expect(stateOf(_rd), isA<SuggestionRailFailed>());
      expect(stateOf(_more), isA<SuggestionRailFailed>());
      controls.retry(_rd);
      expect(stateOf(_rd), isA<SuggestionRailLoading>());
      expect(service.captures, hasLength(2));
      await land();
      expect(shown(_rd), ['R2-0', 'R2-1', 'R2-2']);
      expect(stateOf(_more), isA<SuggestionRailFailed>());
    });

    test('a failed background refresh keeps the frozen items', () async {
      await start();
      await land();
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      expect(service.captures, hasLength(2));
      service.last.fail();
      await settle();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      expect(ready(_rd).showNotice, isFalse);
    });
  });

  group('tap', () {
    test('plays that single track through LibraryActions, nothing else',
        () async {
      await start();
      await land();
      final tapped = ready(_more).tracks[1];
      final outcome = await controls.playTrack(tapped);
      expect(outcome, isA<Accepted>());
      expect(actions.lists, hasLength(1));
      final (uuids, startIndex, source) = actions.lists.single;
      expect(uuids, ['M1-1']);
      expect(startIndex, 0);
      expect(source, suggestionsQueueSource);
      expect(service.captures, hasLength(1), reason: 'a tap re-snapshots nothing');
    });
  });

  group('new history (refresh policy)', () {
    test('a rail at its start refreshes silently: no loading, no notice, '
        'a new start', () async {
      await start();
      await land();
      final firstToken = ready(_rd).resetToken;
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      expect(service.captures, hasLength(2));
      // The old items stay until the new ones are ready.
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      await land();
      expect(shown(_rd), ['R2-0', 'R2-1', 'R2-2']);
      expect(shown(_more), ['M2-0', 'M2-1', 'M2-2']);
      expect(ready(_rd).showNotice, isFalse);
      expect(ready(_rd).resetToken, isNot(firstToken));
    });

    test('a history change (rename, edit) counts like new activity', () async {
      await start();
      await land();
      service.last.staleness.add(SnapshotStaleness.historyChanged);
      await settle();
      expect(service.captures, hasLength(2));
    });

    test('a rail scrolled into keeps its items and shows the notice; the rail '
        'at its start refreshes', () async {
      await start();
      await land();
      controls.setRailEngagement(_rd, _scrolledIn);
      final before = ready(_rd);
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      await land();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      expect(identical(ready(_rd).tracks, before.tracks), isTrue);
      expect(ready(_rd).resetToken, before.resetToken);
      expect(ready(_rd).showNotice, isTrue);
      expect(shown(_more), ['M2-0', 'M2-1', 'M2-2']);
    });

    test('the notice tap re-snapshots that rail and returns it to its start',
        () async {
      await start();
      await land();
      controls.setRailEngagement(_rd, _scrolledIn);
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      final token = ready(_rd).resetToken;
      final captures = service.captures.length;
      controls.refreshRail(_rd);
      expect(service.captures, hasLength(captures + 1));
      await land();
      expect(shown(_rd), ['R${captures + 1}-0', 'R${captures + 1}-1', 'R${captures + 1}-2']);
      expect(ready(_rd).showNotice, isFalse);
      expect(ready(_rd).resetToken, isNot(token));
    });

    test('a pointer down at the start defers the refresh, without a notice, '
        'until it lifts', () async {
      await start();
      await land();
      controls.setRailEngagement(_rd, _touchedAtStart);
      controls.setRailEngagement(_more, _touchedAtStart);
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      expect(service.captures, hasLength(1));
      expect(ready(_rd).showNotice, isFalse, reason: 'not scrolled in');
      controls.setRailEngagement(_rd, _atRest);
      await settle();
      expect(service.captures, hasLength(2));
      await land();
      expect(shown(_rd), ['R2-0', 'R2-1', 'R2-2']);
      expect(shown(_more), ['M1-0', 'M1-1', 'M1-2'], reason: 'still touched');
    });

    test('a scrolled rail that comes back to rest at its start refreshes '
        'silently and drops the notice', () async {
      await start();
      await land();
      controls.setRailEngagement(_rd, _scrolledTouched);
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      await land();
      expect(ready(_rd).showNotice, isTrue);
      controls.setRailEngagement(_rd, _touchedAtStart);
      await settle();
      expect(ready(_rd).showNotice, isFalse, reason: 'only while scrolled in');
      final captures = service.captures.length;
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      controls.setRailEngagement(_rd, _atRest);
      await settle();
      expect(service.captures, hasLength(captures + 1));
      await land();
      expect(shown(_rd).first, startsWith('R${captures + 1}-'));
      expect(ready(_rd).showNotice, isFalse);
    });

    test('a refresh that lands after the user scrolled in is held: items '
        'never move under the user', () async {
      await start();
      await land();
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      expect(service.captures, hasLength(2));
      controls.setRailEngagement(_rd, _scrolledIn);
      await land();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      expect(ready(_rd).showNotice, isTrue);
      expect(shown(_more), ['M2-0', 'M2-1', 'M2-2']);
    });

    test('a refresh that lands while a pointer went down at the start is held',
        () async {
      await start();
      await land();
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      controls.setRailEngagement(_rd, _touchedAtStart);
      await land();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      controls.setRailEngagement(_rd, _atRest);
      await settle();
      expect(service.captures, hasLength(3));
      await land();
      expect(shown(_rd), ['R3-0', 'R3-1', 'R3-2']);
    });

    test('new history while Home is not visible does nothing until it is',
        () async {
      await start();
      await land();
      controls.setHomeVisible(false);
      service.last.staleness.add(SnapshotStaleness.newActivity);
      downloads.add((count: 3, totalBytes: 10));
      await settle();
      expect(service.captures, hasLength(1));
      expect(ready(_rd).showNotice, isFalse);
    });
  });

  group('Home visible', () {
    test('becoming visible re-snapshots both rails once, even a rail left '
        'scrolled in', () async {
      await start();
      await land();
      controls.setRailEngagement(_rd, _scrolledIn);
      controls.setHomeVisible(false);
      await settle();
      expect(service.captures, hasLength(1));
      controls.setHomeVisible(true);
      await settle();
      expect(service.captures, hasLength(2));
      final token = ready(_rd).resetToken;
      await land();
      expect(shown(_rd), ['R2-0', 'R2-1', 'R2-2']);
      expect(shown(_more), ['M2-0', 'M2-1', 'M2-2']);
      expect(ready(_rd).resetToken, isNot(token));
      expect(ready(_rd).showNotice, isFalse);
    });

    test('visible again without having been hidden does nothing', () async {
      await start();
      await land();
      controls.setHomeVisible(true);
      await settle();
      expect(service.captures, hasLength(1));
    });

    test('a pointer down when the visible-refresh lands holds it', () async {
      await start();
      await land();
      controls.setHomeVisible(false);
      controls.setHomeVisible(true);
      await settle();
      controls.setRailEngagement(_rd, _touchedAtStart);
      await land();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      expect(shown(_more), ['M2-0', 'M2-1', 'M2-2']);
    });
  });

  group('filter change', () {
    test('the Home chip re-snapshots both rails with the new filter', () async {
      service.candidates[2] = {
        _rd: const ['R2-a', 'R2-d1', 'R2-d2'],
        _more: const ['M2-a'],
      };
      await start();
      await land();
      home.setDownloaded(true);
      expect(stateOf(_rd), isA<SuggestionRailLoading>());
      expect(service.captures, hasLength(2));
      await land();
      expect(shown(_rd), ['R2-d1', 'R2-d2']);
      expect(shown(_more), isEmpty);
      expect(ready(_more).emptiedByFilter, isTrue);
    });

    test('a load overtaken by a filter change never lands', () async {
      // Snapshot 1 has a downloaded pick, so landing late would show it.
      service.candidates[1] = {_rd: const ['R1-d'], _more: const ['M1-d']};
      await start();
      final first = service.last;
      home.setDownloaded(true);
      final second = service.last;
      expect(second, isNot(same(first)));
      await land(second);
      expect(shown(_rd), isEmpty);
      first.complete();
      await settle();
      expect(shown(_rd), isEmpty, reason: 'snapshot 1 is stale');
      expect(ready(_rd).emptiedByFilter, isTrue);
    });
  });

  group('current track (same frozen snapshot)', () {
    test('a new current track is excluded at once and refilled without a new '
        'snapshot', () async {
      await start();
      await land();
      // Hold hydration: what shows before it is the immediate exclusion.
      service.resolveGate = Completer<void>();
      container.read(_current.notifier).state = track('R1-1');
      await settle();
      expect(shown(_rd), ['R1-0', 'R1-2']);
      service.resolveGate!.complete();
      service.resolveGate = null;
      await settle();
      expect(shown(_rd), ['R1-0', 'R1-2', 'R1-3']);
      expect(service.captures, hasLength(1));
      // The previous current track comes back from the same snapshot.
      service.resolveGate = Completer<void>();
      container.read(_current.notifier).state = track('M1-0');
      await settle();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      expect(shown(_more), ['M1-1', 'M1-2']);
      service.resolveGate!.complete();
      service.resolveGate = null;
      await settle();
      expect(shown(_more), ['M1-1', 'M1-2', 'M1-3']);
      expect(service.captures, hasLength(1));
    });

    test('a track restored at launch is excluded from the first snapshot',
        () async {
      container = makeContainer();
      container.read(_current.notifier).state = track('R1-0');
      final prefsSub = container.listen(homeLayoutPreferencesProvider, (_, _) {});
      addTearDown(prefsSub.close);
      await container.read(homeLayoutPreferencesProvider.future);
      controls = container.read(homeSuggestionsControlsProvider);
      await settle();
      await land();
      expect(shown(_rd), ['R1-1', 'R1-2', 'R1-3']);
    });

    test('a late refill for an older current track never lands', () async {
      await start();
      await land();
      service.resolveGate = Completer<void>();
      container.read(_current.notifier).state = track('R1-0');
      await settle();
      final slow = service.resolveGate!;
      service.resolveGate = null;
      container.read(_current.notifier).state = track('R1-1');
      await settle();
      expect(shown(_rd), ['R1-0', 'R1-2', 'R1-3']);
      slow.complete();
      await settle();
      expect(shown(_rd), ['R1-0', 'R1-2', 'R1-3']);
    });

    test('a scrolled-in rail with a notice still excludes the current track '
        'from what it shows', () async {
      await start();
      await land();
      controls.setRailEngagement(_rd, _scrolledIn);
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      await land();
      expect(ready(_rd).showNotice, isTrue);
      final captures = service.captures.length;
      container.read(_current.notifier).state = track('R1-2');
      await settle();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-3']);
      expect(ready(_rd).showNotice, isTrue);
      expect(service.captures, hasLength(captures));
    });
  });

  group('download and metadata invalidation', () {
    test('a download change refreshes a rail at rest and only flags a '
        'scrolled one', () async {
      await start();
      // The watch's first value is the baseline, not a change (review r1 F4).
      downloads.add((count: 0, totalBytes: 0));
      await land();
      expect(service.captures, hasLength(1));
      controls.setRailEngagement(_more, _scrolledIn);
      downloads.add((count: 1, totalBytes: 5));
      await settle();
      expect(service.captures, hasLength(2));
      await land();
      expect(shown(_rd), ['R2-0', 'R2-1', 'R2-2']);
      expect(shown(_more), ['M1-0', 'M1-1', 'M1-2']);
      expect(ready(_more).showNotice, isTrue);
    });
  });

  group('hide', () {
    test('hiding a rail drops its in-flight load; showing it again loads '
        'anew', () async {
      await start();
      await container
          .read(homeLayoutPreferencesProvider.notifier)
          .setHidden(HomeSectionIds.rediscover, true);
      await land(service.captures.first);
      expect(stateOf(_rd), isNot(isA<SuggestionRailReady>()));
      expect(shown(_more), ['M1-0', 'M1-1', 'M1-2']);
      final captures = service.captures.length;
      // A hidden rail does no work on new history (the visible one is
      // scrolled in, so it only flags).
      controls.setRailEngagement(_more, _scrolledIn);
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      expect(service.captures, hasLength(captures));

      await container
          .read(homeLayoutPreferencesProvider.notifier)
          .setHidden(HomeSectionIds.rediscover, false);
      await settle();
      expect(stateOf(_rd), isA<SuggestionRailLoading>());
      expect(service.captures, hasLength(captures + 1));
      await land();
      expect(shown(_rd).first, startsWith('R${captures + 1}-'));
      expect(shown(_more), ['M1-0', 'M1-1', 'M1-2'], reason: 'untouched');
    });

    test('a hidden rail stored before launch never loads', () async {
      SharedPreferences.setMockInitialValues({
        'settings.homeHiddenSections': [
          HomeSectionIds.rediscover,
          HomeSectionIds.moreFromArtists,
        ],
      });
      await start();
      expect(service.captures, isEmpty);
    });
  });

  // Correctness review r1 (phase-9/9B.2-review.md).
  group('review r1', () {
    test('F1: a Home-visible refresh is held when the user scrolled in after '
        'the trigger', () async {
      await start();
      await land();
      final token = ready(_rd).resetToken;
      controls.setHomeVisible(false);
      controls.setHomeVisible(true);
      await settle();
      expect(service.captures, hasLength(2));
      controls.setRailEngagement(_rd, _scrolledIn);
      await land();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      expect(ready(_rd).resetToken, token);
      expect(ready(_rd).showNotice, isTrue);
      expect(shown(_more), ['M2-0', 'M2-1', 'M2-2']);
    });

    test('F2: a rail that collapsed while scrolled in comes back on new '
        'history', () async {
      service.candidates[2] = {_rd: const [], _more: const ['M2-a']};
      await start();
      await land();
      controls.setRailEngagement(_rd, _scrolledIn);
      // The notice tap takes snapshot 2, in which Rediscover is empty: the
      // rail collapses and no rail widget reports engagement any more.
      controls.refreshRail(_rd);
      await land();
      expect(shown(_rd), isEmpty);
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      expect(service.captures, hasLength(3));
      await land();
      expect(shown(_rd), ['R3-0', 'R3-1', 'R3-2']);
    });

    test('F3: a failed background refresh keeps the rail pending, so it '
        'retries later (the real freshness stream emits each change once)',
        () async {
      await start();
      await land();
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      expect(service.captures, hasLength(2));
      service.last.fail();
      await settle();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      controls.setRailEngagement(_rd, _scrolledIn);
      expect(ready(_rd).showNotice, isTrue);
      controls.setRailEngagement(_rd, _atRest);
      await settle();
      expect(service.captures, hasLength(3));
    });

    test('F4: a download change during a load refreshes once it lands', () async {
      await start();
      downloads.add((count: 0, totalBytes: 0)); // baseline
      downloads.add((count: 1, totalBytes: 5)); // a download finished
      await settle();
      expect(service.captures, hasLength(1));
      await land();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      expect(service.captures, hasLength(2));
      await land();
      expect(shown(_rd), ['R2-0', 'R2-1', 'R2-2']);
    });

    test('F5: a refill overtaken by a refresh that is held still lands',
        () async {
      await start();
      await land();
      service.resolveGate = Completer<void>();
      container.read(_current.notifier).state = track('R1-0');
      await settle();
      expect(shown(_rd), ['R1-1', 'R1-2']);
      final slow = service.resolveGate!;
      service.resolveGate = null;
      service.last.staleness.add(SnapshotStaleness.newActivity);
      await settle();
      expect(service.captures, hasLength(2));
      controls.setRailEngagement(_rd, _scrolledIn);
      await land();
      expect(ready(_rd).showNotice, isTrue);
      slow.complete();
      await settle();
      expect(shown(_rd), ['R1-1', 'R1-2', 'R1-3']);
    });

    test('F1 re-check N1: dragging further into a rail scrolled in at the '
        'trigger holds the visible refresh', () async {
      await start();
      await land();
      controls.setRailEngagement(_rd, _scrolledIn);
      final token = ready(_rd).resetToken;
      controls.setHomeVisible(false);
      controls.setHomeVisible(true);
      await settle();
      // The user drags the rail further and lets go: same final value.
      controls.setRailEngagement(_rd, _scrolledTouched);
      controls.setRailEngagement(_rd, _scrolledIn);
      await land();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
      expect(ready(_rd).resetToken, token);
    });

    test('F1 re-check N2: a visible refresh lands when the rail is at rest at '
        'landing', () async {
      await start();
      await land();
      controls.setRailEngagement(_rd, _touchedAtStart);
      controls.setHomeVisible(false);
      controls.setHomeVisible(true);
      await settle();
      controls.setRailEngagement(_rd, _atRest);
      await settle();
      await land(service.captures[1]);
      expect(shown(_rd).first, startsWith('R2-'));
      expect(ready(_rd).showNotice, isFalse);
    });

    test('F10: an error on the freshness stream keeps the frozen items',
        () async {
      await start();
      await land();
      service.last.staleness.addError(StateError('db closed'));
      await settle();
      expect(shown(_rd), ['R1-0', 'R1-1', 'R1-2']);
    });
  });

  group('disposal', () {
    test('a result arriving after the scope is gone is dropped', () async {
      await start();
      final pending = service.last;
      container.dispose();
      pending.complete();
      await settle();
      expect(notifications, 0);
    });
  });
}
