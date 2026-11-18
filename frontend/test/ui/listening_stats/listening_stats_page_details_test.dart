// Phase 9A.2a (spec §2 time ranges and rounding, §3 para 4 chart, §4 para
// 1; review 9-U02 presentation, 9-V01 chart alternative table): what a
// loaded snapshot shows besides the summaries. The UTC label and the
// snapshot instant, the chart with the table of the same values, the
// unavailable subtotal on its own line, the future-timestamp diagnostic,
// the chart-limit labels and "About these numbers".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/ui/listening_stats/bucket_chart.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';

import '../browse_harness.dart' show teardownTree;
import 'stats_page_harness.dart';

final _unavailable = find.byKey(const ValueKey('stats-unavailable'));

void main() {
  late StatsPageHarness h;
  setUp(() => h = StatsPageHarness());
  tearDown(() => h.close());

  testWidgets('times are labelled UTC with the snapshot instant',
      (tester) async {
    await h.open(tester);
    await h.show(tester, StatsReady(sevenDays(), hasHistory: true, pendingListens: 0),
        range: StatsRange.last7Days);
    expect(find.textContaining('12 Nov 2026, 14:03 UTC'), findsOneWidget);
    expect(find.textContaining('All times are UTC'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('the chart and the table on the page carry the same values',
      (tester) async {
    final values = <double>[0, 45, 3660, 0, 7200.5, 60, 0, 30];
    await h.open(tester);
    await h.show(
      tester,
      StatsReady(sevenDays(buckets: values), hasHistory: true, pendingListens: 0),
      range: StatsRange.last7Days,
    );
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter)
        .whereType<BucketChartPainter>()
        .single;
    expect(painter.values, values);
    // Written out by hand: 8 UTC days from 5 Nov (the 7-day window starts
    // 5 Nov 14:03 and ends 12 Nov 14:03).
    const labels = [
      '5 Nov 2026', '6 Nov 2026', '7 Nov 2026', '8 Nov 2026',
      '9 Nov 2026', '10 Nov 2026', '11 Nov 2026', '12 Nov 2026',
    ];
    const times = [
      '0 min', 'Under 1 min', '1 h 1 min', '0 min',
      '2 h', '1 min', '0 min', 'Under 1 min',
    ];
    for (var i = 0; i < labels.length; i++) {
      expect(
        textsUnder(tester, find.byKey(BucketTable.rowKey(i))),
        [labels[i], times[i]],
      );
    }
    expect(find.byKey(BucketTable.rowKey(labels.length)), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('a rolling chart says its first and last days are partial',
      (tester) async {
    await h.open(tester);
    await h.show(tester, StatsReady(sevenDays(), hasHistory: true, pendingListens: 0),
        range: StatsRange.last7Days);
    expect(find.textContaining('first and last days are partial'),
        findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('the all-time chart limit is labelled while totals stay all '
      'time', (tester) async {
    await h.open(tester);
    await h.show(
      tester,
      StatsReady(
        sevenDays(range: StatsRange.allTime, capped: true),
        hasHistory: true, pendingListens: 0,
      ),
      range: StatsRange.allTime,
    );
    expect(
      find.textContaining('latest 24 months'),
      findsOneWidget,
    );
    expect(find.textContaining('totals cover all time'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('no chart limit label when the chart is not capped',
      (tester) async {
    await h.open(tester);
    await h.show(
      tester,
      StatsReady(sevenDays(range: StatsRange.allTime), hasHistory: true, pendingListens: 0),
      range: StatsRange.allTime,
    );
    expect(find.textContaining('latest 24 months'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('a range with no buckets shows no chart, not an empty one',
      (tester) async {
    await h.open(tester);
    await h.show(
      tester,
      StatsReady(sevenDays(buckets: const []), hasHistory: true, pendingListens: 0),
      range: StatsRange.last7Days,
    );
    expect(find.byType(BucketChart), findsNothing);
    expect(find.byType(BucketTable), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('the unavailable subtotal is its own line, even at zero',
      (tester) async {
    await h.open(tester);
    await h.show(
      tester,
      StatsReady(
        sevenDays(seconds: 7200, plays: 9, unavailableSeconds: 1830,
            unavailablePlays: 2),
        hasHistory: true, pendingListens: 0,
      ),
    );
    final texts = textsUnder(tester, _unavailable).join(' ');
    expect(texts, contains('30 min'));
    expect(texts, contains('2 qualified plays'));
    expect(texts, contains('included in the totals'));
    // Decision 6, row 2 (owner, 2026-11-17): "unknown", not "unresolved".
    expect(
      texts,
      contains('(deleted or unknown tracks; included in the totals above).'),
    );
    expect(texts, contains('Unavailable history: 30 min'));
    // The overall totals are not reduced by it.
    expect(summaryValue('time', '2 h'), findsOneWidget);
    expect(summaryValue('plays', '9'), findsOneWidget);

    await h.show(tester, StatsReady(sevenDays(), hasHistory: true, pendingListens: 0));
    expect(textsUnder(tester, _unavailable).join(' '), contains('0 min'));
    await teardownTree(tester);
  });

  testWidgets('future-dated listens are reported, only when there are any',
      (tester) async {
    await h.open(tester);
    await h.show(tester, StatsReady(sevenDays(future: 3), hasHistory: true, pendingListens: 0));
    expect(find.textContaining('3 listens are dated in the future'),
        findsOneWidget);
    await h.show(tester, StatsReady(sevenDays(future: 1), hasHistory: true, pendingListens: 0));
    expect(find.textContaining('1 listen is dated in the future'),
        findsOneWidget);
    await h.show(tester, StatsReady(sevenDays(), hasHistory: true, pendingListens: 0));
    expect(find.textContaining('dated in the future'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('About these numbers explains what is counted', (tester) async {
    await h.open(tester);
    await h.show(tester, StatsReady(sevenDays(), hasHistory: true, pendingListens: 0));
    final about = find.text('About these numbers');
    expect(about, findsOneWidget);
    await tester.ensureVisible(about);
    await tester.tap(about);
    await tester.pumpAndSettle();
    for (final phrase in [
      '30 seconds', // the qualification threshold
      'rounded down',
      'UTC',
      'two devices',
      'current',
    ]) {
      expect(find.textContaining(phrase), findsWidgets, reason: phrase);
    }
    await teardownTree(tester);
  });

  testWidgets('fits a narrow screen with large text', (tester) async {
    await h.open(tester, size: const Size(320, 3000), textScale: 2);
    await h.show(
      tester,
      StatsReady(
        sevenDays(seconds: 360000, plays: 12345, tracks: 999, days: 7,
            unavailableSeconds: 3600, unavailablePlays: 4, future: 2,
            buckets: List.filled(8, 3600)),
        hasHistory: true, pendingListens: 0,
      ),
      range: StatsRange.last7Days,
    );
    expect(tester.takeException(), isNull);
    await teardownTree(tester);
  });
}
