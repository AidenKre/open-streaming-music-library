// Phase 9A.2a (spec §4 para 1 "Add Home entry point Listening stats by
// appending a HomeEntryPoint(listening_stats) to the SC-07 list (a
// Home-navigator route; Year in music is pushed from it)"; SC-07; plan
// drift D8): the entry is appended after Phase 4's four, opens the page on
// Home's navigator, and the page lists the links later pieces register
// (the recap's "Year in music" is 9C.1's line in that list).
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/history/history_diagnostics.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';
import 'package:frontend/ui/listening_stats_page.dart';
import 'package:frontend/ui/navigation/library_routes.dart';

import '../browse_harness.dart';
import '../fake_listening_stats_controls.dart';
import 'stats_page_harness.dart' show sevenDays;

void main() {
  test('listening_stats is appended after Phase 4\'s entry points', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final entries = container.read(homeEntryPointsProvider);
    expect([for (final e in entries) e.id], [
      'artists',
      'albums',
      'tracks',
      'downloaded',
      'listening_stats',
    ]);
    final stats = entries.last;
    expect(stats.label, 'Listening stats');
    expect(stats.destination, BrowseDestination.listeningStats);
  });

  test('the only page link is 9C.1\'s Year in music', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      [for (final l in container.read(listeningStatsLinksProvider)) l.id],
      ['annual_recap'],
    );
  });

  group('on Home', () {
    late AppDatabase db;
    late BrowseHarness harness;
    late FakeListeningStatsControls fake;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      harness = await BrowseHarness.create(db);
      fake = FakeListeningStatsControls();
    });
    tearDown(() async {
      await harness.dispose();
      await db.close();
    });

    Widget wrap({List<ListeningStatsLink> links = const []}) => harness.wrap(
      const HomePage(),
      overrides: [
        listeningStatsControllerFactoryProvider.overrideWithValue(() => fake),
        historyDiagnosticsProvider.overrideWith(
          (ref) => const Stream<HistoryDiagnostics>.empty(),
        ),
        listeningStatsLinksProvider.overrideWithValue(links),
      ],
    );

    testWidgets('the entry opens the statistics page on Home\'s navigator',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap());
      await tester.pump();
      final entry = find.byKey(const ValueKey('entry.listening_stats'));
      expect(
        find.descendant(of: entry, matching: find.text('Listening stats')),
        findsOneWidget,
      );
      await tester.tap(entry);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(ListeningStatsPage), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('registered links show on the page and open their route',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var opened = 0;
      await tester.pumpWidget(
        wrap(
          links: [
            ListeningStatsLink(
              id: 'probe',
              label: 'Probe link',
              icon: Icons.star,
              open: (context) => opened++,
            ),
          ],
        ),
      );
      await tester.pump();
      openBrowse(
        tester.element(find.byType(HomePage)),
        BrowseDestination.listeningStats,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      fake.show(StatsReady(sevenDays(), hasHistory: true, pendingListens: 0));
      await tester.pump();
      final link = find.text('Probe link');
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pump();
      expect(opened, 1);
      await teardownTree(tester);
    });
  });
}
