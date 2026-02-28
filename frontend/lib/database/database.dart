import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

class Tracks extends Table {
  TextColumn get uuidId => text()();
  TextColumn get filePath => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get lastUpdated => integer()();

  @override
  Set<Column> get primaryKey => {uuidId};
}

class Trackmetadata extends Table {
  TextColumn get uuidId => text().references(Tracks, #uuidId)();
  TextColumn get title => text().nullable()();
  TextColumn get artist => text().nullable()();
  TextColumn get album => text().nullable()();
  TextColumn get albumArtist => text().nullable()();
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
  BoolColumn get hasAlbumArt => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {uuidId};
}

// Column allowlists (mirrors backend database.py)
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

const allowedOperators = {'=', '>=', '<=', '<', '>'};

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

String aliasMap(String column) {
  return allowedMetadataColumns.contains(column) ? 'tm' : 't';
}

// Converts a Dart value to a Drift Variable. Supports String, int, double.
// Booleans are stored as integers in SQLite — pass 1/0 instead of true/false.
Variable _variableFrom(Object value) {
  if (value is String) return Variable.withString(value);
  if (value is int) return Variable.withInt(value);
  if (value is double) return Variable.withReal(value);
  throw ArgumentError('Unsupported variable type: ${value.runtimeType}');
}

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

(String, List<Variable>) artistAlbumFilterClause(String artist, String? album) {
  final artistLower = artist.toLowerCase();
  final values = <Variable>[
    Variable.withString(artistLower),
    Variable.withString(artistLower),
  ];

  final artistClause =
      '((LOWER(tm.album_artist) = ?)'
      ' OR (tm.album_artist IS NULL AND LOWER(tm.artist) = ?))';

  final String albumClause;
  if (album == null) {
    albumClause = 'tm.album IS NULL';
  } else {
    albumClause = 'tm.album = ?';
    values.add(Variable.withString(album));
  }

  return ('$artistClause AND $albumClause', values);
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const _selectColumns =
    'tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, '
    'tm.year, tm.date, tm.genre, tm.track_number, tm.disc_number, '
    'tm.codec, tm.duration, tm.bitrate_kbps, tm.sample_rate_hz, '
    'tm.channels, tm.has_album_art, t.file_path, t.created_at, t.last_updated';

@DriftDatabase(tables: [Tracks, Trackmetadata])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  (String, List<Variable>) _buildTrackQuery({
    List<SearchParameter> searchParams = const [],
    List<OrderParameter> orderBy = const [],
    List<RowFilterParameter> cursorFilters = const [],
    String? artist,
    String? album,
    int? limit,
  }) {
    if (album != null && artist == null) {
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

    // Artist/album filter
    if (artist != null) {
      final (aaClause, aaVars) = artistAlbumFilterClause(artist, album);
      whereClauses.add('($aaClause)');
      vars.addAll(aaVars);
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
    String? artist,
    String? album,
    int? limit,
  }) {
    final (sql, vars) = _buildTrackQuery(
      searchParams: searchParams,
      orderBy: orderBy,
      cursorFilters: cursorFilters,
      artist: artist,
      album: album,
      limit: limit,
    );
    return customSelect(
      sql,
      variables: vars,
      readsFrom: {trackmetadata, tracks},
    ).get();
  }

  /// Watches the count of tracks at or before [cursorFilters] position.
  /// When cursorFilters is empty, counts all matching tracks.
  Stream<int> watchTrackCount({
    List<OrderParameter> orderBy = const [],
    List<RowFilterParameter> cursorFilters = const [],
    String? artist,
    String? album,
  }) {
    if (album != null && artist == null) {
      throw ArgumentError('Cannot filter by album without artist');
    }

    final vars = <Variable>[];
    final whereClauses = <String>[];

    // Artist/album filter
    if (artist != null) {
      final (aaClause, aaVars) = artistAlbumFilterClause(artist, album);
      whereClauses.add('($aaClause)');
      vars.addAll(aaVars);
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

  // Mirrors backend: database.py get_artists()
  Future<List<String>> getArtists({int? limit, int? offset}) async {
    String query =
        ("WITH candidates(value, row_order) AS ( "
        " SELECT artist, rowid FROM trackmetadata "
        " WHERE (album_artist IS NULL OR album_artist IS '') "
        " AND (artist IS NOT NULL AND artist <> '') "
        " UNION ALL "
        " SELECT album_artist, rowid FROM trackmetadata "
        " WHERE album_artist IS NOT NULL AND album_artist <> '' "
        ") "
        "SELECT value, MIN(row_order) FROM candidates "
        "GROUP BY LOWER(value) "
        "ORDER BY LOWER(value) ASC ");

    List<Variable<Object>> vars = [];
    if (limit != null) {
      query += "LIMIT ? ";
      vars.add(Variable.withInt(limit));
      if (offset != null) {
        query += "OFFSET ? ";
        vars.add(Variable.withInt(offset));
      }
    }

    final rows = await customSelect(
      query,
      variables: vars,
      readsFrom: {trackmetadata},
    ).get();
    return rows.map((r) => r.read<String>('value')).toList();
  }

  Stream<int> watchArtistCount() {
    String sql =
        "WITH candidates(value) AS ( "
        " SELECT artist FROM trackmetadata "
        " WHERE (album_artist IS NULL OR album_artist IS '') "
        " AND (artist IS NOT NULL AND artist <> '') "
        " UNION ALL "
        " SELECT album_artist FROM trackmetadata "
        " WHERE album_artist IS NOT NULL AND album_artist <> '' "
        ") "
        "SELECT COUNT(*) AS c FROM ( "
        " SELECT value FROM candidates "
        " GROUP BY LOWER(value) "
        ") ";
    return customSelect(
      sql,
      readsFrom: {trackmetadata},
    ).watch().map((rows) => rows.first.read<int>('c'));
  }

  // Mirrors backend: database.py get_artist_albums()
  Future<List<String>> getAlbums({
    String? artist,
    int? limit,
    int? offset,
    String orderBy = "year",
  }) async {
    late final String orderClause;
    if (orderBy == "alphabetical") {
      orderClause = "ORDER BY LOWER(value) ASC ";
    } else {
      orderClause = "ORDER BY MIN(year_n) ASC ";
    }

    String query;

    List<Variable<Object>> vars = [];

    if (artist != null) {
      query =
          ("WITH candidates(value, year_n, row_order) AS ( "
          ' SELECT album, "year", rowid FROM trackmetadata '
          " WHERE artist LIKE ? "
          " AND (album IS NOT NULL AND album IS NOT '') "
          " AND (album_artist IS NULL OR album_artist IS '') "
          " UNION ALL "
          ' SELECT album, "year", rowid FROM trackmetadata '
          " WHERE album_artist LIKE ? "
          " AND (album IS NOT NULL AND album IS NOT '') "
          ") "
          "SELECT value, MIN(row_order) FROM candidates "
          "GROUP BY LOWER(value) ");
      vars.addAll([Variable.withString(artist), Variable.withString(artist)]);
    } else {
      query =
          ("WITH candidates(value, year_n, row_order) AS ( "
          ' SELECT album, "year", rowid FROM trackmetadata '
          " WHERE (album IS NOT NULL AND album IS NOT '') "
          ") "
          "SELECT value, MIN(row_order) FROM candidates "
          "GROUP BY LOWER(value) ");
    }

    query += orderClause;

    if (limit != null) {
      query += "LIMIT ? ";
      vars.add(Variable.withInt(limit));
      if (offset != null) {
        query += "OFFSET ? ";
        vars.add(Variable.withInt(offset));
      }
    }

    final rows = await customSelect(
      query,
      variables: vars,
      readsFrom: {trackmetadata},
    ).get();
    return rows.map((r) => r.read<String>('value')).toList();
  }

  Stream<int> watchAlbumsCount({String? artist}) {
    String query;
    List<Variable<Object>> vars = [];
    if (artist != null) {
      query =
          ("WITH candidates(value) AS ( "
          " SELECT album FROM trackmetadata "
          " WHERE artist LIKE ? "
          " AND (album IS NOT NULL AND album IS NOT '') "
          " AND (album_artist IS NULL OR album_artist IS '') "
          " UNION ALL "
          " SELECT album FROM trackmetadata "
          " WHERE album_artist LIKE ? "
          " AND (album IS NOT NULL AND album IS NOT '') "
          ") "
          "SELECT COUNT(*) AS c FROM ("
          " SELECT value FROM candidates"
          " GROUP BY LOWER(value)"
          ")");
      vars.addAll([Variable.withString(artist), Variable.withString(artist)]);
    } else {
      query =
          ("SELECT COUNT(*) AS c FROM ("
          " SELECT album FROM trackmetadata "
          " WHERE (album IS NOT NULL AND album IS NOT '') "
          " GROUP BY LOWER(album)"
          ")");
    }
    return customSelect(
      query,
      variables: vars,
      readsFrom: {trackmetadata},
    ).watch().map((rows) => rows.first.read<int>('c'));
  }
}

LazyDatabase openAppDatabase() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'database.db'));
    return NativeDatabase.createInBackground(file);
  });
}

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
