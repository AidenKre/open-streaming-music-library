// Phase 9A.1b (spec §3 para 1, SC-11, common §3 schema rule): Drift schema
// v8 adds the `catalog_attribution` triggers on `trackmetadata`, in onCreate
// and in the 7 -> 8 step. The upgrade starts from a real v7 file (generated
// schema_v7.dart) through production initialisation, keeps every row, is one
// transaction, matches a fresh install (normalised sqlite_master, triggers
// included), and a second open is a no-op. The counter's behaviour through
// the real writers is in catalog_attribution_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show GeneratedDatabase;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';

import '../drift/default/generated/schema_v1.dart' as v1;
import '../drift/default/generated/schema_v7.dart' as v7;

const _fts = [
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_tracks USING fts5("
      "title, artist_name, album_name, "
      "content='', content_rowid='id', tokenize='unicode61')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_artists USING fts5("
      "name, content='', content_rowid='id', tokenize='unicode61')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_albums USING fts5("
      "name, artist_name, content='', content_rowid='id', tokenize='unicode61')",
];

/// A real v7 install also carries Phase 5's history_content trigger, which
/// lives outside drift's exported schema (so the generated v7 helper does
/// not create it); added like the FTS tables.
const _historyContentTriggerV7 = '''
CREATE TRIGGER history_content
AFTER UPDATE OF kind, entity_type, entity_ref, occurred_at, seconds_played, track_length
ON history_events
WHEN OLD.kind IS NOT NEW.kind
  OR OLD.entity_type IS NOT NEW.entity_type
  OR OLD.entity_ref IS NOT NEW.entity_ref
  OR OLD.occurred_at IS NOT NEW.occurred_at
  OR OLD.seconds_played IS NOT NEW.seconds_played
  OR OLD.track_length IS NOT NEW.track_length
BEGIN
  INSERT INTO local_counters (key, value) VALUES ('history_content', 1)
  ON CONFLICT(key) DO UPDATE SET value = value + 1;
END
''';

/// Independent fixture: the triggers v8 puts on `trackmetadata`.
const _trackmetadataTriggers = {
  'catalog_attribution_insert',
  'catalog_attribution_delete',
  'catalog_attribution_update',
};

Future<List<Map<String, Object?>>> _rows(GeneratedDatabase db, String sql)
    async => [for (final r in await db.customSelect(sql).get()) r.data];

Future<int> _version(GeneratedDatabase db) async =>
    (await _rows(db, 'PRAGMA user_version')).single.values.single as int;

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

Future<Set<String>> _triggersOn(GeneratedDatabase db, String table) async => {
  for (final r in await _rows(
    db,
    "SELECT name FROM sqlite_master WHERE type = 'trigger' "
    "AND tbl_name = '$table'",
  ))
    r['name']! as String,
};

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

Future<void> _seedV7(v7.DatabaseAtV7 db) async {
  Future<void> exec(String sql) => db.customStatement(sql);
  await exec(
    'INSERT INTO server_binding (id, instance_id, local_binding_id, '
    'last_base_url, bound_at, catalog_reconciled_at_binding, user_id) '
    "VALUES (1, 'inst-1', 'bind-1', 'http://srv:1', 1000, 1, 7)",
  );
  await exec("INSERT INTO artists (id, name) VALUES (1, 'Artist')");
  await exec(
    'INSERT INTO albums (id, name, artist_id, year, is_single_grouping) '
    "VALUES (1, 'Album', 1, 2001, 0)",
  );
  for (final u in ['u1', 'u2']) {
    await exec(
      'INSERT INTO tracks (uuid_id, file_path, created_at, last_updated, '
      "revision) VALUES ('$u', '/dl/$u.flac', 10, 20, 7)",
    );
    await exec(
      'INSERT INTO trackmetadata (uuid_id, title, artist, album, '
      'album_artist, artist_id, album_id, year, genre, codec, duration, '
      'bitrate_kbps, sample_rate_hz, channels, has_album_art) VALUES '
      "('$u', 'title-$u', 'Artist', 'Album', NULL, 1, 1, 2001, 'Rock', "
      "'flac', 210.5, NULL, 48000, 2, 0)",
    );
  }
  await exec(
    'INSERT INTO fts_tracks(rowid, title, artist_name, album_name) '
    'SELECT rowid, title, artist, album FROM trackmetadata',
  );
  await exec(
    'INSERT INTO history_events (event_uuid, kind, entity_type, entity_ref, '
    'occurred_at, seconds_played, track_length, pending_upload) VALUES '
    "('e1', 'play', 'track', 'u1', 1000, 31.5, 210.5, 0)",
  );
  await exec(
    "INSERT INTO local_counters (key, value) VALUES ('history_content', 3)",
  );
  await exec("INSERT INTO sync_cursors (stream, value) VALUES ('catalog', 42)");
  await exec(
    'INSERT INTO owned_file_cleanup (path, root_kind, size, mtime, '
    "local_binding_id, created_at) VALUES ('/docs/tracks/x.m4a', "
    "'downloads', 3, 1700, 'bind-1', 5)",
  );
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('mig_v8'));
  tearDown(() => dir.delete(recursive: true));

  /// A real v7 file; returns it with every row it holds.
  Future<(File, Map<String, List<String>>)> v7File({
    bool withData = true,
    List<String> extra = const [],
  }) async {
    final file = File('${dir.path}/app.db');
    final old = v7.DatabaseAtV7(NativeDatabase(file));
    for (final s in _fts) {
      await old.customStatement(s);
    }
    await old.customStatement(_historyContentTriggerV7);
    if (withData) await _seedV7(old);
    for (final s in extra) {
      await old.customStatement(s);
    }
    final rows = await _allRows(old);
    await old.close();
    return (file, rows);
  }

  test('the client schema is v8', () {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(db.schemaVersion, 8);
  });

  test('upgrade from a real v7 file keeps every row and adds no counter',
      () async {
    final (file, before) = await v7File();
    expect(before['trackmetadata'], hasLength(2), reason: 'fixture sanity');
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await _version(db), 8);
    expect(await _allRows(db), before,
        reason: 'the step only creates triggers: no row added or changed');
    expect(await _triggersOn(db, 'trackmetadata'), _trackmetadataTriggers);
  });

  test('a migrated v7 file equals a fresh install, triggers included',
      () async {
    final (file, _) = await v7File(withData: false);
    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final fresh = AppDatabase(NativeDatabase.memory());
    addTearDown(fresh.close);

    expect(await _triggersOn(fresh, 'trackmetadata'), _trackmetadataTriggers);
    // Every object exists on both sides. Table SQL text is compared only
    // for triggers: drift's generated v7 helper quotes CHECK/PRIMARY KEY
    // columns differently from createAll() (pre-existing, not a v8 change).
    Future<List<(String, String, String)>> names(GeneratedDatabase db) async =>
        [for (final o in await _schema(db)) (o.$1, o.$2, o.$3)];
    expect(await names(upgraded), await names(fresh));
    Future<List<(String, String, String, String?)>> triggers(
      GeneratedDatabase db,
    ) async => [for (final o in await _schema(db)) if (o.$1 == 'trigger') o];
    expect(await triggers(upgraded), await triggers(fresh));
  });

  test('the full chain from a real v1 file installs the same triggers',
      () async {
    final file = File('${dir.path}/v1.db');
    final old = v1.DatabaseAtV1(NativeDatabase(file));
    for (final s in _fts) {
      await old.customStatement(s);
    }
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final fresh = AppDatabase(NativeDatabase.memory());
    addTearDown(fresh.close);
    expect(await _version(upgraded), 8);
    Future<List<(String, String, String, String?)>> triggers(GeneratedDatabase db) async =>
        [for (final o in await _schema(db)) if (o.$1 == 'trigger') o];
    expect(await triggers(upgraded), await triggers(fresh));
  });

  test('a second open of the upgraded file is a no-op', () async {
    final (file, before) = await v7File();
    final first = AppDatabase(NativeDatabase(file));
    final schemaAfterFirst = await _schema(first);
    await first.close();

    final second = AppDatabase(NativeDatabase(file));
    addTearDown(second.close);
    expect(await _version(second), 8);
    expect(await _schema(second), schemaAfterFirst);
    expect(await _allRows(second), before);
  });

  test('a failed upgrade rolls back completely (version stays 7)', () async {
    // Fail late in the step: the delete trigger's name is taken, so the
    // insert trigger created before it must be rolled back too.
    final (file, before) = await v7File(extra: [
      'CREATE TRIGGER catalog_attribution_delete AFTER DELETE ON tracks '
          'BEGIN SELECT 1; END',
    ]);
    final db = AppDatabase(NativeDatabase(file));
    await expectLater(db.customSelect('SELECT 1').get(), throwsA(anything));
    await db.close();

    final raw = v7.DatabaseAtV7(NativeDatabase(file));
    addTearDown(raw.close);
    expect(await _version(raw), 7);
    expect(await _triggersOn(raw, 'trackmetadata'), isEmpty);
    expect(await _allRows(raw), before);
  });
}
