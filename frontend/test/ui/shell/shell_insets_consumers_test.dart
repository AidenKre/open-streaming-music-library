import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/browse/browse_pages.dart';
import 'package:frontend/ui/downloaded_tracks_page.dart';
import 'package:frontend/ui/get_info_page.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/shell/app_shell.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/widgets/library_card.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';

/// 4B.1 (phase-4 §8): every surface inside the shell pads its end by the
/// MEASURED bottom chrome, so its last item is reachable above the glass.
void main() {
  late AppDatabase db;
  late BrowseHarness h;

  setUpAll(() => ApiClient.init('http://localhost:8000'));

  setUp(() async {
    initCoverArtCache(CoverArtCacheManager.noop());
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, [
      // Artist 1: 20 single-track albums (artist detail grid).
      for (var i = 1; i <= 20; i++)
        SeedTrack(
          uuid: 'a$i',
          title: 'Song A$i',
          artistId: 1,
          artist: 'Ann',
          albumId: i,
          album: 'Album $i',
          downloaded: i <= 12,
        ),
      // Artist 2: one album with 30 tracks (album detail list).
      for (var i = 1; i <= 30; i++)
        SeedTrack(
          uuid: 'b$i',
          title: 'Song B$i',
          artistId: 2,
          artist: 'Bo',
          albumId: 100,
          album: 'Big',
          trackNumber: i,
          downloaded: i <= 10,
        ),
      // 40 more artists (Artists browse > one window).
      for (var i = 1; i <= 40; i++)
        SeedTrack(
          uuid: 'c$i',
          title: 'Song C$i',
          artistId: 10 + i,
          artist: 'Artist $i',
          albumId: 200 + i,
          album: 'Cee $i',
        ),
    ]);
    h = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await db.close();
    await h.dispose();
  });

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      h.wrap(
        const SessionHost(root: AppShell()),
        overrides: [
          sessionControlsProvider.overrideWithValue(FakeSessionControls()),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Page to the true end (growing windows), then check the last item.
  Future<void> expectLastAboveChrome(
    WidgetTester tester,
    Finder within,
    Finder items,
  ) async {
    final scrollable = find
        .descendant(of: within, matching: find.byType(Scrollable))
        .last;
    for (var i = 0; i < 8; i++) {
      final pos = tester.state<ScrollableState>(scrollable).position;
      pos.jumpTo(pos.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    final last = tester.getRect(
      find.descendant(of: within, matching: items).last,
    );
    final chromeTop = tester.getTopLeft(find.byKey(AppShell.bottomStackKey)).dy;
    expect(
      last.bottom,
      lessThanOrEqualTo(chromeTop + 0.5),
      reason: 'last item ${last.bottom} vs chrome top $chromeTop',
    );
  }

  Future<void> openEntry(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('Artists browse grid', (tester) async {
    await pumpShell(tester);
    await openEntry(tester, 'Artists');
    await expectLastAboveChrome(
      tester,
      find.byType(ArtistsBrowsePage),
      find.byType(LibraryCard),
    );
    await teardownTree(tester);
  });

  testWidgets('Albums browse grid', (tester) async {
    await pumpShell(tester);
    await openEntry(tester, 'Albums');
    await expectLastAboveChrome(
      tester,
      find.byType(AlbumsBrowsePage),
      find.byType(LibraryCard),
    );
    await teardownTree(tester);
  });

  testWidgets('Tracks browse list and its search results', (tester) async {
    await pumpShell(tester);
    await openEntry(tester, 'Tracks');
    await expectLastAboveChrome(
      tester,
      find.byType(TracksBrowsePage),
      find.byType(TrackTile),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Search tracks'),
      'Song',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await expectLastAboveChrome(
      tester,
      find.byType(TracksBrowsePage),
      find.byType(TrackTile),
    );
    await teardownTree(tester);
  });

  testWidgets('Downloaded list', (tester) async {
    await pumpShell(tester);
    await openEntry(tester, 'Downloaded');
    await expectLastAboveChrome(
      tester,
      find.byType(DownloadedTracksPage),
      find.byType(TrackTile),
    );
    await teardownTree(tester);
  });

  testWidgets('artist detail grid and album detail list', (tester) async {
    await pumpShell(tester);
    await openEntry(tester, 'Artists');
    await tester.tap(find.text('Ann'));
    await tester.pumpAndSettle();
    await expectLastAboveChrome(
      tester,
      find.byType(AlbumsPage).last,
      find.byType(LibraryCard),
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    // 'Bo' sorts after 'Artist 1..40': reach it through the in-page search.
    await tester.enterText(
      find.widgetWithText(TextField, 'Search artists'),
      'Bo',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(LibraryCard), matching: find.text('Bo')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Big'));
    await tester.pumpAndSettle();
    await expectLastAboveChrome(
      tester,
      find.byType(TracksPage).last,
      find.byType(TrackTile),
    );
    await teardownTree(tester);
  });

  testWidgets('Get info: the last row is reachable', (tester) async {
    await pumpShell(tester);
    final track = await tester.runAsync(
      () => BrowseRepository(db).getTrack('b1'),
    );
    openTrackInfo(tester.element(find.text('Artists')), track!);
    await tester.pumpAndSettle();
    final page = find.byType(GetInfoPage);
    final scrollable = find
        .descendant(of: page, matching: find.byType(Scrollable))
        .first;
    final pos = tester.state<ScrollableState>(scrollable).position;
    pos.jumpTo(pos.maxScrollExtent);
    await tester.pumpAndSettle();
    // The list's last child: its bottom edge sits above the chrome.
    final listBox = tester.getRect(scrollable);
    final chromeTop = tester.getTopLeft(find.byKey(AppShell.bottomStackKey)).dy;
    final contentEnd =
        listBox.top +
        pos.viewportDimension -
        (pos.pixels - pos.maxScrollExtent);
    expect(pos.extentAfter, 0);
    // The padding at the end is at least the chrome's height over the list.
    expect(
      listBox.bottom - chromeTop,
      greaterThan(0),
      reason: 'list runs under chrome',
    );
    final lastText = tester.getRect(
      find.descendant(of: page, matching: find.byType(Text)).last,
    );
    expect(
      lastText.bottom,
      lessThanOrEqualTo(chromeTop + 0.5),
      reason:
          'last text ${lastText.bottom} vs chrome $chromeTop (end $contentEnd)',
    );
    await teardownTree(tester);
  });
}
