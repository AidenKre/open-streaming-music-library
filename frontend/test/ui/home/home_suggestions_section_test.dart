// Phase 9 §5 / SC-07 / SC-26 / D7 / 9-U11 / 9-R02 (unit half): Home
// registers `home.rediscover` and `home.more_from_artists` after the recents
// rail, each hideable through `HomeLayoutPreferences` (the registry filters a
// hidden section out; Home's widget tree is not edited). The sections render
// only what `HomeSuggestionsControls` says and forward every input to it.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/home_suggestions_service.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/home/home_controller.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/home/home_suggestions_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../browse_harness.dart';

TrackUI _track(String uuid) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: 'Song $uuid',
  artist: 'Ann',
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

class _FakeHome extends ChangeNotifier implements HomeControls {
  @override
  BrowseFilters get filters =>
      const BrowseFilters(policy: OfflineFilterPolicy.manual);
  @override
  void setDownloaded(bool value) {}
  @override
  HomeRecentsState get recents => const HomeRecentsEmpty(filtered: false);
  @override
  void retryRecents() {}
  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) async => const Accepted(1);
}

class _FakeSuggestions extends ChangeNotifier
    implements HomeSuggestionsControls {
  final states = <SuggestionRail, SuggestionRailState>{
    SuggestionRail.rediscover: const SuggestionRailLoading(),
    SuggestionRail.moreFromArtists: const SuggestionRailLoading(),
  };
  final played = <String>[];
  final refreshed = <SuggestionRail>[];
  final retried = <SuggestionRail>[];
  final engagement = <(SuggestionRail, RailEngagement)>[];

  void set(SuggestionRail rail, SuggestionRailState state) {
    states[rail] = state;
    notifyListeners();
  }

  @override
  SuggestionRailState stateOf(SuggestionRail rail) => states[rail]!;
  @override
  void setHomeVisible(bool visible) {}
  @override
  void setRailEngagement(SuggestionRail rail, RailEngagement e) =>
      engagement.add((rail, e));
  @override
  void refreshRail(SuggestionRail rail) => refreshed.add(rail);
  @override
  void retry(SuggestionRail rail) => retried.add(rail);
  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) async {
    played.add(track.uuidId);
    return const Accepted(1);
  }
}

SuggestionRailReady _ready(
  List<String> ids, {
  bool emptiedByFilter = false,
  bool showNotice = false,
  Object resetToken = 1,
}) => SuggestionRailReady(
  tracks: [for (final id in ids) _track(id)],
  emptiedByFilter: emptiedByFilter,
  resetToken: resetToken,
  showNotice: showNotice,
);

const _rd = SuggestionRail.rediscover;
const _more = SuggestionRail.moreFromArtists;
const _rdCaption = 'Tracks you enjoyed, but haven’t played in two weeks';
const _moreCaption =
    'Music you haven’t played through yet, from artists you listened to in '
    'the last 30 days';

Finder _body(String id) => find.byKey(ValueKey('feed.rail.$id.body'));

void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late _FakeSuggestions fake;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
    fake = _FakeSuggestions();
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<void> pumpHome(WidgetTester tester, {bool settle = true}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      harness.wrap(
        const HomePage(),
        overrides: [
          homeControlsProvider.overrideWithValue(_FakeHome()),
          homeSuggestionsControlsProvider.overrideWithValue(fake),
        ],
      ),
    );
    // A loading rail's spinner never settles.
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  group('registry', () {
    Future<List<HomeSectionSpec>> sections(ProviderContainer c) async {
      final sub = c.listen(homeLayoutPreferencesProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(homeLayoutPreferencesProvider.future);
      return c.read(homeSectionsProvider);
    }

    test('both rails follow recents, hideable by their own id', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final specs = await sections(c);
      final ids = [for (final s in specs) s.id];
      final recents = ids.indexOf(HomeSectionIds.recents);
      expect(ids.indexOf(HomeSectionIds.rediscover), recents + 1);
      expect(ids.indexOf(HomeSectionIds.moreFromArtists), recents + 2);
      final keys = {for (final s in specs) s.id: s.hidePreferenceKey};
      expect(keys[HomeSectionIds.rediscover], HomeSectionIds.rediscover);
      expect(keys[HomeSectionIds.moreFromArtists], HomeSectionIds.moreFromArtists);
      expect(keys[HomeSectionIds.recents], isNull);
    });

    test('a hidden rail is not in the list; the other stays', () async {
      SharedPreferences.setMockInitialValues({
        'settings.homeHiddenSections': [HomeSectionIds.rediscover],
      });
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ids = [for (final s in await sections(c)) s.id];
      expect(ids, isNot(contains(HomeSectionIds.rediscover)));
      expect(ids, contains(HomeSectionIds.moreFromArtists));
      expect(ids, contains(HomeSectionIds.recents));
    });

    test('hideable rails are left out while the preference is unknown', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final ids = [for (final s in c.read(homeSectionsProvider)) s.id];
      expect(ids, isNot(contains(HomeSectionIds.rediscover)));
      expect(ids, isNot(contains(HomeSectionIds.moreFromArtists)));
      expect(ids, contains(HomeSectionIds.recents));
    });

    testWidgets('hiding a rail in Settings removes it from Home at once', (
      tester,
    ) async {
      fake.set(_rd, _ready(['a']));
      fake.set(_more, _ready(['b']));
      await pumpHome(tester);
      expect(find.text('Rediscover'), findsOneWidget);
      final element = tester.element(find.byType(HomePage));
      await ProviderScope.containerOf(element)
          .read(homeLayoutPreferencesProvider.notifier)
          .setHidden(HomeSectionIds.rediscover, true);
      await tester.pumpAndSettle();
      expect(find.text('Rediscover'), findsNothing);
      expect(find.text('More from your artists'), findsOneWidget);
      await teardownTree(tester);
    });
  });

  group('states', () {
    testWidgets('loading keeps the rail extent under the title', (tester) async {
      await pumpHome(tester, settle: false);
      expect(find.text('Rediscover'), findsOneWidget);
      expect(_body(HomeSectionIds.rediscover), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      await teardownTree(tester);
    });

    testWidgets('ready: title, caption and cards in order', (tester) async {
      fake.set(_rd, _ready(['a', 'b']));
      fake.set(_more, _ready(['c']));
      await pumpHome(tester);
      expect(find.text(_rdCaption), findsOneWidget);
      expect(find.text(_moreCaption), findsOneWidget);
      expect(find.text('More from your artists'), findsOneWidget);
      final a = tester.getTopLeft(find.byKey(const ValueKey('track:a'))).dx;
      final b = tester.getTopLeft(find.byKey(const ValueKey('track:b'))).dx;
      expect(a < b, isTrue);
      final rd = tester.getTopLeft(find.text('Rediscover')).dy;
      final more = tester.getTopLeft(find.text('More from your artists')).dy;
      expect(rd < more, isTrue);
      await teardownTree(tester);
    });

    testWidgets('empty collapses completely: no title, no caption', (
      tester,
    ) async {
      fake.set(_rd, _ready(const []));
      fake.set(_more, _ready(['c']));
      await pumpHome(tester);
      expect(find.text('Rediscover'), findsNothing);
      expect(find.text(_rdCaption), findsNothing);
      expect(_body(HomeSectionIds.rediscover), findsNothing);
      expect(find.text('More from your artists'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('emptied by the Downloaded chip keeps the title and says so',
        (tester) async {
      fake.set(_rd, _ready(const [], emptiedByFilter: true));
      fake.set(_more, _ready(const []));
      await pumpHome(tester);
      expect(find.text('Rediscover'), findsOneWidget);
      expect(find.text('No downloaded suggestions'), findsOneWidget);
      expect(find.text('More from your artists'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a failed load offers Retry for that rail', (tester) async {
      fake.set(_rd, _ready(['a']));
      fake.set(_more, const SuggestionRailFailed());
      await pumpHome(tester);
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(fake.retried, [_more]);
      await teardownTree(tester);
    });
  });

  group('input', () {
    testWidgets('a card tap plays that track through the controller', (
      tester,
    ) async {
      fake.set(_rd, _ready(['a', 'b']));
      fake.set(_more, _ready(['c']));
      await pumpHome(tester);
      await tester.tap(find.byKey(const ValueKey('track:b')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('track:c')));
      await tester.pump();
      expect(fake.played, ['b', 'c']);
      await teardownTree(tester);
    });

    testWidgets('the notice shows its copy and its tap refreshes that rail', (
      tester,
    ) async {
      fake.set(_rd, _ready(['a']));
      fake.set(_more, _ready(['c'], showNotice: true));
      await pumpHome(tester);
      expect(find.text('New listening activity'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      await tester.tap(find.text('Refresh'));
      await tester.pump();
      expect(fake.refreshed, [_more]);
      await teardownTree(tester);
    });

    testWidgets('no notice while the controller shows none', (tester) async {
      fake.set(_rd, _ready(['a']));
      fake.set(_more, _ready(['c']));
      await pumpHome(tester);
      expect(find.text('New listening activity'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a pointer on a rail is reported for that rail', (tester) async {
      fake.set(_rd, _ready(['a', 'b']));
      fake.set(_more, _ready(['c']));
      await pumpHome(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('track:c'))),
      );
      await tester.pump();
      expect(
        fake.engagement.last,
        (_more, const RailEngagement(atStart: true, pointerDown: true)),
      );
      await gesture.up();
      await tester.pump();
      expect(
        fake.engagement.last,
        (_more, const RailEngagement(atStart: true, pointerDown: false)),
      );
      await teardownTree(tester);
    });
  });
}
