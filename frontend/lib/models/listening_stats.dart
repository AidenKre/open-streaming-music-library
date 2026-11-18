/// Phase 9 listening statistics: ranges, windows and bucket plans (spec §2,
/// §3). Pure model: no I/O, nothing from `ui/`.
library;

import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';

/// Bucket granularity of a statistics chart.
enum StatsBucketUnit { day, month }

/// A statistics range. Value-equal, so it can key a snapshot token.
sealed class StatsRange {
  const StatsRange();

  static const last7Days = RollingDaysRange(7);
  static const last30Days = RollingDaysRange(30);
  static const thisUtcYear = ThisUtcYearRange();
  static const allTime = AllTimeRange();

  /// A chosen UTC calendar year (the recap's range).
  const factory StatsRange.year(int year) = UtcYearRange;

  /// The half-open UTC window this range covers at [capturedNowUtcMs].
  StatsWindow resolve(int capturedNowUtcMs);
}

StatsWindow _yearWindow(int year, int now) => StatsWindow(
      startUtcMs: DateTime.utc(year).millisecondsSinceEpoch,
      endUtcMs: DateTime.utc(year + 1).millisecondsSinceEpoch,
      capturedNowUtcMs: now,
      unit: StatsBucketUnit.month,
    );

/// `[now − days·24 h, now)`.
final class RollingDaysRange extends StatsRange {
  const RollingDaysRange(this.days);
  final int days;

  @override
  StatsWindow resolve(int capturedNowUtcMs) {
    if (days <= 0) throw ArgumentError.value(days, 'days', 'must be positive');
    return StatsWindow(
      startUtcMs: capturedNowUtcMs - days * 86400000,
      endUtcMs: capturedNowUtcMs,
      capturedNowUtcMs: capturedNowUtcMs,
      unit: StatsBucketUnit.day,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RollingDaysRange && other.days == days;

  @override
  int get hashCode => Object.hash(RollingDaysRange, days);
}

/// The UTC calendar year containing the captured now.
final class ThisUtcYearRange extends StatsRange {
  const ThisUtcYearRange();

  @override
  StatsWindow resolve(int capturedNowUtcMs) => _yearWindow(
        DateTime.fromMillisecondsSinceEpoch(capturedNowUtcMs, isUtc: true).year,
        capturedNowUtcMs,
      );

  @override
  bool operator ==(Object other) => other is ThisUtcYearRange;

  @override
  int get hashCode => (ThisUtcYearRange).hashCode;
}

/// A chosen UTC calendar year.
final class UtcYearRange extends StatsRange {
  const UtcYearRange(this.year);
  final int year;

  @override
  StatsWindow resolve(int capturedNowUtcMs) =>
      _yearWindow(year, capturedNowUtcMs);

  @override
  bool operator ==(Object other) => other is UtcYearRange && other.year == year;

  @override
  int get hashCode => Object.hash(UtcYearRange, year);
}

/// Everything before the captured now.
final class AllTimeRange extends StatsRange {
  const AllTimeRange();

  @override
  StatsWindow resolve(int capturedNowUtcMs) => StatsWindow(
        startUtcMs: null,
        endUtcMs: capturedNowUtcMs,
        capturedNowUtcMs: capturedNowUtcMs,
        unit: StatsBucketUnit.month,
      );

  @override
  bool operator ==(Object other) => other is AllTimeRange;

  @override
  int get hashCode => (AllTimeRange).hashCode;
}

/// One resolved range: listens starting in `[startUtcMs, countedEndUtcMs)`
/// count. [startUtcMs] is null for all time.
final class StatsWindow {
  const StatsWindow({
    required this.startUtcMs,
    required this.endUtcMs,
    required this.capturedNowUtcMs,
    required this.unit,
  });

  final int? startUtcMs;

  /// The range's nominal exclusive end (next 1 January for a year).
  final int endUtcMs;
  final int capturedNowUtcMs;
  final StatsBucketUnit unit;

  /// The exclusive end listens are counted to: future-dated events never
  /// count.
  int get countedEndUtcMs =>
      endUtcMs < capturedNowUtcMs ? endUtcMs : capturedNowUtcMs;

  /// The chart's buckets. [earliestListenUtcMs] (the earliest counted listen,
  /// null when none) is used only by all time.
  StatsBucketPlan bucketPlan({int? earliestListenUtcMs}) {
    final end = countedEndUtcMs;
    final start = startUtcMs ?? earliestListenUtcMs;
    if (start == null || end <= start) {
      return StatsBucketPlan(const [], capped: false);
    }
    final isDay = unit == StatsBucketUnit.day;
    DateTime floor(int ms) {
      final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
      return isDay ? DateTime.utc(d.year, d.month, d.day) : DateTime.utc(d.year, d.month);
    }

    DateTime next(DateTime d) => isDay
        ? DateTime.utc(d.year, d.month, d.day + 1)
        : DateTime.utc(d.year, d.month + 1);

    var first = floor(start);
    final last = floor(end - 1);
    var capped = false;
    if (startUtcMs == null) {
      final earliestAllowed = DateTime.utc(last.year, last.month - 23);
      if (first.isBefore(earliestAllowed)) {
        first = earliestAllowed;
        capped = true;
      }
    }
    final spans = <StatsBucketSpan>[];
    for (var d = first; !d.isAfter(last); d = next(d)) {
      spans.add(StatsBucketSpan(
        d.millisecondsSinceEpoch,
        next(d).millisecondsSinceEpoch,
      ));
    }
    return StatsBucketPlan(List.unmodifiable(spans), capped: capped);
  }
}

/// One chart bucket's half-open UTC span.
final class StatsBucketSpan {
  const StatsBucketSpan(this.startUtcMs, this.endUtcMs);
  final int startUtcMs;
  final int endUtcMs;
}

/// The bucket spans of a chart; [capped] when all time's chart was cut to
/// the latest 24 months while older listens exist.
final class StatsBucketPlan {
  const StatsBucketPlan(this.spans, {required this.capped});
  final List<StatsBucketSpan> spans;
  final bool capped;
}

/// Overall totals of a range (spec §2). Seconds are exact; rounding happens
/// only at presentation.
final class ListeningTotals {
  const ListeningTotals({
    required this.listeningSeconds,
    required this.qualifiedPlays,
    required this.uniqueTracks,
    required this.activeDays,
  });
  final double listeningSeconds;
  final int qualifiedPlays;
  final int uniqueTracks;
  final int activeDays;
}

/// Time and qualified plays of deleted or unresolved tracks: part of the
/// overall totals, never of a ranking.
final class ListeningSubtotal {
  const ListeningSubtotal({
    required this.listeningSeconds,
    required this.qualifiedPlays,
  });
  final double listeningSeconds;
  final int qualifiedPlays;
}

/// One zero-filled chart bucket.
final class ListeningBucket {
  const ListeningBucket({
    required this.startUtcMs,
    required this.endUtcMs,
    required this.listeningSeconds,
  });
  final int startUtcMs;
  final int endUtcMs;
  final double listeningSeconds;
}

/// One ranked, hydrated entity (track, artist or album read model).
final class RankedEntry<T> {
  const RankedEntry({
    required this.entity,
    required this.listeningSeconds,
    required this.qualifiedPlays,
  });
  final T entity;
  final double listeningSeconds;
  final int qualifiedPlays;
}

/// One immutable statistics snapshot: everything `load` read in one
/// transaction.
final class ListeningStats {
  ListeningStats({
    required this.range,
    required this.window,
    required this.boundaryLocalId,
    required this.totals,
    required this.unavailable,
    required this.futureTimestampCount,
    required this.overlongListenCount,
    required List<ListeningBucket> buckets,
    required this.chartCapped,
    required List<RankedEntry<TrackUI>> topTracks,
    required List<RankedEntry<ArtistUI>> topArtists,
    required List<RankedEntry<AlbumUI>> topAlbums,
  }) : buckets = List.unmodifiable(buckets),
       topTracks = List.unmodifiable(topTracks),
       topArtists = List.unmodifiable(topArtists),
       topAlbums = List.unmodifiable(topAlbums);

  final StatsRange range;
  final StatsWindow window;
  final int boundaryLocalId;
  final ListeningTotals totals;
  final ListeningSubtotal unavailable;

  /// Play rows dated at or after the captured now, whatever the range:
  /// excluded from every total until their time (a diagnostic).
  final int futureTimestampCount;

  /// Finite play rows longer than the per-listen bound
  /// (`maxListenSeconds`) that started in the range's counted window or at/
  /// after the captured now: excluded from every statistic and counted here
  /// whatever their date, so they are never silently dropped (a diagnostic,
  /// like [futureTimestampCount]; an overlong row is never in that count).
  final int overlongListenCount;
  final List<ListeningBucket> buckets;

  /// All time only: the chart shows the latest 24 months, totals all time.
  final bool chartCapped;
  final List<RankedEntry<TrackUI>> topTracks;
  final List<RankedEntry<ArtistUI>> topArtists;
  final List<RankedEntry<AlbumUI>> topAlbums;

  StatsBucketUnit get bucketUnit => window.unit;
  int get capturedNowUtcMs => window.capturedNowUtcMs;
}

/// Keyset position after one ranked entity (SC-10 cursor): its exact
/// listening time in integer microseconds, its qualified plays and its key
/// (track uuid, artist or album id): the rank order's whole sort tuple.
final class RankCursor<K> {
  const RankCursor({
    required this.listeningMicros,
    required this.qualifiedPlays,
    required this.key,
  });
  final int listeningMicros;
  final int qualifiedPlays;
  final K key;

  @override
  bool operator ==(Object other) =>
      other is RankCursor<K> &&
      other.listeningMicros == listeningMicros &&
      other.qualifiedPlays == qualifiedPlays &&
      other.key == key;

  @override
  int get hashCode => Object.hash(listeningMicros, qualifiedPlays, key);

  @override
  String toString() => 'RankCursor($listeningMicros µs, $qualifiedPlays, $key)';
}

/// One entry of a ranking page with its keyset position.
final class RankedPageEntry<E, K> {
  const RankedPageEntry(this.entry, this.cursor);
  final RankedEntry<E> entry;
  final RankCursor<K> cursor;
}

/// The entities a statistics screen shows, as they resolve in the catalog
/// now (SC-12). A shown entity missing here is unavailable: deleted, or no
/// longer resolving. Its snapshot numbers still stand.
final class CurrentStatsEntities {
  CurrentStatsEntities({
    required Map<String, TrackUI> tracks,
    required Map<int, ArtistUI> artists,
    required Map<int, AlbumUI> albums,
  }) : tracks = Map.unmodifiable(tracks),
       artists = Map.unmodifiable(artists),
       albums = Map.unmodifiable(albums);

  final Map<String, TrackUI> tracks;
  final Map<int, ArtistUI> artists;
  final Map<int, AlbumUI> albums;

  /// [shown] (a track, artist or album read model from a snapshot) as it
  /// resolves now; null when it no longer resolves (unavailable).
  Object? currentOf(Object shown) => switch (shown) {
    TrackUI() => tracks[shown.uuidId],
    ArtistUI() => artists[shown.id],
    AlbumUI() => albums[shown.id],
    _ => null,
  };
}
