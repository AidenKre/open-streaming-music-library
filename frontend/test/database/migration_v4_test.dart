// Phase 5 decision 6: Drift schema v4 — `tracks.damaged_file_path`, the
// path of a download that exists on disk but failed to play. The upgrade
// starts from a real v3 file (generated schema_v3.dart), adds the nullable
// column without touching existing rows, and matches a fresh install.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';

import '../drift/default/generated/schema_v3.dart' as v3;

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
  setUp(() async => dir = await Directory.systemTemp.createTemp('mig_v4'));
  tearDown(() => dir.delete(recursive: true));

  test('upgrade from a real v3 file adds damaged_file_path and keeps '
      'downloads', () async {
    final file = File('${dir.path}/app.db');
    final old = v3.DatabaseAtV3(NativeDatabase(file));
    for (final s in _fts) {
      await old.customStatement(s);
    }
    await old.customStatement(
      'INSERT INTO tracks (uuid_id, file_path, created_at, last_updated, '
      'revision, file_size_bytes, downloaded_quality) '
      "VALUES ('u1', '/dl/u1.m4a', 10, 20, 7, 1234, '320')",
    );
    await old.customStatement(
      'INSERT INTO tracks (uuid_id, created_at, last_updated) '
      "VALUES ('u2', 11, 21)",
    );
    await old.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(
      (await _rows(db, 'PRAGMA user_version')).single.values.single,
      4,
    );
    expect(
      await _rows(
        db,
        'SELECT uuid_id, file_path, file_size_bytes, downloaded_quality, '
        'damaged_file_path FROM tracks ORDER BY uuid_id',
      ),
      [
        {
          'uuid_id': 'u1',
          'file_path': '/dl/u1.m4a',
          'file_size_bytes': 1234,
          'downloaded_quality': '320',
          'damaged_file_path': null,
        },
        {
          'uuid_id': 'u2',
          'file_path': null,
          'file_size_bytes': null,
          'downloaded_quality': null,
          'damaged_file_path': null,
        },
      ],
    );
  });

  test('the upgraded tracks table matches a fresh install', () async {
    final file = File('${dir.path}/app.db');
    final old = v3.DatabaseAtV3(NativeDatabase(file));
    for (final s in _fts) {
      await old.customStatement(s);
    }
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    final fresh = AppDatabase(NativeDatabase.memory());
    addTearDown(fresh.close);
    Future<List<Map<String, Object?>>> columns(AppDatabase db) =>
        _rows(db, 'PRAGMA table_info(tracks)');
    expect(await columns(upgraded), await columns(fresh));
  });
}
