// Phase 9C.1 S1: the annual recap snapshot (spec §6 paragraph 1; review
// 9-U06 tie/empty/year-so-far, 9-U02 "no busiest month for an all-zero
// year"). Inputs are hand-built statistics; every expected value is written
// out here from the spec, not computed.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/annual_recap.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import '../helpers/listening_stats_builder.dart';

// 2026-03-15T12:00Z.
final now = utc(2026, 3, 15, 12);

HistorySnapshotToken tokenAt(int nowMs, {int boundary = 42}) =>
    HistorySnapshotToken(
      boundaryLocalId: boundary,
      historyContentVersion: 3,
      capturedNowUtcMs: nowMs,
      filterKey: 'any',
    );

TrackUI track(String uuid) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: uuid,
  duration: 200,
  bitrateKbps: null,
  sampleRateHz: null,
  channels: null,
  hasAlbumArt: false,
);

RankedEntry<T> entry<T>(T e, double s, int q) =>
    RankedEntry(entity: e, listeningSeconds: s, qualifiedPlays: q);

/// Monthly buckets of [year] from January, one per given seconds value.
List<ListeningBucket> months(int year, List<double> seconds) => [
  for (var i = 0; i < seconds.length; i++)
    ListeningBucket(
      startUtcMs: utc(year, i + 1),
      endUtcMs: utc(year, i + 2),
      listeningSeconds: seconds[i],
    ),
];

ListeningStats stats(
  int year, {
  int nowMs = 0,
  int boundary = 42,
  StatsRange? range,
  double seconds = 0,
  int qualified = 0,
  int unique = 0,
  int days = 0,
  double unavailableSeconds = 0,
  int unavailableQualified = 0,
  List<double> monthly = const [],
  List<RankedEntry<TrackUI>> tracks = const [],
  List<RankedEntry<ArtistUI>> artists = const [],
  List<RankedEntry<AlbumUI>> albums = const [],
}) {
  final r = range ?? StatsRange.year(year);
  final n = nowMs == 0 ? now : nowMs;
  return listeningStatsOf(
    range: r,
    window: r.resolve(n),
    boundaryLocalId: boundary,
    seconds: seconds,
    qualifiedPlays: qualified,
    uniqueTracks: unique,
    activeDays: days,
    unavailableSeconds: unavailableSeconds,
    unavailablePlays: unavailableQualified,
    buckets: months(year, monthly),
    topTracks: tracks,
    topArtists: artists,
    topAlbums: albums,
  );
}

void main() {
  group('the year and its label', () {
    test('a prior year is a whole UTC year, not "Year so far"', () {
      final recap = AnnualRecap.fromStats(
        stats(2025, monthly: List.filled(12, 0)),
        tokenAt(now),
      );
      expect(recap.year, 2025);
      expect(recap.isYearSoFar, isFalse);
      expect(recap.window.startUtcMs, utc(2025));
      expect(recap.window.endUtcMs, utc(2026));
      expect(recap.window.countedEndUtcMs, utc(2026));
    });

    test('the captured now\'s UTC year is "Year so far", counted to now', () {
      final recap = AnnualRecap.fromStats(
        stats(2026, monthly: [0, 0, 0]),
        tokenAt(now),
      );
      expect(recap.year, 2026);
      expect(recap.isYearSoFar, isTrue);
      expect(recap.window.startUtcMs, utc(2026));
      expect(recap.window.endUtcMs, utc(2027));
      expect(recap.window.countedEndUtcMs, now);
    });

    test('the year is judged in UTC: 1 ms before New Year is the old year',
        () {
      final lastMs = utc(2026) - 1;
      final recap = AnnualRecap.fromStats(
        stats(2025, nowMs: lastMs, monthly: List.filled(12, 0)),
        tokenAt(lastMs),
      );
      expect(recap.isYearSoFar, isTrue);
      final next = AnnualRecap.fromStats(
        stats(2025, nowMs: utc(2026), monthly: List.filled(12, 0)),
        tokenAt(utc(2026)),
      );
      expect(next.isYearSoFar, isFalse);
    });

    test('the generated time is the token\'s captured now (SC-20)', () {
      final token = tokenAt(now);
      final recap = AnnualRecap.fromStats(stats(2025), token);
      expect(recap.generatedAtUtcMs, now);
      expect(recap.token, token);
    });
  });

  group('one load under one token', () {
    test('statistics of a range that is not a chosen year are refused', () {
      expect(
        () => AnnualRecap.fromStats(
          stats(2026, range: StatsRange.thisUtcYear),
          tokenAt(now),
        ),
        throwsArgumentError,
      );
      expect(
        () => AnnualRecap.fromStats(
          stats(2026, range: StatsRange.last30Days),
          tokenAt(now),
        ),
        throwsArgumentError,
      );
    });

    test('statistics loaded under another boundary or now are refused', () {
      expect(
        () => AnnualRecap.fromStats(stats(2025, boundary: 41), tokenAt(now)),
        throwsArgumentError,
      );
      expect(
        () => AnnualRecap.fromStats(stats(2025), tokenAt(now + 1)),
        throwsArgumentError,
      );
    });
  });

  group('numbers come from the load unchanged', () {
    test('totals, unavailable time and months are the load\'s, exact', () {
      final recap = AnnualRecap.fromStats(
        stats(
          2025,
          seconds: 2020.5,
          qualified: 10,
          unique: 7,
          days: 11,
          unavailableSeconds: 100.25,
          unavailableQualified: 1,
          monthly: [120.5, 0, 600, 0, 250, 0, 600, 0, 300, 0, 100.25, 50],
        ),
        tokenAt(now),
      );
      expect(recap.totals.listeningSeconds, 2020.5);
      expect(recap.totals.qualifiedPlays, 10);
      expect(recap.totals.uniqueTracks, 7);
      expect(recap.totals.activeDays, 11);
      expect(recap.unavailable.listeningSeconds, 100.25);
      expect(recap.unavailable.qualifiedPlays, 1);
      expect(
        [for (final m in recap.months) m.listeningSeconds],
        [120.5, 0, 600, 0, 250, 0, 600, 0, 300, 0, 100.25, 50],
      );
      expect(recap.months.first.startUtcMs, utc(2025));
    });
  });

  group('top five', () {
    test('the first five of each list in repository order, ties kept', () {
      final ts = [
        for (final (u, s) in [
          ('t-a', 420.5),
          ('t-c', 400.0),
          ('t-b', 300.0),
          ('t-d', 280.0),
          ('t-e', 250.0),
          ('t-f', 250.0),
          ('t-g', 20.0),
        ])
          entry(track(u), s, 1),
      ];
      final artists = [
        for (var i = 1; i <= 7; i++)
          entry(ArtistUI(id: i, name: 'a$i'), 100.0 - i, 1),
      ];
      final albums = [
        for (var i = 1; i <= 3; i++)
          entry(AlbumUI(id: i, artistId: 1, name: 'b$i'), 10.0, 1),
      ];
      final recap = AnnualRecap.fromStats(
        stats(2025, tracks: ts, artists: artists, albums: albums),
        tokenAt(now),
      );
      expect(
        [for (final e in recap.topTracks) e.entity.uuidId],
        ['t-a', 't-c', 't-b', 't-d', 't-e'],
      );
      expect([for (final e in recap.topArtists) e.entity.id], [1, 2, 3, 4, 5]);
      // Fewer than five: all of them, nothing invented.
      expect([for (final e in recap.topAlbums) e.entity.id], [1, 2, 3]);
    });
  });

  group('busiest month', () {
    test('the month with the most listening time', () {
      final recap = AnnualRecap.fromStats(
        stats(2026, seconds: 290, monthly: [60, 200, 30]),
        tokenAt(now),
      );
      expect(recap.busiestMonth!.startUtcMs, utc(2026, 2));
      expect(recap.busiestMonth!.endUtcMs, utc(2026, 3));
      expect(recap.busiestMonth!.listeningSeconds, 200);
    });

    test('a tie chooses the earliest month', () {
      final recap = AnnualRecap.fromStats(
        stats(
          2025,
          seconds: 2020.5,
          monthly: [120.5, 0, 600, 0, 250, 0, 600, 0, 300, 0, 100, 50],
        ),
        tokenAt(now),
      );
      expect(recap.busiestMonth!.startUtcMs, utc(2025, 3));
    });

    test('a tie of differently split sums is still a tie (exact micros)', () {
      // 0.1 + 0.2 and 0.3 are equal recorded time; as doubles 0.1 + 0.2 is
      // larger, which must not make the later month win.
      final recap = AnnualRecap.fromStats(
        stats(2025, seconds: 0.6, monthly: [0.3, 0.1 + 0.2]),
        tokenAt(now),
      );
      expect(recap.busiestMonth!.startUtcMs, utc(2025, 1));
    });

    test('isEmpty: no listening time (review F4)', () {
      expect(
        AnnualRecap.fromStats(stats(2025, monthly: [0]), tokenAt(now)).isEmpty,
        isTrue,
      );
      expect(
        AnnualRecap.fromStats(
          stats(2025, seconds: 0.5, monthly: [0.5]),
          tokenAt(now),
        ).isEmpty,
        isFalse,
      );
    });

    test('a year with no listening has none, not January with 0', () {
      final recap = AnnualRecap.fromStats(
        stats(2025, monthly: List.filled(12, 0)),
        tokenAt(now),
      );
      expect(recap.busiestMonth, isNull);
      expect(recap.topTracks, isEmpty);
      expect(recap.topArtists, isEmpty);
      expect(recap.topAlbums, isEmpty);
    });

    test('a future year (no months at all) has none either', () {
      final recap = AnnualRecap.fromStats(stats(2027), tokenAt(now));
      expect(recap.months, isEmpty);
      expect(recap.busiestMonth, isNull);
      expect(recap.isYearSoFar, isFalse);
    });
  });

  test('the lists are unmodifiable', () {
    final recap = AnnualRecap.fromStats(
      stats(2025, monthly: [1], tracks: [entry(track('t'), 1, 0)]),
      tokenAt(now),
    );
    expect(() => recap.topTracks.add(recap.topTracks.first),
        throwsUnsupportedError);
    expect(() => recap.months.clear(), throwsUnsupportedError);
  });
}
