part of 'database.dart';

// ── SELECT columns for track queries ────────────────────────────────────

const trackSelectColumns =
    'tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, '
    'tm.artist_id, tm.album_id, '
    'tm.year, tm.date, tm.genre, tm.track_number, tm.disc_number, '
    'tm.codec, tm.duration, tm.bitrate_kbps, tm.sample_rate_hz, '
    'tm.channels, tm.has_album_art, tm.cover_art_id, t.file_path, t.created_at, t.last_updated, '
    't.revision, '
    't.downloaded_bitrate_kbps, t.file_size_bytes, t.downloaded_quality, '
    't.downloaded_at_revision, t.downloaded_codec, t.stale_dismissed_at_revision, '
    't.damaged_file_path';

/// SQL test, over a `tracks` row aliased `t`, for a download the app can
/// use: the file is recorded and not marked damaged (Phase 5 decision 6).
/// The one definition behind every "is it downloaded?" rule (the Downloaded
/// filter, counts, stale downloads, playback entries). Must agree with
/// `TrackUI.isDownloaded`.
const usableDownloadPredicate =
    '(t.file_path IS NOT NULL AND t.damaged_file_path IS NULL)';

/// SQL form of the stale-download rule, over a `tracks` row aliased `t`: the
/// track has a downloaded file, its revision moved past the one the file is
/// current as of, and the user hasn't dismissed this particular change.
/// NULL `revision`/`downloaded_at_revision` compare as NULL (= not stale).
/// Must agree with `TrackUI.isStaleDownload` -- the Dart mirror used on
/// already-loaded rows; `test/models/ui/track_ui_test.dart` asserts the two
/// agree over every null/ordering combination.
const staleDownloadPredicate =
    '$usableDownloadPredicate '
    'AND t.revision > t.downloaded_at_revision '
    'AND (t.stale_dismissed_at_revision IS NULL '
    'OR t.revision > t.stale_dismissed_at_revision)';

/// SQL `EXISTS` test: some track whose `trackmetadata.[column]` equals
/// [owner] has a downloaded file. The one definition of "has downloads",
/// shared by browse and search so the Downloaded filter means the same thing
/// on every surface.
String hasDownloadedTrack(String column, String owner) =>
    'EXISTS (SELECT 1 FROM trackmetadata tm '
    'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id '
    'WHERE tm.$column = $owner AND $usableDownloadPredicate)';

/// Scalar subquery picking the cover art for the tracks whose
/// `trackmetadata.[column]` equals [owner]: the lowest-numbered track with
/// art. With [downloadedOnly] only downloaded tracks qualify; otherwise the
/// chosen `cover_art_id` may belong to a streaming-only track and resolving
/// it needs a network round trip. Shared by browse and search so an artist or
/// album shows the same cover in both.
String _coverArtSubquery(
  String column,
  String owner, {
  required bool downloadedOnly,
}) =>
    'SELECT tm.cover_art_id FROM trackmetadata tm '
    '${downloadedOnly ? 'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id ' : ''}'
    'WHERE tm.$column = $owner '
    'AND tm.has_album_art = 1 '
    'AND tm.cover_art_id IS NOT NULL '
    '${downloadedOnly ? 'AND $usableDownloadPredicate ' : ''}'
    'ORDER BY tm.track_number ASC, tm.uuid_id ASC '
    'LIMIT 1';

/// SC-12: the one album display projection (browse, search, by-ID). Rows alias
/// the album `a` and its artist `ar`. Uses the same cover rule everywhere, so a
/// result shows the same art as its browse card (and, filtered, art that
/// resolves offline).
String _albumProjection({required bool downloadedOnly}) =>
    'SELECT a.id, a.name, ar.name AS artist, a.artist_id, '
    'a."year", a.is_single_grouping, '
    '(${_coverArtSubquery('album_id', 'a.id', downloadedOnly: downloadedOnly)}) AS cover_art_id '
    'FROM albums a '
    'JOIN artists ar ON a.artist_id = ar.id';

/// SC-12: the one artist display projection. Rows come from `artists`.
String _artistProjection({required bool downloadedOnly}) =>
    'SELECT id, name, '
    '(${_coverArtSubquery('artist_id', 'artists.id', downloadedOnly: downloadedOnly)}) AS cover_art_id '
    'FROM artists';

/// FTS-relevant values of one trackmetadata row (see [AppDatabase.readTrackFtsEntry]).
typedef TrackFtsEntry = ({int rowid, String title, String artist, String album});

String prepareFtsQuery(String rawQuery) {
  final terms = rawQuery.trim().split(RegExp(r'\s+'));
  if (terms.isEmpty || (terms.length == 1 && terms[0].isEmpty)) return '';
  return terms.map((t) => '"${t.replaceAll('"', '""')}"*').join(' ');
}
