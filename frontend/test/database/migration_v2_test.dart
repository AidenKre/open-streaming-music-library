// 5-T01 / Phase 5 §5: the FIRST real Drift onUpgrade (schema 1 -> 2).
//
// A real version-1 database FILE (built from the frozen drift_schemas v1
// snapshot via the generated DatabaseAtV1, plus the v1 FTS tables) is opened
// by the production AppDatabase, which must upgrade it in place:
//  * new tables `server_binding` (SC-01) and `sync_cursors` (SC-02);
//  * trackmetadata duration / sample_rate_hz / channels become nullable and
//    local zeros become NULL (SC-16l, unknown is not zero);
//  * downloads, queue, pending edits and FTS search survive;
//  * the upgraded schema equals a fresh install's.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';

import '../drift/default/generated/schema_v1.dart' as v1;

// FTS DDL exactly as schema version 1 created it in onCreate.
const _v1Fts = [
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_tracks USING fts5("
      "title, artist_name, album_name, "
      "content='', content_rowid='id', tokenize='unicode61')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_artists USING fts5("
      "name, content='', content_rowid='id', tokenize='unicode61')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_albums USING fts5("
      "name, artist_name, content='', content_rowid='id', tokenize='unicode61')",
];

const _u1 = 'u1-zero-props';
const _u2 = 'u2-deleted';
const _u3 = 'u3-known-props';

Future<void> _createV1File(File file) async {
  final db = v1.DatabaseAtV1(NativeDatabase(file));
  for (final s in _v1Fts) {
    await db.customStatement(s);
  }
  Future<void> exec(String sql) => db.customStatement(sql);
  await exec("INSERT INTO artists (id, name) VALUES (1, 'Artist')");
  await exec(
    "INSERT INTO albums (id, name, artist_id, year, is_single_grouping) "
    "VALUES (1, 'Album', 1, 2001, 0)",
  );
  for (final (uuid, path) in [
    (_u1, '/dl/u1.flac'),
    (_u2, null),
    (_u3, null),
  ]) {
    await exec(
      'INSERT INTO tracks (uuid_id, file_path, created_at, last_updated, '
      'revision, downloaded_bitrate_kbps, file_size_bytes, downloaded_quality, '
      'downloaded_at_revision, downloaded_codec) VALUES '
      "('$uuid', ${path == null ? 'NULL' : "'$path'"}, 10, 20, 7, "
      "${path == null ? 'NULL, NULL, NULL, NULL, NULL' : "320, 1234, 'original', 7, 'flac'"})",
    );
  }
  Future<void> meta(String uuid, String title, String props) => exec(
    'INSERT INTO trackmetadata (uuid_id, title, artist, album, album_artist, '
    'artist_id, album_id, year, date, genre, track_number, disc_number, codec, '
    'duration, bitrate_kbps, sample_rate_hz, channels, has_album_art, '
    'cover_art_id) VALUES '
    "('$uuid', '$title', 'Artist', 'Album', NULL, 1, 1, 2001, '2001-01-01', "
    "'Rock', 3, 1, 'flac', $props, 1, 42)",
  );
  await meta(_u1, 'zeroed', '0.0, 900.5, 0, 0');
  await meta(_u2, 'gone', '1.0, 1.0, 1, 1');
  await meta(_u3, 'knownprops', '210.5, NULL, 48000, 2');
  // Leave a rowid gap: fts_tracks is keyed by trackmetadata's implicit rowid.
  await exec("DELETE FROM trackmetadata WHERE uuid_id = '$_u2'");
  await exec("DELETE FROM tracks WHERE uuid_id = '$_u2'");
  await exec(
    'INSERT INTO fts_tracks(rowid, title, artist_name, album_name) '
    "SELECT rowid, title, artist, album FROM trackmetadata",
  );
  await exec("INSERT INTO fts_artists(rowid, name) VALUES (1, 'Artist')");
  await exec(
    "INSERT INTO fts_albums(rowid, name, artist_name) VALUES (1, 'Album', 'Artist')",
  );
  await exec(
    'INSERT INTO queue_sessions (id, is_active, created_at, updated_at, '
    "source_type, current_item_id, current_position_ms, repeat_mode, "
    "shuffle_enabled) VALUES (1, 1, 1, 2, 'album', 2, 1500, 'all', 0)",
  );
  await exec(
    'INSERT INTO queue_session_items (item_id, session_id, queue_type, '
    "position, uuid_id) VALUES (1, 1, 'main', 0, '$_u1'), "
    "(2, 1, 'main', 1, '$_u3')",
  );
  await exec(
    'INSERT INTO queue_session_play_order (session_id, play_position, item_id) '
    'VALUES (1, 0, 1), (1, 1, 2)',
  );
  await exec(
    'INSERT INTO pending_edits (uuid_id, values_json, write_mode, '
    "base_revision, status, updated_at) VALUES "
    "('$_u3', '{\"title\":\"x\"}', 'db_only', 7, 'pending', 99)",
  );
  await db.close();
}

Future<List<Map<String, Object?>>> _rows(AppDatabase db, String sql) async =>
    [for (final r in await db.customSelect(sql).get()) r.data];

Future<Map<String, Object?>> _schemaShape(AppDatabase db) async {
  final shape = <String, Object?>{};
  final tables = await _rows(
    db,
    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
  );
  for (final t in tables) {
    final name = t['name']! as String;
    shape['table:$name'] = (
      await _rows(db, 'PRAGMA table_xinfo("$name")'),
      await _rows(db, 'PRAGMA foreign_key_list("$name")'),
    ).toString();
  }
  final indexes = await _rows(
    db,
    "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' "
    'ORDER BY name',
  );
  for (final i in indexes) {
    final sql = (i['sql'] as String?)
        ?.replaceAll('"', '')
        .replaceAll(RegExp(r'\s+'), '')
        .toLowerCase();
    shape['index:${i['name']}'] = '${i['tbl_name']} $sql';
  }
  return shape;
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('osml_migration_v2_');
    file = File('${dir.path}/database.db');
    await _createV1File(file);
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<AppDatabase> openUpgraded() async {
    final db = AppDatabase(NativeDatabase(file));
    await db.customSelect('SELECT 1').get(); // runs the migration
    return db;
  }

  test('upgrades the file to schema version 2', () async {
    final db = await openUpgraded();
    addTearDown(db.close);
    expect(db.schemaVersion, 2);
    final v = await db.customSelect('PRAGMA user_version').getSingle();
    expect(v.data.values.single, 2);
  });

  test('adds empty server_binding and sync_cursors tables', () async {
    final db = await openUpgraded();
    addTearDown(db.close);
    final binding = await _rows(db, 'PRAGMA table_info(server_binding)');
    expect(
      binding.map((c) => c['name']),
      containsAll([
        'instance_id',
        'local_binding_id',
        'last_base_url',
        'bound_at',
        'catalog_reconciled_at_binding',
      ]),
    );
    final instanceId = binding.firstWhere((c) => c['name'] == 'instance_id');
    expect(instanceId['notnull'], 0, reason: 'NULL = provisional/legacy');
    final cursors = await _rows(db, 'PRAGMA table_info(sync_cursors)');
    expect(cursors.map((c) => c['name']), containsAll(['stream', 'value']));
    expect(await _rows(db, 'SELECT * FROM server_binding'), isEmpty);
    expect(await _rows(db, 'SELECT * FROM sync_cursors'), isEmpty);
  });

  test('audio properties become nullable; zeros become NULL', () async {
    final db = await openUpgraded();
    addTearDown(db.close);
    final cols = {
      for (final c in await _rows(db, 'PRAGMA table_info(trackmetadata)'))
        c['name']: c['notnull'],
    };
    expect(cols['duration'], 0);
    expect(cols['sample_rate_hz'], 0);
    expect(cols['channels'], 0);

    final rows = {
      for (final r in await _rows(
        db,
        'SELECT uuid_id, duration, bitrate_kbps, sample_rate_hz, channels '
        'FROM trackmetadata',
      ))
        r['uuid_id']: r,
    };
    expect(rows[_u1]!['duration'], isNull);
    expect(rows[_u1]!['sample_rate_hz'], isNull);
    expect(rows[_u1]!['channels'], isNull);
    expect(rows[_u1]!['bitrate_kbps'], 900.5, reason: 'untouched column');
    expect(rows[_u3]!['duration'], 210.5);
    expect(rows[_u3]!['sample_rate_hz'], 48000);
    expect(rows[_u3]!['channels'], 2);
    expect(rows[_u3]!['bitrate_kbps'], isNull);
  });

  test('every other trackmetadata column survives', () async {
    final db = await openUpgraded();
    addTearDown(db.close);
    final r = (await _rows(
      db,
      "SELECT * FROM trackmetadata WHERE uuid_id = '$_u3'",
    )).single;
    expect(r, containsPair('title', 'knownprops'));
    expect(r, containsPair('artist', 'Artist'));
    expect(r, containsPair('album', 'Album'));
    expect(r, containsPair('artist_id', 1));
    expect(r, containsPair('album_id', 1));
    expect(r, containsPair('year', 2001));
    expect(r, containsPair('date', '2001-01-01'));
    expect(r, containsPair('genre', 'Rock'));
    expect(r, containsPair('track_number', 3));
    expect(r, containsPair('disc_number', 1));
    expect(r, containsPair('codec', 'flac'));
    expect(r, containsPair('has_album_art', 1));
    expect(r, containsPair('cover_art_id', 42));
  });

  test('downloads, queue and pending edits survive', () async {
    final db = await openUpgraded();
    addTearDown(db.close);
    final t1 = (await _rows(
      db,
      "SELECT * FROM tracks WHERE uuid_id = '$_u1'",
    )).single;
    expect(t1['file_path'], '/dl/u1.flac');
    expect(t1['downloaded_quality'], 'original');
    expect(t1['downloaded_at_revision'], 7);
    expect(t1['file_size_bytes'], 1234);
    final session = (await _rows(db, 'SELECT * FROM queue_sessions')).single;
    expect(session['current_item_id'], 2);
    expect(session['current_position_ms'], 1500);
    expect(
      (await _rows(
        db,
        'SELECT uuid_id FROM queue_session_items ORDER BY position',
      )).map((r) => r['uuid_id']),
      [_u1, _u3],
    );
    expect(await _rows(db, 'SELECT * FROM queue_session_play_order'), hasLength(2));
    expect(
      (await _rows(db, 'SELECT * FROM pending_edits')).single['values_json'],
      '{"title":"x"}',
    );
    expect(await _rows(db, 'PRAGMA foreign_key_check'), isEmpty);
  });

  test('FTS search still finds the right tracks after the upgrade', () async {
    final db = await openUpgraded();
    addTearDown(db.close);
    for (final (query, uuid) in [('knownprops', _u3), ('zeroed', _u1)]) {
      final results = await db.getSearchResults(query);
      expect(
        results.tracks.map((r) => r.read<String>('uuid_id')),
        [uuid],
        reason: query,
      );
    }
    final artists = await db.getSearchResults('Artist', searchTracks: false);
    expect(artists.artists, hasLength(1));
  });

  test('reopening the upgraded file is a no-op', () async {
    final first = await openUpgraded();
    final before = await _rows(first, 'SELECT * FROM trackmetadata ORDER BY uuid_id');
    await first.close();
    final second = await openUpgraded();
    addTearDown(second.close);
    expect(await _rows(second, 'SELECT * FROM trackmetadata ORDER BY uuid_id'), before);
    final v = await second.customSelect('PRAGMA user_version').getSingle();
    expect(v.data.values.single, 2);
  });

  test('a failed upgrade rolls back completely and can be retried', () async {
    // Fault injection: an index named like a v2 table makes the step fail
    // AFTER it has already created server_binding.
    final raw = v1.DatabaseAtV1(NativeDatabase(file));
    await raw.customStatement(
      'CREATE INDEX sync_cursors ON pending_edits (updated_at)',
    );
    await raw.close();

    final failing = AppDatabase(NativeDatabase(file));
    await expectLater(failing.customSelect('SELECT 1').get(), throwsA(anything));
    await failing.close();

    final check = v1.DatabaseAtV1(NativeDatabase(file));
    final version = await check.customSelect('PRAGMA user_version').getSingle();
    expect(version.data.values.single, 1);
    final tables = await check
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name IN ('server_binding', 'sync_cursors')",
        )
        .get();
    expect(tables, isEmpty, reason: 'partial DDL must be rolled back');
    final duration = (await check
            .customSelect('PRAGMA table_info(trackmetadata)')
            .get())
        .firstWhere((c) => c.data['name'] == 'duration');
    expect(duration.data['notnull'], 1, reason: 'trackmetadata untouched');
    await check.customStatement('DROP INDEX sync_cursors');
    await check.close();

    // With the fault removed the same file upgrades normally.
    final retried = await openUpgraded();
    addTearDown(retried.close);
    final v = await retried.customSelect('PRAGMA user_version').getSingle();
    expect(v.data.values.single, 2);
    expect(
      (await retried.getSearchResults('knownprops')).tracks.single.read<String>('uuid_id'),
      _u3,
    );
  });

  test('the upgraded schema equals a fresh install', () async {
    final upgraded = await openUpgraded();
    addTearDown(upgraded.close);
    final fresh = AppDatabase(NativeDatabase.memory());
    addTearDown(fresh.close);
    await fresh.customSelect('SELECT 1').get();
    expect(await _schemaShape(upgraded), await _schemaShape(fresh));
  });
}
