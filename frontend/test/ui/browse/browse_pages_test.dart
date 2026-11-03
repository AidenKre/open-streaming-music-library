import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/browse/browse_pages.dart';
import 'package:frontend/ui/downloaded_tracks_page.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/library_card.dart';

import '../browse_harness.dart';

/// 4A.4 (phase-4 §4): browse-all routes own ONE back AppBar and reuse the
/// page bodies in browse-all mode; details never get browse controls.
void main() {
  late AppDatabase db;
  late BrowseHarness h;

  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(
        uuid: 'u1',
        title: 'Song',
        artistId: 1,
        artist: 'Ann',
        albumId: 2,
        album: 'Air',
      ),
    ]);
    h = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await h.dispose();
    await db.close();
  });

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext host;
    await tester.pumpWidget(
      h.wrap(
        Builder(
          builder: (context) {
            host = context;
            return const Scaffold(body: Text('host'));
          },
        ),
      ),
    );
    return host;
  }

  for (final (destination, title, hint) in [
    (BrowseDestination.artists, 'Artists', 'Search artists'),
    (BrowseDestination.albums, 'Albums', 'Search albums'),
    (BrowseDestination.tracks, 'Tracks', 'Search tracks'),
  ]) {
    testWidgets('$title browse: one back AppBar with the top-bar actions, '
        'chip and in-page search', (tester) async {
      final host = await pumpHost(tester);
      openBrowse(host, destination);
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.widgetWithText(AppBar, title), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byTooltip('Downloads'), findsOneWidget);
      expect(find.byTooltip('Settings'), findsOneWidget);
      expect(find.byType(FilterBar), findsOneWidget);
      expect(find.widgetWithText(TextField, hint), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('host'), findsOneWidget);
      await teardownTree(tester);
    });
  }

  testWidgets('Downloaded entry opens the Downloaded page with a back bar', (
    tester,
  ) async {
    final host = await pumpHost(tester);
    openBrowse(host, BrowseDestination.downloaded);
    await tester.pumpAndSettle();
    expect(find.byType(DownloadedTracksPage), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Downloaded'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('artist and album details get no chip or search', (tester) async {
    final host = await pumpHost(tester);
    openArtistDetail(host, const ArtistUI(id: 1, name: 'Ann'));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(FilterBar), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(LibraryCard), findsOneWidget);

    openAlbumDetail(host, const AlbumUI(id: 2, artistId: 1, name: 'Air'));
    await tester.pumpAndSettle();
    expect(find.byType(FilterBar), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Song'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('wrappers construct', (tester) async {
    // Constructible without arguments (const routes from the registry).
    expect(const ArtistsBrowsePage(), isA<Widget>());
    expect(const AlbumsBrowsePage(), isA<Widget>());
    expect(const TracksBrowsePage(), isA<Widget>());
  });
}
