// Phase M §7.4 / SC-01 Phase M amendment (M-U21 schema): Drift schema v5
// adds `server_binding.user_id INTEGER NULL`. The upgrade starts from a real
// v4 file (generated schema_v4.dart) through production `onUpgrade`, keeps
// the existing binding row with an unknown (NULL, never 0) user, leaves the
// catalog untouched, and matches a fresh install.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';

import '../drift/default/generated/schema_v4.dart' as v4;

const _fts = [
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_tracks USING fts5("
      "title, artist_name, album_name, "
      "content='', content_rowid='id', tokenize='unicode61')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_artists USING fts5("
      "name, content='', content_rowid='id', tokenize='unicode61')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_albums USING fts5("
      "name, artist_name, content='', content_rowid='id', tokenize='unicode61')",
];

Future<List<Map<String, Object?>>> _rows(AppDatabase db, String sql) async =>
    [for (final r in await db.customSelect(sql).get()) r.data];

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('mig_v5'));
  tearDown(() => dir.delete(recursive: true));

  Future<File> v4File({bool withBinding = true}) async {
    final file = File('${dir.path}/app.db');
    final old = v4.DatabaseAtV4(NativeDatabase(file));
    for (final s in _fts) {
      await old.customStatement(s);
    }
    if (withBinding) {
      await old.customStatement(
        'INSERT INTO server_binding (id, instance_id, local_binding_id, '
        'last_base_url, bound_at, catalog_reconciled_at_binding) '
        "VALUES (1, 'inst-1', 'bind-1', 'http://srv:1', 1000, 1)",
      );
    }
    await old.customStatement(
      'INSERT INTO tracks (uuid_id, file_path, created_at, last_updated, '
      'revision, file_size_bytes, downloaded_quality) '
      "VALUES ('u1', '/dl/u1.m4a', 10, 20, 7, 1234, '320')",
    );
    await old.close();
    return file;
  }

  test('upgrade from a real v4 file adds a NULL user_id and keeps the '
      'binding and the downloads', () async {
    final db = AppDatabase(NativeDatabase(await v4File()));
    addTearDown(db.close);
    expect(
      (await _rows(db, 'PRAGMA user_version')).single.values.single,
      db.schemaVersion, // the full chain runs to the current version
    );
    expect(
      await _rows(
        db,
        'SELECT id, instance_id, local_binding_id, last_base_url, bound_at, '
        'catalog_reconciled_at_binding, user_id FROM server_binding',
      ),
      [
        {
          'id': 1,
          'instance_id': 'inst-1',
          'local_binding_id': 'bind-1',
          'last_base_url': 'http://srv:1',
          'bound_at': 1000,
          'catalog_reconciled_at_binding': 1,
          'user_id': null,
        },
      ],
    );
    expect(
      await _rows(db, 'SELECT uuid_id, file_path, revision FROM tracks'),
      [
        {'uuid_id': 'u1', 'file_path': '/dl/u1.m4a', 'revision': 7},
      ],
    );
  });

  test('the upgraded server_binding table matches a fresh install', () async {
    final upgraded = AppDatabase(NativeDatabase(await v4File(withBinding: false)));
    addTearDown(upgraded.close);
    final fresh = AppDatabase(NativeDatabase.memory());
    addTearDown(fresh.close);
    Future<List<Map<String, Object?>>> columns(AppDatabase db) =>
        _rows(db, 'PRAGMA table_info(server_binding)');
    expect(await columns(upgraded), await columns(fresh));
    expect(
      (await columns(fresh)).where((c) => c['name'] == 'user_id').single,
      containsPair('notnull', 0),
    );
  });
}
