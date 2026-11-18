// Phase 6A.2 (spec §5 "Place Play/Shuffle in artist/album detail body
// before list/grid ... Do not add them to browse-all Artists/Albums/Tracks",
// 6-U09 detail half): the collection action header appears only on an
// artist's album grid and an album's track list, above the content, and its
// states come from the real availability predicate.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/browse/browse_pages.dart';
import 'package:frontend/ui/downloaded_tracks_page.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/collection_action_header.dart';
import 'package:frontend/models/library_scope.dart';

import 'browse_harness.dart';
import 'fake_library_actions.dart';
import '../helpers/library_seed.dart' show SeedTrack, seedLibrary;

void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late FakeLibraryActions actions;

  // Artist 1: album 2 (k1 downloaded, k2 not), album 3 (nothing downloaded).
  const seed = [
    SeedTrack(uuid: 'k1', title: 'Kite One', artistId: 1, artist: 'Ann',
        albumId: 2, album: 'Air', trackNumber: 1, downloaded: true),
    SeedTrack(uuid: 'k2', title: 'Kite Two', artistId: 1, artist: 'Ann',
        albumId: 2, album: 'Air', trackNumber: 2),
    SeedTrack(uuid: 'r1', title: 'Rain One', artistId: 1, artist: 'Ann',
        albumId: 3, album: 'Rain', trackNumber: 1),
  ];

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, seed);
    harness = await BrowseHarness.create(db);
    actions = FakeLibraryActions();
  });

  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, Widget page,
      {bool offline = false}) async {
    await tester.pumpWidget(harness.wrap(
      Scaffold(body: page),
      offline: offline,
      overrides: [libraryActionsProvider.overrideWithValue(actions)],
    ));
    await tester.pumpAndSettle();
  }

  void expectEnabled(WidgetTester tester, String label, bool enabled) {
    final button = find.bySemanticsLabel(label);
    expect(button, findsOneWidget);
    expect(tester.getSemantics(button),
        isSemantics(isButton: true, isEnabled: enabled, hasTapAction: enabled));
  }

  group('detail modes show the header', () {
    testWidgets('an album track list: Play and Shuffle the album',
        (tester) async {
      await pump(tester, const TracksPage.album(AlbumScope(artistId: 1, albumId: 2)));
      expectEnabled(tester, 'Play album', true);
      expectEnabled(tester, 'Shuffle album', true);
      await tester.tap(find.bySemanticsLabel('Play album'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Shuffle album'));
      await tester.pumpAndSettle();
      expect(actions.calls, ['play album(1,2)', 'shuffle album(1,2)']);
      await teardownTree(tester);
    });

    testWidgets('an artist album grid: Play and Shuffle the artist',
        (tester) async {
      await pump(tester, const AlbumsPage(artistId: 1));
      expectEnabled(tester, 'Play artist', true);
      expectEnabled(tester, 'Shuffle artist', true);
      await tester.tap(find.bySemanticsLabel('Shuffle artist'));
      await tester.pumpAndSettle();
      expect(actions.calls, ['shuffle artist(1)']);
      await teardownTree(tester);
    });

    testWidgets('the header sits in the body, above the list', (tester) async {
      await pump(tester, const TracksPage.album(AlbumScope(artistId: 1, albumId: 2)));
      final header = tester.getRect(find.byType(CollectionActionHeader));
      final firstRow = tester.getRect(find.text('Kite One'));
      expect(header.bottom, lessThanOrEqualTo(firstRow.top));
      await teardownTree(tester);
    });

    testWidgets('the header is above the artist grid', (tester) async {
      await pump(tester, const AlbumsPage(artistId: 1));
      final header = tester.getRect(find.byType(CollectionActionHeader));
      final firstCard = tester.getRect(find.text('Air').first);
      expect(header.bottom, lessThanOrEqualTo(firstCard.top));
      await teardownTree(tester);
    });
  });

  group('browse-all modes never show it', () {
    for (final (label, page) in <(String, Widget)>[
      ('Tracks browse page', const TracksBrowsePage()),
      ('Albums browse page', const AlbumsBrowsePage()),
      ('Artists browse page', const ArtistsBrowsePage()),
      ('Downloaded tracks page', const DownloadedTracksPage()),
      ('TracksPage(browseAll)', const TracksPage(browseAll: true)),
      ('AlbumsPage(browseAll)', const AlbumsPage(browseAll: true)),
    ]) {
      testWidgets(label, (tester) async {
        await pump(tester, page);
        expect(find.byType(CollectionActionHeader), findsNothing);
        expect(find.bySemanticsLabel(RegExp(r'^(Play|Shuffle) (album|artist)$')),
            findsNothing);
        await teardownTree(tester);
      });
    }
  });

  group('states from the real availability', () {
    testWidgets('offline, a partly downloaded album can play (O2)',
        (tester) async {
      await pump(tester, const TracksPage.album(AlbumScope(artistId: 1, albumId: 2)),
          offline: true);
      expectEnabled(tester, 'Play album', true);
      expectEnabled(tester, 'Shuffle album', true);
      await teardownTree(tester);
    });

    testWidgets('offline, an album with no download is disabled, with the '
        'reason', (tester) async {
      await pump(tester, const TracksPage.album(AlbumScope(artistId: 1, albumId: 3)),
          offline: true);
      expectEnabled(tester, 'Play album', false);
      expectEnabled(tester, 'Shuffle album', false);
      expect(find.text('Nothing here plays offline.'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('an album with no tracks is empty and disabled',
        (tester) async {
      await pump(tester, const TracksPage.album(AlbumScope(artistId: 1, albumId: 99)));
      expectEnabled(tester, 'Play album', false);
      expect(find.text('No tracks to play.'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('an artist with no albums is empty and disabled',
        (tester) async {
      await pump(tester, const AlbumsPage(artistId: 42));
      expectEnabled(tester, 'Play artist', false);
      expect(find.text('No tracks to play.'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('a loaded album is not empty', (tester) async {
      await pump(tester, const TracksPage.album(AlbumScope(artistId: 1, albumId: 2)));
      expect(find.text('No tracks to play.'), findsNothing);
      await teardownTree(tester);
    });
  });
}
