// Spec §2 time ranges and §3 bucket charts. Every expected instant is written
// out as a calendar date here, independently of the model's arithmetic.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/listening_stats.dart';

int utc(int y, [int mo = 1, int d = 1, int h = 0, int mi = 0, int s = 0,
        int ms = 0]) =>
    DateTime.utc(y, mo, d, h, mi, s, ms).millisecondsSinceEpoch;

String label(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  return d.toIso8601String();
}

List<String> spans(StatsBucketPlan plan) => [
  for (final s in plan.spans) '${label(s.startUtcMs)}..${label(s.endUtcMs)}',
];

String day(int y, int mo, int d) =>
    '${label(utc(y, mo, d))}..${label(utc(y, mo, d + 1))}';

String month(int y, int mo) =>
    '${label(utc(y, mo))}..${label(utc(y, mo + 1))}';

void main() {
  final now = utc(2026, 1, 3, 12); // 2026-01-03T12:00Z

  group('ranges resolve to half-open UTC windows', () {
    test('7 and 30 days are rolling N x 24 h ending at now, daily buckets', () {
      final w7 = StatsRange.last7Days.resolve(now);
      expect(w7.startUtcMs, utc(2025, 12, 27, 12));
      expect(w7.endUtcMs, now);
      expect(w7.countedEndUtcMs, now);
      expect(w7.unit, StatsBucketUnit.day);
      final w30 = StatsRange.last30Days.resolve(now);
      expect(w30.startUtcMs, utc(2025, 12, 4, 12));
      expect(w30.endUtcMs, now);
      expect(w30.unit, StatsBucketUnit.day);
    });

    test('this UTC year is [1 Jan, next 1 Jan), counted only up to now', () {
      final w = StatsRange.thisUtcYear.resolve(now);
      expect(w.startUtcMs, utc(2026));
      expect(w.endUtcMs, utc(2027));
      expect(w.countedEndUtcMs, now, reason: 'future events never count');
      expect(w.unit, StatsBucketUnit.month);
    });

    test('the year is taken from now in UTC, not local time', () {
      // 31 Dec 23:30 UTC is already 1 Jan in UTC+1; the year stays 2025.
      final w = StatsRange.thisUtcYear.resolve(utc(2025, 12, 31, 23, 30));
      expect(w.startUtcMs, utc(2025));
      expect(w.endUtcMs, utc(2026));
      // The first millisecond of 2026 belongs to 2026.
      expect(StatsRange.thisUtcYear.resolve(utc(2026)).startUtcMs, utc(2026));
    });

    test('a chosen past year is whole; a future year counts nothing', () {
      final past = StatsRange.year(2025).resolve(now);
      expect(past.startUtcMs, utc(2025));
      expect(past.endUtcMs, utc(2026));
      expect(past.countedEndUtcMs, utc(2026));
      final future = StatsRange.year(2027).resolve(now);
      expect(future.startUtcMs, utc(2027));
      expect(future.countedEndUtcMs, now);
    });

    test('all time has no start and ends at now, monthly buckets', () {
      final w = StatsRange.allTime.resolve(now);
      expect(w.startUtcMs, isNull);
      expect(w.endUtcMs, now);
      expect(w.countedEndUtcMs, now);
      expect(w.unit, StatsBucketUnit.month);
    });

    test('a leap year resolves to its own calendar bounds', () {
      final w = StatsRange.year(2024).resolve(now);
      expect(w.endUtcMs - w.startUtcMs!, 366 * 86400000);
    });

    test('ranges are value-equal (they key snapshot tokens)', () {
      expect(const RollingDaysRange(7), StatsRange.last7Days);
      expect(RollingDaysRange(7.abs()), StatsRange.last7Days);
      expect(RollingDaysRange(7.abs()).hashCode,
          StatsRange.last7Days.hashCode);
      expect(StatsRange.year(2025), UtcYearRange(2025.abs()));
      expect(StatsRange.year(2025).hashCode, UtcYearRange(2025.abs()).hashCode);
      expect(StatsRange.year(2025), isNot(StatsRange.year(2026)));
      expect(StatsRange.last7Days, isNot(StatsRange.last30Days));
      expect(StatsRange.thisUtcYear, isNot(StatsRange.year(2026)));
      expect(StatsRange.allTime, const AllTimeRange());
    });

    test('a non-positive rolling length is refused', () {
      expect(() => RollingDaysRange(0.abs()).resolve(now), throwsArgumentError);
    });
  });

  group('bucket plans', () {
    test('7 days not at midnight: every touched UTC day, partial ends', () {
      final plan = StatsRange.last7Days.resolve(now).bucketPlan();
      expect(spans(plan), [
        day(2025, 12, 27),
        day(2025, 12, 28),
        day(2025, 12, 29),
        day(2025, 12, 30),
        day(2025, 12, 31),
        day(2026, 1, 1),
        day(2026, 1, 2),
        day(2026, 1, 3),
      ]);
      expect(plan.capped, isFalse);
    });

    test('7 days at exactly UTC midnight: seven whole days', () {
      final plan = StatsRange.last7Days.resolve(utc(2026, 1, 2)).bucketPlan();
      expect(spans(plan), [
        day(2025, 12, 26),
        day(2025, 12, 27),
        day(2025, 12, 28),
        day(2025, 12, 29),
        day(2025, 12, 30),
        day(2025, 12, 31),
        day(2026, 1, 1),
      ]);
    });

    test('30 days spans 31 touched days', () {
      final plan = StatsRange.last30Days.resolve(now).bucketPlan();
      expect(plan.spans, hasLength(31));
      expect(spans(plan).first, day(2025, 12, 4));
      expect(spans(plan).last, day(2026, 1, 3));
    });

    test('this year: months from January to the month of now', () {
      final plan = StatsRange.thisUtcYear
          .resolve(utc(2026, 3, 15))
          .bucketPlan();
      expect(spans(plan), [month(2026, 1), month(2026, 2), month(2026, 3)]);
    });

    test('a past year: twelve months, December ends at next 1 January', () {
      final plan = StatsRange.year(2025).resolve(now).bucketPlan();
      expect(plan.spans, hasLength(12));
      expect(spans(plan).first, month(2025, 1));
      expect(spans(plan).last, '${label(utc(2025, 12))}..${label(utc(2026))}');
    });

    test('a future year has no buckets', () {
      expect(StatsRange.year(2027).resolve(now).bucketPlan().spans, isEmpty);
    });

    test('all time with no listen has no buckets', () {
      final plan = StatsRange.allTime.resolve(now).bucketPlan();
      expect(plan.spans, isEmpty);
      expect(plan.capped, isFalse);
    });

    test('all time starts at the earliest listen month when within 24', () {
      final plan = StatsRange.allTime.resolve(now).bucketPlan(
        earliestListenUtcMs: utc(2025, 11, 30, 23, 59),
      );
      expect(spans(plan), [month(2025, 11), month(2025, 12), month(2026, 1)]);
      expect(plan.capped, isFalse);
    });

    test('all time is capped to the latest 24 months when older', () {
      final plan = StatsRange.allTime.resolve(now).bucketPlan(
        earliestListenUtcMs: utc(2023, 6, 15, 8),
      );
      expect(plan.spans, hasLength(24));
      expect(spans(plan).first, month(2024, 2));
      expect(spans(plan).last, month(2026, 1));
      expect(plan.capped, isTrue);
    });

    test('exactly 24 months of history is not capped', () {
      final plan = StatsRange.allTime.resolve(now).bucketPlan(
        earliestListenUtcMs: utc(2024, 2),
      );
      expect(plan.spans, hasLength(24));
      expect(plan.capped, isFalse);
    });

    test('now at exactly 1 January: the last bucket is December', () {
      final plan = StatsRange.allTime.resolve(utc(2026)).bucketPlan(
        earliestListenUtcMs: utc(2025, 12, 31, 23, 59, 59, 999),
      );
      expect(spans(plan), [month(2025, 12)]);
    });

    test('bucket lists are unmodifiable', () {
      final plan = StatsRange.last7Days.resolve(now).bucketPlan();
      expect(() => plan.spans.add(const StatsBucketSpan(0, 1)),
          throwsUnsupportedError);
    });
  });
}
