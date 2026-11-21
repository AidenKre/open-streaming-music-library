part of 'database.dart';

mixin _DownloadStateQueries on _$AppDatabase {
  /// Dismisses the stale-download warning for [uuidIds] as of each track's
  /// CURRENT revision -- stamping `staleDismissedAtRevision` (not a bool) so
  /// the warning re-arms if the track changes on the server again later.
  /// Unknown uuids are ignored. One statement, so there's no read-then-write
  /// window for a concurrent `/changes` upsert to slip a newer revision into
  /// (which would silently dismiss a change the user never saw).
  Future<void> dismissStaleDownloads(Iterable<String> uuidIds) async {
    final ids = uuidIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(', ');
    await customUpdate(
      'UPDATE tracks SET stale_dismissed_at_revision = revision '
      'WHERE uuid_id IN ($placeholders)',
      variables: ids.map(Variable.withString).toList(),
      updates: {tracks},
      updateKind: UpdateKind.update,
    );
  }

  Future<void> dismissStaleDownload(String uuidId) =>
      dismissStaleDownloads([uuidId]);

  /// Live list of downloaded tracks that are stale ([staleDownloadPredicate])
  /// -- filtered in SQL so the always-on banner watch doesn't map every
  /// downloaded track on each emission.
  Stream<List<QueryRow>> watchStaleDownloads() {
    return customSelect(
      'SELECT $trackSelectColumns '
      'FROM trackmetadata AS tm '
      'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id '
      'WHERE $staleDownloadPredicate '
      'ORDER BY tm.title COLLATE NOCASE, tm.uuid_id',
      readsFrom: {trackmetadata, tracks},
    ).watch();
  }

  /// Downloads that failed to play although their file exists (decision 6),
  /// kept for the user to re-download or delete.
  Stream<List<QueryRow>> watchDamagedDownloads() {
    return customSelect(
      'SELECT $trackSelectColumns '
      'FROM trackmetadata AS tm '
      'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id '
      'WHERE t.damaged_file_path IS NOT NULL '
      'ORDER BY tm.title COLLATE NOCASE, tm.uuid_id',
      readsFrom: {trackmetadata, tracks},
    ).watch();
  }

  /// Every local file a track owns (its download and a kept damaged copy),
  /// distinct; rows in the order SQLite returns them, within a row
  /// `file_path` before `damaged_file_path`. All tracks when [uuids] is
  /// null; an empty [uuids] reads nothing. Run it inside
  /// the caller's transaction, before the row is cleared or deleted. This is
  /// the one reader of "which files does a track own", so a new path column is
  /// added here once (and to `clearedDownloadColumns`).
  Future<List<String>> ownedTrackFilePaths({Iterable<String>? uuids}) async {
    final List<QueryRow> rows;
    if (uuids == null) {
      rows = await customSelect(
        'SELECT file_path, damaged_file_path FROM tracks '
        'WHERE file_path IS NOT NULL OR damaged_file_path IS NOT NULL',
        readsFrom: {tracks},
      ).get();
    } else {
      final list = uuids.toList(growable: false);
      if (list.isEmpty) return const [];
      final placeholders = List.filled(list.length, '?').join(', ');
      rows = await customSelect(
        'SELECT file_path, damaged_file_path FROM tracks '
        'WHERE uuid_id IN ($placeholders) '
        'AND (file_path IS NOT NULL OR damaged_file_path IS NOT NULL)',
        variables: list.map(Variable.withString).toList(),
        readsFrom: {tracks},
      ).get();
    }
    return <String>{
      for (final row in rows)
        for (final column in const ['file_path', 'damaged_file_path'])
          ?row.readNullable<String>(column),
    }.toList();
  }

  Stream<({int count, int totalBytes})> watchDownloadedStats() {
    return customSelect(
      'SELECT COUNT(*) AS c, COALESCE(SUM(t.file_size_bytes), 0) AS total_bytes '
      'FROM tracks AS t WHERE $usableDownloadPredicate',
      readsFrom: {tracks},
    ).watch().map(
      (rows) => (
        count: rows.first.read<int>('c'),
        totalBytes: rows.first.read<int>('total_bytes'),
      ),
    );
  }

  /// The cover ids of [uuids] whose track has a download (a file or a kept
  /// damaged copy).
  Future<Set<int>> downloadedCoverArtIds(List<String> uuids) async {
    if (uuids.isEmpty) return const {};
    final placeholders = List.filled(uuids.length, '?').join(', ');
    final rows = await customSelect(
      'SELECT DISTINCT tm.cover_art_id AS id FROM trackmetadata tm '
      'INNER JOIN tracks t ON t.uuid_id = tm.uuid_id '
      'WHERE t.uuid_id IN ($placeholders) AND tm.cover_art_id IS NOT NULL '
      'AND (t.file_path IS NOT NULL OR t.damaged_file_path IS NOT NULL)',
      variables: uuids.map(Variable.withString).toList(),
      readsFrom: {tracks, trackmetadata},
    ).get();
    return {for (final r in rows) r.read<int>('id')};
  }

  /// Whether a track with a download (a file or a kept damaged copy) shows
  /// cover [coverArtId].
  Future<bool> coverArtUsedByDownload(int coverArtId) async {
    final row = await customSelect(
      'SELECT 1 FROM trackmetadata tm '
      'INNER JOIN tracks t ON t.uuid_id = tm.uuid_id '
      'WHERE tm.cover_art_id = ? '
      'AND (t.file_path IS NOT NULL OR t.damaged_file_path IS NOT NULL) '
      'LIMIT 1',
      variables: [Variable.withInt(coverArtId)],
      readsFrom: {tracks, trackmetadata},
    ).getSingleOrNull();
    return row != null;
  }

  // ── Download status aggregates ────────────────────────────────────────

  /// Download counts for every album in one grouped query: `(total,
  /// downloaded)` per album id; an album is "fully downloaded" iff
  /// `downloaded == total && total > 0`. Lets the UI batch all visible album
  /// cards into a single read instead of one query per card.
  Future<Map<int, ({int total, int downloaded})>> getAllAlbumDownloadCounts() =>
      _downloadCountsByColumn('album_id');

  /// Download counts for every artist in one grouped query.
  Future<Map<int, ({int total, int downloaded})>>
      getAllArtistDownloadCounts() =>
          _downloadCountsByColumn('artist_id');

  /// Grouped (total, downloaded) track counts by [groupColumn], for every
  /// (non-null) group. [groupColumn] is a hardcoded internal literal
  /// ('album_id'/'artist_id') — never user input — so interpolating it is
  /// safe.
  Future<Map<int, ({int total, int downloaded})>> _downloadCountsByColumn(
    String groupColumn,
  ) async {
    final rows = await customSelect(
      'SELECT tm.$groupColumn AS aid, COUNT(*) AS total, '
      'SUM(CASE WHEN $usableDownloadPredicate THEN 1 ELSE 0 END) AS downloaded '
      'FROM trackmetadata tm '
      'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id '
      'WHERE tm.$groupColumn IS NOT NULL '
      'GROUP BY tm.$groupColumn',
      readsFrom: {trackmetadata, tracks},
    ).get();
    return {
      for (final r in rows)
        r.read<int>('aid'): (
          total: r.read<int>('total'),
          downloaded: r.read<int>('downloaded'),
        ),
    };
  }
}
