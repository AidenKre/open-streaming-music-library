// Phase 6 §3 (Home rail, Recent taps, Home chip) / SC-07 / O6 / O7 /
// 6-R03, 6-R06, 6-R07 (unit halves): Home registers `home.filters` and
// `home.recents`; the sections render only what `HomeControls` says.
// Widget tests over a fake controller (SC-26: the view observes the
// controller and forwards input).
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/new_activity_notice.dart';
import 'package:frontend/ui/home/home_controller.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';

import '../../helpers/fake_home_controls.dart';
import '../browse_harness.dart';

TrackUI _track(String uuid) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: 'Song $uuid',
  artist: 'Ann',
  artistId: 1,
  albumId: 2,
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

const _album = AlbumUI(id: 2, artistId: 1, name: 'Second', artist: 'Ann');
const _artist = ArtistUI(id: 1, name: 'Ann');

List<FeedEntity> _tracks(List<String> ids) => [
  for (final id in ids) TrackEntity(_track(id)),
];

const _title = 'Recently played';
final _body = find.byKey(const ValueKey('feed.rail.home.recents.body'));
final _chip = find.byKey(FilterBar.downloadedChipKey);

void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  /// [inScaffold]: inside a Scaffold, as in the shell, so a notice shows.
  Future<void> pumpHome(
    WidgetTester tester,
    FakeHomeControls fake, {
    bool inScaffold = false,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      harness.wrap(
        inScaffold ? const Scaffold(body: HomePage()) : const HomePage(),
        overrides: [homeControlsProvider.overrideWithValue(fake)],
      ),
    );
    await tester.pump();
  }

  test('home.filters is registered directly before home.recents', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final ids = [for (final s in container.read(homeSectionsProvider)) s.id];
    final f = ids.indexOf(HomeSectionIds.filters);
    expect(f, isNot(-1));
    expect(ids.indexOf(HomeSectionIds.recents), f + 1);
  });

  group('states', () {
    testWidgets('settled empty hides the title; the chip stays (O6)',
        (tester) async {
      await pumpHome(tester, FakeHomeControls(
        const HomeRecentsEmpty(filtered: false),
      ));
      expect(find.text(_title), findsNothing);
      expect(find.text('No downloaded recents'), findsNothing);
      expect(_body, findsNothing);
      expect(_chip, findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('filtered empty keeps the title, the message and the chip',
        (tester) async {
      final fake = FakeHomeControls(const HomeRecentsEmpty(filtered: true));
      await pumpHome(tester, fake);
      fake.setDownloaded(true);
      await tester.pump();
      expect(find.text(_title), findsOneWidget);
      expect(find.text('No downloaded recents'), findsOneWidget);
      expect(_chip, findsOneWidget);
      // The chip is above the rail title, and can turn the filter off.
      expect(
        tester.getTopLeft(_chip).dy,
        lessThan(tester.getTopLeft(find.text(_title)).dy),
      );
      await tester.tap(_chip);
      await tester.pump();
      expect(fake.chipTaps, [true, false]);
      await teardownTree(tester);
    });

    testWidgets('an error shows a retry section', (tester) async {
      final fake = FakeHomeControls(const HomeRecentsFailed());
      await pumpHome(tester, fake);
      expect(find.text(_title), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(fake.retries, 1);
      await teardownTree(tester);
    });

    testWidgets('loading reserves the normal rail extent', (tester) async {
      final fake = FakeHomeControls(const HomeRecentsLoading());
      await pumpHome(tester, fake);
      expect(find.text(_title), findsOneWidget);
      final loading = tester.getSize(_body).height;
      fake.recentsState = HomeRecentsReady(_tracks(['a']));
      await tester.pump();
      expect(tester.getSize(_body).height, loading);
      expect(find.text('Song a'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('ready shows the entities in order and follows the '
        'controller', (tester) async {
      final fake = FakeHomeControls(
        HomeRecentsReady([
          const AlbumEntity(_album),
          TrackEntity(_track('a')),
          const ArtistEntity(_artist),
        ]),
      );
      await pumpHome(tester, fake);
      double x(Key k) => tester.getTopLeft(find.byKey(k)).dx;
      expect(x(const ValueKey('album:2')),
          lessThan(x(const ValueKey('track:a'))));
      expect(x(const ValueKey('track:a')),
          lessThan(x(const ValueKey('artist:1'))));
      fake.recentsState = const HomeRecentsEmpty(filtered: false);
      await tester.pump();
      expect(find.text(_title), findsNothing);
      await teardownTree(tester);
    });
  });

  group('taps', () {
    testWidgets('a track plays through the controller', (tester) async {
      final fake = FakeHomeControls(HomeRecentsReady(_tracks(['a', 'b'])));
      await pumpHome(tester, fake);
      await tester.tap(find.text('Song b'));
      await tester.pump();
      expect(fake.played, ['b']);
      await teardownTree(tester);
    });

    // Owner decision 5 (2026-11-17), APP-OTHER-1 D5: a track tap whose
    // playback does not start shows the playback message as a notice.
    testWidgets('a track tap that does not start playback says so', (
      tester,
    ) async {
      final fake = FakeHomeControls(HomeRecentsReady(_tracks(['a', 'b'])))
        ..playOutcome = Failed(StateError('x'));
      await pumpHome(tester, fake, inScaffold: true);
      expect(find.text("Couldn't start playback."), findsNothing);
      await tester.tap(find.text('Song b'));
      await tester.pump();
      await tester.pump();
      expect(fake.played, ['b']);
      expect(find.text("Couldn't start playback."), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('an album opens its detail page only', (tester) async {
      final fake = FakeHomeControls(
        const HomeRecentsReady([AlbumEntity(_album)]),
      );
      await pumpHome(tester, fake);
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(find.byType(TracksPage), findsOneWidget);
      expect(fake.played, isEmpty);
      expect(harness.audio.calls, isEmpty);
      await teardownTree(tester);
    });

    testWidgets('an artist opens its detail page only', (tester) async {
      final fake = FakeHomeControls(
        const HomeRecentsReady([ArtistEntity(_artist)]),
      );
      await pumpHome(tester, fake);
      await tester.tap(find.byKey(const ValueKey('artist:1')));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumsPage), findsOneWidget);
      expect(fake.played, isEmpty);
      expect(harness.audio.calls, isEmpty);
      await teardownTree(tester);
    });
  });

  testWidgets('the rail keeps its anchor and offers New activity (O7)',
      (tester) async {
    final ids = [for (var i = 0; i < 10; i++) 't$i'];
    final fake = FakeHomeControls(HomeRecentsReady(_tracks(ids)));
    await pumpHome(tester, fake);
    final rail = tester
        .state<ScrollableState>(
          find.descendant(of: _body, matching: find.byType(Scrollable)),
        )
        .position;
    rail.jumpTo(8 + 3 * FeedCardExtent.cardWidth + 20);
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(const ValueKey('track:t3')));

    fake.recentsState = HomeRecentsReady(_tracks(['n0', ...ids]));
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('track:t3'))),
      before,
    );
    expect(find.byType(NewActivityNotice), findsOneWidget);
    expect(find.text('New activity'), findsOneWidget);
    await teardownTree(tester);
  });
}
