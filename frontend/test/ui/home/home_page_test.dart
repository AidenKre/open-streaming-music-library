import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/artist_page.dart';
import 'package:frontend/ui/downloaded_tracks_page.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/tracks_page.dart';

import '../browse_harness.dart';

/// SC-07: Home is registry-driven (sections + entry points).
void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  double dy(WidgetTester t, String text) => t.getTopLeft(find.text(text)).dy;

  testWidgets('search header, then Artists, Albums, Tracks, Downloaded', (
    tester,
  ) async {
    await tester.pumpWidget(harness.wrap(const HomePage()));
    await tester.pump();
    expect(find.text('Search your library'), findsOneWidget);
    final order = [
      'Search your library',
      'Artists',
      'Albums',
      'Tracks',
      'Downloaded',
    ];
    final ys = [for (final t in order) dy(tester, t)];
    expect([...ys]..sort(), ys);
    // Nothing for unimplemented features (no empty Recently played rail).
    expect(find.textContaining('Recent'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('the search header navigates; it never takes focus itself', (
    tester,
  ) async {
    var activated = 0;
    await tester.pumpWidget(
      harness.wrap(HomePage(onSearchActivated: () => activated++)),
    );
    await tester.pump();
    // (A focused field's node context sits INSIDE its EditableText.)
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>(),
      isNull,
    );
    await tester.tap(find.text('Search your library'));
    expect(activated, 1);
    await teardownTree(tester);
  });

  testWidgets('later phases append entry points without editing Home', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness.wrap(
        const HomePage(),
        overrides: [
          homeEntryPointsProvider.overrideWithValue(const [
            HomeEntryPoint(
              id: 'tracks',
              label: 'Tracks',
              icon: Icons.music_note,
              destination: BrowseDestination.tracks,
            ),
            HomeEntryPoint(
              id: 'extra',
              label: 'Extra',
              icon: Icons.star,
              destination: BrowseDestination.downloaded,
            ),
          ]),
          homeSectionsProvider.overrideWithValue([homeEntryPointsSectionSpec]),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('Extra'), findsOneWidget);
    expect(find.text('Artists'), findsNothing);
    // Without the home.search section, no header.
    expect(find.text('Search your library'), findsNothing);
    await teardownTree(tester);
  });

  for (final (label, page) in [
    ('Artists', ArtistsPage),
    ('Albums', AlbumsPage),
    ('Tracks', TracksPage),
    ('Downloaded', DownloadedTracksPage),
  ]) {
    testWidgets('$label opens its browse page (offline too)', (tester) async {
      await tester.pumpWidget(harness.wrap(const HomePage(), offline: true));
      await tester.pump();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(find.byType(page), findsOneWidget);
      await teardownTree(tester);
    });
  }

  test('home.recents is reserved after the entry points, not registered', () {
    expect(
      HomeSectionIds.order.indexOf('home.recents'),
      greaterThan(HomeSectionIds.order.indexOf(HomeSectionIds.entryPoints)),
    );
  });

  // Audit 4A(b) #5: the registered sections follow HomeSectionIds.order
  // (later phases insert into the list; the order list is the contract).
  test('registered Home sections follow HomeSectionIds.order', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final ids = [for (final s in container.read(homeSectionsProvider)) s.id];
    final idx = [for (final id in ids) HomeSectionIds.order.indexOf(id)];
    expect(idx, isNot(contains(-1)));
    expect(idx, [...idx]..sort());
  });
}
