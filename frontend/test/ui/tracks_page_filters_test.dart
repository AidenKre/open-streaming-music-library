import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

import 'browse_harness.dart';

void main() {
  late AppDatabase db;
  late BrowseHarness h;

  setUp(() async {
    initCoverArtCache(CoverArtCacheManager.noop());
    db = AppDatabase(NativeDatabase.memory());
    // One album holding a downloaded and a streaming-only track, so the same
    // seed serves both the root tab and the album-detail sub-route.
    await seedLibrary(db, const [
      SeedTrack(
        uuid: 'd1',
        title: 'Kept Song',
        artistId: 1,
        artist: 'Artist',
        albumId: 10,
        album: 'Album',
        downloaded: true,
      ),
      SeedTrack(
        uuid: 's1',
        title: 'Remote Song',
        artistId: 1,
        artist: 'Artist',
        albumId: 10,
        album: 'Album',
        trackNumber: 2,
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

  TrackTile tileFor(WidgetTester tester, String title) => tester.widget(
    find.ancestor(of: find.text(title), matching: find.byType(TrackTile)),
  );

  Future<void> pump(
    WidgetTester tester,
    Widget page, {
    bool offline = false,
  }) async {
    await tester.pumpWidget(h.wrap(page, offline: offline));
    await tester.pumpAndSettle();
  }

  Future<void> tapChip(WidgetTester tester) async {
    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    await tester.pumpAndSettle();
  }

  Future<void> setOffline(WidgetTester tester, bool value) async {
    h.offline.set(value);
    await tester.pumpAndSettle();
  }

  const root = TracksPage(isRoot: true);
  const detail = Scaffold(body: TracksPage(artistId: 1, albumId: 10));

  group('root Tracks tab', () {
    testWidgets('online: chip off lists everything undimmed; on filters', (
      tester,
    ) async {
      await pump(tester, root);

      expect(chip(tester).selected, isFalse);
      expect(find.text('Kept Song'), findsOneWidget);
      expect(find.text('Remote Song'), findsOneWidget);
      expect(tileFor(tester, 'Remote Song').isDimmed, isFalse);

      await tapChip(tester);
      expect(find.text('Kept Song'), findsOneWidget);
      expect(find.text('Remote Song'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('offline: filters (not dims) with the chip locked on', (
      tester,
    ) async {
      await pump(tester, root, offline: true);

      expect(chip(tester).selected, isTrue);
      expect(chip(tester).onSelected, isNull);
      expect(find.text('Kept Song'), findsOneWidget);
      expect(
        find.text('Remote Song'),
        findsNothing,
        reason: 'the Tracks tab now filters offline instead of dimming',
      );
      await teardownTree(tester);
    });

    testWidgets('the play queue follows the effective filter', (tester) async {
      await pump(tester, root);

      await tester.tap(find.text('Kept Song'));
      await tester.pumpAndSettle();
      expect(h.audio.calls.last, containsPair('downloadedOnly', false));

      await tapChip(tester);
      await tester.tap(find.text('Kept Song'));
      await tester.pumpAndSettle();
      expect(h.audio.calls.last, containsPair('method', 'playFromQueue'));
      expect(h.audio.calls.last, containsPair('downloadedOnly', true));
      await teardownTree(tester);
    });

    testWidgets('offline round trip restores the explicit choice', (
      tester,
    ) async {
      await pump(tester, root);

      await setOffline(tester, true);
      expect(find.text('Remote Song'), findsNothing);
      await setOffline(tester, false);
      expect(chip(tester).selected, isFalse);
      expect(find.text('Remote Song'), findsOneWidget);

      await tapChip(tester);
      await setOffline(tester, true);
      await setOffline(tester, false);
      expect(chip(tester).selected, isTrue);
      expect(find.text('Remote Song'), findsNothing);
      await teardownTree(tester);
    });
  });

  group('album-detail sub-route (unchanged)', () {
    testWidgets('offline: no FilterBar; streaming-only rows stay, dimmed', (
      tester,
    ) async {
      await pump(tester, detail, offline: true);

      expect(find.byType(FilterBar), findsNothing);
      expect(find.text('Remote Song'), findsOneWidget);
      expect(tileFor(tester, 'Remote Song').isDimmed, isTrue);
      expect(tileFor(tester, 'Kept Song').isDimmed, isFalse);
      await teardownTree(tester);
    });

    testWidgets('a row tap never forces a downloaded-only queue', (
      tester,
    ) async {
      await pump(tester, detail);

      await tester.tap(find.text('Remote Song'));
      await tester.pumpAndSettle();
      expect(h.audio.calls.single, containsPair('downloadedOnly', false));
      expect(h.audio.calls.single, containsPair('sourceType', 'album'));
      await teardownTree(tester);
    });
  });

  group('filtered empty state', () {
    const message = 'No downloaded tracks yet.';

  Future<void> clearAllDownloads() async {
    await db.update(db.tracks).write(clearedDownloadColumns);
  }

  Future<void> clearLibrary() async {
    for (final t in ['trackmetadata', 'tracks', 'albums', 'artists']) {
      await db.customStatement('DELETE FROM $t');
    }
  }

    testWidgets('root: shown once a filtered window settles empty', (
      tester,
    ) async {
      await clearAllDownloads();
      await tester.pumpWidget(h.wrap(root, offline: true));
      expect(find.text(message), findsNothing, reason: 'still loading');

      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('root: not shown for an unfiltered empty library', (
      tester,
    ) async {
      await clearLibrary();
      await pump(tester, root);
      expect(find.text(message), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('detail: never shown (it dims rather than filters)', (
      tester,
    ) async {
      await clearAllDownloads();
      await pump(tester, detail, offline: true);
      expect(find.text(message), findsNothing);
      expect(find.text('Remote Song'), findsOneWidget);
      await teardownTree(tester);
    });
  });
}
