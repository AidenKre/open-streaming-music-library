import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/downloaded_tracks_page.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/tracks_page.dart';

import 'browse_harness.dart';
import 'fake_library_actions.dart';

/// SC-26: every row tap on today's pages goes to LibraryActionControls
/// (never to the queue player), with the right scope, list and filter.
void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late FakeLibraryActions actions;

  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(
        uuid: 'k1',
        title: 'Kite One',
        artistId: 1,
        artist: 'Ann',
        albumId: 2,
        album: 'Air',
        trackNumber: 1,
        downloaded: true,
      ),
      SeedTrack(
        uuid: 'k2',
        title: 'Kite Two',
        artistId: 1,
        artist: 'Ann',
        albumId: 2,
        album: 'Air',
        trackNumber: 2,
        downloaded: true,
      ),
    ]);
    harness = await BrowseHarness.create(db);
    actions = FakeLibraryActions();
  });

  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      harness.wrap(
        page,
        overrides: [libraryActionsProvider.overrideWithValue(actions)],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  testWidgets('album detail row tap plays the album query', (tester) async {
    await pump(
      tester,
      const Scaffold(body: TracksPage(artistId: 1, albumId: 2)),
    );
    await tester.tap(find.text('Kite Two'));
    expect(actions.calls, ['playQuery k2 album(1,2) downloadedOnly=false']);
    await teardownTree(tester);
  });

  testWidgets('root Tracks row tap plays the library query with the chip', (
    tester,
  ) async {
    await pump(tester, const Scaffold(body: TracksPage(browseAll: true)));
    await tester.tap(find.text('Downloaded'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kite One'));
    expect(actions.calls, ['playQuery k1 library downloadedOnly=true']);
    await teardownTree(tester);
  });

  testWidgets('root Tracks search row tap plays the result list', (
    tester,
  ) async {
    await pump(tester, const Scaffold(body: TracksPage(browseAll: true)));
    await search(tester, 'kite');
    await tester.tap(find.text('Kite Two'));
    expect(actions.calls, ['playFromList k1,k2 @1 search']);
    await teardownTree(tester);
  });

  testWidgets('global Search song tap plays the result list', (tester) async {
    await pump(tester, const SearchPage());
    await search(tester, 'kite');
    await tester.tap(find.text('Kite One'));
    expect(actions.calls, ['playFromList k1,k2 @0 search']);
    await teardownTree(tester);
  });

  testWidgets('Downloaded row tap plays the downloaded library query', (
    tester,
  ) async {
    await pump(tester, const DownloadedTracksPage());
    await tester.tap(find.text('Kite Two'));
    expect(actions.calls, ['playQuery k2 library downloadedOnly=true']);
    await teardownTree(tester);
  });
}
