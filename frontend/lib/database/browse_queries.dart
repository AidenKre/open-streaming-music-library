part of 'database.dart';

mixin _BrowseQueries on _$AppDatabase {
  // ── Track queries ─────────────────────────────────────────────────────

  (String, List<Variable>) _buildTrackQuery({
    List<SearchParameter> searchParams = const [],
    List<OrderParameter> orderBy = const [],
    int? artistId,
    int? albumId,
    int? limit,
    bool downloadedOnly = false,
  }) {
    if (albumId != null && artistId == null) {
      throw ArgumentError('Cannot filter by album without artist');
    }

    final vars = <Variable>[];
    final whereClauses = <String>[];

    // Search parameters
    for (final param in searchParams) {
      final alias = aliasMap(param.column);
      if (param.value == null) {
        whereClauses.add('$alias."${param.column}" IS NULL');
      } else {
        whereClauses.add('$alias."${param.column}" ${param.operator} ?');
        vars.add(_variableFrom(param.value!));
      }
    }

    // Artist/album ID filters
    if (artistId != null) {
      whereClauses.add('tm."artist_id" = ?');
      vars.add(Variable.withInt(artistId));
    }
    if (albumId != null) {
      whereClauses.add('tm."album_id" = ?');
      vars.add(Variable.withInt(albumId));
    }

    if (downloadedOnly) {
      whereClauses.add(usableDownloadPredicate);
    }

    var sql =
        'SELECT $trackSelectColumns '
        'FROM trackmetadata AS tm '
        'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id';

    if (whereClauses.isNotEmpty) {
      sql += ' WHERE ${whereClauses.join(' AND ')}';
    }

    if (orderBy.isNotEmpty) {
      sql += ' ORDER BY ${trackOrderClause(orderBy)}';
    }

    if (limit != null) {
      sql += ' LIMIT ?';
      vars.add(Variable.withInt(limit));
    }

    return (sql, vars);
  }

  Future<List<QueryRow>> getTracks({
    List<SearchParameter> searchParams = const [],
    List<OrderParameter> orderBy = const [],
    int? artistId,
    int? albumId,
    int? limit,
    bool downloadedOnly = false,
  }) {
    final (sql, vars) = _buildTrackQuery(
      searchParams: searchParams,
      orderBy: orderBy,
      artistId: artistId,
      albumId: albumId,
      limit: limit,
      downloadedOnly: downloadedOnly,
    );
    return customSelect(
      sql,
      variables: vars,
      readsFrom: {trackmetadata, tracks},
    ).get();
  }

  /// Reactive window of the first [limit] tracks in display order. Re-emits on
  /// any write to the read tables, so edits/sync reflect without a refresh.
  Stream<List<QueryRow>> watchTracks({
    List<OrderParameter> orderBy = const [],
    int? artistId,
    int? albumId,
    int? limit,
    bool downloadedOnly = false,
  }) {
    final (sql, vars) = _buildTrackQuery(
      orderBy: orderBy,
      artistId: artistId,
      albumId: albumId,
      limit: limit,
      downloadedOnly: downloadedOnly,
    );
    return customSelect(
      sql,
      variables: vars,
      readsFrom: {trackmetadata, tracks},
    ).watch();
  }

  Future<List<QueryRow>> getTrackByUuid(String uuid) {
    return getTracks(
      searchParams: [
        SearchParameter(column: 'uuid_id', operator: '=', value: uuid),
      ],
      limit: 1,
    );
  }

  /// Live form of [getTrackByUuid]: re-emits when the track's rows change
  /// (e.g. a `/changes` pull lands a not-yet-synced track).
  Stream<List<QueryRow>> watchTrackByUuid(String uuid) {
    final (sql, vars) = _buildTrackQuery(
      searchParams: [
        SearchParameter(column: 'uuid_id', operator: '=', value: uuid),
      ],
      limit: 1,
    );
    return customSelect(
      sql,
      variables: vars,
      readsFrom: {trackmetadata, tracks},
    ).watch();
  }

  /// SC-12 by-ID album resolver: one query over the shared album projection,
  /// returned in the order of [ids] with missing ids dropped.
  /// [downloadedArtOnly] picks the cover from usable downloads only (the
  /// offline local-art variant, the same subquery the Downloaded grids use);
  /// it does NOT filter membership.
  Future<List<QueryRow>> getAlbumsByIds(
    List<int> ids, {
    bool downloadedArtOnly = false,
  }) async {
    if (ids.isEmpty) return [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await customSelect(
      '${_albumProjection(downloadedOnly: downloadedArtOnly)} '
      'WHERE a.id IN ($placeholders)',
      variables: ids.map(Variable.withInt).toList(),
      readsFrom: {albums, artists, trackmetadata, tracks},
    ).get();
    final byId = {for (final row in rows) row.read<int>('id'): row};
    return [
      for (final id in ids)
        if (byId.containsKey(id)) byId[id]!,
    ];
  }

  /// SC-12 by-ID artist resolver; same contract as [getAlbumsByIds].
  Future<List<QueryRow>> getArtistsByIds(
    List<int> ids, {
    bool downloadedArtOnly = false,
  }) async {
    if (ids.isEmpty) return [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await customSelect(
      '${_artistProjection(downloadedOnly: downloadedArtOnly)} '
      'WHERE id IN ($placeholders)',
      variables: ids.map(Variable.withInt).toList(),
      readsFrom: {artists, trackmetadata, tracks},
    ).get();
    final byId = {for (final row in rows) row.read<int>('id'): row};
    return [
      for (final id in ids)
        if (byId.containsKey(id)) byId[id]!,
    ];
  }

  Future<List<QueryRow>> getTracksByUuids(List<String> uuids) {
    if (uuids.isEmpty) return Future.value([]);

    final placeholders = List.filled(uuids.length, '?').join(', ');
    final vars = uuids.map((u) => Variable.withString(u)).toList();

    final sql =
        'SELECT $trackSelectColumns '
        'FROM trackmetadata AS tm '
        'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id '
        'WHERE tm.uuid_id IN ($placeholders)';

    return customSelect(
      sql,
      variables: vars,
      readsFrom: {trackmetadata, tracks},
    ).get().then((rows) {
      final rowsByUuid = {
        for (final row in rows) row.read<String>('uuid_id'): row,
      };
      return [
        for (final uuid in uuids)
          if (rowsByUuid.containsKey(uuid)) rowsByUuid[uuid]!,
      ];
    });
  }

  // ── Artist queries ────────────────────────────────────────────────────

  /// Reactive window of the first [limit] artists in display order. Re-emits on
  /// any write to the read tables, so edits/sync reflect without a refresh.
  Stream<List<QueryRow>> watchArtists({
    List<ArtistOrderParameter> orderBy = const [],
    int? limit,
    bool downloadedOnly = false,
  }) {
    final (sql, vars) = _buildArtistQuery(
      orderBy: orderBy,
      limit: limit,
      downloadedOnly: downloadedOnly,
    );
    return customSelect(
      sql,
      variables: vars,
      readsFrom: {artists, trackmetadata, tracks},
    ).watch();
  }

  (String, List<Variable>) _buildArtistQuery({
    List<ArtistOrderParameter> orderBy = const [],
    int? limit,
    bool downloadedOnly = false,
  }) {
    final vars = <Variable>[];

    var query = _artistProjection(downloadedOnly: downloadedOnly);

    final whereClauses = <String>[];

    if (downloadedOnly) {
      // Artist appears iff at least one of their tracks is downloaded. EXISTS
      // short-circuits on first hit, so this is cheaper than a COUNT.
      whereClauses.add(hasDownloadedTrack('artist_id', 'artists.id'));
    }

    if (whereClauses.isNotEmpty) {
      query += ' WHERE ${whereClauses.join(' AND ')}';
    }

    // ORDER BY
    if (orderBy.isNotEmpty) {
      final orderParts = <String>[];
      for (final o in orderBy) {
        final col = o.column;
        final dir = o.isAscending ? 'ASC' : 'DESC';
        final collate = artistTextColumns.contains(col)
            ? ' COLLATE NOCASE'
            : '';
        orderParts.add('"$col"$collate $dir');
      }
      query += ' ORDER BY ${orderParts.join(', ')}';
    } else {
      query += ' ORDER BY name COLLATE NOCASE ASC';
    }

    if (limit != null) {
      query += ' LIMIT ?';
      vars.add(Variable.withInt(limit));
    }

    return (query, vars);
  }

  // ── Album queries ─────────────────────────────────────────────────────

  (String, List<Variable>) _buildAlbumQuery({
    int? artistId,
    List<AlbumOrderParameter> orderBy = const [],
    int? limit,
    bool downloadedOnly = false,
  }) {
    final vars = <Variable>[];

    var sql = _albumProjection(downloadedOnly: downloadedOnly);

    final whereClauses = <String>[];

    if (artistId != null) {
      whereClauses.add('a.artist_id = ?');
      vars.add(Variable.withInt(artistId));
    }

    if (downloadedOnly) {
      whereClauses.add(hasDownloadedTrack('album_id', 'a.id'));
    }

    if (whereClauses.isNotEmpty) {
      sql += ' WHERE ${whereClauses.join(' AND ')}';
    }

    // ORDER BY
    if (orderBy.isNotEmpty) {
      final orderParts = <String>[];
      for (final o in orderBy) {
        final col = o.column;
        final colRef = _albumColRef(col);
        final dir = o.isAscending ? 'ASC' : 'DESC';
        final collate = albumTextColumns.contains(col) ? ' COLLATE NOCASE' : '';
        if (o.nullsLast) {
          orderParts.add('$colRef IS NULL ASC');
        }
        orderParts.add('$colRef$collate $dir');
      }
      sql += ' ORDER BY ${orderParts.join(', ')}';
    }

    if (limit != null) {
      sql += ' LIMIT ?';
      vars.add(Variable.withInt(limit));
    }

    return (sql, vars);
  }

  Future<List<QueryRow>> getAlbums({
    int? artistId,
    List<AlbumOrderParameter> orderBy = const [],
    int? limit,
    bool downloadedOnly = false,
  }) {
    final (sql, vars) = _buildAlbumQuery(
      artistId: artistId,
      orderBy: orderBy,
      limit: limit,
      downloadedOnly: downloadedOnly,
    );
    return customSelect(
      sql,
      variables: vars,
      readsFrom: {albums, artists, trackmetadata, tracks},
    ).get();
  }

  /// Reactive window of the first [limit] albums in display order. Re-emits on
  /// any write to the read tables, so edits/sync reflect without a refresh.
  Stream<List<QueryRow>> watchAlbums({
    int? artistId,
    List<AlbumOrderParameter> orderBy = const [],
    int? limit,
    bool downloadedOnly = false,
  }) {
    final (sql, vars) = _buildAlbumQuery(
      artistId: artistId,
      orderBy: orderBy,
      limit: limit,
      downloadedOnly: downloadedOnly,
    );
    return customSelect(
      sql,
      variables: vars,
      readsFrom: {albums, artists, trackmetadata, tracks},
    ).watch();
  }

  Future<
    ({List<QueryRow> tracks, List<QueryRow> artists, List<QueryRow> albums})
  >
  getSearchResults(
    String query, {
    bool searchTracks = true,
    bool searchArtists = true,
    bool searchAlbums = true,
    int limitPerType = 10,
    bool downloadedOnly = false,
  }) async {
    final ftsQuery = prepareFtsQuery(query);
    if (ftsQuery.isEmpty) {
      return (
        tracks: <QueryRow>[],
        artists: <QueryRow>[],
        albums: <QueryRow>[],
      );
    }

    final resultTracks = <QueryRow>[];
    final resultArtists = <QueryRow>[];
    final resultAlbums = <QueryRow>[];

    // When downloadedOnly, the filter is applied INSIDE the FTS query, before
    // LIMIT — otherwise a downloaded match ranked below limitPerType would be
    // dropped before we ever see it.
    final trackDownloadedFilter = downloadedOnly
        ? ' AND ${hasDownloadedTrack('rowid', 'fts_tracks.rowid')}'
        : '';
    final artistDownloadedFilter = downloadedOnly
        ? ' AND ${hasDownloadedTrack('artist_id', 'fts_artists.rowid')}'
        : '';
    final albumDownloadedFilter = downloadedOnly
        ? ' AND ${hasDownloadedTrack('album_id', 'fts_albums.rowid')}'
        : '';

    if (searchTracks) {
      final ftsRows = await customSelect(
        'SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH ?'
        '$trackDownloadedFilter ORDER BY rank, rowid LIMIT ?',
        variables: [
          Variable.withString(ftsQuery),
          Variable.withInt(limitPerType),
        ],
        readsFrom: {},
      ).get();
      if (ftsRows.isNotEmpty) {
        final trackIds = ftsRows.map((r) => r.read<int>('rowid')).toList();
        final placeholders = List.filled(trackIds.length, '?').join(', ');
        final vars = trackIds.map((id) => Variable.withInt(id)).toList();
        final fullRows = await customSelect(
          'SELECT $trackSelectColumns, tm.rowid AS _tm_rowid '
          'FROM trackmetadata AS tm '
          'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id '
          'WHERE tm.rowid IN ($placeholders)',
          variables: vars,
          readsFrom: {trackmetadata, tracks},
        ).get();
        final idOrder = {
          for (var i = 0; i < trackIds.length; i++) trackIds[i]: i,
        };
        final sorted = List<QueryRow>.from(fullRows)
          ..sort(
            (a, b) => (idOrder[a.read<int>('_tm_rowid')] ?? 999).compareTo(
              idOrder[b.read<int>('_tm_rowid')] ?? 999,
            ),
          );
        resultTracks.addAll(sorted);
      }
    }

    if (searchArtists) {
      final ftsRows = await customSelect(
        'SELECT rowid FROM fts_artists WHERE fts_artists MATCH ?'
        '$artistDownloadedFilter ORDER BY rank, rowid LIMIT ?',
        variables: [
          Variable.withString(ftsQuery),
          Variable.withInt(limitPerType),
        ],
        readsFrom: {},
      ).get();
      if (ftsRows.isNotEmpty) {
        final artistIds = ftsRows.map((r) => r.read<int>('rowid')).toList();
        resultArtists.addAll(
          await getArtistsByIds(artistIds, downloadedArtOnly: downloadedOnly),
        );
      }
    }

    if (searchAlbums) {
      final ftsRows = await customSelect(
        'SELECT rowid FROM fts_albums WHERE fts_albums MATCH ?'
        '$albumDownloadedFilter ORDER BY rank, rowid LIMIT ?',
        variables: [
          Variable.withString(ftsQuery),
          Variable.withInt(limitPerType),
        ],
        readsFrom: {},
      ).get();
      if (ftsRows.isNotEmpty) {
        final albumIds = ftsRows.map((r) => r.read<int>('rowid')).toList();
        resultAlbums.addAll(
          await getAlbumsByIds(albumIds, downloadedArtOnly: downloadedOnly),
        );
      }
    }

    return (tracks: resultTracks, artists: resultArtists, albums: resultAlbums);
  }
}
