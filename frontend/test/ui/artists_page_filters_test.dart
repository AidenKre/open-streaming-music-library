import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/artist_page.dart';
import 'package:frontend/ui/widgets/downloaded_only_badge.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';

import 'browse_harness.dart';

void main() {
  late AppDatabase db;
  late BrowseHarness h;

  setUp(() async {
    initCoverArtCache(CoverArtCacheManager.noop());
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(
        uuid: 'd1',
        title: 'Kept Song',
        artistId: 1,
        artist: 'Downloaded Artist',
        albumId: 10,
        album: 'Kept Album',
        downloaded: true,
      ),
      SeedTrack(
        uuid: 's1',
        title: 'Remote Song',
        artistId: 2,
        artist: 'Streaming Artist',
        albumId: 20,
        album: 'Remote Album',
      ),
    ]);
    h = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await db.close();
    await h.dispose();
  });

  FilterChip chip(WidgetTester tester) =>
      tester.widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey));

  Future<void> pumpRoot(WidgetTester tester, {bool offline = false}) async {
    await tester.pumpWidget(
      h.wrap(const ArtistsPage(isRoot: true), offline: offline),
    );
    await tester.pumpAndSettle();
  }

  Future<void> setOffline(WidgetTester tester, bool value) async {
    h.offline.set(value);
    await tester.pumpAndSettle();
  }

  group('Downloaded chip (root)', () {
    testWidgets('online: chip shown unselected, everything listed, no badge', (
      tester,
    ) async {
      await pumpRoot(tester);

      expect(find.byType(FilterBar), findsOneWidget);
      expect(chip(tester).selected, isFalse);
      expect(find.text('Downloaded Artist'), findsOneWidget);
      expect(find.text('Streaming Artist'), findsOneWidget);
      expect(find.byType(DownloadedOnlyBadge), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('toggling the chip filters and unfilters the grid', (
      tester,
    ) async {
      await pumpRoot(tester);

      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      expect(chip(tester).selected, isTrue);
      expect(find.text('Downloaded Artist'), findsOneWidget);
      expect(find.text('Streaming Artist'), findsNothing);

      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      expect(find.text('Streaming Artist'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('offline: chip locked on, filtered, and no badge', (
      tester,
    ) async {
      await pumpRoot(tester, offline: true);

      expect(chip(tester).selected, isTrue);
      expect(chip(tester).onSelected, isNull);
      expect(find.text('Downloaded Artist'), findsOneWidget);
      expect(find.text('Streaming Artist'), findsNothing);
      expect(find.byType(DownloadedOnlyBadge), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('coming back online restores an explicit OFF', (tester) async {
      await pumpRoot(tester);

      await setOffline(tester, true);
      expect(chip(tester).selected, isTrue);
      expect(find.text('Streaming Artist'), findsNothing);

      await setOffline(tester, false);
      expect(chip(tester).selected, isFalse);
      expect(find.text('Streaming Artist'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('coming back online keeps an explicit ON', (tester) async {
      await pumpRoot(tester);
      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();

      await setOffline(tester, true);
      await setOffline(tester, false);
      expect(chip(tester).selected, isTrue);
      expect(chip(tester).onSelected, isNotNull);
      expect(find.text('Streaming Artist'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a non-root ArtistsPage gets no FilterBar', (tester) async {
      await tester.pumpWidget(h.wrap(const ArtistsPage(), offline: true));
      await tester.pumpAndSettle();

      expect(find.byType(FilterBar), findsNothing);
      expect(find.byType(DownloadedOnlyBadge), findsOneWidget);
      await teardownTree(tester);
    });
  });

  group('filtered empty state', () {
    const message = 'No downloaded artists yet.';

  Future<void> clearAllDownloads() async {
    await db.update(db.tracks).write(clearedDownloadColumns);
  }

  Future<void> clearLibrary() async {
    for (final t in ['trackmetadata', 'tracks', 'albums', 'artists']) {
      await db.customStatement('DELETE FROM $t');
    }
  }

    testWidgets('shown once a filtered window settles empty', (tester) async {
      await clearAllDownloads();
      await tester.pumpWidget(
        h.wrap(const ArtistsPage(isRoot: true), offline: true),
      );
      expect(find.text(message), findsNothing, reason: 'still loading');

      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('shown when the chip filters everything out online', (
      tester,
    ) async {
      await clearAllDownloads();
      await pumpRoot(tester);
      expect(find.text(message), findsNothing);

      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('not shown for an unfiltered empty library', (tester) async {
      await clearLibrary();
      await pumpRoot(tester);
      expect(find.text(message), findsNothing);
      await teardownTree(tester);
    });
  });
}
