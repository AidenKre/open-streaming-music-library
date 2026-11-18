import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/ui/listening_stats/listening_stats_format.dart';

/// The bucket chart: bars drawn from the bucket values only.
class BucketChart extends StatelessWidget {
  const BucketChart({super.key, required this.buckets});

  final List<ListeningBucket> buckets;

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        'Bar chart of listening time. The same values are in the table below.',
    excludeSemantics: true,
    child: SizedBox(
      height: 160,
      width: double.infinity,
      child: CustomPaint(
        painter: BucketChartPainter([
          for (final b in buckets) b.listeningSeconds,
        ], color: Theme.of(context).colorScheme.primary),
      ),
    ),
  );
}

/// Paints one bar per value, scaled to the largest.
class BucketChartPainter extends CustomPainter {
  const BucketChartPainter(this.values, {this.color = Colors.blue});

  final List<double> values;
  final Color color;

  /// The bars' rectangles in [size], one per value, in order.
  List<Rect> barRects(Size size) {
    if (values.isEmpty) return const [];
    final peak = values.reduce(math.max);
    final slot = size.width / values.length;
    final gap = slot * 0.15;
    return [
      for (var i = 0; i < values.length; i++)
        Rect.fromLTRB(
          i * slot + gap / 2,
          size.height - (peak > 0 ? values[i] / peak * size.height : 0),
          (i + 1) * slot - gap / 2,
          size.height,
        ),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (final r in barRects(size)) {
      if (r.height > 0) canvas.drawRect(r, paint);
    }
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      paint..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(BucketChartPainter oldDelegate) =>
      !listEquals(values, oldDelegate.values) || color != oldDelegate.color;
}

/// The chart's values as a table (the accessible equivalent).
class BucketTable extends StatelessWidget {
  const BucketTable({super.key, required this.buckets, required this.unit});

  final List<ListeningBucket> buckets;
  final StatsBucketUnit unit;

  static Key rowKey(int index) => ValueKey('stats-bucket-row-$index');

  @override
  Widget build(BuildContext context) {
    final head = Theme.of(context).textTheme.labelLarge;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                unit == StatsBucketUnit.day ? 'UTC day' : 'UTC month',
                style: head,
              ),
            ),
            Flexible(
              child: Text(
                'Listening time',
                style: head,
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        for (var i = 0; i < buckets.length; i++)
          Padding(
            key: rowKey(i),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(bucketLabel(buckets[i].startUtcMs, unit)),
                ),
                Flexible(
                  child: Text(
                    formatListeningTime(buckets[i].listeningSeconds),
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
