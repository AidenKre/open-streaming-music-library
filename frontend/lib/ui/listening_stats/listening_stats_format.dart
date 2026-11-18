import 'package:frontend/models/listening_stats.dart';
import 'package:intl/intl.dart';

/// Listening time as hours and minutes, rounded down (decision O13). The
/// model keeps exact seconds; this is the one place they are rounded.
String formatListeningTime(double seconds) {
  if (seconds <= 0) return '0 min';
  if (seconds < 60) return 'Under 1 min';
  final minutes = seconds ~/ 60;
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}

/// The selector label of a range.
String rangeLabel(StatsRange range) => switch (range) {
  RollingDaysRange(:final days) => '$days days',
  ThisUtcYearRange() => 'This year',
  UtcYearRange(:final year) => '$year',
  AllTimeRange() => 'All time',
};

/// The UTC date (day unit) or month (month unit) a bucket starts on.
String bucketLabel(int startUtcMs, StatsBucketUnit unit) {
  final at = DateTime.fromMillisecondsSinceEpoch(startUtcMs, isUtc: true);
  return switch (unit) {
    StatsBucketUnit.day => DateFormat('d MMM y').format(at),
    StatsBucketUnit.month => DateFormat('MMM y').format(at),
  };
}

/// A captured instant, in UTC, labelled as such.
String formatUtcInstant(int utcMs) {
  final at = DateTime.fromMillisecondsSinceEpoch(utcMs, isUtc: true);
  return '${DateFormat('d MMM y, HH:mm').format(at)} UTC';
}

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// The English name of the UTC month a bucket starts in.
String recapMonthName(ListeningBucket b) =>
    _monthNames[DateTime.fromMillisecondsSinceEpoch(
          b.startUtcMs,
          isUtc: true,
        ).month -
        1];
