import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
import 'package:frontend/ui/widgets/downloaded_only_badge.dart';
import 'package:frontend/ui/widgets/search_status.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

import 'browse_harness.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore coverStore;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await _seedSearchData(db);
    tempDir = await Directory.systemTemp.createTemp('search-page-test');
    coverStore =
        await LocalCoverArtStore.create(directoryProvider: () async => tempDir);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets(
    'search artist and album cards expose queue actions on long press',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            localCoverArtStoreProvider.overrideWithValue(coverStore),
          ],
          child: const MaterialApp(home: SearchPage()),
        ),
      );

      await tester.enterText(find.byType(TextField), 'Search');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(find.byType(ArtistCard), findsOneWidget);
      expect(find.byType(AlbumCard), findsOneWidget);

      await tester.longPress(find.byType(ArtistCard));
      await tester.pumpAndSettle();

      expect(find.text('Play Next'), findsOneWidget);
      expect(find.text('Add to Queue'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();

      expect(find.text('Play Next'), findsOneWidget);
      expect(find.text('Add to Queue'), findsOneWidget);
    },
  );

  group('shared search primitive (regressions)', () {
    late AppDatabase libDb;
    late BrowseHarness h;

    setUp(() async {
      initCoverArtCache(CoverArtCacheManager.noop());
      libDb = AppDatabase(NativeDatabase.memory());
      // Seven tracks match "Blue" by title only; artist/album names don't,
      // so the Songs section is the only one on screen.
      await seedLibrary(libDb, [
        for (var i = 1; i <= 7; i++)
          SeedTrack(
            uuid: 'b$i',
            title: 'Blue $i',
            artistId: i,
            artist: 'Artist $i',
            downloaded: i == 1,
          ),
      ]);
      h = await BrowseHarness.create(libDb);
    });

    tearDown(() async {
      await libDb.close();
      await h.dispose();
    });

    Future<void> search(WidgetTester tester, String query) async {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
    }

    String fieldText(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    testWidgets('the field stays above scrolled results, keeping its text '
        'and never taking focus back', (tester) async {
      // Matches in all three sections make the results taller than the
      // 600px test viewport. The field used to be the results list's first
      // child: scrolled away it was disposed (losing its text), and rebuilt
      // it autofocused again, reopening the keyboard.
      await seedLibrary(libDb, [
        for (var i = 1; i <= 6; i++)
          SeedTrack(
            uuid: 'z$i',
            title: 'Zed Song $i',
            artistId: 100 + i,
            artist: 'Zed Artist $i',
            albumId: 100 + i,
            album: 'Zed Album $i',
          ),
      ]);
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Zed');
      expect(find.byType(ArtistCard), findsWidgets);
      FocusManager.instance.primaryFocus?.unfocus(); // e.g. after opening a result
      await tester.pump();

      final results = find.byType(ListView).first;
      await tester.drag(results, const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.byType(ArtistCard), findsNothing, reason: 'scrolled away');
      expect(fieldText(tester), 'Zed');
      expect(find.byTooltip('Clear search'), findsOneWidget);

      await tester.drag(results, const Offset(0, 2000));
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'Zed');
      expect(find.byType(ArtistCard), findsWidgets);
      expect(
        tester.testTextInput.isVisible,
        isFalse,
        reason: 'the dismissed keyboard stays dismissed',
      );
      await teardownTree(tester);
    });

    testWidgets('the keyboard search action searches without the debounce', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.textInputAction, TextInputAction.search);

      await tester.showKeyboard(find.byType(TextField));
      tester.testTextInput.enterText('Blue');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(); // one frame: the search starts
      await tester.pump(); // ... and lands
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.byType(TrackTile), findsNWidgets(5));
      // The debounce timer from typing was cancelled; nothing re-runs.
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(TrackTile), findsNWidgets(5));
    });

    testWidgets('a failed search says so instead of "No results found"', (
      tester,
    ) async {
      await tester.pumpWidget(
        h.wrap(const SearchPage(), repository: _FailingSearchRepo(libDb)),
      );
      await search(tester, 'Blue');
      expect(find.text(searchFailedMessage), findsOneWidget);
      expect(find.text('No results found'), findsNothing);
    });

    testWidgets('tapping a track plays the visible results in rank order', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Blue');
      final shown = tester
          .widgetList<TrackTile>(find.byType(TrackTile))
          .map((t) => t.track.uuidId)
          .toList();
      expect(shown, hasLength(5));

      await tester.tap(find.text('Blue 3'));
      await tester.pump();
      expect(h.audio.calls.single, {
        'method': 'playFromTrackList',
        'uuids': shown,
        'uuid': 'b3',
        'sourceType': 'search',
      });
    });

    testWidgets('an artist result opens that artist\'s albums', (
      tester,
    ) async {
      await seedLibrary(libDb, [
        const SeedTrack(
          uuid: 'q1',
          title: 'Quiet One',
          artistId: 50,
          artist: 'Quasar',
          albumId: 50,
          album: 'Nebula',
        ),
      ]);
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Quasar');
      await tester.tap(find.byType(ArtistCard));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Quasar'), findsOneWidget);
      expect(tester.widget<AlbumsPage>(find.byType(AlbumsPage)).artistId, 50);
      await teardownTree(tester);
    });

    Future<void> seedNebula({required bool singles}) async {
      await seedLibrary(libDb, [
        const SeedTrack(
          uuid: 'n1',
          title: 'Orbit',
          artistId: 60,
          artist: 'Nova',
          albumId: 60,
          album: 'Nebula',
        ),
      ]);
      await (libDb.update(libDb.albums)..where((a) => a.id.equals(60))).write(
        AlbumsCompanion(isSingleGrouping: Value(singles)),
      );
    }

    testWidgets('an album result opens its tracks', (tester) async {
      await seedNebula(singles: false);
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Nebula');
      await tester.tap(find.byType(AlbumCard));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Nebula'), findsOneWidget);
      final page = tester.widget<TracksPage>(find.byType(TracksPage));
      expect((page.artistId, page.albumId), (60, 60));
      await teardownTree(tester);
    });

    testWidgets('a singles grouping opens titled "<artist> - Singles"', (
      tester,
    ) async {
      await seedNebula(singles: true);
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Nebula');
      await tester.tap(find.byType(AlbumCard));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Nova - Singles'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('coming back online re-runs the query unfiltered', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage(), offline: true));
      await search(tester, 'Blue');
      expect(find.byType(TrackTile), findsOneWidget);
      expect(find.byType(DownloadedOnlyBadge), findsOneWidget);

      h.offline.set(false);
      await tester.pumpAndSettle();
      expect(find.byType(TrackTile), findsNWidgets(5));
      expect(find.byType(DownloadedOnlyBadge), findsNothing);
    });

    testWidgets('offline, deleting the only downloaded match empties the '
        'results with the offline copy', (tester) async {
      await tester.pumpWidget(h.wrap(const SearchPage(), offline: true));
      await search(tester, 'Blue');
      expect(find.text('Blue 1'), findsOneWidget);

      await tester.runAsync(() => h.manager.deleteDownload('b1'));
      await tester.pumpAndSettle();
      expect(find.byType(TrackTile), findsNothing);
      expect(
        find.textContaining('No downloaded results match "Blue"'),
        findsOneWidget,
      );
    });

    testWidgets('caps each section at 5 results', (tester) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Blue');
      expect(find.byType(TrackTile), findsNWidgets(5));
    });

    testWidgets('the clear button returns to the blank state immediately', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Blue');
      expect(find.byType(TrackTile), findsWidgets);

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pump(); // one frame — no debounce wait
      expect(find.byType(TrackTile), findsNothing);
      expect(fieldText(tester), isEmpty);
      expect(
        find.text('No results found'),
        findsNothing,
        reason: 'cleared means out of search mode, not an empty search',
      );
    });

    testWidgets('going offline mid-query re-runs it downloaded-only', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Blue');
      expect(find.byType(TrackTile), findsNWidgets(5));

      h.offline.set(true);
      await tester.pumpAndSettle();
      expect(find.byType(TrackTile), findsOneWidget);
      expect(find.text('Blue 1'), findsOneWidget);
    });

    // Whether the controller patches or re-searches is pinned by its unit
    // tests; this checks the page wiring delivers the event.
    testWidgets('online, a new download updates its row', (
      tester,
    ) async {
      await tester.pumpWidget(h.wrap(const SearchPage()));
      await search(tester, 'Blue');
      TrackTile tile() => tester.widget(
        find.ancestor(of: find.text('Blue 2'), matching: find.byType(TrackTile)),
      );
      expect(tile().track.isDownloaded, isFalse);

      await markDownloaded(libDb, 'b2');
      h.manager.downloadStatusVersion.value++;
      await tester.pumpAndSettle();
      expect(tile().track.isDownloaded, isTrue);
    });
  });
}

Future<void> _seedSearchData(AppDatabase db) async {
  await db.batch((batch) {
    batch.insert(
      db.artists,
      const ArtistsCompanion(id: Value(1), name: Value('Search Artist')),
    );
    batch.insert(
      db.albums,
      const AlbumsCompanion(
        id: Value(1),
        name: Value('Search Album'),
        artistId: Value(1),
        year: Value(2024),
        isSingleGrouping: Value(false),
      ),
    );
    batch.insert(
      db.tracks,
      const TracksCompanion(
        uuidId: Value('track-search-1'),
        createdAt: Value(1),
        lastUpdated: Value(1),
      ),
    );
    batch.insert(
      db.trackmetadata,
      const TrackmetadataCompanion(
        uuidId: Value('track-search-1'),
        title: Value('Search Song'),
        artist: Value('Search Artist'),
        album: Value('Search Album'),
        albumArtist: Value('Search Artist'),
        artistId: Value(1),
        albumId: Value(1),
        year: Value(2024),
        date: Value('2024-01-01'),
        genre: Value('Rock'),
        trackNumber: Value(1),
        discNumber: Value(1),
        codec: Value('flac'),
        duration: Value(180.0),
        bitrateKbps: Value(320.0),
        sampleRateHz: Value(44100),
        channels: Value(2),
        hasAlbumArt: Value(false),
      ),
    );
  });

  await db.rebuildFtsIndexes();
}

/// Every search throws, as a corrupt FTS index would.
class _FailingSearchRepo extends BrowseRepository {
  _FailingSearchRepo(super.db);

  @override
  Future<LibrarySearchResults> search(
    String query, {
    Set<SearchType> types = const {
      SearchType.artists,
      SearchType.albums,
      SearchType.tracks,
    },
    int limitPerType = 5,
    bool downloadedOnly = false,
  }) async => throw StateError('fts index corrupt');
}
