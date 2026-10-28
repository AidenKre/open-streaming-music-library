import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/artist_page.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
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

    testWidgets('offline: chip switched on, filtered, and no badge', (
      tester,
    ) async {
      await pumpRoot(tester, offline: true);

      expect(chip(tester).selected, isTrue);
      expect(find.text('Downloaded Artist'), findsOneWidget);
      expect(find.text('Streaming Artist'), findsNothing);
      expect(find.byType(DownloadedOnlyBadge), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('offline: the chip can be switched off to browse everything', (
      tester,
    ) async {
      await pumpRoot(tester, offline: true);
      expect(chip(tester).onSelected, isNotNull, reason: 'not locked');

      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      expect(chip(tester).selected, isFalse);
      expect(find.text('Downloaded Artist'), findsOneWidget);
      expect(find.text('Streaming Artist'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('going offline mid-session switches the chip on', (
      tester,
    ) async {
      await pumpRoot(tester);

      await setOffline(tester, true);
      expect(chip(tester).selected, isTrue);
      expect(find.text('Streaming Artist'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('coming back online undoes the offline switch-on', (
      tester,
    ) async {
      await pumpRoot(tester);

      await setOffline(tester, true);
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
      expect(find.text('Streaming Artist'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a choice made while offline survives reconnecting', (
      tester,
    ) async {
      await pumpRoot(tester, offline: true);
      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      expect(chip(tester).selected, isFalse);

      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      await setOffline(tester, false);
      expect(
        chip(tester).selected,
        isTrue,
        reason: 'the user switched it back on themselves',
      );
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

  group('in-page search', () {
    Future<void> search(WidgetTester tester, String query) async {
      await tester.enterText(find.byType(TextField), query);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
    }

    CursorPaginationMixin<ArtistUI> pageState(WidgetTester tester) =>
        tester.state(find.byType(ArtistsPage))
            as CursorPaginationMixin<ArtistUI>;

    testWidgets('root shows a search field', (tester) async {
      await pumpRoot(tester);
      expect(find.widgetWithText(TextField, 'Search artists'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('non-root shows no search field', (tester) async {
      await tester.pumpWidget(h.wrap(const ArtistsPage()));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a query swaps the grid for results and suspends browse', (
      tester,
    ) async {
      await pumpRoot(tester);
      await search(tester, 'Downloaded');

      expect(find.text('Downloaded Artist'), findsOneWidget);
      expect(find.text('Streaming Artist'), findsNothing);
      expect(pageState(tester).isPaginationSuspended, isTrue);

      // A DB write underneath search mode must not reach the dormant window.
      final dormant = List.of(pageState(tester).paginatedItems);
      await db
          .into(db.artists)
          .insert(
            const ArtistsCompanion(id: Value(99), name: Value('New Artist')),
          );
      await tester.pumpAndSettle();
      expect(pageState(tester).paginatedItems, dormant);
      expect(find.text('New Artist'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('clearing returns to browse through refresh()', (tester) async {
      await pumpRoot(tester);
      await search(tester, 'Downloaded');

      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      expect(pageState(tester).isPaginationSuspended, isFalse);
      expect(find.text('Downloaded Artist'), findsOneWidget);
      expect(find.text('Streaming Artist'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('no match explains itself, naming the Downloaded filter', (
      tester,
    ) async {
      await pumpRoot(tester);
      await search(tester, 'Nope');
      expect(find.text('No artists match "Nope".'), findsOneWidget);

      await search(tester, 'Streaming');
      expect(find.text('Streaming Artist'), findsOneWidget);
      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      expect(
        find.text('No downloaded artists match "Streaming".'),
        findsOneWidget,
      );
      await teardownTree(tester);
    });

    testWidgets('toggling the chip re-runs the search; browse stays asleep', (
      tester,
    ) async {
      await pumpRoot(tester);
      await search(tester, 'Artist');
      expect(find.text('Streaming Artist'), findsOneWidget);

      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      expect(find.text('Downloaded Artist'), findsOneWidget);
      expect(find.text('Streaming Artist'), findsNothing);
      expect(pageState(tester).isPaginationSuspended, isTrue);

      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      expect(find.text('Streaming Artist'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('going offline mid-search re-runs it downloaded-only', (
      tester,
    ) async {
      await pumpRoot(tester);
      await search(tester, 'Streaming');
      expect(find.text('Streaming Artist'), findsOneWidget);

      await setOffline(tester, true);
      expect(find.text('Streaming Artist'), findsNothing);
      // The chip can lift the filter here, so no "reconnect" advice.
      expect(
        find.text('No downloaded artists match "Streaming".'),
        findsOneWidget,
      );
      expect(pageState(tester).isPaginationSuspended, isTrue);

      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      expect(
        find.text('Streaming Artist'),
        findsOneWidget,
        reason: 'offline search can still cover the full library',
      );
      await teardownTree(tester);
    });

    testWidgets('deleting the last download drops a filtered result', (
      tester,
    ) async {
      await pumpRoot(tester);
      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      await search(tester, 'Artist');
      expect(find.text('Downloaded Artist'), findsOneWidget);

      // Real file I/O: must run outside the widget test's fake-async zone.
      await tester.runAsync(() => h.manager.deleteDownload('d1'));
      await tester.pumpAndSettle();
      expect(find.text('Downloaded Artist'), findsNothing);
      expect(
        find.text('No downloaded artists match "Artist".'),
        findsOneWidget,
      );
      await teardownTree(tester);
    });

    testWidgets('a full page of matches is capped at 100 with a hint', (
      tester,
    ) async {
      await seedLibrary(db, [
        for (var i = 0; i < 105; i++)
          SeedTrack(
            uuid: 'm$i',
            title: 'Song $i',
            artistId: 100 + i,
            artist: 'Many $i',
          ),
      ]);
      await pumpRoot(tester);
      await search(tester, 'Many');

      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate = grid.childrenDelegate as SliverChildBuilderDelegate;
      expect(delegate.childCount, 100);
      expect(find.textContaining('Showing the first 100 matches'), findsOne);
      await teardownTree(tester);
    });

    testWidgets('no hint below the cap', (tester) async {
      await pumpRoot(tester);
      await search(tester, 'Artist');
      expect(find.textContaining('Showing the first'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('unmounting with a pending debounce leaks nothing', (
      tester,
    ) async {
      await pumpRoot(tester);
      await tester.enterText(find.byType(TextField), 'Down');
      await teardownTree(tester); // debounce still pending
    });
  });
}
