// Phase 9A.2a (spec §2 "Display minutes/hours rounded only at
// presentation"; decision O13: hours and minutes rounded down, in one
// place): the statistics page's presentation formatting.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/ui/listening_stats/listening_stats_format.dart';

int _utc(int y, int m, [int d = 1, int h = 0, int min = 0]) =>
    DateTime.utc(y, m, d, h, min).millisecondsSinceEpoch;

void main() {
  group('listening time (rounded down)', () {
    final cases = <double, String>{
      0: '0 min',
      0.4: 'Under 1 min',
      59.999: 'Under 1 min',
      60: '1 min',
      119.9: '1 min',
      3599.99: '59 min',
      3600: '1 h',
      3660: '1 h 1 min',
      7199.5: '1 h 59 min',
      36000 + 300: '10 h 5 min',
      1000 * 3600 + 59: '1000 h',
    };
    cases.forEach((seconds, text) {
      test('$seconds s → $text', () {
        expect(formatListeningTime(seconds), text);
      });
    });
  });

  group('range labels', () {
    test('presets', () {
      expect(rangeLabel(StatsRange.last7Days), '7 days');
      expect(rangeLabel(StatsRange.last30Days), '30 days');
      expect(rangeLabel(StatsRange.thisUtcYear), 'This year');
      expect(rangeLabel(StatsRange.allTime), 'All time');
      expect(rangeLabel(StatsRange.year(2024)), '2024');
    });
  });

  group('bucket labels are UTC', () {
    test('a day bucket names its UTC date', () {
      expect(
        bucketLabel(_utc(2026, 11, 3), StatsBucketUnit.day),
        '3 Nov 2026',
      );
    });

    test('a month bucket names its UTC month', () {
      expect(bucketLabel(_utc(2025, 1), StatsBucketUnit.month), 'Jan 2025');
    });

    test('the label does not shift into a local day', () {
      // 23:30 UTC on 31 Dec is still 31 Dec in UTC whatever the zone.
      expect(
        bucketLabel(_utc(2025, 12, 31, 23, 30), StatsBucketUnit.day),
        '31 Dec 2025',
      );
    });
  });

  test('a captured instant is shown in UTC and says so', () {
    expect(formatUtcInstant(_utc(2026, 11, 12, 14, 3)), '12 Nov 2026, 14:03 UTC');
    expect(formatUtcInstant(_utc(2026, 1, 2, 0, 5)), '2 Jan 2026, 00:05 UTC');
  });
}
