import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/browse/browse_pages.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/library_card.dart';
import 'package:frontend/ui/widgets/search_status.dart';

import 'browse_harness.dart';
import '../helpers/library_seed.dart' show SeedTrack, seedLibrary;

/// 4A.4: the new all-Albums browse (phase-4 §6): watchAlbums(artistId:
/// null), the Downloaded chip (filter before limit), album-only search.
void main() {
  late AppDatabase db;
  late BrowseHarness h;

  setUpAll(() {
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      // Same album title under two artists.
      SeedTrack(
        uuid: 'a1',
        title: 'One',
        artistId: 1,
        artist: 'Ann',
        albumId: 10,
        album: 'Echoes',
      ),
      SeedTrack(
        uuid: 'a2',
        title: 'Two',
        artistId: 1,
        artist: 'Ann',
        albumId: 10,
        album: 'Echoes',
        trackNumber: 2,
        downloaded: true,
      ),
      SeedTrack(
        uuid: 'b1',
        title: 'Three',
        artistId: 2,
        artist: 'Bo',
        albumId: 20,
        album: 'Echoes',
      ),
      // A Singles grouping, and a third artist's album.
      SeedTrack(
        uuid: 's1',
        title: 'Lone',
        artistId: 2,
        artist: 'Bo',
        albumId: 21,
        album: 'Bo - Singles',
        albumIsSingles: true,
      ),
      SeedTrack(
        uuid: 'c1',
        title: 'Four',
        artistId: 3,
        artist: 'Cy',
        albumId: 30,
        album: 'Quartz',
      ),
    ]);
    h = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await h.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, {bool offline = false}) async {
    await tester.pumpWidget(h.wrap(const AlbumsBrowsePage(), offline: offline));
    await tester.pumpAndSettle();
  }

  List<int> shownIds(WidgetTester tester) => tester
      .widgetList<AlbumCard>(find.byType(AlbumCard))
      .map((c) => c.album.id)
      .toList();

  FilterChip chip(WidgetTester tester) =>
      tester.widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey));

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  testWidgets('lists every artist\'s albums, incl. same titles and Singles', (
    tester,
  ) async {
    await pump(tester);
    expect(shownIds(tester).toSet(), {10, 20, 21, 30});
    expect(find.text('Echoes'), findsNWidgets(2));
    expect(find.text('Singles'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('the chip keeps albums with at least one download (partial)', (
    tester,
  ) async {
    await pump(tester);
    expect(chip(tester).selected, isFalse);
    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    await tester.pumpAndSettle();
    expect(shownIds(tester), [10]);
    await teardownTree(tester);
  });

  testWidgets('offline turns the chip on; reconnecting undoes it', (
    tester,
  ) async {
    await pump(tester, offline: true);
    expect(chip(tester).selected, isTrue);
    expect(shownIds(tester), [10]);
    h.offline.set(false);
    await tester.pumpAndSettle();
    expect(chip(tester).selected, isFalse);
    expect(shownIds(tester).toSet(), {10, 20, 21, 30});
    await teardownTree(tester);
  });

  // Audit 4A(c) #6: renamed (2 results never reach the cap; filter-before-
  // LIMIT for albums is pinned by browse_repository_test).
  testWidgets('album-only search, then the chip narrows the results', (
    tester,
  ) async {
    await pump(tester);
    await search(tester, 'Echoes');
    expect(shownIds(tester).toSet(), {10, 20});
    await search(tester, 'Four'); // a track title: albums only
    expect(find.byType(AlbumCard), findsNothing);
    expect(find.text('No albums match "Four".'), findsOneWidget);

    await search(tester, 'Echoes');
    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    await tester.pumpAndSettle();
    expect(shownIds(tester), [10]);
    expect(find.textContaining('Showing the first'), findsNothing);
    expect(find.text(searchFailedMessage), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('an album opens its detail without browse controls', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Quartz'));
    await tester.pumpAndSettle();
    final page = tester.widget<TracksPage>(find.byType(TracksPage));
    expect(
      (page.album?.artistId, page.album?.albumId, page.browseAll),
      (3, 30, false),
    );
    expect(find.byType(FilterBar), findsNothing);
    await teardownTree(tester);
  });

  // Audit 4A(c) #5: paging and search suspension on the all-Albums browse.
  group('paging (more than one window)', () {
    setUp(() async {
      await seedLibrary(db, [
        for (var i = 1; i <= 40; i++)
          SeedTrack(
            uuid: 'pg$i',
            title: 'Pg Song $i',
            artistId: 100 + i,
            artist: 'Pg Artist $i',
            albumId: 100 + i,
            album: 'Pg Album $i',
          ),
      ]);
    });

    CursorPaginationMixin<AlbumUI> page(WidgetTester t) =>
        t.state(find.byType(AlbumsPage)) as CursorPaginationMixin<AlbumUI>;
    final grid = find.descendant(
      of: find.byType(AlbumsBrowsePage),
      matching: find.byType(GridView),
    );

    testWidgets('loads the next window on scroll, without duplicates', (
      tester,
    ) async {
      await pump(tester);
      expect(page(tester).paginatedItems, hasLength(30), reason: 'one window');
      expect(page(tester).hasMore, isTrue);
      for (var i = 0; i < 6; i++) {
        await tester.drag(grid, const Offset(0, -3000));
        await tester.pumpAndSettle();
      }
      final ids = page(tester).paginatedItems.map((a) => a.id).toList();
      expect(ids, hasLength(44));
      expect(ids.toSet(), hasLength(44));
      await teardownTree(tester);
    });

    testWidgets('search suspends the window; clearing resumes it at the top', (
      tester,
    ) async {
      await pump(tester);
      await search(tester, 'Pg');
      expect(page(tester).isPaginationSuspended, isTrue);
      final dormant = List.of(page(tester).paginatedItems);
      await tester.drag(grid, const Offset(0, -3000)); // scroll the RESULTS
      await tester.pumpAndSettle();
      expect(page(tester).paginatedItems, dormant, reason: 'no load-more');

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expect(page(tester).isPaginationSuspended, isFalse);
      final pos = tester
          .state<ScrollableState>(
            find.descendant(of: grid, matching: find.byType(Scrollable)).first,
          )
          .position;
      expect(pos.pixels, 0);
      expect(page(tester).paginatedItems, hasLength(30));
      await teardownTree(tester);
    });

    testWidgets('a same-name album opens with its own ids', (tester) async {
      await pump(tester);
      await search(tester, 'Echoes');
      final bo = find.byWidgetPredicate(
        (w) => w is AlbumCard && w.album.id == 20,
      );
      await tester.tap(bo);
      await tester.pumpAndSettle();
      final d = tester.widget<TracksPage>(find.byType(TracksPage));
      expect((d.album?.albumId, d.album?.artistId), (20, 2));
      await teardownTree(tester);
    });
  });

  // 6-R1-05 / DEV-6-05: the shared card's one availability rule applies in
  // the browse grid too.
  testWidgets('offline with the chip off: albums with nothing playable dim, '
      'a partly downloaded one does not, and a dimmed one still opens', (
    tester,
  ) async {
    await pump(tester, offline: true);
    await tester.tap(find.byKey(FilterBar.downloadedChipKey)); // OFF
    await tester.pumpAndSettle();
    expect(shownIds(tester).toSet(), {10, 20, 21, 30});

    Finder card(int id) => find.byWidgetPredicate(
        (w) => w is AlbumCard && w.album.id == id);
    bool dimmed(int id) => tester
        .widget<LibraryCard>(
            find.descendant(of: card(id), matching: find.byType(LibraryCard)))
        .dimmed;
    expect(dimmed(10), isFalse, reason: 'one of two tracks is downloaded');
    expect(dimmed(20), isTrue);
    expect(dimmed(21), isTrue);
    expect(dimmed(30), isTrue);

    await tester.tap(card(30));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TracksPage>(find.byType(TracksPage)).album?.albumId,
      30,
    );
    await teardownTree(tester);
  });

  testWidgets('online, nothing dims', (tester) async {
    await pump(tester);
    for (final c in tester.widgetList<LibraryCard>(find.byType(LibraryCard))) {
      expect(c.dimmed, isFalse);
    }
    await teardownTree(tester);
  });
}
