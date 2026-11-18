// Phase 9C.1 S9 (spec §6 "Reach Year in music from Listening stats"; spec
// §4 "opening the page, changing range or exporting does not itself create
// history"; SC-27): the statistics page lists "Year in music", which opens
// the recap; opening and using the recap creates no history and plays
// nothing.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/ui/annual_recap_controller.dart';
import 'package:frontend/ui/annual_recap_page.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';
import 'package:frontend/ui/listening_stats_page.dart';

import '../helpers/fake_clock.dart';
import '../helpers/recap_page_fixtures.dart' show FakeRecapControls;
import 'browse_harness.dart' show teardownTree;
import 'listening_stats/stats_page_harness.dart';

/// Fails the test on any playback request.
class NoPlayback extends PlaybackRequests {
  NoPlayback(super.ref);
  int submitted = 0;

  @override
  Future<PlaybackOutcome> submit(PlaybackRequest request) {
    submitted++;
    fail('the recap must not request playback: $request');
  }
}

void main() {
  test('the recap is the statistics page\'s one link', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final links = container.read(listeningStatsLinksProvider);
    expect([for (final l in links) l.id], ['annual_recap']);
    expect(links.single.label, 'Year in music');
  });

  testWidgets('"Year in music" opens the recap from the statistics page, '
      'and back returns', (tester) async {
    final harness = StatsPageHarness();
    addTearDown(harness.close);
    final opened = <int>[];
    final recap = FakeRecapControls();
    recap.loading = true;
    await harness.open(
      tester,
      overrides: [
        annualRecapControllerFactoryProvider.overrideWithValue(() {
          opened.add(1);
          return recap;
        }),
      ],
    );
    await harness.show(
      tester,
      StatsReady(sevenDays(), hasHistory: true, pendingListens: 0),
    );
    final link = find.text('Year in music');
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(AnnualRecapPage), findsOneWidget);
    // One controller, which asks for the current UTC year itself.
    expect(opened, hasLength(1));

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AnnualRecapPage), findsNothing);
    expect(find.byType(ListeningStatsPage), findsOneWidget);
    expect(recap.disposed, isTrue);
    await teardownTree(tester);
  });

  group('the real recap controller over a real database', () {
    late AppDatabase db;
    late ProviderContainer container;
    late NoPlayback playback;
    final clock = FakeClock(
      startUtcMs: DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch,
    );

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(clock),
          playbackRequestsProvider.overrideWith((ref) {
            return playback = NoPlayback(ref);
          }),
        ],
      );
      // Make sure the guard exists before the recap runs.
      container.read(playbackRequestsProvider);
      for (final (i, at, secs) in [
        (1, DateTime.utc(2025, 3, 10), 300.0),
        (2, DateTime.utc(2026, 2, 14), 200.0),
      ]) {
        await db.into(db.historyEvents).insert(
          HistoryEventsCompanion.insert(
            eventUuid: 'ev-$i',
            kind: 'play',
            entityType: 'track',
            entityRef: 'gone-$i',
            occurredAt: at.millisecondsSinceEpoch,
            secondsPlayed: Value(secs),
            pendingUpload: i == 2,
          ),
        );
      }
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<List<String>> snapshot() async => [
      for (final table in ['history_events', 'local_counters'])
        for (final r in await db
            .customSelect('SELECT * FROM $table ORDER BY 1')
            .get())
          '$table ${r.data}',
    ];

    Future<void> untilLoaded(AnnualRecapControls c) async {
      for (var i = 0; i < 200 && (c.loading || c.years.length < 2); i++) {
        await pumpEventQueue();
      }
      expect(c.loading, isFalse);
      expect(c.failed, isFalse);
    }

    test('opening, choosing years and refreshing create no history and '
        'play nothing', () async {
      final before = await snapshot();
      final c = container.read(annualRecapControllerFactoryProvider)();
      await untilLoaded(c);
      expect(c.recap!.year, 2026);
      expect(c.recap!.totals.listeningSeconds, 200.0);
      expect(c.years, [2026, 2025]);

      c.selectYear(2025);
      await untilLoaded(c);
      expect(c.recap!.totals.listeningSeconds, 300.0);
      c.refresh();
      await untilLoaded(c);
      c.dispose();

      expect(await snapshot(), before);
      expect(before, hasLength(2), reason: 'two history rows, no counters');
      expect(playback.submitted, 0);
    });
  });
}
