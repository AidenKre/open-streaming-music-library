/// Phase 9C annual recap (spec §6): one immutable snapshot of a UTC year,
/// built from one statistics `load` under one history snapshot token. The
/// page and every export (JSON now, PNG in 9C.2) read this one object.
/// Pure model: no I/O, nothing from `ui/`.
library;

import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/history_snapshot.dart';

/// How many entries of each top list a recap shows.
const recapTopCount = 5;

/// The UTC calendar year of [utcMs].
int utcYearOf(int utcMs) =>
    DateTime.fromMillisecondsSinceEpoch(utcMs, isUtc: true).year;

final class AnnualRecap {
  AnnualRecap._({
    required this.year,
    required this.window,
    required this.isYearSoFar,
    required this.generatedAtUtcMs,
    required this.token,
    required this.totals,
    required this.unavailable,
    required this.months,
    required this.busiestMonth,
    required this.topTracks,
    required this.topArtists,
    required this.topAlbums,
  });

  /// The recap of [stats] (a [UtcYearRange] load) captured under [token].
  /// Throws [ArgumentError] when [stats] is not a year's statistics or was
  /// not loaded with [token]'s boundary and captured now.
  factory AnnualRecap.fromStats(
    ListeningStats stats,
    HistorySnapshotToken token,
  ) {
    final range = stats.range;
    if (range is! UtcYearRange) {
      throw ArgumentError.value(range, 'stats.range', 'must be a UtcYearRange');
    }
    if (stats.boundaryLocalId != token.boundaryLocalId) {
      throw ArgumentError.value(
        stats.boundaryLocalId,
        'stats.boundaryLocalId',
        'must equal the token boundary ${token.boundaryLocalId}',
      );
    }
    if (stats.capturedNowUtcMs != token.capturedNowUtcMs) {
      throw ArgumentError.value(
        stats.capturedNowUtcMs,
        'stats.capturedNowUtcMs',
        'must equal the token captured now ${token.capturedNowUtcMs}',
      );
    }
    final nowYear = utcYearOf(token.capturedNowUtcMs);
    ListeningBucket? busiest;
    if (stats.totals.listeningSeconds != 0) {
      int micros(ListeningBucket b) => (b.listeningSeconds * 1e6).round();
      for (final b in stats.buckets) {
        if (busiest == null || micros(b) > micros(busiest)) busiest = b;
      }
    }
    return AnnualRecap._(
      year: range.year,
      window: stats.window,
      isYearSoFar: nowYear == range.year,
      generatedAtUtcMs: token.capturedNowUtcMs,
      token: token,
      totals: stats.totals,
      unavailable: stats.unavailable,
      months: stats.buckets,
      busiestMonth: busiest,
      topTracks: List.unmodifiable(stats.topTracks.take(recapTopCount)),
      topArtists: List.unmodifiable(stats.topArtists.take(recapTopCount)),
      topAlbums: List.unmodifiable(stats.topAlbums.take(recapTopCount)),
    );
  }

  /// The UTC calendar year.
  final int year;

  /// `[1 January, next 1 January)` UTC; listens count up to
  /// `window.countedEndUtcMs`.
  final StatsWindow window;

  /// The year is the captured now's UTC year: show "Year so far".
  final bool isYearSoFar;

  /// When the snapshot was captured (the token's `capturedNowUtcMs`).
  final int generatedAtUtcMs;

  final HistorySnapshotToken token;
  final ListeningTotals totals;
  final ListeningSubtotal unavailable;

  /// Zero-filled monthly buckets from January to the last counted month.
  final List<ListeningBucket> months;

  /// The year has no listening time.
  bool get isEmpty => totals.listeningSeconds == 0;

  /// The month with the most listening time, the earliest on a tie; null
  /// when the year has no listening time.
  final ListeningBucket? busiestMonth;

  final List<RankedEntry<TrackUI>> topTracks;
  final List<RankedEntry<ArtistUI>> topArtists;
  final List<RankedEntry<AlbumUI>> topAlbums;
}
