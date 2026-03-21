import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

// ── Table definitions ──────────────────────────────────────────────────

@TableIndex(name: 'idx_artists_name_lower', columns: {#nameLower})
class Artists extends Table {
  IntColumn get id => integer()();
  TextColumn get name => text()();
  TextColumn get nameLower =>
      text().unique().generatedAs(name.lower(), stored: true)();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_albums_name_lower', columns: {#nameLower})
@TableIndex(name: 'idx_albums_artist_id', columns: {#artistId})
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_albums_regular '
  'ON albums (name_lower, artist_id) WHERE is_single_grouping = 0',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_albums_singles '
  'ON albums (artist_id, COALESCE(year, -1)) WHERE is_single_grouping = 1',
)
class Albums extends Table {
  IntColumn get id => integer()();
  TextColumn get name => text().nullable()();
  TextColumn get nameLower =>
      text().nullable().generatedAs(name.lower(), stored: true)();
  IntColumn get artistId => integer().references(Artists, #id)();
  IntColumn get year => integer().nullable()();
  BoolColumn get isSingleGrouping =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class Tracks extends Table {
  TextColumn get uuidId => text()();
  TextColumn get filePath => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get lastUpdated => integer()();

  @override
  Set<Column> get primaryKey => {uuidId};
}

@TableIndex(name: 'idx_title', columns: {#title})
@TableIndex(name: 'idx_artist', columns: {#artist})
@TableIndex(name: 'idx_album', columns: {#album})
@TableIndex(name: 'idx_album_artist', columns: {#albumArtist})
@TableIndex(name: 'idx_tm_artist_id', columns: {#artistId})
@TableIndex(name: 'idx_tm_album_id', columns: {#albumId})
@TableIndex(name: 'idx_year', columns: {#year})
@TableIndex(name: 'idx_date', columns: {#date})
@TableIndex(name: 'idx_genre', columns: {#genre})
@TableIndex(name: 'idx_track_number', columns: {#trackNumber})
@TableIndex(name: 'idx_disc_number', columns: {#discNumber})
@TableIndex(name: 'idx_codec', columns: {#codec})
@TableIndex(name: 'idx_duration', columns: {#duration})
@TableIndex(name: 'idx_bitrate_kbps', columns: {#bitrateKbps})
@TableIndex(name: 'idx_sample_rate_hz', columns: {#sampleRateHz})
@TableIndex(name: 'idx_channels', columns: {#channels})
@TableIndex(name: 'idx_has_album_art', columns: {#hasAlbumArt})
class Trackmetadata extends Table {
  TextColumn get uuidId => text().references(Tracks, #uuidId)();
  TextColumn get title => text().nullable()();
  TextColumn get artist => text().nullable()();
  TextColumn get album => text().nullable()();
  TextColumn get albumArtist => text().nullable()();
  IntColumn get artistId => integer().nullable().references(Artists, #id)();
  IntColumn get albumId => integer().nullable().references(Albums, #id)();
  IntColumn get year => integer().nullable()();
  TextColumn get date => text().nullable()();
  TextColumn get genre => text().nullable()();
  IntColumn get trackNumber => integer().nullable()();
  IntColumn get discNumber => integer().nullable()();
  TextColumn get codec => text().nullable()();
  RealColumn get duration => real()();
  RealColumn get bitrateKbps => real()();
  IntColumn get sampleRateHz => integer()();
  IntColumn get channels => integer()();
  BoolColumn get hasAlbumArt =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {uuidId};
}

// ── Column allowlists (mirrors backend database.py) ─────────────────────

const allowedMetadataColumns = {
  'title',
  'artist',
  'album',
  'album_artist',
  'year',
  'date',
  'genre',
  'track_number',
  'disc_number',
  'codec',
  'duration',
  'bitrate_kbps',
  'sample_rate_hz',
  'channels',
  'has_album_art',
};

const allowedTrackColumns = {'uuid_id', 'created_at', 'last_updated'};

const allowedAlbumColumns = {
  'id',
  'name',
  'artist',
  'artist_id',
  'year',
  'is_single_grouping',
};
const albumTextColumns = {'name', 'artist'};
const albumIntegerColumns = {'id', 'artist_id', 'year', 'is_single_grouping'};

const allowedArtistColumns = {'id', 'name'};
const artistTextColumns = {'name'};

const allowedOperators = {'=', '>=', '<=', '<', '>'};

// ── Parameter classes ───────────────────────────────────────────────────

class SearchParameter {
  final String column;
  final String operator;
  final Object? value;

  SearchParameter({required this.column, required this.operator, this.value}) {
    if (!allowedOperators.contains(operator)) {
      throw ArgumentError('operator must be in allowedOperators');
    }
    if (!allowedMetadataColumns.contains(column) &&
        !allowedTrackColumns.contains(column)) {
      throw ArgumentError(
        'column must be in allowedMetadataColumns or allowedTrackColumns',
      );
    }
  }
}

class OrderParameter {
  final String column;
  final bool isAscending;

  OrderParameter({required this.column, this.isAscending = true}) {
    if (!allowedMetadataColumns.contains(column) &&
        !allowedTrackColumns.contains(column)) {
      throw ArgumentError(
        'column must be in allowedMetadataColumns or allowedTrackColumns',
      );
    }
  }
}

class RowFilterParameter {
  final String column;
  final Object? value;

  RowFilterParameter({required this.column, this.value}) {
    if (!allowedMetadataColumns.contains(column) &&
        !allowedTrackColumns.contains(column)) {
      throw ArgumentError(
        'column must be in allowedMetadataColumns or allowedTrackColumns',
      );
    }
  }
}

class AlbumOrderParameter {
  final String column;
  final bool isAscending;
  final bool nullsLast;

  AlbumOrderParameter({
    required this.column,
    this.isAscending = true,
    this.nullsLast = false,
  }) {
    if (!allowedAlbumColumns.contains(column)) {
      throw ArgumentError('column must be in allowedAlbumColumns');
    }
  }
}

class AlbumRowFilterParameter {
  final String column;
  final Object? value;

  AlbumRowFilterParameter({required this.column, this.value}) {
    if (!allowedAlbumColumns.contains(column)) {
      throw ArgumentError('column must be in allowedAlbumColumns');
    }
  }
}

class ArtistOrderParameter {
  final String column;
  final bool isAscending;

  ArtistOrderParameter({required this.column, this.isAscending = true}) {
    if (!allowedArtistColumns.contains(column)) {
      throw ArgumentError('column must be in allowedArtistColumns');
    }
  }
}

class ArtistRowFilterParameter {
  final String column;
  final Object? value;

  ArtistRowFilterParameter({required this.column, this.value}) {
    if (!allowedArtistColumns.contains(column)) {
      throw ArgumentError('column must be in allowedArtistColumns');
    }
  }
}

// ── Helper functions ────────────────────────────────────────────────────

String aliasMap(String column) {
  return allowedMetadataColumns.contains(column) ? 'tm' : 't';
}

Variable _variableFrom(Object value) {
  if (value is String) return Variable.withString(value);
  if (value is int) return Variable.withInt(value);
  if (value is double) return Variable.withReal(value);
  throw ArgumentError('Unsupported variable type: ${value.runtimeType}');
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ── Track cursor filter ─────────────────────────────────────────────────

(String, List<Variable>) filterForCursor(
  List<RowFilterParameter> rowFilters,
  List<OrderParameter> orderParams,
) {
  final columns = rowFilters.map((r) => r.column).toList();
  final orderColumns = orderParams.map((o) => o.column).toList();

  if (columns.length != columns.toSet().length) {
    throw ArgumentError('Filtering by row requires all unique columns');
  }
  if (!_listEquals(columns, orderColumns)) {
    throw ArgumentError(
      'row_filter_parameters columns must match order_parameters columns',
    );
  }

  final constraints = <String>[];
  final values = <Variable>[];

  for (var depth = 0; depth < rowFilters.length; depth++) {
    final equalityParts = <String>[];
    final equalityValues = <Variable>[];

    for (var i = 0; i < depth; i++) {
      final alias = aliasMap(rowFilters[i].column);
      final col = rowFilters[i].column;
      final v = rowFilters[i].value;
      if (v == null) {
        equalityParts.add('$alias."$col" IS NULL');
      } else {
        equalityParts.add('$alias."$col" = ?');
        equalityValues.add(_variableFrom(v));
      }
    }

    final alias = aliasMap(rowFilters[depth].column);
    final col = rowFilters[depth].column;
    final cursorValue = rowFilters[depth].value;

    if (cursorValue == null) {
      if (orderParams[depth].isAscending) {
        final allParts = [...equalityParts, '$alias."$col" IS NOT NULL'];
        if (allParts.length == 1) {
          constraints.add(allParts[0]);
        } else {
          constraints.add('(${allParts.join(' AND ')})');
        }
        values.addAll(equalityValues);
      }
      // DESC with null cursor: skip (nothing is less than NULL)
      continue;
    }

    final op = orderParams[depth].isAscending ? '>' : '<';
    final finalPart = '$alias."$col" $op ?';
    final allParts = [...equalityParts, finalPart];
    final allValues = [...equalityValues, _variableFrom(cursorValue)];

    if (allParts.length == 1) {
      constraints.add(allParts[0]);
    } else {
      constraints.add('(${allParts.join(' AND ')})');
    }
    values.addAll(allValues);
  }

  if (constraints.isEmpty) return ('', values);
  return (constraints.join(' OR '), values);
}

// ── Album cursor filter ─────────────────────────────────────────────────

/// Maps album column names to table-qualified SQL references.
/// The get_albums query joins `albums a` with `artists ar`, so "artist"
/// maps to `ar."name"` (the actual column, not the SELECT alias).
String _albumColRef(String col) {
  if (col == 'artist') return 'ar."name"';
  return 'a."$col"';
}

(String, List<Variable>) filterForAlbumCursor(
  List<AlbumRowFilterParameter> rowFilters,
  List<AlbumOrderParameter> orderParams,
) {
  final columns = rowFilters.map((r) => r.column).toList();
  final orderColumns = orderParams.map((o) => o.column).toList();

  if (columns.length != columns.toSet().length) {
    throw ArgumentError('Filtering by row requires all unique columns');
  }
  if (!_listEquals(columns, orderColumns)) {
    throw ArgumentError(
      'row_filter_parameters columns must match order_parameters columns',
    );
  }

  final constraints = <String>[];
  final values = <Variable>[];

  for (var depth = 0; depth < rowFilters.length; depth++) {
    final equalityParts = <String>[];
    final equalityValues = <Variable>[];

    for (var i = 0; i < depth; i++) {
      final col = rowFilters[i].column;
      final v = rowFilters[i].value;
      final colRef = _albumColRef(col);
      final collate =
          albumTextColumns.contains(col) ? ' COLLATE NOCASE' : '';
      final param =
          albumIntegerColumns.contains(col) ? 'CAST(? AS INTEGER)' : '?';
      if (v == null) {
        equalityParts.add('$colRef IS NULL');
      } else {
        equalityParts.add('$colRef$collate = $param');
        equalityValues.add(_variableFrom(v));
      }
    }

    final col = rowFilters[depth].column;
    final cursorValue = rowFilters[depth].value;
    final nullsLast = orderParams[depth].nullsLast;
    final colRef = _albumColRef(col);
    final collate =
        albumTextColumns.contains(col) ? ' COLLATE NOCASE' : '';
    final param =
        albumIntegerColumns.contains(col) ? 'CAST(? AS INTEGER)' : '?';

    if (cursorValue == null) {
      if (nullsLast) {
        // NULLs sort last: nothing comes after NULL
        continue;
      } else if (orderParams[depth].isAscending) {
        // NULLs sort first (default): any non-null comes after NULL
        final allParts = [...equalityParts, '$colRef IS NOT NULL'];
        if (allParts.length == 1) {
          constraints.add(allParts[0]);
        } else {
          constraints.add('(${allParts.join(' AND ')})');
        }
        values.addAll(equalityValues);
      }
      // DESC with null cursor: skip
      continue;
    }

    final op = orderParams[depth].isAscending ? '>' : '<';
    late final String finalPart;
    late final List<Variable> allValues;
    if (nullsLast) {
      // Non-NULL cursor with nullsLast: greater values OR NULLs come after
      finalPart = '($colRef$collate $op $param OR $colRef IS NULL)';
      allValues = [...equalityValues, _variableFrom(cursorValue)];
    } else {
      finalPart = '$colRef$collate $op $param';
      allValues = [...equalityValues, _variableFrom(cursorValue)];
    }
    final allParts = [...equalityParts, finalPart];

    if (allParts.length == 1) {
      constraints.add(allParts[0]);
    } else {
      constraints.add('(${allParts.join(' AND ')})');
    }
    values.addAll(allValues);
  }

  if (constraints.isEmpty) return ('', values);
  return (constraints.join(' OR '), values);
}

// ── Artist cursor filter ────────────────────────────────────────────────

(String, List<Variable>) filterForArtistCursor(
  List<ArtistRowFilterParameter> rowFilters,
  List<ArtistOrderParameter> orderParams,
) {
  if (rowFilters.isEmpty) return ('', <Variable>[]);

  final columns = rowFilters.map((r) => r.column).toList();
  final orderColumns = orderParams.map((o) => o.column).toList();

  if (columns.length != columns.toSet().length) {
    throw ArgumentError('Filtering by row requires all unique columns');
  }
  if (!_listEquals(columns, orderColumns)) {
    throw ArgumentError(
      'row_filter_parameters columns must match order_parameters columns',
    );
  }

  final constraints = <String>[];
  final values = <Variable>[];

  for (var depth = 0; depth < rowFilters.length; depth++) {
    final equalityParts = <String>[];
    final equalityValues = <Variable>[];

    for (var i = 0; i < depth; i++) {
      final col = rowFilters[i].column;
      final v = rowFilters[i].value;
      final collate =
          artistTextColumns.contains(col) ? ' COLLATE NOCASE' : '';
      if (v == null) {
        equalityParts.add('"$col" IS NULL');
      } else {
        equalityParts.add('"$col"$collate = ?');
        equalityValues.add(_variableFrom(v));
      }
    }

    final col = rowFilters[depth].column;
    final cursorValue = rowFilters[depth].value;
    final collate =
        artistTextColumns.contains(col) ? ' COLLATE NOCASE' : '';

    if (cursorValue == null) {
      if (orderParams[depth].isAscending) {
        final allParts = [...equalityParts, '"$col" IS NOT NULL'];
        if (allParts.length == 1) {
          constraints.add(allParts[0]);
        } else {
          constraints.add('(${allParts.join(' AND ')})');
        }
        values.addAll(equalityValues);
      }
      continue;
    }

    final op = orderParams[depth].isAscending ? '>' : '<';
    final finalPart = '"$col"$collate $op ?';
    final allParts = [...equalityParts, finalPart];
    final allValues = [...equalityValues, _variableFrom(cursorValue)];

    if (allParts.length == 1) {
      constraints.add(allParts[0]);
    } else {
      constraints.add('(${allParts.join(' AND ')})');
    }
    values.addAll(allValues);
  }

  if (constraints.isEmpty) return ('', values);
  return (constraints.join(' OR '), values);
}

// ── SELECT columns for track queries ────────────────────────────────────

const _selectColumns =
    'tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, '
    'tm.artist_id, tm.album_id, '
    'tm.year, tm.date, tm.genre, tm.track_number, tm.disc_number, '
    'tm.codec, tm.duration, tm.bitrate_kbps, tm.sample_rate_hz, '
    'tm.channels, tm.has_album_art, t.file_path, t.created_at, t.last_updated';

// ── FTS5 virtual table creation statements ──────────────────────────────

const _ftsStatements = [
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_tracks USING fts5("
      "title, artist_name, album_name, "
      "content='', content_rowid='id', tokenize='unicode61')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_artists USING fts5("
      "name, "
      "content='', content_rowid='id', tokenize='unicode61')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_albums USING fts5("
      "name, artist_name, "
      "content='', content_rowid='id', tokenize='unicode61')",
];

String prepareFtsQuery(String rawQuery) {
  final terms = rawQuery.trim().split(RegExp(r'\s+'));
  if (terms.isEmpty || (terms.length == 1 && terms[0].isEmpty)) return '';
  return terms.map((t) => '"${t.replaceAll('"', '""')}"*').join(' ');
}

// ── Database ────────────────────────────────────────────────────────────

@DriftDatabase(tables: [Artists, Albums, Tracks, Trackmetadata])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          for (final stmt in _ftsStatements) {
            await customStatement(stmt);
          }
        },
        onUpgrade: (m, from, to) async {
          // Destructive migration: drop everything and recreate.
          // The backend is the ground truth; a full re-sync repopulates.
          await customStatement('DROP TABLE IF EXISTS fts_tracks');
          await customStatement('DROP TABLE IF EXISTS fts_artists');
          await customStatement('DROP TABLE IF EXISTS fts_albums');
          await m.deleteTable('trackmetadata');
          await m.deleteTable('tracks');
          await m.deleteTable('albums');
          await m.deleteTable('artists');
          await m.createAll();
          for (final stmt in _ftsStatements) {
            await customStatement(stmt);
          }
        },
      );

  // ── Track queries ─────────────────────────────────────────────────────

  (String, List<Variable>) _buildTrackQuery({
    List<SearchParameter> searchParams = const [],
    List<OrderParameter> orderBy = const [],
    List<RowFilterParameter> cursorFilters = const [],
    int? artistId,
    int? albumId,
    int? limit,
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

    // Cursor filter
    if (cursorFilters.isNotEmpty && orderBy.isNotEmpty) {
      final (cursorClause, cursorVars) = filterForCursor(
        cursorFilters,
        orderBy,
      );
      if (cursorClause.isNotEmpty) {
        whereClauses.add('($cursorClause)');
        vars.addAll(cursorVars);
      }
    }

    var sql =
        'SELECT $_selectColumns '
        'FROM trackmetadata AS tm '
        'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id';

    if (whereClauses.isNotEmpty) {
      sql += ' WHERE ${whereClauses.join(' AND ')}';
    }

    if (orderBy.isNotEmpty) {
      final orderParts = orderBy.map((o) {
        final alias = aliasMap(o.column);
        final dir = o.isAscending ? 'ASC' : 'DESC';
        return '$alias."${o.column}" $dir';
      });
      sql += ' ORDER BY ${orderParts.join(', ')}';
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
    List<RowFilterParameter> cursorFilters = const [],
    int? artistId,
    int? albumId,
    int? limit,
  }) {
    final (sql, vars) = _buildTrackQuery(
      searchParams: searchParams,
      orderBy: orderBy,
      cursorFilters: cursorFilters,
      artistId: artistId,
      albumId: albumId,
      limit: limit,
    );
    return customSelect(
      sql,
      variables: vars,
      readsFrom: {trackmetadata, tracks},
    ).get();
  }

  Future<List<String>> getTrackUuids({
    List<OrderParameter> orderBy = const [],
    int? artistId,
    int? albumId,
  }) async {
    if (albumId != null && artistId == null) {
      throw ArgumentError('Cannot filter by album without artist');
    }

    final vars = <Variable>[];
    final whereClauses = <String>[];

    if (artistId != null) {
      whereClauses.add('tm."artist_id" = ?');
      vars.add(Variable.withInt(artistId));
    }
    if (albumId != null) {
      whereClauses.add('tm."album_id" = ?');
      vars.add(Variable.withInt(albumId));
    }

    var sql =
        'SELECT tm.uuid_id '
        'FROM trackmetadata AS tm '
        'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id';

    if (whereClauses.isNotEmpty) {
      sql += ' WHERE ${whereClauses.join(' AND ')}';
    }

    if (orderBy.isNotEmpty) {
      final orderParts = orderBy.map((o) {
        final alias = aliasMap(o.column);
        final dir = o.isAscending ? 'ASC' : 'DESC';
        return '$alias."${o.column}" $dir';
      });
      sql += ' ORDER BY ${orderParts.join(', ')}';
    }

    final rows = await customSelect(
      sql,
      variables: vars,
      readsFrom: {trackmetadata, tracks},
    ).get();
    return rows.map((r) => r.read<String>('uuid_id')).toList();
  }

  Future<List<QueryRow>> getTrackByUuid(String uuid) {
    return getTracks(
      searchParams: [
        SearchParameter(column: 'uuid_id', operator: '=', value: uuid),
      ],
      limit: 1,
    );
  }

  Future<List<QueryRow>> getTracksByUuids(List<String> uuids) {
    if (uuids.isEmpty) return Future.value([]);

    final placeholders = List.filled(uuids.length, '?').join(', ');
    final vars = uuids.map((u) => Variable.withString(u)).toList();

    final sql =
        'SELECT $_selectColumns '
        'FROM trackmetadata AS tm '
        'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id '
        'WHERE tm.uuid_id IN ($placeholders)';

    return customSelect(
      sql,
      variables: vars,
      readsFrom: {trackmetadata, tracks},
    ).get();
  }

  Stream<int> watchTrackCount({
    List<OrderParameter> orderBy = const [],
    List<RowFilterParameter> cursorFilters = const [],
    int? artistId,
    int? albumId,
  }) {
    if (albumId != null && artistId == null) {
      throw ArgumentError('Cannot filter by album without artist');
    }

    final vars = <Variable>[];
    final whereClauses = <String>[];

    if (artistId != null) {
      whereClauses.add('tm."artist_id" = ?');
      vars.add(Variable.withInt(artistId));
    }
    if (albumId != null) {
      whereClauses.add('tm."album_id" = ?');
      vars.add(Variable.withInt(albumId));
    }

    // Inverse cursor: count rows at or before the cursor position
    if (cursorFilters.isNotEmpty && orderBy.isNotEmpty) {
      final (cursorClause, cursorVars) = filterForCursor(
        cursorFilters,
        orderBy,
      );
      if (cursorClause.isNotEmpty) {
        whereClauses.add('NOT ($cursorClause)');
        vars.addAll(cursorVars);
      }
    }

    var sql =
        'SELECT COUNT(*) AS c '
        'FROM trackmetadata AS tm '
        'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id';

    if (whereClauses.isNotEmpty) {
      sql += ' WHERE ${whereClauses.join(' AND ')}';
    }

    return customSelect(
      sql,
      variables: vars,
      readsFrom: {trackmetadata, tracks},
    ).watch().map((rows) => rows.first.read<int>('c'));
  }

  // ── Artist queries ────────────────────────────────────────────────────

  Future<List<QueryRow>> getArtists({
    List<ArtistOrderParameter> orderBy = const [],
    List<ArtistRowFilterParameter> cursorFilters = const [],
    int? limit,
    int? offset,
  }) async {
    final vars = <Variable>[];

    var query = 'SELECT id, name FROM artists';

    // Cursor filter
    if (cursorFilters.isNotEmpty && orderBy.isNotEmpty) {
      final (cursorClause, cursorVars) = filterForArtistCursor(
        cursorFilters,
        orderBy,
      );
      if (cursorClause.isNotEmpty) {
        query += ' WHERE $cursorClause';
        vars.addAll(cursorVars);
      }
    }

    // ORDER BY
    if (orderBy.isNotEmpty) {
      final orderParts = <String>[];
      for (final o in orderBy) {
        final col = o.column;
        final dir = o.isAscending ? 'ASC' : 'DESC';
        final collate =
            artistTextColumns.contains(col) ? ' COLLATE NOCASE' : '';
        orderParts.add('"$col"$collate $dir');
      }
      query += ' ORDER BY ${orderParts.join(', ')}';
    } else {
      query += ' ORDER BY name COLLATE NOCASE ASC';
    }

    if (limit != null) {
      query += ' LIMIT ?';
      vars.add(Variable.withInt(limit));
      if (offset != null) {
        query += ' OFFSET ?';
        vars.add(Variable.withInt(offset));
      }
    }

    return customSelect(
      query,
      variables: vars,
      readsFrom: {artists},
    ).get();
  }

  Stream<int> watchArtistCount({
    List<ArtistOrderParameter> orderBy = const [],
    List<ArtistRowFilterParameter> cursorFilters = const [],
  }) {
    final vars = <Variable>[];

    var query = 'SELECT COUNT(*) AS c FROM artists';

    // Inverse cursor: count rows at or before cursor position
    if (cursorFilters.isNotEmpty && orderBy.isNotEmpty) {
      final (cursorClause, cursorVars) = filterForArtistCursor(
        cursorFilters,
        orderBy,
      );
      if (cursorClause.isNotEmpty) {
        query += ' WHERE NOT ($cursorClause)';
        vars.addAll(cursorVars);
      }
    }

    return customSelect(
      query,
      variables: vars,
      readsFrom: {artists},
    ).watch().map((rows) => rows.first.read<int>('c'));
  }

  // ── Album queries ─────────────────────────────────────────────────────

  (String, List<Variable>) _buildAlbumQuery({
    int? artistId,
    List<AlbumOrderParameter> orderBy = const [],
    List<AlbumRowFilterParameter> cursorFilters = const [],
    int? limit,
  }) {
    final vars = <Variable>[];

    var sql =
        'SELECT a.id, a.name, ar.name AS artist, a.artist_id, '
        'a."year", a.is_single_grouping '
        'FROM albums a '
        'JOIN artists ar ON a.artist_id = ar.id';

    final whereClauses = <String>[];

    if (artistId != null) {
      whereClauses.add('a.artist_id = ?');
      vars.add(Variable.withInt(artistId));
    }

    // Cursor filter
    if (cursorFilters.isNotEmpty && orderBy.isNotEmpty) {
      final (cursorClause, cursorVars) = filterForAlbumCursor(
        cursorFilters,
        orderBy,
      );
      if (cursorClause.isNotEmpty) {
        whereClauses.add('($cursorClause)');
        vars.addAll(cursorVars);
      }
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
        final collate =
            albumTextColumns.contains(col) ? ' COLLATE NOCASE' : '';
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
    List<AlbumRowFilterParameter> cursorFilters = const [],
    int? limit,
  }) {
    final (sql, vars) = _buildAlbumQuery(
      artistId: artistId,
      orderBy: orderBy,
      cursorFilters: cursorFilters,
      limit: limit,
    );
    return customSelect(
      sql,
      variables: vars,
      readsFrom: {albums, artists},
    ).get();
  }

  Stream<int> watchAlbumsCount({
    int? artistId,
    List<AlbumOrderParameter> orderBy = const [],
    List<AlbumRowFilterParameter> cursorFilters = const [],
  }) {
    final vars = <Variable>[];

    var sql =
        'SELECT COUNT(*) AS c FROM albums a '
        'JOIN artists ar ON a.artist_id = ar.id';

    final whereClauses = <String>[];

    if (artistId != null) {
      whereClauses.add('a.artist_id = ?');
      vars.add(Variable.withInt(artistId));
    }

    // Inverse cursor
    if (cursorFilters.isNotEmpty && orderBy.isNotEmpty) {
      final (cursorClause, cursorVars) = filterForAlbumCursor(
        cursorFilters,
        orderBy,
      );
      if (cursorClause.isNotEmpty) {
        whereClauses.add('NOT ($cursorClause)');
        vars.addAll(cursorVars);
      }
    }

    if (whereClauses.isNotEmpty) {
      sql += ' WHERE ${whereClauses.join(' AND ')}';
    }

    return customSelect(
      sql,
      variables: vars,
      readsFrom: {albums, artists},
    ).watch().map((rows) => rows.first.read<int>('c'));
  }

  Future<({List<QueryRow> tracks, List<QueryRow> artists, List<QueryRow> albums})> getSearchResults(
    String query, {
    bool searchTracks = true,
    bool searchArtists = true,
    bool searchAlbums = true,
    int limitPerType = 10,
  }) async {
    final ftsQuery = prepareFtsQuery(query);
    if (ftsQuery.isEmpty) {
      return (tracks: <QueryRow>[], artists: <QueryRow>[], albums: <QueryRow>[]);
    }

    final resultTracks = <QueryRow>[];
    final resultArtists = <QueryRow>[];
    final resultAlbums = <QueryRow>[];

    if (searchTracks) {
      final ftsRows = await customSelect(
        'SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH ? ORDER BY rank LIMIT ?',
        variables: [Variable.withString(ftsQuery), Variable.withInt(limitPerType)],
        readsFrom: {},
      ).get();
      if (ftsRows.isNotEmpty) {
        final trackIds = ftsRows.map((r) => r.read<int>('rowid')).toList();
        final placeholders = List.filled(trackIds.length, '?').join(', ');
        final vars = trackIds.map((id) => Variable.withInt(id)).toList();
        final fullRows = await customSelect(
          'SELECT $_selectColumns, tm.rowid AS _tm_rowid '
          'FROM trackmetadata AS tm '
          'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id '
          'WHERE tm.rowid IN ($placeholders)',
          variables: vars,
          readsFrom: {trackmetadata, tracks},
        ).get();
        final idOrder = {for (var i = 0; i < trackIds.length; i++) trackIds[i]: i};
        final sorted = List<QueryRow>.from(fullRows)
          ..sort((a, b) => (idOrder[a.read<int>('_tm_rowid')] ?? 999)
              .compareTo(idOrder[b.read<int>('_tm_rowid')] ?? 999));
        resultTracks.addAll(sorted);
      }
    }

    if (searchArtists) {
      final ftsRows = await customSelect(
        'SELECT rowid FROM fts_artists WHERE fts_artists MATCH ? ORDER BY rank LIMIT ?',
        variables: [Variable.withString(ftsQuery), Variable.withInt(limitPerType)],
        readsFrom: {},
      ).get();
      if (ftsRows.isNotEmpty) {
        final artistIds = ftsRows.map((r) => r.read<int>('rowid')).toList();
        final placeholders = List.filled(artistIds.length, '?').join(', ');
        final vars = artistIds.map((id) => Variable.withInt(id)).toList();
        final fullRows = await customSelect(
          'SELECT id, name FROM artists WHERE id IN ($placeholders)',
          variables: vars,
          readsFrom: {artists},
        ).get();
        final idOrder = {for (var i = 0; i < artistIds.length; i++) artistIds[i]: i};
        final sorted = List<QueryRow>.from(fullRows)
          ..sort((a, b) => (idOrder[a.read<int>('id')] ?? 999)
              .compareTo(idOrder[b.read<int>('id')] ?? 999));
        resultArtists.addAll(sorted);
      }
    }

    if (searchAlbums) {
      final ftsRows = await customSelect(
        'SELECT rowid FROM fts_albums WHERE fts_albums MATCH ? ORDER BY rank LIMIT ?',
        variables: [Variable.withString(ftsQuery), Variable.withInt(limitPerType)],
        readsFrom: {},
      ).get();
      if (ftsRows.isNotEmpty) {
        final albumIds = ftsRows.map((r) => r.read<int>('rowid')).toList();
        final placeholders = List.filled(albumIds.length, '?').join(', ');
        final vars = albumIds.map((id) => Variable.withInt(id)).toList();
        final fullRows = await customSelect(
          'SELECT a.id, a.name, ar.name AS artist, a.artist_id, '
          'a."year", a.is_single_grouping '
          'FROM albums a '
          'JOIN artists ar ON a.artist_id = ar.id '
          'WHERE a.id IN ($placeholders)',
          variables: vars,
          readsFrom: {albums, artists},
        ).get();
        final idOrder = {for (var i = 0; i < albumIds.length; i++) albumIds[i]: i};
        final sorted = List<QueryRow>.from(fullRows)
          ..sort((a, b) => (idOrder[a.read<int>('id')] ?? 999)
              .compareTo(idOrder[b.read<int>('id')] ?? 999));
        resultAlbums.addAll(sorted);
      }
    }

    return (tracks: resultTracks, artists: resultArtists, albums: resultAlbums);
  }
}

// ── Database factory ────────────────────────────────────────────────────

LazyDatabase openAppDatabase() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'database.db'));
    return NativeDatabase.createInBackground(file);
  });
}

// ── DTO → Companion converters ──────────────────────────────────────────

TracksCompanion tracksCompanionFromDto(ClientTrackDto dto) {
  return TracksCompanion(
    uuidId: Value(dto.uuidId),
    createdAt: Value(dto.createdAt),
    lastUpdated: Value(dto.lastUpdated),
    filePath: Value.absent(),
  );
}

TrackmetadataCompanion trackmetadataCompanionFromDto(ClientTrackDto dto) {
  final meta = dto.metadata;
  return TrackmetadataCompanion(
    uuidId: Value(dto.uuidId),
    title: Value(meta.title),
    artist: Value(meta.artist),
    album: Value(meta.album),
    albumArtist: Value(meta.albumArtist),
    artistId: Value(meta.artistId),
    albumId: Value(meta.albumId),
    year: Value(meta.year),
    date: Value(meta.date),
    genre: Value(meta.genre),
    trackNumber: Value(meta.trackNumber),
    discNumber: Value(meta.discNumber),
    codec: Value(meta.codec),
    duration: Value(meta.duration),
    bitrateKbps: Value(meta.bitrateKbps),
    sampleRateHz: Value(meta.sampleRateHz),
    channels: Value(meta.channels),
    hasAlbumArt: Value(meta.hasAlbumArt),
  );
}
