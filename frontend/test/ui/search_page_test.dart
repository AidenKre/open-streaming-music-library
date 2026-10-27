import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
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

    testWidgets('online, a new download patches its row in place', (
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
