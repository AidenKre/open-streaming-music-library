// The app database's schema version (2026-11-17 reset, refactor APP-RESET).
//
// Schema history was reset before the first release: version 1 is the
// baseline and no database from before the reset is upgraded. This file
// proves, through production initialisation on real database files:
//  * another stored version (2, 8) is refused and the file is not written;
//  * the place for upgrade steps still works: a test subclass at version 2
//    with one fake step upgrades a version-1 file, and a step that fails
//    leaves the file exactly as it was (one transaction, version included);
//  * a fresh install is version 1 with every table, index, trigger and search
//    table, and a second open changes nothing.
// The "fresh install" groups also hold the fresh-database tests and checks
// that used to live in the deleted test/database/migration_v2..v8_test.dart
// (each one's disposition is in the APP-RESET progress file).
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';

Future<List<Map<String, Object?>>> _rows(GeneratedDatabase db, String sql) async =>
    [for (final r in await db.customSelect(sql).get()) r.data];

Future<int> _version(GeneratedDatabase db) async =>
    (await _rows(db, 'PRAGMA user_version')).single.values.single! as int;

/// Every schema object, SQL whitespace-normalised, ordered by type and name.
Future<List<(String, String, String, String?)>> _schema(GeneratedDatabase db) async => [
  for (final r in await _rows(
    db,
    'SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name',
  ))
    (
      r['type']! as String,
      r['name']! as String,
      r['tbl_name']! as String,
      (r['sql'] as String?)?.replaceAll(RegExp(r'\s+'), ' ').trim(),
    ),
];

/// Every row of every ordinary table (FTS and sqlite internals excluded),
/// order-independent.
Future<Map<String, List<String>>> _allRows(GeneratedDatabase db) async {
  final tables = [
    for (final r in await _rows(
      db,
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'fts_%' ORDER BY name",
    ))
      r['name']! as String,
  ];
  return {
    for (final t in tables)
      t: [for (final r in await _rows(db, 'SELECT * FROM "$t"')) jsonEncode(r)]
        ..sort(),
  };
}

/// Opens a database file without migrating or writing it. The file's stored
/// version must equal [version]; any other version makes the probe refuse to
/// open, so a probe that opens has also confirmed the stored version.
class _Probe extends GeneratedDatabase {
  _Probe(super.executor, this.version);

  final int version;

  @override
  int get schemaVersion => version;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async => throw StateError('probe: the file has no database'),
    onUpgrade: (_, from, to) async =>
        throw StateError('probe: the file is at version $from, not $to'),
  );
}

/// What a file holds: its stored version, its schema and its rows.
typedef _FileState = (
  int,
  List<(String, String, String, String?)>,
  Map<String, List<String>>,
);

Future<_FileState> _stateOf(File file, {required int version}) async {
  final probe = _Probe(NativeDatabase(file), version);
  try {
    return (await _version(probe), await _schema(probe), await _allRows(probe));
  } finally {
    await probe.close();
  }
}

/// A test subclass one version ahead of the app, with one fake step.
class _NextVersionDb extends AppDatabase {
  _NextVersionDb(super.e, this.step, {this.failBeforeOpen = false});

  final OnUpgrade step;

  /// Fails the open after the production onUpgrade has returned, before
  /// drift writes the version itself.
  final bool failBeforeOpen;

  @override
  int get schemaVersion => 2;

  @override
  OnUpgrade get upgradeSteps => step;

  @override
  MigrationStrategy get migration {
    final production = super.migration;
    if (!failBeforeOpen) return production;
    return MigrationStrategy(
      onCreate: production.onCreate,
      onUpgrade: production.onUpgrade,
      beforeOpen: (_) async => throw StateError('beforeOpen failed'),
    );
  }
}

Future<void> _seed(AppDatabase db) async {
  Future<void> exec(String sql) => db.customStatement(sql);
  await exec("INSERT INTO artists (id, name) VALUES (1, 'Artist')");
  await exec(
    'INSERT INTO albums (id, name, artist_id, year, is_single_grouping) '
    "VALUES (1, 'Album', 1, 2001, 0)",
  );
  await exec(
    'INSERT INTO tracks (uuid_id, file_path, created_at, last_updated, '
    "revision) VALUES ('u1', '/dl/u1.flac', 10, 20, 7)",
  );
  await exec(
    'INSERT INTO trackmetadata (uuid_id, title, artist, album, album_artist, '
    'artist_id, album_id, year, genre, codec, duration, bitrate_kbps, '
    'sample_rate_hz, channels, has_album_art) VALUES '
    "('u1', 'title-u1', 'Artist', 'Album', NULL, 1, 1, 2001, 'Rock', 'flac', "
    '210.5, NULL, 48000, 2, 0)',
  );
  await exec("INSERT INTO sync_cursors (stream, value) VALUES ('catalog', 42)");
}

/// A fresh install on disk (created by production onCreate) with a few rows.
Future<File> _installedFile(Directory dir) async {
  final file = File('${dir.path}/app.db');
  final db = AppDatabase(NativeDatabase(file));
  await _seed(db);
  await db.close();
  return file;
}

/// Writes [version] into the file's header before drift reads it, whatever
/// the file held.
Future<void> _stamp(File file, int version) async {
  final probe = _Probe(
    NativeDatabase(file, setup: (raw) => raw.userVersion = version),
    version,
  );
  await probe.customSelect('SELECT 1').get();
  await probe.close();
}

// ── Independent fixtures (taken from the last exported schema snapshot,
// the FTS DDL and the trigger DDL; not read from the table classes) ───────

const _tables = {
  'artists',
  'albums',
  'tracks',
  'trackmetadata',
  'queue_sessions',
  'queue_session_items',
  'queue_session_play_order',
  'pending_edits',
  'server_binding',
  'sync_cursors',
  'history_events',
  'local_counters',
  'history_sync_failures',
  'history_conflict_archive',
  'active_listens',
  'durable_submissions',
  'upload_intents',
  'owned_file_cleanup',
};

const _searchTables = {'fts_tracks', 'fts_artists', 'fts_albums'};

const _indexes = {
  'idx_albums_name_lower',
  'idx_albums_artist_id',
  'idx_albums_regular',
  'idx_albums_singles',
  'idx_title',
  'idx_artist',
  'idx_album',
  'idx_album_artist',
  'idx_tm_artist_id',
  'idx_tm_album_id',
  'idx_year',
  'idx_date',
  'idx_genre',
  'idx_genre_nocase',
  'idx_track_number',
  'idx_disc_number',
  'idx_codec',
  'idx_duration',
  'idx_bitrate_kbps',
  'idx_sample_rate_hz',
  'idx_channels',
  'idx_has_album_art',
  'idx_tm_library_queue_order',
  'idx_tm_artist_queue_order',
  'idx_tm_album_queue_order',
  'idx_queue_session_items_session_position',
  'idx_queue_session_items_session_uuid',
  'idx_queue_session_play_order_session_position',
  'idx_queue_session_play_order_session_item',
  'idx_history_events_pending',
  'idx_history_events_kind_occurred',
  'idx_active_listens_accumulating',
  'idx_durable_submissions_unresolved',
  'idx_upload_intents_batch',
};

/// (trigger, table).
const _triggers = {
  ('history_content', 'history_events'),
  ('catalog_attribution_insert', 'trackmetadata'),
  ('catalog_attribution_delete', 'trackmetadata'),
  ('catalog_attribution_update', 'trackmetadata'),
};

/// (name, notnull, pk) per column, in declaration order.
const _submissionColumns = [
  ('operation_uuid', 1, 1),
  ('kind', 1, 0),
  ('local_binding_id', 1, 0),
  ('frozen_body_json', 0, 0),
  ('state', 1, 0),
  ('receipt_json', 0, 0),
  ('error_code', 0, 0),
  ('created_at', 1, 0),
  ('updated_at', 1, 0),
];

const _intentColumns = [
  ('item_uuid', 1, 1),
  ('batch_uuid', 1, 0),
  ('parent_item_uuid', 0, 0),
  ('selection_index', 1, 0),
  ('display_name', 1, 0),
  ('source_descriptor_json', 0, 0),
  ('expected_sha256', 0, 0),
  ('expected_length', 0, 0),
  ('last_state', 1, 0),
  ('last_error_code', 0, 0),
  ('last_error_message', 0, 0),
  ('operation_uuid', 0, 0),
  ('transfer_operation_uuid', 0, 0),
  ('review_generation', 0, 0),
  ('draft_json', 0, 0),
  ('local_binding_id', 1, 0),
  ('created_at', 1, 0),
  ('updated_at', 1, 0),
];

const _cleanupColumns = [
  ('id', 1, 1),
  ('path', 1, 0),
  ('root_kind', 1, 0),
  ('dev', 0, 0),
  ('ino', 0, 0),
  ('size', 0, 0),
  ('mtime', 0, 0),
  ('local_binding_id', 0, 0),
  ('attempts', 1, 0),
  ('last_error', 0, 0),
  ('created_at', 1, 0),
];

Future<List<(String, int, int)>> _columns(GeneratedDatabase db, String table) async =>
    [
      for (final c in await _rows(db, 'PRAGMA table_info($table)'))
        (c['name']! as String, c['notnull']! as int, c['pk']! as int),
    ];

Future<Map<String, int>> _notNull(GeneratedDatabase db, String table) async => {
  for (final c in await _rows(db, 'PRAGMA table_info($table)'))
    c['name']! as String: c['notnull']! as int,
};

// ── Helpers of the moved history-store tests (from migration_v3_test) ────

Future<int> _counter(AppDatabase db) async {
  final rows = await _rows(
    db,
    "SELECT value FROM local_counters WHERE key = 'history_content'",
  );
  return rows.isEmpty ? 0 : rows.single['value']! as int;
}

TableInfo<Table, dynamic> _table(AppDatabase db, String name) =>
    db.allTables.firstWhere((t) => t.actualTableName == name);

Future<void> _insertEvent(
  AppDatabase db, {
  String uuid = 'e1',
  int pending = 1,
  Object? serverRevision,
}) => db.customStatement(
  'INSERT INTO history_events (event_uuid, kind, entity_type, entity_ref, '
  'occurred_at, seconds_played, track_length, server_revision, received_at, '
  "pending_upload) VALUES ('$uuid', 'play', 'track', 't-1', 1000, 12.5, NULL, "
  "${serverRevision ?? 'NULL'}, NULL, $pending)",
);

// ── Helpers of the moved v6 / v7 table tests ────────────────────────────

Future<void> _insertSubmission(AppDatabase db, {required String state}) =>
    db.customStatement(
      'INSERT INTO durable_submissions (operation_uuid, kind, '
      'local_binding_id, frozen_body_json, state, created_at, updated_at) '
      "VALUES ('op-1', 'k', 'bind-1', '{\"a\":1}', ?, 1, 1)",
      [state],
    );

Future<void> _insertCleanup(
  AppDatabase db, {
  String path = '/docs/tracks/u1.m4a',
  String rootKind = 'downloads',
}) =>
    db.customStatement(
      'INSERT INTO owned_file_cleanup (path, root_kind, size, mtime, '
      'local_binding_id, created_at) VALUES (?, ?, 3, 1700, ?, 5)',
      [path, rootKind, 'bind-1'],
    );

// ── The version-1 snapshot guard (pre-merge review D5-01) ───────────────
//
// drift_schema_v1.json holds two descriptions of the schema, and the guard
// compares both with the live database:
//  * `fixed_sql`: the CREATE statement drift generated for every table and
//    index. drift_dev reads only these when the file has them (they are the
//    version 1 that `make-migrations` will upgrade from), so they are
//    compared in full, text against sqlite_master;
//  * `entities`: drift's element model, compared field by field against the
//    PRAGMAs (columns, types, nullability, order, defaults, column and
//    table constraints, primary key, rowid, generated columns; each index's
//    table, uniqueness, columns and SQL).
// What only Dart sees (getter names, client-side defaults, the Dart text of
// a generated or CHECK expression) is not schema and is not compared; the
// SQL it produces is, through `fixed_sql`. Triggers, views and the search
// tables are created by hand-written SQL and are not in the snapshot; the
// test "has every table, index, trigger and search table" names them.

const _snapshotPath = 'drift_schemas/default/drift_schema_v1.json';

Map<String, Object?> _readSnapshot() =>
    jsonDecode(File(_snapshotPath).readAsStringSync()) as Map<String, Object?>;

/// A CREATE statement as SQLite keeps it in sqlite_master: one space per run
/// of white space, no `IF NOT EXISTS`, no closing semicolon.
String _normalSql(String sql) => sql
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceFirst(RegExp(r';$'), '')
    .replaceFirstMapped(
      RegExp(r'^CREATE (TABLE|UNIQUE INDEX|INDEX) IF NOT EXISTS '),
      (m) => 'CREATE ${m[1]} ',
    );

/// The index just past the bracket that closes the one at [open], skipping
/// quoted text.
int _pastClosing(String s, int open) {
  var depth = 0;
  String? quote;
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == quote) quote = null;
    } else if (c == "'" || c == '"') {
      quote = c;
    } else if (c == '(') {
      depth++;
    } else if (c == ')' && --depth == 0) {
      return i + 1;
    }
  }
  return s.length;
}

/// The start of every top-level match of [at] in [s] (outside brackets and
/// quotes) for which [at] answers true.
List<int> _topLevel(String s, bool Function(int i) at) {
  final found = <int>[];
  var depth = 0;
  String? quote;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == quote) quote = null;
    } else if (c == "'" || c == '"') {
      quote = c;
    } else if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
    } else if (depth == 0 && at(i)) {
      found.add(i);
    }
  }
  return found;
}

/// A CREATE TABLE statement split into its column definitions (by column
/// name, in order), its table constraints and what follows the bracket.
({Map<String, String> columns, List<String> constraints, String options})
    _tableParts(String sql) {
  final open = sql.indexOf('(');
  final close = _pastClosing(sql, open);
  final body = sql.substring(open + 1, close - 1);
  final cuts = [-1, ..._topLevel(body, (i) => body[i] == ','), body.length];
  final columns = <String, String>{};
  final constraints = <String>[];
  for (var k = 0; k + 1 < cuts.length; k++) {
    final part = body.substring(cuts[k] + 1, cuts[k + 1]).trim();
    if (RegExp(r'^(PRIMARY KEY|UNIQUE|CHECK|FOREIGN KEY|CONSTRAINT)\b',
            caseSensitive: false)
        .hasMatch(part)) {
      constraints.add(part);
    } else {
      final name = RegExp(r'^"([^"]+)"|^(\S+)').firstMatch(part)!;
      columns[name[1] ?? name[2]!] = part;
    }
  }
  return (
    columns: columns,
    constraints: constraints,
    options: sql.substring(close).trim(),
  );
}

const _columnKeywords = [
  'NOT NULL',
  'NULL',
  'DEFAULT',
  'CHECK',
  'REFERENCES',
  'UNIQUE',
  'PRIMARY KEY',
  'GENERATED ALWAYS AS',
  'COLLATE',
];

/// A column definition split by property: its declared type, then one entry
/// per constraint keyword (`NOT NULL`/`NULL` under "nullability").
Map<String, String> _columnClauses(String definition) {
  final name = RegExp(r'^"[^"]+"|^\S+').firstMatch(definition)!;
  final rest = definition.substring(name.end).trim();
  String? keywordAt(int i) {
    if (i > 0 && rest[i - 1] != ' ') return null;
    return _columnKeywords.where((k) =>
        rest.startsWith(k, i) &&
        (i + k.length == rest.length || ' ('.contains(rest[i + k.length])))
        .firstOrNull;
  }

  final starts = <int>[];
  for (final i in _topLevel(rest, (i) => keywordAt(i) != null)) {
    // `NULL` inside `NOT NULL` is not a clause of its own.
    if (starts.isEmpty || i >= starts.last + keywordAt(starts.last)!.length) {
      starts.add(i);
    }
  }
  final clauses = <String, String>{
    'type': rest.substring(0, starts.isEmpty ? rest.length : starts.first).trim(),
  };
  for (var k = 0; k < starts.length; k++) {
    final text = rest
        .substring(starts[k], k + 1 < starts.length ? starts[k + 1] : rest.length)
        .trim();
    final keyword = _columnKeywords.firstWhere((w) => text.startsWith(w));
    final key = keyword.endsWith('NULL') ? 'nullability' : keyword;
    clauses[key] = [?clauses[key], text].join(' ');
  }
  return clauses;
}

/// A CREATE INDEX statement by property, or null when it does not parse.
Map<String, String>? _indexParts(String sql) {
  final head = RegExp(r'^CREATE (UNIQUE )?INDEX "?([^"\s]+)"? ON "?([^"\s(]+)"? ?')
      .firstMatch(sql);
  if (head == null || head.end >= sql.length || sql[head.end] != '(') {
    return null;
  }
  final close = _pastClosing(sql, head.end);
  final rest = sql.substring(close).trim();
  return {
    'unique': head[1] == null ? 'no' : 'yes',
    'table': head[3]!,
    'columns': sql.substring(head.end + 1, close - 1),
    'WHERE': rest.isEmpty ? 'none' : rest.replaceFirst(RegExp(r'^WHERE '), ''),
  };
}

String _shown(Object? v) => v == null ? 'none' : '`$v`';

/// Where two CREATE TABLE statements differ, by column and property.
List<String> _tableSqlDifferences(String table, String snap, String live) {
  final a = _tableParts(snap);
  final b = _tableParts(live);
  final out = <String>[];
  for (final c in {...a.columns.keys, ...b.columns.keys}) {
    final x = a.columns[c];
    final y = b.columns[c];
    if (y == null) {
      out.add('table $table, column $c: in the snapshot, not in the live database');
    } else if (x == null) {
      out.add('table $table, column $c: in the live database, not in the snapshot');
    } else if (x != y) {
      final px = _columnClauses(x);
      final py = _columnClauses(y);
      final props = [
        for (final k in {...px.keys, ...py.keys})
          if (px[k] != py[k])
            'table $table, column $c, $k: snapshot ${_shown(px[k])}, '
                'live ${_shown(py[k])}',
      ];
      out.addAll(props.isNotEmpty
          ? props
          : ['table $table, column $c: definition: snapshot `$x`, live `$y`']);
    }
  }
  final orderA = a.columns.keys.join(', ');
  final orderB = b.columns.keys.join(', ');
  if (out.isEmpty && orderA != orderB) {
    out.add('table $table, column order: snapshot $orderA; live $orderB');
  }
  for (final k in a.constraints) {
    if (!b.constraints.contains(k)) {
      out.add('table $table, table constraint `$k`: in the snapshot, '
          'not in the live database');
    }
  }
  for (final k in b.constraints) {
    if (!a.constraints.contains(k)) {
      out.add('table $table, table constraint `$k`: in the live database, '
          'not in the snapshot');
    }
  }
  if (a.options != b.options) {
    out.add('table $table, table options: snapshot ${_shown(a.options)}, '
        'live ${_shown(b.options)}');
  }
  return out.isNotEmpty
      ? out
      : ['table $table: CREATE statement: snapshot `$snap`, live `$live`'];
}

/// Where two CREATE INDEX statements differ, by property.
List<String> _indexSqlDifferences(String index, String snap, String live) {
  final a = _indexParts(snap);
  final b = _indexParts(live);
  final out = [
    if (a != null && b != null)
      for (final k in a.keys)
        if (a[k] != b[k]) 'index $index, $k: snapshot `${a[k]}`, live `${b[k]}`',
  ];
  return out.isNotEmpty
      ? out
      : ['index $index: CREATE statement: snapshot `$snap`, live `$live`'];
}

/// The live tables and indexes drift creates from the table classes, by
/// name: (type, table, SQL). The search tables and their shadow tables are
/// created by hand-written SQL and are not in the snapshot; SQLite's own
/// objects are not either.
Future<Map<String, (String, String, String)>> _liveObjects(
  GeneratedDatabase db,
) async {
  bool search(String name) =>
      _searchTables.any((s) => name == s || name.startsWith('${s}_'));
  return {
    for (final o in await _schema(db))
      if ((o.$1 == 'table' || o.$1 == 'index') &&
          !o.$2.startsWith('sqlite_') &&
          !search(o.$3))
        o.$2: (o.$1, o.$3, o.$4!),
  };
}

/// The value inside drift's `const CustomExpression('…')`, the form the
/// snapshot records a column default in; null for any other form.
String? _defaultSql(String dart) {
  final m = RegExp(r"^const CustomExpression\('(.*)'\)$").firstMatch(dart);
  return m?[1]!.replaceAll(r"\'", "'").replaceAll(r'\\', r'\');
}

/// Every way the live schema of [db] differs from [snapshot] (the decoded
/// drift_schema_v1.json), each naming the table, column or index and the
/// property; empty when they match.
Future<List<String>> _snapshotDifferences(
  GeneratedDatabase db,
  Map<String, Object?> snapshot,
) async {
  final live = await _liveObjects(db);
  final diffs = <String>[];

  // 1. The CREATE statements drift generated (`fixed_sql`).
  final fixed = <String, String>{
    for (final e in (snapshot['fixed_sql'] as List? ?? const []).cast<Map>())
      for (final s in (e['sql']! as List).cast<Map>())
        if (s['dialect'] == 'sqlite')
          e['name']! as String: _normalSql(s['sql']! as String),
  };
  if (fixed.isEmpty) {
    diffs.add('CREATE statements: the snapshot has none (no `fixed_sql`)');
  }
  for (final name in ({...fixed.keys, ...live.keys}.toList()..sort())) {
    final snap = fixed[name];
    final now = live[name];
    if (now == null) {
      final kind = snap!.startsWith('CREATE TABLE') ? 'table' : 'index';
      diffs.add('CREATE statements: $kind $name: in the snapshot, '
          'not in the live database');
    } else if (snap == null) {
      diffs.add('CREATE statements: ${now.$1} $name: in the live database, '
          'not in the snapshot');
    } else if (snap != now.$3) {
      diffs.addAll([
        for (final d in now.$1 == 'table'
            ? _tableSqlDifferences(name, snap, now.$3)
            : _indexSqlDifferences(name, snap, now.$3))
          'CREATE statements: $d',
      ]);
    }
  }

  // 2. The element model (`entities`).
  final asText =
      (snapshot['options'] as Map?)?['store_date_time_values_as_text'] == true;
  final sqlType = {
    'string': 'TEXT',
    'int': 'INTEGER',
    'bigInt': 'INTEGER',
    'bool': 'INTEGER',
    'dateTime': asText ? 'TEXT' : 'INTEGER',
    'double': 'REAL',
    'blob': 'BLOB',
  };
  final entities = [
    for (final e in snapshot['entities']! as List) e as Map<String, Object?>,
  ];
  final nameOf = {
    for (final e in entities) e['id']: (e['data']! as Map)['name'] as String,
  };
  void entity(String what) => diffs.add('entities: $what');

  for (final name in live.keys.toSet().difference(nameOf.values.toSet())) {
    entity('${live[name]!.$1} $name: in the live database, not in the snapshot');
  }
  for (final e in entities) {
    final data = e['data']! as Map<String, Object?>;
    final name = data['name']! as String;
    final type = e['type']! as String;
    final now = live[name];
    if (now == null || now.$1 != type) {
      entity('$type $name: in the snapshot, not in the live database');
      continue;
    }
    final columns = (data['columns']! as List).cast<Map<String, Object?>>();
    if (type == 'table') {
      final parts = _tableParts(now.$3);
      final xinfo = {
        for (final c in await _rows(db, 'PRAGMA table_xinfo("$name")'))
          c['name']! as String: c,
      };
      final snapOrder = [for (final c in columns) c['name']! as String];
      for (final c in snapOrder.toSet().difference(xinfo.keys.toSet())) {
        entity('table $name, column $c: in the snapshot, not in the live database');
      }
      for (final c in xinfo.keys.toSet().difference(snapOrder.toSet())) {
        entity('table $name, column $c: in the live database, not in the snapshot');
      }
      final common = [for (final c in snapOrder) if (xinfo.containsKey(c)) c];
      final liveOrder = [for (final c in xinfo.keys) if (snapOrder.contains(c)) c];
      if (common.join(', ') != liveOrder.join(', ')) {
        entity('table $name, column order: snapshot ${common.join(', ')}; '
            'live ${liveOrder.join(', ')}');
      }
      for (final c in columns) {
        final col = c['name']! as String;
        final x = xinfo[col];
        if (x == null) continue;
        void prop(String p, Object? snap, Object? liveValue) {
          if (snap != liveValue) {
            entity('table $name, column $col, $p: snapshot ${_shown(snap)}, '
                'live ${_shown(liveValue)}');
          }
        }

        prop('type', sqlType[c['moor_type']] ?? c['moor_type'], x['type']);
        prop('nullable', c['nullable'], x['notnull'] == 0);
        final dart = c['default_dart'] as String?;
        if (dart != null && _defaultSql(dart) == null) {
          entity('table $name, column $col, default: the snapshot records '
              '`$dart`, a form this guard does not read (compare it by hand '
              'and extend _defaultSql)');
        } else {
          prop('default', dart == null ? null : _defaultSql(dart), x['dflt_value']);
        }
        final generated = (c['dsl_features'] as List? ?? const [])
            .whereType<Map>()
            .map((f) => f['generated_as'])
            .whereType<Map>()
            .firstOrNull;
        prop(
          'generated',
          generated == null ? 'no' : (generated['stored'] == true ? 'stored' : 'virtual'),
          switch (x['hidden']) { 2 => 'virtual', 3 => 'stored', _ => 'no' },
        );
        final definition = parts.columns[col] ?? '';
        for (final key in ['defaultConstraints', 'customConstraints']) {
          final text = c[key] as String?;
          if (text != null && !definition.contains(_normalSql(text))) {
            entity('table $name, column $col, constraint `$text` ($key): '
                'not in the live definition `$definition`');
          }
        }
      }
      final pk = data['explicit_pk'] as List?;
      if (pk != null) {
        final livePk = [
          for (final c in (xinfo.values.where((c) => (c['pk']! as int) > 0).toList()
                ..sort((a, b) => (a['pk']! as int).compareTo(b['pk']! as int))))
            c['name'],
        ];
        if (pk.join(', ') != livePk.join(', ')) {
          entity('table $name, primary key: snapshot (${pk.join(', ')}), '
              'live (${livePk.join(', ')})');
        }
      }
      for (final k in (data['constraints'] as List? ?? const []).cast<String>()) {
        if (!now.$3.contains(_normalSql(k))) {
          entity('table $name, table constraint `$k`: in the snapshot, '
              'not in the live database');
        }
      }
      if ((data['without_rowid'] == true) != parts.options.contains('WITHOUT ROWID')) {
        entity('table $name, without rowid: snapshot ${data['without_rowid']}, '
            'live ${parts.options.contains('WITHOUT ROWID')}');
      }
      if ((data['is_virtual'] == true) != now.$3.startsWith('CREATE VIRTUAL')) {
        entity('table $name, virtual: snapshot ${data['is_virtual']}, live '
            '${now.$3.startsWith('CREATE VIRTUAL')}');
      }
    } else {
      final on = nameOf[data['on']];
      if (on != now.$2) entity('index $name, table: snapshot `$on`, live `${now.$2}`');
      final unique = (await _rows(
        db,
        "SELECT \"unique\" FROM pragma_index_list('${now.$2}') WHERE name = '$name'",
      )).single['unique'] == 1;
      if ((data['unique'] == true) != unique) {
        entity('index $name, unique: snapshot ${data['unique'] == true ? 'yes' : 'no'}, '
            'live ${unique ? 'yes' : 'no'}');
      }
      final sql = data['sql'] as String?;
      if (sql != null && _normalSql(sql) != now.$3) {
        for (final d in _indexSqlDifferences(name, _normalSql(sql), now.$3)) {
          entity(d);
        }
      }
      if (columns.isNotEmpty) {
        String key(Map<String, Object?> c) =>
            '${c['column']}${'${c['order_by']}'.toLowerCase() == 'desc' ? ' DESC' : ''}';
        final snapKeys = [for (final c in columns) key(c)];
        final liveKeys = [
          for (final c in await _rows(db, 'PRAGMA index_xinfo("$name")'))
            if (c['key'] == 1) '${c['name']}${c['desc'] == 1 ? ' DESC' : ''}',
        ];
        if (snapKeys.join(', ') != liveKeys.join(', ')) {
          entity('index $name, columns: snapshot `${snapKeys.join(', ')}`, '
              'live `${liveKeys.join(', ')}`');
        }
      }
    }
  }
  return diffs;
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('app_schema'));
  tearDown(() => dir.delete(recursive: true));

  group('another stored version is refused', () {
    for (final stored in [2, 8]) {
      test('a file stamped $stored fails to open and is not written', () async {
        final file = await _installedFile(dir);
        await _stamp(file, stored);
        final before = await _stateOf(file, version: stored);
        expect(before.$1, stored, reason: 'fixture sanity');
        expect(before.$3['trackmetadata'], hasLength(1), reason: 'fixture sanity');

        final db = AppDatabase(NativeDatabase(file));
        // Pre-merge review D3-01: the refusal names both versions and
        // nothing else (no path).
        await expectLater(
          db.customSelect('SELECT 1').get(),
          throwsA(isA<DatabaseVersionRefused>()
              .having((e) => e.found, 'found', stored)
              .having((e) => e.expected, 'expected', 1)
              .having((e) => '$e', 'text', isNot(contains(dir.path)))),
        );
        await db.close();

        final after = await _stateOf(file, version: stored);
        expect(after.$1, stored, reason: 'the stored version is unchanged');
        expect(after.$2, before.$2, reason: 'no table, index or trigger changed');
        expect(after.$3, before.$3, reason: 'no row changed');
      });
    }
  });

  group('the place for upgrade steps', () {
    test('a subclass at version 2 runs its one step on a version-1 file',
        () async {
      final file = await _installedFile(dir);
      final before = await _stateOf(file, version: 1);
      final calls = <(int, int)>[];
      final db = _NextVersionDb(NativeDatabase(file), (m, from, to) async {
        calls.add((from, to));
        await m.database.customStatement(
          'CREATE TABLE fake_v2 (id INTEGER PRIMARY KEY, note TEXT)',
        );
        await m.database.customStatement(
          "INSERT INTO fake_v2 (id, note) VALUES (1, 'step ran')",
        );
      });
      addTearDown(db.close);

      expect(await _version(db), 2);
      expect(calls, [(1, 2)]);
      expect(await _rows(db, 'SELECT id, note FROM fake_v2'), [
        {'id': 1, 'note': 'step ran'},
      ]);
      final rows = await _allRows(db);
      expect(rows.remove('fake_v2'), isNotNull);
      expect(rows, before.$3, reason: 'existing rows survive the step');
    });

    test('a step that fails leaves the file at version 1 with nothing added',
        () async {
      final file = await _installedFile(dir);
      final before = await _stateOf(file, version: 1);
      final failing = _NextVersionDb(NativeDatabase(file), (m, from, to) async {
        // Writes DDL, a row and the version before it fails: the one
        // transaction must undo all three.
        await m.database.customStatement(
          'CREATE TABLE fake_v2 (id INTEGER PRIMARY KEY)',
        );
        await m.database.customStatement('INSERT INTO fake_v2 (id) VALUES (1)');
        await m.database.customStatement(
          "UPDATE sync_cursors SET value = 99 WHERE stream = 'catalog'",
        );
        await m.database.customStatement('PRAGMA user_version = 2');
        throw StateError('fake step failed');
      });
      await expectLater(
        failing.customSelect('SELECT 1').get(),
        throwsA(isA<StateError>()),
      );
      await failing.close();

      final after = await _stateOf(file, version: 1);
      expect(after.$1, 1, reason: 'the version write was rolled back');
      expect(after.$2, before.$2, reason: 'the table creation was rolled back');
      expect(after.$3, before.$3, reason: 'the row writes were rolled back');

      // The app (version 1) still opens the untouched file.
      final app = AppDatabase(NativeDatabase(file));
      expect(await _version(app), 1);
      await app.close();

      // And the upgrade can be retried: a working step now succeeds.
      final retried = _NextVersionDb(NativeDatabase(file), (m, from, to) async {
        await m.database.customStatement(
          'CREATE TABLE fake_v2 (id INTEGER PRIMARY KEY)',
        );
      });
      addTearDown(retried.close);
      expect(await _version(retried), 2);
      expect(await _rows(retried, 'SELECT id FROM fake_v2'), isEmpty);
    });

    test('the version is committed with the steps, before drift writes it',
        () async {
      // The open fails after onUpgrade returned: drift never writes the
      // version, so only onUpgrade's own write inside its transaction can
      // record that the step ran (a re-run would fail on the existing table).
      final file = await _installedFile(dir);
      final db = _NextVersionDb(
        NativeDatabase(file),
        (m, from, to) async => m.database.customStatement(
          'CREATE TABLE fake_v2 (id INTEGER PRIMARY KEY)',
        ),
        failBeforeOpen: true,
      );
      await expectLater(
        db.customSelect('SELECT 1').get(),
        throwsA(isA<StateError>()),
      );
      await db.close();

      final after = await _stateOf(file, version: 2);
      expect(after.$1, 2);
      expect([for (final o in after.$2) o.$2], contains('fake_v2'));
    });
  });

  group('a fresh install', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('is version 1', () async {
      expect(db.schemaVersion, 1);
      expect(await _version(db), 1);
    });

    test('has every table, index, trigger and search table', () async {
      final objects = await _schema(db);
      Set<String> named(String type) => {
        for (final o in objects)
          if (o.$1 == type && !o.$2.startsWith('sqlite_')) o.$2,
      };
      final tables = named('table');
      expect(tables.difference(_searchTables).where((t) => !t.startsWith('fts_')),
          unorderedEquals(_tables));
      expect(tables, containsAll(_searchTables));
      for (final fts in _searchTables) {
        final sql = objects.singleWhere((o) => o.$2 == fts).$4!;
        expect(sql, startsWith('CREATE VIRTUAL TABLE $fts USING fts5('),
            reason: fts);
      }
      expect(named('index'), unorderedEquals(_indexes));
      expect({
        for (final o in objects)
          if (o.$1 == 'trigger') (o.$2, o.$3),
      }, _triggers);
      expect(named('view'), isEmpty);
    });

    // The tracked snapshot is the baseline the first upgrade step will be
    // generated against: while version 1 is edited directly, it must still
    // describe today's tables (re-export it with `drift_dev schema dump`).
    // Every property the file records is compared (see _snapshotDifferences;
    // the group below proves each kind of difference is reported).
    test('matches the tracked version-1 schema snapshot', () async {
      final diffs = await _snapshotDifferences(db, _readSnapshot());
      expect(
        diffs,
        isEmpty,
        reason: 'The app database no longer matches $_snapshotPath, the '
            'record of schema version 1 that the first upgrade step will be '
            'generated against:\n  ${diffs.join('\n  ')}\n'
            'If you changed lib/database/tables.dart (or database.dart) on '
            'purpose and version 1 has not been released, re-export the '
            'snapshot from frontend/: dart run drift_dev schema dump '
            'lib/database/database.dart drift_schemas/default/ (once version '
            '1 has shipped, a change needs version 2 and an upgrade step '
            'instead).',
      );
    });

    // Row 15: the artists' own name_lower index was a duplicate of the
    // automatic index of its unique() constraint and is gone; the constraint
    // and its index stay.
    test('a second artist with the same lower-cased name is refused',
        () async {
      await db.customStatement("INSERT INTO artists (id, name) VALUES (1, 'Abba')");
      await expectLater(
        db.customStatement("INSERT INTO artists (id, name) VALUES (2, 'ABBA')"),
        throwsA(isA<SqliteException>()),
      );
      final unique = await db
          .customSelect(
            "SELECT il.name FROM pragma_index_list('artists') il "
            "JOIN pragma_index_info(il.name) ii "
            "WHERE il.\"unique\" = 1 AND ii.name = 'name_lower'",
          )
          .get();
      expect(unique, hasLength(1));
    });

    test('has the columns the upgrade tests pinned', () async {
      expect(await _columns(db, 'durable_submissions'), _submissionColumns);
      expect(await _columns(db, 'upload_intents'), _intentColumns);
      expect(await _columns(db, 'owned_file_cleanup'), _cleanupColumns);

      final binding = await _notNull(db, 'server_binding');
      expect(binding.keys, containsAll([
        'instance_id',
        'local_binding_id',
        'last_base_url',
        'bound_at',
        'catalog_reconciled_at_binding',
        'user_id',
      ]));
      expect(binding['instance_id'], 0, reason: 'NULL = provisional/legacy');
      expect(binding['user_id'], 0, reason: 'NULL = unknown user, never 0');
      expect((await _notNull(db, 'sync_cursors')).keys,
          containsAll(['stream', 'value']));

      // SC-16l: unknown audio properties are NULL, never 0.
      final meta = await _notNull(db, 'trackmetadata');
      for (final col in ['duration', 'bitrate_kbps', 'sample_rate_hz', 'channels']) {
        expect(meta[col], 0, reason: 'trackmetadata.$col is nullable');
      }
      expect((await _notNull(db, 'tracks'))['damaged_file_path'], 0);
    });
  });

  // Pre-merge review D5-01: the guard above must fail for every kind of
  // drift between the tables and the snapshot. A table edit needs code
  // generation to reach the live database, so each case edits a copy of the
  // snapshot instead (the same difference, seen from the other side) and
  // expects the guard to name the table, column or index and the property.
  group('the snapshot guard names each kind of difference', () {
    late AppDatabase db;
    setUpAll(() => db = AppDatabase(NativeDatabase.memory()));
    tearDownAll(() => db.close());

    Map<String, Object?> data(Map<String, Object?> snap, String name) =>
        [
          for (final e in snap['entities']! as List)
            (e as Map)['data'] as Map<String, Object?>,
        ].singleWhere((d) => d['name'] == name);

    Map<String, Object?> column(
      Map<String, Object?> snap,
      String table,
      String name,
    ) =>
        (data(snap, table)['columns']! as List)
            .cast<Map<String, Object?>>()
            .singleWhere((c) => c['name'] == name);

    /// Replaces [from] by [to] in the CREATE statement of [name].
    void sql(Map<String, Object?> snap, String name, String from, String to) {
      final entry = (snap['fixed_sql']! as List)
          .cast<Map>()
          .singleWhere((e) => e['name'] == name);
      final statement = ((entry['sql']! as List).single as Map);
      final before = statement['sql']! as String;
      expect(before, contains(from), reason: 'fixture: $name has `$from`');
      statement['sql'] = before.replaceFirst(from, to);
    }

    final cases = <(String, void Function(Map<String, Object?>), String)>[
      // CREATE statements (what drift_dev reads as version 1).
      (
        'a column default',
        (s) => sql(s, 'queue_sessions', "DEFAULT 'off'", "DEFAULT 'all'"),
        "CREATE statements: table queue_sessions, column repeat_mode, DEFAULT: "
            "snapshot `DEFAULT 'all'`, live `DEFAULT 'off'`",
      ),
      (
        'a removed CHECK',
        (s) => sql(s, 'owned_file_cleanup', " CHECK (root_kind IN ('downloads'))", ''),
        'CREATE statements: table owned_file_cleanup, column root_kind, CHECK: '
            "snapshot none, live `CHECK (root_kind IN ('downloads'))`",
      ),
      (
        'a changed CHECK',
        (s) => sql(s, 'server_binding', 'CHECK("id" = 1)', 'CHECK("id" = 2)'),
        'CREATE statements: table server_binding, column id, CHECK: '
            'snapshot `CHECK("id" = 2)`, live `CHECK("id" = 1)`',
      ),
      (
        'a changed table UNIQUE',
        (s) => sql(s, 'queue_session_items', 'UNIQUE(session_id, queue_type, position)',
            'UNIQUE(session_id, position)'),
        'CREATE statements: table queue_session_items, table constraint '
            '`UNIQUE(session_id, queue_type, position)`: in the live database, '
            'not in the snapshot',
      ),
      (
        'a changed table PRIMARY KEY',
        (s) => sql(s, 'durable_submissions', 'PRIMARY KEY(operation_uuid)',
            'PRIMARY KEY(operation_uuid, kind)'),
        'CREATE statements: table durable_submissions, table constraint '
            '`PRIMARY KEY(operation_uuid, kind)`: in the snapshot, not in the '
            'live database',
      ),
      (
        'a column made nullable',
        (s) => sql(s, 'queue_sessions', '"repeat_mode" TEXT NOT NULL',
            '"repeat_mode" TEXT NULL'),
        'CREATE statements: table queue_sessions, column repeat_mode, '
            'nullability: snapshot `NULL`, live `NOT NULL`',
      ),
      (
        'a column added to the tables',
        (s) => sql(s, 'tracks', ', "damaged_file_path" TEXT NULL', ''),
        'CREATE statements: table tracks, column damaged_file_path: in the live '
            'database, not in the snapshot',
      ),
      (
        'an index made unique',
        (s) => sql(s, 'idx_albums_name_lower', 'CREATE INDEX', 'CREATE UNIQUE INDEX'),
        'CREATE statements: index idx_albums_name_lower, unique: snapshot `yes`, '
            'live `no`',
      ),
      (
        'an index made non-unique',
        (s) => sql(s, 'idx_albums_regular', 'CREATE UNIQUE INDEX', 'CREATE INDEX'),
        'CREATE statements: index idx_albums_regular, unique: snapshot `no`, '
            'live `yes`',
      ),
      (
        "a SQL-declared index's WHERE",
        (s) => sql(s, 'idx_albums_regular', 'WHERE is_single_grouping = 0',
            'WHERE is_single_grouping = 1'),
        'CREATE statements: index idx_albums_regular, WHERE: snapshot '
            '`is_single_grouping = 1`, live `is_single_grouping = 0`',
      ),
      (
        "a SQL-declared index's columns",
        (s) => sql(s, 'idx_albums_singles', 'COALESCE(year, -1)', 'year'),
        'CREATE statements: index idx_albums_singles, columns: snapshot '
            '`artist_id, year`, live `artist_id, COALESCE(year, -1)`',
      ),
      (
        'an index added to the tables',
        (s) => (s['fixed_sql']! as List)
            .removeWhere((e) => (e as Map)['name'] == 'idx_genre_nocase'),
        'CREATE statements: index idx_genre_nocase: in the live database, not '
            'in the snapshot',
      ),
      // The element model.
      (
        'an entity column default',
        (s) => column(s, 'queue_sessions', 'repeat_mode')['default_dart'] =
            r"const CustomExpression('\'all\'')",
        "entities: table queue_sessions, column repeat_mode, default: snapshot "
            "`'all'`, live `'off'`",
      ),
      (
        'an entity custom constraint (CHECK)',
        (s) => column(s, 'owned_file_cleanup', 'root_kind')['customConstraints'] =
            "NOT NULL CHECK (root_kind IN ('downloads', 'covers'))",
        'entities: table owned_file_cleanup, column root_kind, constraint '
            "`NOT NULL CHECK (root_kind IN ('downloads', 'covers'))` "
            '(customConstraints): not in the live definition',
      ),
      (
        'an entity column constraint',
        (s) => column(s, 'queue_session_items', 'session_id')['defaultConstraints'] =
            'REFERENCES queue_sessions (id) ON DELETE RESTRICT',
        'entities: table queue_session_items, column session_id, constraint '
            '`REFERENCES queue_sessions (id) ON DELETE RESTRICT` '
            '(defaultConstraints): not in the live definition',
      ),
      (
        'an entity table constraint',
        (s) => data(s, 'queue_session_play_order')['constraints'] = [
          'UNIQUE(session_id, play_position, item_id)',
        ],
        'entities: table queue_session_play_order, table constraint '
            '`UNIQUE(session_id, play_position, item_id)`: in the snapshot, not '
            'in the live database',
      ),
      (
        'an entity primary key',
        (s) => data(s, 'queue_session_play_order')['explicit_pk'] = ['session_id'],
        'entities: table queue_session_play_order, primary key: snapshot '
            '(session_id), live (session_id, play_position)',
      ),
      (
        'an entity column type',
        (s) => column(s, 'tracks', 'revision')['moor_type'] = 'string',
        'entities: table tracks, column revision, type: snapshot `TEXT`, live '
            '`INTEGER`',
      ),
      (
        'an entity column nullability',
        (s) => column(s, 'tracks', 'created_at')['nullable'] = true,
        'entities: table tracks, column created_at, nullable: snapshot `true`, '
            'live `false`',
      ),
      (
        'an entity generated column',
        (s) => column(s, 'albums', 'name_lower')['dsl_features'] = [],
        'entities: table albums, column name_lower, generated: snapshot `no`, '
            'live `stored`',
      ),
      (
        'an entity rowid option',
        (s) => data(s, 'sync_cursors')['without_rowid'] = true,
        'entities: table sync_cursors, without rowid: snapshot true, live false',
      ),
      (
        'an entity index uniqueness',
        (s) => data(s, 'idx_albums_artist_id')['unique'] = true,
        'entities: index idx_albums_artist_id, unique: snapshot yes, live no',
      ),
      (
        'an entity index SQL',
        (s) => data(s, 'idx_active_listens_accumulating')['sql'] =
            'CREATE UNIQUE INDEX idx_active_listens_accumulating ON '
            "active_listens (state) WHERE state = 'finalizing'",
        'entities: index idx_active_listens_accumulating, WHERE: snapshot '
            "`state = 'finalizing'`, live `state = 'accumulating'`",
      ),
      (
        'entity index columns',
        (s) => (data(s, 'idx_upload_intents_batch')['columns']! as List)
            .removeAt(0),
        'entities: index idx_upload_intents_batch, columns: snapshot '
            '`batch_uuid, selection_index`, live `local_binding_id, batch_uuid, '
            'selection_index`',
      ),
      (
        'a missing entity',
        (s) => (s['entities']! as List).removeWhere(
            (e) => ((e as Map)['data'] as Map)['name'] == 'idx_genre_nocase'),
        'entities: index idx_genre_nocase: in the live database, not in the '
            'snapshot',
      ),
    ];
    for (final (what, edit, expected) in cases) {
      test(what, () async {
        final snap = _readSnapshot();
        edit(snap);
        expect(await _snapshotDifferences(db, snap), contains(startsWith(expected)));
      });
    }

    test('an index added to the live database', () async {
      final grown = AppDatabase(NativeDatabase.memory());
      addTearDown(grown.close);
      await grown.customStatement('CREATE INDEX idx_extra ON albums (year)');
      expect(await _snapshotDifferences(grown, _readSnapshot()), [
        'CREATE statements: index idx_extra: in the live database, not in the '
            'snapshot',
        'entities: index idx_extra: in the live database, not in the snapshot',
      ]);
    });
  });

  test('a second open of an installed file changes nothing', () async {
    final file = await _installedFile(dir);
    final first = AppDatabase(NativeDatabase(file));
    await _insertCleanup(first);
    await _insertSubmission(first, state: 'prepared');
    final schemaAfterFirst = await _schema(first);
    final rowsAfterFirst = await _allRows(first);
    await first.close();

    final second = AppDatabase(NativeDatabase(file));
    addTearDown(second.close);
    expect(await _version(second), 1);
    expect(await _schema(second), schemaAfterFirst);
    expect(await _allRows(second), rowsAfterFirst);
  });

  // Moved verbatim from migration_v3_test.dart ("the v3 history store").
  group('a fresh install: the history store', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('history_events shape, uniqueness and indexes', () async {
      final cols = {
        for (final r in await _rows(db, 'PRAGMA table_info(history_events)'))
          r['name']: (r['notnull'], r['pk']),
      };
      expect(cols, {
        'local_id': (1, 1),
        'event_uuid': (1, 0),
        'kind': (1, 0),
        'entity_type': (1, 0),
        'entity_ref': (1, 0),
        'occurred_at': (1, 0),
        'seconds_played': (0, 0),
        'track_length': (0, 0),
        'server_revision': (0, 0),
        'received_at': (0, 0),
        'pending_upload': (1, 0),
      });
      await _insertEvent(db);
      await expectLater(_insertEvent(db), throwsA(anything)); // same uuid
      await _insertEvent(db, uuid: 'e2', serverRevision: 5);
      await expectLater(
        _insertEvent(db, uuid: 'e3', serverRevision: 5),
        throwsA(anything),
      ); // same server_revision
      await _insertEvent(db, uuid: 'e4'); // many NULL server_revisions
      final indexed = <List<String>>[];
      for (final idx in await _rows(db, 'PRAGMA index_list(history_events)')) {
        final info = await _rows(db, 'PRAGMA index_xinfo("${idx['name']}")');
        indexed.add([
          for (final c in info)
            if (c['key'] == 1) '${c['name']}${c['desc'] == 1 ? ' DESC' : ''}',
        ]);
      }
      expect(
        indexed,
        containsAll([
          ['pending_upload', 'local_id'],
          ['kind', 'occurred_at DESC', 'event_uuid DESC'],
        ]),
      );
    });

    test('local_id is autoincrement (never reused after delete)', () async {
      await _insertEvent(db, uuid: 'a');
      await _insertEvent(db, uuid: 'b');
      await db.customStatement("DELETE FROM history_events WHERE event_uuid = 'b'");
      await _insertEvent(db, uuid: 'c');
      final ids = await _rows(
        db,
        "SELECT local_id FROM history_events WHERE event_uuid = 'c'",
      );
      expect(ids.single['local_id'], 3);
    });

    test('history_content bumps only when a payload value changes', () async {
      await _insertEvent(db);
      expect(await _counter(db), 0, reason: 'insert is not a payload update');
      Future<void> update(String set) =>
          db.customStatement("UPDATE history_events SET $set WHERE event_uuid = 'e1'");
      await update('pending_upload = 0, server_revision = 9, received_at = 77');
      expect(await _counter(db), 0, reason: 'metadata is not payload');
      await update("kind = 'play'");
      expect(await _counter(db), 0, reason: 'same value: guarded');
      await update('track_length = NULL');
      expect(await _counter(db), 0, reason: 'NULL to NULL: guarded');
      var expected = 0;
      for (final set in [
        "kind = 'clicked'",
        "entity_type = 'album'",
        "entity_ref = 'x:1'",
        'occurred_at = 2000',
        'seconds_played = 13.0',
        'seconds_played = NULL',
        'track_length = 200.0',
      ]) {
        await update(set);
        expect(await _counter(db), ++expected, reason: set);
      }
    });

    test('a Drift write to history_events reaches local_counters watchers',
        () async {
      await _insertEvent(db);
      final seen = <int>[];
      final sub = db
          .customSelect(
            "SELECT value FROM local_counters WHERE key = 'history_content'",
            readsFrom: {_table(db, 'local_counters')},
          )
          .watch()
          .listen((rows) => seen.add(rows.isEmpty ? 0 : rows.single.read<int>('value')));
      addTearDown(sub.cancel);
      await pumpEventQueue();
      await db.customUpdate(
        "UPDATE history_events SET kind = 'clicked' WHERE event_uuid = 'e1'",
        updates: {_table(db, 'history_events')},
        updateKind: UpdateKind.update,
      );
      await pumpEventQueue();
      expect(seen.last, 1);
    });

    test('at most one listen draft accumulates', () async {
      Future<void> draft(String id, String state) => db.customStatement(
        'INSERT INTO active_listens (listen_uuid, queue_session_id, '
        'queue_item_id, track_uuid, started_at, duration_seconds, '
        'accumulated_micros, last_checkpoint_at, state, final_payload_json) '
        "VALUES ('$id', 1, 1, 't', 0, NULL, 0, 0, '$state', NULL)",
      );
      await draft('l1', 'accumulating');
      await expectLater(draft('l2', 'accumulating'), throwsA(anything));
      await draft('l3', 'finalizing');
      await draft('l4', 'finalizing');
      await expectLater(draft('l5', 'paused'), throwsA(anything));
    });

    test('failure and conflict-archive records exist with their keys',
        () async {
      await db.customStatement(
        'INSERT INTO history_sync_failures (event_uuid, reason, detail, '
        "failed_at) VALUES ('e1', 'conflict', 'x', 1)",
      );
      await expectLater(
        db.customStatement(
          'INSERT INTO history_sync_failures (event_uuid, reason, detail, '
          "failed_at) VALUES ('e1', 'rejected', NULL, 2)",
        ),
        throwsA(anything),
      );
      await db.customStatement(
        'INSERT INTO history_conflict_archive (event_uuid, payload_json, '
        "archived_at) VALUES ('e1', '{}', 1), ('e1', '{}', 2)",
      );
      final rows = await _rows(db, 'SELECT archive_id FROM history_conflict_archive');
      expect(rows.length, 2);
    });
  });

  // Moved verbatim from migration_v6_test.dart and migration_v7_test.dart.
  group('a fresh install: submissions, upload intents and the cleanup queue',
      () {
    test('durable_submissions.state accepts only the SC-14 states', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      for (final s in ['prepared', 'sent', 'accepted', 'rejected', 'ambiguous']) {
        await db.customStatement('DELETE FROM durable_submissions');
        await _insertSubmission(db, state: s);
      }
      await db.customStatement('DELETE FROM durable_submissions');
      await expectLater(_insertSubmission(db, state: 'done'), throwsA(anything));
      expect(await _rows(db, 'SELECT * FROM durable_submissions'), isEmpty);
    });

    test('a local reset wipes durable submissions and upload intents',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _insertSubmission(db, state: 'sent');
      await db.customStatement(
        'INSERT INTO upload_intents (item_uuid, batch_uuid, selection_index, '
        'display_name, last_state, local_binding_id, created_at, updated_at) '
        "VALUES ('i1', 'b1', 0, 'a.flac', 'selected', 'bind-1', 1, 1)",
      );
      await db.resetLocalData();
      expect(await _rows(db, 'SELECT * FROM durable_submissions'), isEmpty);
      expect(await _rows(db, 'SELECT * FROM upload_intents'), isEmpty);
    });

    test('root_kind accepts only the known roots', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _insertCleanup(db);
      await expectLater(
        _insertCleanup(db, rootKind: 'documents'),
        throwsA(anything),
      );
      expect(await _rows(db, 'SELECT root_kind FROM owned_file_cleanup'), [
        {'root_kind': 'downloads'},
      ]);
    });

    test('a local reset wipes pending cleanup rows', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await _insertCleanup(db);
      await _insertCleanup(db, path: '/docs/tracks/u2.m4a');
      await db.resetLocalData();
      expect(await _rows(db, 'SELECT * FROM owned_file_cleanup'), isEmpty);
    });
  });
}
