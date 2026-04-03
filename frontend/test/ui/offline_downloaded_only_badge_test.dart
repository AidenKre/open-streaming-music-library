import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/artist_page.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/widgets/downloaded_only_badge.dart';

/// Pins [offlineModeProvider] to a fixed value without running the real
/// health-poll timer.
class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore coverStore;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await _seedSearchData(db);
    tempDir = await Directory.systemTemp.createTemp('badge-test');
    coverStore =
        await LocalCoverArtStore.create(directoryProvider: () async => tempDir);
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget wrap(Widget child, {required bool offline}) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        localCoverArtStoreProvider.overrideWithValue(coverStore),
        offlineModeProvider.overrideWith(() => _StubOffline(offline)),
      ],
      child: MaterialApp(home: child),
    );
  }

  // Tearing down ArtistsPage/AlbumsPage cancels a drift stream subscription,
  // which schedules a zero-duration Timer that the test binding flags as a
  // pending timer when the test ends. Pumping an empty tree inside the test
  // body lets that timer fire before the binding's invariant check.
  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets('ArtistsPage shows DownloadedOnlyBadge when offline',
      (tester) async {
    await tester.pumpWidget(wrap(const ArtistsPage(), offline: true));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadedOnlyBadge), findsOneWidget);
    expect(find.text('Showing downloaded only'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('ArtistsPage hides DownloadedOnlyBadge when online',
      (tester) async {
    await tester.pumpWidget(wrap(const ArtistsPage(), offline: false));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadedOnlyBadge), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('AlbumsPage shows DownloadedOnlyBadge when offline',
      (tester) async {
    await tester.pumpWidget(wrap(const AlbumsPage(), offline: true));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadedOnlyBadge), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('AlbumsPage hides DownloadedOnlyBadge when online',
      (tester) async {
    await tester.pumpWidget(wrap(const AlbumsPage(), offline: false));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadedOnlyBadge), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('SearchPage shows DownloadedOnlyBadge when offline',
      (tester) async {
    await tester.pumpWidget(wrap(const SearchPage(), offline: true));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadedOnlyBadge), findsOneWidget);
  });

  testWidgets('SearchPage hides DownloadedOnlyBadge when online',
      (tester) async {
    await tester.pumpWidget(wrap(const SearchPage(), offline: false));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadedOnlyBadge), findsNothing);
  });

  testWidgets(
      'SearchPage empty-state explains offline filtering when no matches',
      (tester) async {
    await tester.pumpWidget(wrap(const SearchPage(), offline: true));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'NoSuchThing');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('No downloaded results match "NoSuchThing"'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Reconnect to the server'),
      findsOneWidget,
    );
    expect(find.text('No results found'), findsNothing);
  });

  testWidgets('SearchPage empty-state uses generic copy when online',
      (tester) async {
    await tester.pumpWidget(wrap(const SearchPage(), offline: false));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'NoSuchThing');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('No results found'), findsOneWidget);
    expect(
      find.textContaining('No downloaded results match'),
      findsNothing,
    );
  });
}

/// Seed minimal data + FTS rows so the search page can resolve queries.
/// Mirrors the seeding used in search_page_test.dart.
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
