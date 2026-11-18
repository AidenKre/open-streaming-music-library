// Phase 9A.2a (spec §3 para 4 "Fill missing buckets with zeros, never
// interpolate … Provide equivalent textual/table values for
// accessibility"; review 9-V01 "chart alternative table"): the bucket chart
// is a CustomPainter whose bars are drawn from the bucket values only, and
// the table next to it carries the very same values as text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/ui/listening_stats/bucket_chart.dart';
import 'package:frontend/ui/listening_stats/listening_stats_format.dart';

import '../browse_harness.dart' show teardownTree;

const _day = 86400000;
final _start = DateTime.utc(2026, 11, 1).millisecondsSinceEpoch;

List<ListeningBucket> _buckets(List<double> seconds) => [
  for (var i = 0; i < seconds.length; i++)
    ListeningBucket(
      startUtcMs: _start + i * _day,
      endUtcMs: _start + (i + 1) * _day,
      listeningSeconds: seconds[i],
    ),
];

void main() {
  group('bar geometry', () {
    test('heights are proportional to the values, bottoms on the baseline, '
        'one slot per bucket in order', () {
      final rects = BucketChartPainter(const [0, 30, 60]).barRects(
        const Size(300, 100),
      );
      expect(rects, hasLength(3));
      expect([for (final r in rects) r.height], [0, 50, 100]);
      for (final r in rects) {
        expect(r.bottom, 100);
      }
      for (var i = 0; i < 3; i++) {
        expect(rects[i].left, greaterThanOrEqualTo(i * 100.0));
        expect(rects[i].right, lessThanOrEqualTo((i + 1) * 100.0));
        expect(rects[i].width, greaterThan(0));
      }
    });

    test('an all-zero range draws no bar height (nothing invented)', () {
      final rects = BucketChartPainter(const [0, 0, 0, 0]).barRects(
        const Size(400, 120),
      );
      expect([for (final r in rects) r.height], [0, 0, 0, 0]);
    });

    test('no buckets, no bars', () {
      expect(BucketChartPainter(const []).barRects(const Size(100, 100)),
          isEmpty);
    });

    test('a tiny value next to a big one still scales linearly', () {
      final rects = BucketChartPainter(const [1, 1000]).barRects(
        const Size(200, 1000),
      );
      expect(rects[0].height, closeTo(1, 1e-9));
      expect(rects[1].height, closeTo(1000, 1e-9));
    });

    test('repaints only when the values change', () {
      const a = BucketChartPainter([1, 2]);
      expect(a.shouldRepaint(const BucketChartPainter([1, 2])), isFalse);
      expect(a.shouldRepaint(const BucketChartPainter([1, 3])), isTrue);
      expect(a.shouldRepaint(const BucketChartPainter([1])), isTrue);
    });
  });

  testWidgets('the chart and the table show the same values', (tester) async {
    final buckets = _buckets([0, 45, 3660, 0, 7200.5]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              BucketChart(buckets: buckets),
              BucketTable(buckets: buckets, unit: StatsBucketUnit.day),
            ],
          ),
        ),
      ),
    );

    final paint = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter)
        .whereType<BucketChartPainter>()
        .single;
    expect(paint.values, [for (final b in buckets) b.listeningSeconds]);

    for (var i = 0; i < buckets.length; i++) {
      final row = find.byKey(BucketTable.rowKey(i));
      expect(row, findsOneWidget);
      final b = buckets[i];
      expect(
        find.descendant(
          of: row,
          matching: find.text(bucketLabel(b.startUtcMs, StatsBucketUnit.day)),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text(formatListeningTime(paint.values[i])),
        ),
        findsOneWidget,
      );
    }
    expect(find.byKey(BucketTable.rowKey(buckets.length)), findsNothing);
    // Spot values written out independently of the formatter.
    expect(
      find.descendant(
        of: find.byKey(BucketTable.rowKey(2)),
        matching: find.text('1 h 1 min'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(BucketTable.rowKey(0)),
        matching: find.text('3 Nov 2026'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(BucketTable.rowKey(0)),
        matching: find.text('1 Nov 2026'),
      ),
      findsOneWidget,
    );
    await teardownTree(tester);
  });

  testWidgets('the chart tells screen readers where the values are',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BucketChart(buckets: _buckets([10, 20]))),
      ),
    );
    expect(find.bySemanticsLabel(RegExp('table')), findsOneWidget);
    handle.dispose();
    await teardownTree(tester);
  });
}
