part of 'database.dart';

/// What a catalog page's search maintenance reads before the page is written
/// ([AppDatabase.readSearchBeforePage]) and hands to
/// [AppDatabase.applySearchDeltaOfPage] after it, in the same transaction.
final class PageSearchBefore {
  const PageSearchBefore._({
    required this.trackIds,
    required this.tracks,
    required this.artistIds,
    required this.albumIds,
    required this.parents,
  });

  /// Every track the page upserts or deletes.
  final Set<String> trackIds;

  /// The indexed values of those of [trackIds] that existed, by uuid.
  final Map<String, TrackFtsEntry> tracks;

  /// The artist and album ids the page's upserts write.
  final Set<int> artistIds;
  final Set<int> albumIds;

  /// What `fts_artists` and `fts_albums` index for [artistIds] and
  /// [albumIds].
  final Set<Object?> parents;
}

/// One SELECT or INSERT per 500 ids: a page has 500 entries by default (the
/// server's limit is 1,000), far below SQLite's bound-variable limit.
const _searchIdChunk = 500;

Iterable<List<T>> _chunked<T>(Set<T> ids) sync* {
  final list = ids.toList();
  for (var i = 0; i < list.length; i += _searchIdChunk) {
    yield list.sublist(
      i,
      i + _searchIdChunk > list.length ? list.length : i + _searchIdChunk,
    );
  }
}

String _placeholders(int n) => List.filled(n, '?').join(', ');

/// SQLITE_CORRUPT_VTAB: what FTS5 raises when it finds its index does not
/// hold what it is told (for example a 'delete' given the values of a row it
/// never indexed).
const _sqliteCorruptVtab = 267;

/// True only for SQLITE_CORRUPT_VTAB raised by a statement on one of the
/// three search tables, whether thrown here or relayed from the background
/// isolate the app's database runs in. Every other error is a real fault.
bool isSearchIndexMismatch(Object error) {
  final cause = error is DriftRemoteException ? error.remoteCause : error;
  if (cause is! SqliteException) return false;
  if (cause.extendedResultCode != _sqliteCorruptVtab) return false;
  final statement = cause.causingStatement ?? '';
  return RegExp(r'\bfts_(tracks|artists|albums)\b').hasMatch(statement);
}

mixin _SearchIndex on _$AppDatabase {
  /// Empties the three search tables and fills them again from the catalog
  /// tables. A sync runs it only when a page finds the index does not hold
  /// what the tables say (see [isSearchIndexMismatch]); otherwise each page
  /// updates its own entries ([applySearchDeltaOfPage]). It is also for a
  /// migration step that renumbers trackmetadata's rowids (see
  /// [AppDatabase.schemaVersion]).
  Future<void> rebuildFtsIndexes() async {
    await rebuildParentFtsIndexes();

    await customStatement(
      "INSERT INTO fts_tracks(fts_tracks) VALUES('delete-all')",
    );
    await customStatement(
      "INSERT INTO fts_tracks(rowid, title, artist_name, album_name) "
      "SELECT rowid, COALESCE(title, ''), COALESCE(artist, ''), COALESCE(album, '') "
      "FROM trackmetadata",
    );
  }

  /// Rebuild only the artist/album FTS indexes — small tables, cheap to
  /// re-derive. Single-track reconciliation pairs this with a per-row
  /// [applyTrackFtsDelta] so it never pays the O(library) fts_tracks rebuild.
  Future<void> rebuildParentFtsIndexes() async {
    await customStatement(
      "INSERT INTO fts_artists(fts_artists) VALUES('delete-all')",
    );
    await customStatement(
      "INSERT INTO fts_artists(rowid, name) "
      "SELECT id, name FROM artists",
    );

    await customStatement(
      "INSERT INTO fts_albums(fts_albums) VALUES('delete-all')",
    );
    await customStatement(
      "INSERT INTO fts_albums(rowid, name, artist_name) "
      "SELECT a.id, COALESCE(a.name, ''), ar.name "
      "FROM albums a JOIN artists ar ON a.artist_id = ar.id",
    );
  }

  /// A track's FTS-relevant values, or null if the row doesn't exist. Capture
  /// BEFORE a write so [applyTrackFtsDelta] can delete the old contentless
  /// terms (an FTS5 external-content 'delete' must be given the exact values
  /// that were indexed).
  Future<TrackFtsEntry?> readTrackFtsEntry(String uuidId) async {
    final row = await customSelect(
      "SELECT rowid AS rid, COALESCE(title, '') AS t, "
      "COALESCE(artist, '') AS a, COALESCE(album, '') AS al "
      'FROM trackmetadata WHERE uuid_id = ?',
      variables: [Variable.withString(uuidId)],
      readsFrom: {trackmetadata},
    ).getSingleOrNull();
    if (row == null) return null;
    return (
      rowid: row.read<int>('rid'),
      title: row.read<String>('t'),
      artist: row.read<String>('a'),
      album: row.read<String>('al'),
    );
  }

  /// Reconcile one track's `fts_tracks` entry after its row was updated,
  /// upserted, or deleted: delete [before]'s terms (if the row existed) and
  /// index the current ones (if it still exists). The shared per-row path
  /// used by the optimistic edit write and single-track refetch.
  Future<void> applyTrackFtsDelta(String uuidId, TrackFtsEntry? before) async {
    final after = await readTrackFtsEntry(uuidId);
    if (before != null) {
      await customStatement(
        "INSERT INTO fts_tracks(fts_tracks, rowid, title, artist_name, album_name) "
        "VALUES('delete', ?, ?, ?, ?)",
        [before.rowid, before.title, before.artist, before.album],
      );
    }
    if (after != null) {
      await customStatement(
        'INSERT INTO fts_tracks(rowid, title, artist_name, album_name) '
        'VALUES(?, ?, ?, ?)',
        [after.rowid, after.title, after.artist, after.album],
      );
    }
  }

  /// Run inside a catalog page's transaction, before its writes: the indexed
  /// values of the page's tracks (one query per 500 ids; a contentless index
  /// must be given the exact old values to delete them) and what the parent
  /// indexes hold for the artist and album ids the page writes. A page with
  /// no entries reads nothing.
  Future<PageSearchBefore> readSearchBeforePage({
    required Set<String> trackIds,
    required Set<int> artistIds,
    required Set<int> albumIds,
  }) async {
    final tracks = <String, TrackFtsEntry>{};
    for (final chunk in _chunked(trackIds)) {
      final rows = await customSelect(
        "SELECT uuid_id, rowid AS rid, COALESCE(title, '') AS t, "
        "COALESCE(artist, '') AS a, COALESCE(album, '') AS al "
        'FROM trackmetadata WHERE uuid_id IN (${_placeholders(chunk.length)})',
        variables: [for (final id in chunk) Variable.withString(id)],
        readsFrom: {trackmetadata},
      ).get();
      for (final row in rows) {
        tracks[row.read<String>('uuid_id')] = (
          rowid: row.read<int>('rid'),
          title: row.read<String>('t'),
          artist: row.read<String>('a'),
          album: row.read<String>('al'),
        );
      }
    }
    return PageSearchBefore._(
      trackIds: trackIds,
      tracks: tracks,
      artistIds: artistIds,
      albumIds: albumIds,
      parents: await _readParentFtsSources(artistIds, albumIds),
    );
  }

  /// Run inside the same transaction, after the page's writes: deletes the
  /// old terms of every track in [before] (one batch), indexes the current
  /// row of every one that still exists (one INSERT per 500 ids), and
  /// rebuilds the small artist and album indexes only when the page changed
  /// what they hold: a row the page's upserts write is new, renamed, moved or
  /// gone ([before.parents] differs), or the orphan prune removed a row
  /// ([parentsPruned]).
  Future<void> applySearchDeltaOfPage(
    PageSearchBefore before, {
    required bool parentsPruned,
  }) async {
    if (before.trackIds.isEmpty) return;
    // Every old entry goes before any new one: a rowid freed by a track the
    // page deleted can be taken by a track the same page inserted.
    if (before.tracks.isNotEmpty) {
      await batch((b) {
        for (final e in before.tracks.values) {
          b.customStatement(
            'INSERT INTO fts_tracks(fts_tracks, rowid, title, artist_name, '
            "album_name) VALUES('delete', ?, ?, ?, ?)",
            [e.rowid, e.title, e.artist, e.album],
          );
        }
      });
    }
    for (final chunk in _chunked(before.trackIds)) {
      await customStatement(
        'INSERT INTO fts_tracks(rowid, title, artist_name, album_name) '
        "SELECT rowid, COALESCE(title, ''), COALESCE(artist, ''), "
        "COALESCE(album, '') FROM trackmetadata "
        'WHERE uuid_id IN (${_placeholders(chunk.length)})',
        chunk,
      );
    }
    final parentsNow =
        await _readParentFtsSources(before.artistIds, before.albumIds);
    final parentsSame = parentsNow.length == before.parents.length &&
        parentsNow.containsAll(before.parents);
    if (parentsPruned || !parentsSame) await rebuildParentFtsIndexes();
  }

  /// The values [rebuildParentFtsIndexes] would index for these ids.
  Future<Set<Object?>> _readParentFtsSources(
    Set<int> artistIds,
    Set<int> albumIds,
  ) async {
    final sources = <Object?>{};
    for (final chunk in _chunked(artistIds)) {
      final rows = await customSelect(
        'SELECT id, name FROM artists '
        'WHERE id IN (${_placeholders(chunk.length)})',
        variables: [for (final id in chunk) Variable.withInt(id)],
        readsFrom: {artists},
      ).get();
      for (final r in rows) {
        sources.add(('artist', r.read<int>('id'), r.read<String>('name')));
      }
    }
    for (final chunk in _chunked(albumIds)) {
      final rows = await customSelect(
        "SELECT a.id, COALESCE(a.name, '') AS name, ar.name AS artist_name "
        'FROM albums a JOIN artists ar ON a.artist_id = ar.id '
        'WHERE a.id IN (${_placeholders(chunk.length)})',
        variables: [for (final id in chunk) Variable.withInt(id)],
        readsFrom: {albums, artists},
      ).get();
      for (final r in rows) {
        sources.add((
          'album',
          r.read<int>('id'),
          r.read<String>('name'),
          r.read<String>('artist_name'),
        ));
      }
    }
    return sources;
  }
}
