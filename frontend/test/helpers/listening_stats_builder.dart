import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';

/// Milliseconds since the epoch of a UTC date and hour.
int utc(int y, [int m = 1, int d = 1, int h = 0]) =>
    DateTime.utc(y, m, d, h).millisecondsSinceEpoch;

/// One [ListeningStats] for the statistics and recap tests: every field has
/// a neutral default, so a test names only what it is about and a new field
/// of the model is one edit here (U27-A-03).
ListeningStats listeningStatsOf({
  required StatsRange range,
  required StatsWindow window,
  int boundaryLocalId = 1,
  double seconds = 0,
  int qualifiedPlays = 0,
  int uniqueTracks = 0,
  int activeDays = 0,
  double unavailableSeconds = 0,
  int unavailablePlays = 0,
  int futureTimestampCount = 0,
  int overlongListenCount = 0,
  List<ListeningBucket> buckets = const [],
  bool chartCapped = false,
  List<RankedEntry<TrackUI>> topTracks = const [],
  List<RankedEntry<ArtistUI>> topArtists = const [],
  List<RankedEntry<AlbumUI>> topAlbums = const [],
}) => ListeningStats(
  range: range,
  window: window,
  boundaryLocalId: boundaryLocalId,
  totals: ListeningTotals(
    listeningSeconds: seconds,
    qualifiedPlays: qualifiedPlays,
    uniqueTracks: uniqueTracks,
    activeDays: activeDays,
  ),
  unavailable: ListeningSubtotal(
    listeningSeconds: unavailableSeconds,
    qualifiedPlays: unavailablePlays,
  ),
  futureTimestampCount: futureTimestampCount,
  overlongListenCount: overlongListenCount,
  buckets: buckets,
  chartCapped: chartCapped,
  topTracks: topTracks,
  topArtists: topArtists,
  topAlbums: topAlbums,
);
