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
/// together across tabs and routes.
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

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  FilterChip visibleChip(WidgetTester tester) =>
      tester.widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey));

  testWidgets('both root browse tabs get a chip bar and a search field', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(find.byType(FilterBar), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Search artists'), findsOneWidget);

    await openTab(tester, 'Tracks');
    expect(find.byType(FilterBar), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Search tracks'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('filter state is per tab and survives tab switches', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    await tester.pumpAndSettle();
    expect(find.text('Streaming Artist'), findsNothing);

    await openTab(tester, 'Tracks');
    expect(visibleChip(tester).selected, isFalse, reason: 'per-page state');
    expect(find.text('Remote Song'), findsOneWidget);

    await openTab(tester, 'Artists');
    expect(
      visibleChip(tester).selected,
      isTrue,
      reason: 'kept by IndexedStack',
    );
    expect(find.text('Streaming Artist'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('artist → albums → album detail never shows a chip bar', (
    tester,
  ) async {
    await pumpShell(tester);

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

  testWidgets('a search on one tab does not leak into the other', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.enterText(find.byType(TextField), 'Downloaded');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('Streaming Artist'), findsNothing);

    await openTab(tester, 'Tracks');
    expect(find.text('Kept Song'), findsOneWidget);
    expect(find.text('Remote Song'), findsOneWidget);
    await teardownTree(tester);
  });
}
