import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/editable_fields.dart';
import 'package:frontend/services/local_resettable.dart';
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
  // Monotonic per-track revision from the server, written on every `/changes`
  // upsert. The conflict-detection base for edits (Option A). Nullable only
  // for migration: rows that predate this column read NULL = "unknown base"
  // until their next upsert. The server never sends null.
  IntColumn get revision => integer().nullable()();
  // Bitrate of the file actually stored on disk. Null until a download
  // completes. May differ from trackmetadata.bitrate_kbps when downloaded at
  // a lower quality than the server source (e.g. 128 kbps download from a
  // 320 kbps source) or when bitrate passthrough serves the original.
  IntColumn get downloadedBitrateKbps => integer().nullable()();
  IntColumn get fileSizeBytes => integer().nullable()();
  // The quality preset the user/server selected for this download (e.g.
  // 'original', '320'). Independent of `downloadedBitrateKbps`, which is the
  // bitrate actually written to disk. Storing both lets us answer
  // "is the file at the requested quality?" idempotently even when the
  // backend served a passthrough that didn't match the requested bitrate.
  TextColumn get downloadedQuality => text().nullable()();

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
// NOCASE companion to idx_genre (which is BINARY) so the autocomplete prefix
// scan `genre LIKE ?` stays index-backed and case-insensitive.
@TableIndex.sql(
  'CREATE INDEX idx_genre_nocase ON trackmetadata (genre COLLATE NOCASE)',
)
@TableIndex(name: 'idx_track_number', columns: {#trackNumber})
@TableIndex(name: 'idx_disc_number', columns: {#discNumber})
@TableIndex(name: 'idx_codec', columns: {#codec})
@TableIndex(name: 'idx_duration', columns: {#duration})
@TableIndex(name: 'idx_bitrate_kbps', columns: {#bitrateKbps})
@TableIndex(name: 'idx_sample_rate_hz', columns: {#sampleRateHz})
@TableIndex(name: 'idx_channels', columns: {#channels})
@TableIndex(name: 'idx_has_album_art', columns: {#hasAlbumArt})
@TableIndex.sql(
  'CREATE INDEX idx_tm_library_queue_order '
  'ON trackmetadata (artist, album, disc_number, track_number, uuid_id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_tm_artist_queue_order '
  'ON trackmetadata (artist_id, album, disc_number, track_number, uuid_id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_tm_album_queue_order '
  'ON trackmetadata (artist_id, album_id, disc_number, track_number, uuid_id)',
)
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
  BoolColumn get hasAlbumArt => boolean().withDefault(const Constant(false))();
  IntColumn get coverArtId => integer().nullable()();

  @override
  Set<Column> get primaryKey => {uuidId};
}

class QueueSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  TextColumn get sourceType => text()(); // library|artist|album|search|single
  IntColumn get sourceArtistId => integer().nullable()();
  IntColumn get sourceAlbumId => integer().nullable()();
  IntColumn get currentItemId => integer().nullable()();
  IntColumn get resumeMainItemId => integer().nullable()();
  IntColumn get currentPositionMs => integer().withDefault(const Constant(0))();
  TextColumn get repeatMode => text().withDefault(const Constant('off'))();
  BoolColumn get shuffleEnabled =>
      boolean().withDefault(const Constant(false))();
}

@TableIndex(
  name: 'idx_queue_session_items_session_position',
  columns: {#sessionId, #queueType, #position},
)
@TableIndex(
  name: 'idx_queue_session_items_session_uuid',
  columns: {#sessionId, #uuidId},
)
class QueueSessionItems extends Table {
  IntColumn get itemId => integer().autoIncrement()();
  IntColumn get sessionId =>
      integer().references(QueueSessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get queueType => text().withDefault(const Constant('main'))();
  IntColumn get position => integer()();
  TextColumn get uuidId => text().references(Tracks, #uuidId)();

  @override
  List<String> get customConstraints => const [
    'UNIQUE(session_id, queue_type, position)',
  ];
}

@TableIndex(
  name: 'idx_queue_session_play_order_session_position',
  columns: {#sessionId, #playPosition},
)
@TableIndex(
  name: 'idx_queue_session_play_order_session_item',
  columns: {#sessionId, #itemId},
)
class QueueSessionPlayOrder extends Table {
  IntColumn get sessionId =>
      integer().references(QueueSessions, #id, onDelete: KeyAction.cascade)();
  IntColumn get playPosition => integer()();
  IntColumn get itemId => integer().references(
    QueueSessionItems,
    #itemId,
    onDelete: KeyAction.cascade,
  )();

  @override
  Set<Column> get primaryKey => {sessionId, playPosition};

  @override
  List<String> get customConstraints => const ['UNIQUE(session_id, item_id)'];
}

/// Outbox of unflushed track metadata edits, one coalesced row per track.
class PendingEdits extends Table {
  TextColumn get uuidId => text()();

  /// The coalesced value-map as JSON: keys present = touched, a `null` value =
  /// an explicit clear (so "cleared" is distinct from "untouched").
  TextColumn get valuesJson => text()();

  /// `db_only` or `db_and_master` — monotonically escalates, never downgrades.
  TextColumn get writeMode => text()();

  /// The track revision captured at the first edit of this batch (Option A
  /// base). Nullable = "unknown base" → forces the conflict path on flush.
  IntColumn get baseRevision => integer().nullable()();

  /// `pending` (awaiting flush), `conflicted` (server returned 409), or
  /// `take_server` (resolution chosen; the authoritative single-track refetch
  /// hasn't succeeded yet — retried after each sync).
  TextColumn get status => text().withDefault(const Constant('pending'))();

  /// The server's current revision, recorded on a 409 so a "keep mine"
  /// resolution can rebase onto it.
  IntColumn get serverRevision => integer().nullable()();

  /// Snapshot of the track's editable columns captured at the first edit of the
  /// batch (JSON). Lets "take server"/discard revert the optimistic local write
  /// without a network round-trip.
  TextColumn get originalValuesJson => text().nullable()();

  /// Short human-readable reason recorded when a flush is permanently rejected
  /// (422 / track gone), surfaced in the pending-edits banner until dismissed.
  TextColumn get rejectionReason => text().nullable()();

  IntColumn get updatedAt => integer()();

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
  'cover_art_id',
};

const allowedTrackColumns = {'uuid_id', 'created_at', 'last_updated'};

// The editable-column set lives in models/editable_fields.dart, derived from
// the same descriptor list that drives the offline default form schema.

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
      final collate = albumTextColumns.contains(col) ? ' COLLATE NOCASE' : '';
      final param = albumIntegerColumns.contains(col)
          ? 'CAST(? AS INTEGER)'
          : '?';
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
    final collate = albumTextColumns.contains(col) ? ' COLLATE NOCASE' : '';
    final param = albumIntegerColumns.contains(col)
        ? 'CAST(? AS INTEGER)'
        : '?';

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
      final collate = artistTextColumns.contains(col) ? ' COLLATE NOCASE' : '';
      if (v == null) {
        equalityParts.add('"$col" IS NULL');
      } else {
        equalityParts.add('"$col"$collate = ?');
        equalityValues.add(_variableFrom(v));
      }
    }

    final col = rowFilters[depth].column;
    final cursorValue = rowFilters[depth].value;
    final collate = artistTextColumns.contains(col) ? ' COLLATE NOCASE' : '';

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

const trackSelectColumns =
    'tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, '
    'tm.artist_id, tm.album_id, '
    'tm.year, tm.date, tm.genre, tm.track_number, tm.disc_number, '
    'tm.codec, tm.duration, tm.bitrate_kbps, tm.sample_rate_hz, '
    'tm.channels, tm.has_album_art, tm.cover_art_id, t.file_path, t.created_at, t.last_updated, '
    't.revision, '
    't.downloaded_bitrate_kbps, t.file_size_bytes, t.downloaded_quality';
const _selectColumns = trackSelectColumns;

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

String _quoteSqlIdentifier(String identifier) {
  return '"${identifier.replaceAll('"', '""')}"';
}

// ── Database ────────────────────────────────────────────────────────────

@DriftDatabase(
  tables: [
    Artists,
    Albums,
    Tracks,
    Trackmetadata,
    QueueSessions,
    QueueSessionItems,
    QueueSessionPlayOrder,
    PendingEdits,
  ],
)
class AppDatabase extends _$AppDatabase implements LocalResettable {
  AppDatabase(super.e);

  /// Schema history was reset during beta: the current table definitions ARE
  /// version 1 and there is no upgrade path from the pre-reset versions (an
  /// old-beta database must go through the local-reset flow once).
  ///
  /// Ground rules for the first post-reset migration (learned the hard way —
  /// an unguarded ALTER once bricked every upgrading install):
  ///
  ///  1. `m.createTable(...)` always emits the table's CURRENT Dart shape.
  ///     A column ALTER for a table introduced in version N must therefore be
  ///     guarded `from >= N`, or upgraders that just created the table will
  ///     crash on "duplicate column name".
  ///  2. Every schema bump ships with a test that opens a real previous-version
  ///     database file and runs the actual `onUpgrade` — never a hand-replayed
  ///     statement list, which is exactly what masked the bug above.
  ///  3. Once the schema stabilizes, adopt drift's exported-schema tooling
  ///     (`drift_dev schema` + step-by-step migrations) so upgrades are
  ///     generated against frozen snapshots instead of hand-written.
  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      for (final stmt in _ftsStatements) {
        await customStatement(stmt);
      }
    },
  );

  Future<void> resetLocalData() async {
    await transaction(() async {
      final ftsTables = await customSelect(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' "
        "AND sql LIKE 'CREATE VIRTUAL TABLE%USING fts5%'",
        readsFrom: {},
      ).get();
      for (final row in ftsTables) {
        final name = row.read<String>('name');
        final quoted = _quoteSqlIdentifier(name);
        await customStatement(
          "INSERT INTO $quoted($quoted) VALUES('delete-all')",
        );
      }

      for (final table in allTables.toList().reversed) {
        await customStatement(
          'DELETE FROM ${_quoteSqlIdentifier(table.actualTableName)}',
        );
      }

      try {
        await customStatement('DELETE FROM sqlite_sequence');
      } catch (_) {}
    });
  }

  Future<void> rebuildFtsIndexes() async {
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

    await customStatement(
      "INSERT INTO fts_tracks(fts_tracks) VALUES('delete-all')",
    );
    await customStatement(
      "INSERT INTO fts_tracks(rowid, title, artist_name, album_name) "
      "SELECT rowid, COALESCE(title, ''), COALESCE(artist, ''), COALESCE(album, '') "
      "FROM trackmetadata",
    );
  }

  // --- LocalResettable -------------------------------------------------------
  @override
  int get resetPriority => ResetPriority.wipeDatabase;

  @override
  Future<void> resetLocalState() => resetLocalData();

  // ── Metadata autocomplete ─────────────────────────────────────────────
  //
  // Case-insensitive prefix suggestions drawn from the synced library, for the
  // Get Info form. Artist / album reuse the entities' `name_lower` indexes;
  // genre has no entity table so it rides the NOCASE `idx_genre_nocase`.

  /// Suggestions for the `artist` and `album_artist` fields.
  Future<List<String>> artistSuggestions(String prefix, {int limit = 8}) {
    return _prefixSuggestions(
      "SELECT name FROM artists WHERE name_lower LIKE ? ESCAPE '\\' "
      'ORDER BY name LIMIT ?',
      column: 'name',
      pattern: '${_escapeLike(prefix.trim().toLowerCase())}%',
      rawPrefix: prefix,
      limit: limit,
      reads: {artists},
    );
  }

  /// Suggestions for the `album` field.
  Future<List<String>> albumSuggestions(String prefix, {int limit = 8}) {
    return _prefixSuggestions(
      'SELECT DISTINCT name FROM albums '
      "WHERE name IS NOT NULL AND name_lower LIKE ? ESCAPE '\\' "
      'ORDER BY name LIMIT ?',
      column: 'name',
      pattern: '${_escapeLike(prefix.trim().toLowerCase())}%',
      rawPrefix: prefix,
      limit: limit,
      reads: {albums},
    );
  }

  /// Suggestions for the `genre` field.
  Future<List<String>> genreSuggestions(String prefix, {int limit = 8}) {
    return _prefixSuggestions(
      'SELECT DISTINCT genre FROM trackmetadata '
      "WHERE genre IS NOT NULL AND genre LIKE ? ESCAPE '\\' "
      'ORDER BY genre LIMIT ?',
      column: 'genre',
      pattern: '${_escapeLike(prefix.trim())}%',
      rawPrefix: prefix,
      limit: limit,
      reads: {trackmetadata},
    );
  }

  Future<List<String>> _prefixSuggestions(
    String sql, {
    required String column,
    required String pattern,
    required String rawPrefix,
    required int limit,
    required Set<ResultSetImplementation<dynamic, dynamic>> reads,
  }) async {
    if (rawPrefix.trim().isEmpty) return const [];
    final rows = await customSelect(
      sql,
      variables: [Variable.withString(pattern), Variable.withInt(limit)],
      readsFrom: reads,
    ).get();
    return rows.map((r) => r.read<String>(column)).toList();
  }

  /// Escapes the LIKE metacharacters in user input so a typed `%` or `_` is a
  /// literal, not a wildcard (paired with `ESCAPE '\'` in the queries).
  static String _escapeLike(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  // ── Optimistic edit write (outbox) ────────────────────────────────────

  /// Applies the touched fields of a pending edit to the local denormalized
  /// `trackmetadata` text + a targeted single-row FTS update, so the edit shows
  /// immediately. Deliberately does NOT repoint `artist_id`/`album_id` (that is
  /// the server helper's job) — so after an artist rename the tile shows the new
  /// text but the track stays under the old artist node until flush+sync.
  Future<void> applyOptimisticTrackEdit(
    String uuidId,
    Map<String, Object?> values,
  ) async {
    final cols = values.keys.where(editableMetadataColumns.contains).toList();
    if (cols.isEmpty) return;

    await transaction(() async {
      final before = await customSelect(
        'SELECT rowid AS rid, title, artist, album '
        'FROM trackmetadata WHERE uuid_id = ?',
        variables: [Variable.withString(uuidId)],
        readsFrom: {trackmetadata},
      ).getSingleOrNull();
      if (before == null) return;

      final rowid = before.read<int>('rid');
      final oldTitle = before.readNullable<String>('title') ?? '';
      final oldArtist = before.readNullable<String>('artist') ?? '';
      final oldAlbum = before.readNullable<String>('album') ?? '';

      final setSql = cols.map((c) => '"$c" = ?').join(', ');
      // customUpdate (not customStatement) so drift notifies `trackmetadata`
      // stream watchers — the reactive browse lists must re-render on the edit.
      await customUpdate(
        'UPDATE trackmetadata SET $setSql WHERE uuid_id = ?',
        variables: [
          ...cols.map((c) => Variable(values[c])),
          Variable.withString(uuidId),
        ],
        updates: {trackmetadata},
        updateKind: UpdateKind.update,
      );

      final after = await customSelect(
        'SELECT title, artist, album FROM trackmetadata WHERE uuid_id = ?',
        variables: [Variable.withString(uuidId)],
        readsFrom: {trackmetadata},
      ).getSingle();
      final newTitle = after.readNullable<String>('title') ?? '';
      final newArtist = after.readNullable<String>('artist') ?? '';
      final newAlbum = after.readNullable<String>('album') ?? '';

      // Contentless FTS: delete the old terms by rowid, insert the new ones —
      // mirrors `rebuildFtsIndexes` (artist_name = the denormalized `artist`).
      await customStatement(
        "INSERT INTO fts_tracks(fts_tracks, rowid, title, artist_name, album_name) "
        "VALUES('delete', ?, ?, ?, ?)",
        [rowid, oldTitle, oldArtist, oldAlbum],
      );
      await customStatement(
        'INSERT INTO fts_tracks(rowid, title, artist_name, album_name) '
        'VALUES(?, ?, ?, ?)',
        [rowid, newTitle, newArtist, newAlbum],
      );
    });
  }

  /// Record the server revision a successful edit produced, so the next edit's
  /// `base_revision` builds on it instead of the stale pre-flush value (which
  /// would 409 against this client's own prior edit). Only ever raised, never
  /// lowered, so a concurrently-synced higher revision is not regressed.
  Future<void> updateTrackRevision(String uuidId, int revision) async {
    await customUpdate(
      'UPDATE tracks SET revision = ? '
      'WHERE uuid_id = ? AND (revision IS NULL OR revision < ?)',
      variables: [
        Variable.withInt(revision),
        Variable.withString(uuidId),
        Variable.withInt(revision),
      ],
      updates: {tracks},
      updateKind: UpdateKind.update,
    );
  }

  /// Snapshot of a track's editable column values (the pre-edit state), used to
  /// revert an optimistic edit locally on take-server/discard. Returns an empty
  /// map if the track row is missing.
  Future<Map<String, Object?>> readEditableColumns(String uuidId) async {
    final cols = editableMetadataColumns.toList();
    final select = cols.map((c) => '"$c"').join(', ');
    final row = await customSelect(
      'SELECT $select FROM trackmetadata WHERE uuid_id = ?',
      variables: [Variable.withString(uuidId)],
      readsFrom: {trackmetadata},
    ).getSingleOrNull();
    if (row == null) return {};
    return {for (final c in cols) c: row.data[c]};
  }

  /// The queued write mode (`db_only`/`db_and_master`) for a track's pending
  /// edit, or null if none is queued. Lets Get Info reflect a queued master
  /// write when it reopens.
  Future<String?> pendingWriteMode(String uuidId) async {
    final row = await (select(pendingEdits)
          ..where((t) => t.uuidId.equals(uuidId)))
        .getSingleOrNull();
    return row?.writeMode;
  }

  /// Live counts of outstanding edits for the pending-edits surface.
  Stream<({int pending, int conflicted, int rejected})>
      watchPendingEditCounts() {
    return customSelect(
      "SELECT "
      "SUM(CASE WHEN status = 'conflicted' THEN 1 ELSE 0 END) AS conflicted, "
      "SUM(CASE WHEN status = 'rejected' THEN 1 ELSE 0 END) AS rejected, "
      "COUNT(*) AS total FROM pending_edits",
      readsFrom: {pendingEdits},
    ).watch().map((rows) {
      final row = rows.first;
      final conflicted = row.readNullable<int>('conflicted') ?? 0;
      final rejected = row.readNullable<int>('rejected') ?? 0;
      final total = row.read<int>('total');
      return (
        pending: total - conflicted - rejected,
        conflicted: conflicted,
        rejected: rejected,
      );
    });
  }

  // ── Track queries ─────────────────────────────────────────────────────

  (String, List<Variable>) _buildTrackQuery({
    List<SearchParameter> searchParams = const [],
    List<OrderParameter> orderBy = const [],
    List<RowFilterParameter> cursorFilters = const [],
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
      whereClauses.add('t.file_path IS NOT NULL');
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
    bool downloadedOnly = false,
  }) {
    final (sql, vars) = _buildTrackQuery(
      searchParams: searchParams,
      orderBy: orderBy,
      cursorFilters: cursorFilters,
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

  (String, List<Variable>) buildTrackUuidQuery({
    List<OrderParameter> orderBy = const [],
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

    return (sql, vars);
  }

  Future<List<String>> getTrackUuids({
    List<OrderParameter> orderBy = const [],
    int? artistId,
    int? albumId,
  }) async {
    final (sql, vars) = buildTrackUuidQuery(
      orderBy: orderBy,
      artistId: artistId,
      albumId: albumId,
    );

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

  Stream<int> watchTrackCount({
    List<OrderParameter> orderBy = const [],
    List<RowFilterParameter> cursorFilters = const [],
    int? artistId,
    int? albumId,
    bool downloadedOnly = false,
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

    if (downloadedOnly) {
      whereClauses.add('t.file_path IS NOT NULL');
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

  Future<
    Map<
      String,
      ({
        String? filePath,
        int? downloadedBitrateKbps,
        int? fileSizeBytes,
        String? downloadedQuality,
      })
    >
  >
  getTrackDownloadStates(List<String> uuids) async {
    if (uuids.isEmpty) return {};
    final placeholders = List.filled(uuids.length, '?').join(', ');
    final rows = await customSelect(
      'SELECT uuid_id, file_path, downloaded_bitrate_kbps, file_size_bytes, '
      'downloaded_quality '
      'FROM tracks WHERE uuid_id IN ($placeholders)',
      variables: uuids.map(Variable.withString).toList(),
      readsFrom: {tracks},
    ).get();
    return {
      for (final r in rows)
        r.read<String>('uuid_id'): (
          filePath: r.readNullable<String>('file_path'),
          downloadedBitrateKbps: r.readNullable<int>('downloaded_bitrate_kbps'),
          fileSizeBytes: r.readNullable<int>('file_size_bytes'),
          downloadedQuality: r.readNullable<String>('downloaded_quality'),
        ),
    };
  }

  Stream<({int count, int totalBytes})> watchDownloadedStats() {
    return customSelect(
      'SELECT COUNT(*) AS c, COALESCE(SUM(file_size_bytes), 0) AS total_bytes '
      'FROM tracks WHERE file_path IS NOT NULL',
      readsFrom: {tracks},
    ).watch().map(
      (rows) => (
        count: rows.first.read<int>('c'),
        totalBytes: rows.first.read<int>('total_bytes'),
      ),
    );
  }

  // ── Artist queries ────────────────────────────────────────────────────

  Future<List<QueryRow>> getArtists({
    List<ArtistOrderParameter> orderBy = const [],
    List<ArtistRowFilterParameter> cursorFilters = const [],
    int? limit,
    int? offset,
    bool downloadedOnly = false,
  }) {
    final (sql, vars) = _buildArtistQuery(
      orderBy: orderBy,
      cursorFilters: cursorFilters,
      limit: limit,
      offset: offset,
      downloadedOnly: downloadedOnly,
    );
    return customSelect(
      sql,
      variables: vars,
      readsFrom: {artists, trackmetadata, tracks},
    ).get();
  }

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
    List<ArtistRowFilterParameter> cursorFilters = const [],
    int? limit,
    int? offset,
    bool downloadedOnly = false,
  }) {
    final vars = <Variable>[];

    // When offline, the cover-art subquery must restrict candidate tracks to
    // downloaded ones; otherwise the chosen `cover_art_id` may belong to a
    // streaming-only track and resolving it requires a network round trip.
    final coverArtSubquery = downloadedOnly
        ? 'SELECT tm.cover_art_id FROM trackmetadata tm '
            'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id '
            'WHERE tm.artist_id = artists.id '
            'AND tm.has_album_art = 1 '
            'AND tm.cover_art_id IS NOT NULL '
            'AND t.file_path IS NOT NULL '
            'ORDER BY tm.track_number ASC, tm.uuid_id ASC '
            'LIMIT 1'
        : 'SELECT tm.cover_art_id FROM trackmetadata tm '
            'WHERE tm.artist_id = artists.id '
            'AND tm.has_album_art = 1 '
            'AND tm.cover_art_id IS NOT NULL '
            'ORDER BY tm.track_number ASC, tm.uuid_id ASC '
            'LIMIT 1';

    var query =
        'SELECT id, name, '
        '($coverArtSubquery) AS cover_art_id '
        'FROM artists';

    final whereClauses = <String>[];

    if (downloadedOnly) {
      // Artist appears iff at least one of their tracks is downloaded. EXISTS
      // short-circuits on first hit, so this is cheaper than a COUNT.
      whereClauses.add(
        'EXISTS (SELECT 1 FROM trackmetadata tm '
        'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id '
        'WHERE tm.artist_id = artists.id AND t.file_path IS NOT NULL)',
      );
    }

    // Cursor filter
    if (cursorFilters.isNotEmpty && orderBy.isNotEmpty) {
      final (cursorClause, cursorVars) = filterForArtistCursor(
        cursorFilters,
        orderBy,
      );
      if (cursorClause.isNotEmpty) {
        whereClauses.add(cursorClause);
        vars.addAll(cursorVars);
      }
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
      if (offset != null) {
        query += ' OFFSET ?';
        vars.add(Variable.withInt(offset));
      }
    }

    return (query, vars);
  }

  Stream<int> watchArtistCount({
    List<ArtistOrderParameter> orderBy = const [],
    List<ArtistRowFilterParameter> cursorFilters = const [],
    bool downloadedOnly = false,
  }) {
    final vars = <Variable>[];

    var query = 'SELECT COUNT(*) AS c FROM artists';

    final whereClauses = <String>[];

    if (downloadedOnly) {
      whereClauses.add(
        'EXISTS (SELECT 1 FROM trackmetadata tm '
        'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id '
        'WHERE tm.artist_id = artists.id AND t.file_path IS NOT NULL)',
      );
    }

    // Inverse cursor: count rows at or before cursor position
    if (cursorFilters.isNotEmpty && orderBy.isNotEmpty) {
      final (cursorClause, cursorVars) = filterForArtistCursor(
        cursorFilters,
        orderBy,
      );
      if (cursorClause.isNotEmpty) {
        whereClauses.add('NOT ($cursorClause)');
        vars.addAll(cursorVars);
      }
    }

    if (whereClauses.isNotEmpty) {
      query += ' WHERE ${whereClauses.join(' AND ')}';
    }

    return customSelect(
      query,
      variables: vars,
      readsFrom: {artists, trackmetadata, tracks},
    ).watch().map((rows) => rows.first.read<int>('c'));
  }

  // ── Download status aggregates ────────────────────────────────────────

  /// For each album id, returns `(total, downloaded)` track counts. An album
  /// is "fully downloaded" iff `downloaded == total && total > 0`.
  Future<Map<int, ({int total, int downloaded})>> getAlbumDownloadCounts(
    Iterable<int> albumIds,
  ) => _downloadCountsByColumn('album_id', albumIds);

  /// Same as [getAlbumDownloadCounts] but per artist. Used by ArtistCard to
  /// show a "downloaded" badge when ALL of the artist's tracks are downloaded.
  Future<Map<int, ({int total, int downloaded})>> getArtistDownloadCounts(
    Iterable<int> artistIds,
  ) => _downloadCountsByColumn('artist_id', artistIds);

  /// Download counts for every album in one grouped query. Lets the UI batch
  /// all visible album cards into a single read instead of one query per card.
  Future<Map<int, ({int total, int downloaded})>> getAllAlbumDownloadCounts() =>
      _downloadCountsByColumn('album_id', null);

  /// Download counts for every artist in one grouped query.
  Future<Map<int, ({int total, int downloaded})>>
      getAllArtistDownloadCounts() =>
          _downloadCountsByColumn('artist_id', null);

  /// Grouped (total, downloaded) track counts by [groupColumn]. When [ids] is
  /// null, counts every (non-null) group; otherwise restricts to [ids].
  /// [groupColumn] is a hardcoded internal literal ('album_id'/'artist_id') —
  /// never user input — so interpolating it is safe.
  Future<Map<int, ({int total, int downloaded})>> _downloadCountsByColumn(
    String groupColumn,
    Iterable<int>? ids,
  ) async {
    final String whereClause;
    final List<Variable> variables;
    if (ids == null) {
      whereClause = 'WHERE tm.$groupColumn IS NOT NULL ';
      variables = const [];
    } else {
      final list = ids.toSet().toList(growable: false);
      if (list.isEmpty) return const {};
      final placeholders = List.filled(list.length, '?').join(', ');
      whereClause = 'WHERE tm.$groupColumn IN ($placeholders) ';
      variables = list.map(Variable.withInt).toList();
    }
    final rows = await customSelect(
      'SELECT tm.$groupColumn AS aid, COUNT(*) AS total, '
      'SUM(CASE WHEN t.file_path IS NOT NULL THEN 1 ELSE 0 END) AS downloaded '
      'FROM trackmetadata tm '
      'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id '
      '$whereClause'
      'GROUP BY tm.$groupColumn',
      variables: variables,
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

  // ── Album queries ─────────────────────────────────────────────────────

  (String, List<Variable>) _buildAlbumQuery({
    int? artistId,
    List<AlbumOrderParameter> orderBy = const [],
    List<AlbumRowFilterParameter> cursorFilters = const [],
    int? limit,
    bool downloadedOnly = false,
  }) {
    final vars = <Variable>[];

    // See [getArtists] — when offline, restrict the cover-art subquery to
    // tracks that are downloaded so the chosen `cover_art_id` resolves
    // locally instead of triggering a streaming fallback.
    final coverArtSubquery = downloadedOnly
        ? 'SELECT tm.cover_art_id FROM trackmetadata tm '
            'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id '
            'WHERE tm.album_id = a.id '
            'AND tm.has_album_art = 1 '
            'AND tm.cover_art_id IS NOT NULL '
            'AND t.file_path IS NOT NULL '
            'ORDER BY tm.track_number ASC, tm.uuid_id ASC '
            'LIMIT 1'
        : 'SELECT tm.cover_art_id FROM trackmetadata tm '
            'WHERE tm.album_id = a.id '
            'AND tm.has_album_art = 1 '
            'AND tm.cover_art_id IS NOT NULL '
            'ORDER BY tm.track_number ASC, tm.uuid_id ASC '
            'LIMIT 1';

    var sql =
        'SELECT a.id, a.name, ar.name AS artist, a.artist_id, '
        'a."year", a.is_single_grouping, '
        '($coverArtSubquery) AS cover_art_id '
        'FROM albums a '
        'JOIN artists ar ON a.artist_id = ar.id';

    final whereClauses = <String>[];

    if (artistId != null) {
      whereClauses.add('a.artist_id = ?');
      vars.add(Variable.withInt(artistId));
    }

    if (downloadedOnly) {
      whereClauses.add(
        'EXISTS (SELECT 1 FROM trackmetadata tm '
        'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id '
        'WHERE tm.album_id = a.id AND t.file_path IS NOT NULL)',
      );
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
    List<AlbumRowFilterParameter> cursorFilters = const [],
    int? limit,
    bool downloadedOnly = false,
  }) {
    final (sql, vars) = _buildAlbumQuery(
      artistId: artistId,
      orderBy: orderBy,
      cursorFilters: cursorFilters,
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

  Stream<int> watchAlbumsCount({
    int? artistId,
    List<AlbumOrderParameter> orderBy = const [],
    List<AlbumRowFilterParameter> cursorFilters = const [],
    bool downloadedOnly = false,
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

    if (downloadedOnly) {
      whereClauses.add(
        'EXISTS (SELECT 1 FROM trackmetadata tm '
        'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id '
        'WHERE tm.album_id = a.id AND t.file_path IS NOT NULL)',
      );
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
      readsFrom: {albums, artists, trackmetadata, tracks},
    ).watch().map((rows) => rows.first.read<int>('c'));
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
        ? ' AND EXISTS (SELECT 1 FROM trackmetadata tm '
              'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id '
              'WHERE tm.rowid = fts_tracks.rowid AND t.file_path IS NOT NULL)'
        : '';
    final artistDownloadedFilter = downloadedOnly
        ? ' AND EXISTS (SELECT 1 FROM trackmetadata tm '
              'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id '
              'WHERE tm.artist_id = fts_artists.rowid AND t.file_path IS NOT NULL)'
        : '';
    final albumDownloadedFilter = downloadedOnly
        ? ' AND EXISTS (SELECT 1 FROM trackmetadata tm '
              'INNER JOIN tracks t ON tm.uuid_id = t.uuid_id '
              'WHERE tm.album_id = fts_albums.rowid AND t.file_path IS NOT NULL)'
        : '';

    if (searchTracks) {
      final ftsRows = await customSelect(
        'SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH ?'
        '$trackDownloadedFilter ORDER BY rank LIMIT ?',
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
          'SELECT $_selectColumns, tm.rowid AS _tm_rowid '
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
        '$artistDownloadedFilter ORDER BY rank LIMIT ?',
        variables: [
          Variable.withString(ftsQuery),
          Variable.withInt(limitPerType),
        ],
        readsFrom: {},
      ).get();
      if (ftsRows.isNotEmpty) {
        final artistIds = ftsRows.map((r) => r.read<int>('rowid')).toList();
        final placeholders = List.filled(artistIds.length, '?').join(', ');
        final vars = artistIds.map((id) => Variable.withInt(id)).toList();
        final fullRows = await customSelect(
          'SELECT id, name, '
          '(SELECT tm.cover_art_id FROM trackmetadata tm '
          'WHERE tm.artist_id = artists.id '
          'AND tm.has_album_art = 1 '
          'AND tm.cover_art_id IS NOT NULL '
          'ORDER BY tm.track_number ASC, tm.uuid_id ASC '
          'LIMIT 1) AS cover_art_id '
          'FROM artists WHERE id IN ($placeholders)',
          variables: vars,
          readsFrom: {artists, trackmetadata},
        ).get();
        final idOrder = {
          for (var i = 0; i < artistIds.length; i++) artistIds[i]: i,
        };
        final sorted = List<QueryRow>.from(fullRows)
          ..sort(
            (a, b) => (idOrder[a.read<int>('id')] ?? 999).compareTo(
              idOrder[b.read<int>('id')] ?? 999,
            ),
          );
        resultArtists.addAll(sorted);
      }
    }

    if (searchAlbums) {
      final ftsRows = await customSelect(
        'SELECT rowid FROM fts_albums WHERE fts_albums MATCH ?'
        '$albumDownloadedFilter ORDER BY rank LIMIT ?',
        variables: [
          Variable.withString(ftsQuery),
          Variable.withInt(limitPerType),
        ],
        readsFrom: {},
      ).get();
      if (ftsRows.isNotEmpty) {
        final albumIds = ftsRows.map((r) => r.read<int>('rowid')).toList();
        final placeholders = List.filled(albumIds.length, '?').join(', ');
        final vars = albumIds.map((id) => Variable.withInt(id)).toList();
        final fullRows = await customSelect(
          'SELECT a.id, a.name, ar.name AS artist, a.artist_id, '
          'a."year", a.is_single_grouping, '
          '(SELECT tm.cover_art_id FROM trackmetadata tm '
          'WHERE tm.album_id = a.id '
          'AND tm.has_album_art = 1 '
          'AND tm.cover_art_id IS NOT NULL '
          'ORDER BY tm.track_number ASC, tm.uuid_id ASC '
          'LIMIT 1) AS cover_art_id '
          'FROM albums a '
          'JOIN artists ar ON a.artist_id = ar.id '
          'WHERE a.id IN ($placeholders)',
          variables: vars,
          readsFrom: {albums, artists, trackmetadata},
        ).get();
        final idOrder = {
          for (var i = 0; i < albumIds.length; i++) albumIds[i]: i,
        };
        final sorted = List<QueryRow>.from(fullRows)
          ..sort(
            (a, b) => (idOrder[a.read<int>('id')] ?? 999).compareTo(
              idOrder[b.read<int>('id')] ?? 999,
            ),
          );
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
    revision: Value(dto.revision),
    // `filePath` is local download state, never owned by the server, so leave
    // it absent — the `/changes` upsert must not clobber it.
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
    coverArtId: Value(meta.coverArtId),
  );
}
