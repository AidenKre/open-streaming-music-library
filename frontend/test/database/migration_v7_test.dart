// Phase 8B.2a / 8-C04: Drift schema v7 adds `owned_file_cleanup`, the durable
// queue of app-owned local files whose reference was dropped (spec §6
// para 6). The upgrade starts from a real v6 file (generated schema_v6.dart)
// through production `onUpgrade`, keeps every existing row, and matches a
// fresh install. A reset wipes the new table (no gate).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';

import '../drift/default/generated/schema_v6.dart' as v6;

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

/// Independent fixture: (name, notnull, pk) per column, in declaration
/// order. Not read from the production table classes.
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

Future<List<(String, int, int)>> _columns(AppDatabase db, String table) async =>
    [
      for (final c in await _rows(db, 'PRAGMA table_info($table)'))
        (c['name'] as String, c['notnull'] as int, c['pk'] as int),
    ];

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

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('mig_v7'));
  tearDown(() => dir.delete(recursive: true));

  Future<File> v6File({bool withData = true}) async {
    final file = File('${dir.path}/app.db');
    final old = v6.DatabaseAtV6(NativeDatabase(file));
    for (final s in _fts) {
      await old.customStatement(s);
    }
    if (withData) {
      await old.customStatement(
        'INSERT INTO server_binding (id, instance_id, local_binding_id, '
        'last_base_url, bound_at, catalog_reconciled_at_binding, user_id) '
        "VALUES (1, 'inst-1', 'bind-1', 'http://srv:1', 1000, 1, 7)",
      );
      await old.customStatement(
        'INSERT INTO tracks (uuid_id, file_path, damaged_file_path, '
        'created_at, last_updated, revision, file_size_bytes, '
        'downloaded_quality) '
        "VALUES ('u1', '/dl/u1.m4a', '/dl/u1.old.m4a', 10, 20, 7, 1234, "
        "'320')",
      );
      await old.customStatement(
        'INSERT INTO durable_submissions (operation_uuid, kind, '
        'local_binding_id, frozen_body_json, state, created_at, updated_at) '
        "VALUES ('op-1', 'k', 'bind-1', '{\"a\":1}', 'sent', 1, 2)",
      );
      await old.customStatement(
        'INSERT INTO upload_intents (item_uuid, batch_uuid, selection_index, '
        'display_name, last_state, local_binding_id, created_at, updated_at) '
        "VALUES ('i1', 'b1', 0, 'a.flac', 'selected', 'bind-1', 1, 1)",
      );
      await old.customStatement(
        "INSERT INTO sync_cursors (stream, value) VALUES ('catalog', 42)",
      );
    }
    await old.close();
    return file;
  }

  test('upgrade from a real v6 file keeps the binding, downloads, '
      'submissions, upload intents and cursors, and adds an empty cleanup '
      'table', () async {
    final db = AppDatabase(NativeDatabase(await v6File()));
    addTearDown(db.close);
    expect(
      (await _rows(db, 'PRAGMA user_version')).single.values.single,
      7,
    );
    expect(
      await _rows(
        db,
        'SELECT instance_id, local_binding_id, last_base_url, user_id '
        'FROM server_binding',
      ),
      [
        {
          'instance_id': 'inst-1',
          'local_binding_id': 'bind-1',
          'last_base_url': 'http://srv:1',
          'user_id': 7,
        },
      ],
    );
    expect(
      await _rows(
        db,
        'SELECT uuid_id, file_path, damaged_file_path, revision FROM tracks',
      ),
      [
        {
          'uuid_id': 'u1',
          'file_path': '/dl/u1.m4a',
          'damaged_file_path': '/dl/u1.old.m4a',
          'revision': 7,
        },
      ],
    );
    expect(
      await _rows(
        db,
        'SELECT operation_uuid, state FROM durable_submissions',
      ),
      [
        {'operation_uuid': 'op-1', 'state': 'sent'},
      ],
    );
    expect(
      await _rows(db, 'SELECT item_uuid, last_state FROM upload_intents'),
      [
        {'item_uuid': 'i1', 'last_state': 'selected'},
      ],
    );
    expect(await _rows(db, 'SELECT stream, value FROM sync_cursors'), [
      {'stream': 'catalog', 'value': 42},
    ]);
    expect(await _rows(db, 'SELECT * FROM owned_file_cleanup'), isEmpty);
  });

  test('the upgraded cleanup table matches a fresh install and the fixture',
      () async {
    final upgraded = AppDatabase(NativeDatabase(await v6File(withData: false)));
    addTearDown(upgraded.close);
    final fresh = AppDatabase(NativeDatabase.memory());
    addTearDown(fresh.close);

    expect(await _columns(fresh, 'owned_file_cleanup'), _cleanupColumns);
    expect(
      await _columns(upgraded, 'owned_file_cleanup'),
      await _columns(fresh, 'owned_file_cleanup'),
    );
    Future<List<Map<String, Object?>>> schemaSql(AppDatabase db) => _rows(
          db,
          "SELECT type, name, sql FROM sqlite_master "
          "WHERE tbl_name = 'owned_file_cleanup' ORDER BY name",
        );
    expect(await schemaSql(upgraded), await schemaSql(fresh));
  });

  test('a second open of the upgraded file is a no-op and keeps cleanup rows',
      () async {
    final file = await v6File();
    final first = AppDatabase(NativeDatabase(file));
    await _insertCleanup(first);
    await first.close();

    final second = AppDatabase(NativeDatabase(file));
    addTearDown(second.close);
    expect(
      (await _rows(second, 'PRAGMA user_version')).single.values.single,
      7,
    );
    expect(
      await _rows(
        second,
        'SELECT path, root_kind, dev, ino, size, mtime, local_binding_id, '
        'attempts, last_error, created_at FROM owned_file_cleanup',
      ),
      [
        {
          'path': '/docs/tracks/u1.m4a',
          'root_kind': 'downloads',
          'dev': null,
          'ino': null,
          'size': 3,
          'mtime': 1700,
          'local_binding_id': 'bind-1',
          'attempts': 0,
          'last_error': null,
          'created_at': 5,
        },
      ],
    );
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
}
