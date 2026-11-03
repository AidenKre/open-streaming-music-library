import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/main.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';

import 'browse_harness.dart';

/// Shell-level integration: the real AppShell (IndexedStack of per-tab
/// navigators) over a real in-memory DB, checking how the Phase 3 pieces fit
/// together across tabs and routes (4A.4: Home and Search tabs, browse
/// routes on Home's navigator).
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

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(h.wrap(const AppShell()));
    await tester.pumpAndSettle();
  }

  // 4A.4: the shell has Home and Search tabs; Artists/Tracks browse are
  // routes on Home's navigator (were tabs). Each Phase 3 shell regression
  // below keeps its intent on the new structure.
  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Open a Home entry point (Artists / Tracks browse).
  Future<void> openBrowse(WidgetTester tester, String entry) async {
    await tester.tap(find.text(entry));
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
  }

  FilterChip visibleChip(WidgetTester tester) =>
      tester.widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey));

  testWidgets('both browse-all routes get a chip bar and a search field', (
    tester,
  ) async {
    await pumpShell(tester);
    await openBrowse(tester, 'Artists');
    expect(find.byType(FilterBar), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Search artists'), findsOneWidget);
    await back(tester);

    await openBrowse(tester, 'Tracks');
    expect(find.byType(FilterBar), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Search tracks'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('filter state is per page and survives tab switches', (
    tester,
  ) async {
    await pumpShell(tester);
    await openBrowse(tester, 'Artists');
    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    await tester.pumpAndSettle();
    expect(find.text('Streaming Artist'), findsNothing);

    await openTab(tester, 'Search');
    expect(visibleChip(tester).selected, isFalse, reason: 'per-page state');

    await openTab(tester, 'Home');
    expect(
      visibleChip(tester).selected,
      isTrue,
      reason: 'the Home route is kept by IndexedStack',
    );
    expect(find.text('Streaming Artist'), findsNothing);

    await back(tester);
    await openBrowse(tester, 'Tracks');
    expect(visibleChip(tester).selected, isFalse, reason: 'a new route');
    expect(find.text('Remote Song'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('artist → albums → album detail never shows a chip bar', (
    tester,
  ) async {
    await pumpShell(tester);
    await openBrowse(tester, 'Artists');

    await tester.tap(find.text('Downloaded Artist'));
    await tester.pumpAndSettle();
    expect(find.byType(FilterBar), findsNothing);
    expect(find.text('Kept Album'), findsOneWidget);

    await tester.tap(find.text('Kept Album'));
    await tester.pumpAndSettle();
    expect(find.byType(TracksPage), findsOneWidget);
    expect(find.byType(FilterBar), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Kept Song'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('a search on a browse route does not leak into Search', (
    tester,
  ) async {
    await pumpShell(tester);
    await openBrowse(tester, 'Artists');
    await tester.enterText(find.byType(TextField), 'Downloaded');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Streaming Artist'), findsNothing);

    await openTab(tester, 'Search');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(find.text('Search your library'), findsWidgets);
    await teardownTree(tester);
  });

  // Riverpod pauses a consumer's listeners while TickerMode is off (an
  // offstage IndexedStack tab, a route covered by another) and replays only
  // the last missed (prev, next) on resume. The transitions must still come
  // out right.
  group('offline transitions on a hidden page', () {
    Future<void> setOffline(WidgetTester tester, bool value) async {
      h.offline.set(value);
      await tester.pumpAndSettle();
    }

    testWidgets('a hidden tab catches up on outage and recovery', (
      tester,
    ) async {
      await pumpShell(tester);
      await openBrowse(tester, 'Tracks'); // on Home; Search hidden
      await setOffline(tester, true);
      await openTab(tester, 'Search');
      expect(visibleChip(tester).selected, isTrue, reason: 'auto-applied');

      await openTab(tester, 'Home');
      expect(visibleChip(tester).selected, isTrue);
      expect(find.text('Remote Song'), findsNothing);
      await setOffline(tester, false);
      await openTab(tester, 'Search');
      expect(visibleChip(tester).selected, isFalse, reason: 'auto undone');
      await teardownTree(tester);
    });

    testWidgets('an outage and recovery both while hidden net to no change, '
        'and neither page takes the other\'s choice', (tester) async {
      await pumpShell(tester);
      await openBrowse(tester, 'Artists');
      await tester.tap(find.byKey(FilterBar.downloadedChipKey)); // Artists ON
      await tester.pumpAndSettle();

      await setOffline(tester, true);
      // Explicit OFF on Artists while offline.
      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      expect(visibleChip(tester).selected, isFalse);
      await setOffline(tester, false);
      expect(visibleChip(tester).selected, isFalse, reason: 'user OFF kept');
      await setOffline(tester, true);
      expect(visibleChip(tester).selected, isTrue, reason: 'new outage');
      await setOffline(tester, false);
      expect(visibleChip(tester).selected, isFalse);

      // Search saw all four transitions only as a replay of the last one.
      await openTab(tester, 'Search');
      expect(visibleChip(tester).selected, isFalse);
      await teardownTree(tester);
    });

    testWidgets('a hidden tab keeps an explicit ON through outage and '
        'recovery', (tester) async {
      await pumpShell(tester);
      await openTab(tester, 'Search');
      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      await openTab(tester, 'Home');

      await setOffline(tester, true);
      await setOffline(tester, false);
      await openTab(tester, 'Search');
      expect(visibleChip(tester).selected, isTrue);
      await teardownTree(tester);
    });

    testWidgets('a browse route covered by a detail applies the outage once '
        'uncovered', (tester) async {
      await pumpShell(tester);
      await openBrowse(tester, 'Artists');
      await tester.tap(find.text('Streaming Artist'));
      await tester.pumpAndSettle();
      expect(find.byType(FilterBar), findsNothing);

      await setOffline(tester, true);
      await back(tester);
      expect(visibleChip(tester).selected, isTrue);
      expect(find.text('Streaming Artist'), findsNothing);

      await tester.tap(find.text('Downloaded Artist'));
      await tester.pumpAndSettle();
      await setOffline(tester, false);
      await back(tester);
      expect(visibleChip(tester).selected, isFalse);
      expect(find.text('Streaming Artist'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('a hidden route\'s in-page search re-runs on resume', (
      tester,
    ) async {
      await pumpShell(tester);
      await openBrowse(tester, 'Tracks');
      await tester.enterText(
        find.widgetWithText(TextField, 'Search tracks'),
        'Song',
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Remote Song'), findsOneWidget);

      await openTab(tester, 'Search');
      await setOffline(tester, true);
      await openTab(tester, 'Home');
      expect(visibleChip(tester).selected, isTrue);
      expect(find.text('Remote Song'), findsNothing);
      expect(find.text('Kept Song'), findsOneWidget);
      await teardownTree(tester);
    });
  });
}
