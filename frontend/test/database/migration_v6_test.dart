// Phase 7B.1b / SC-14 / 7-U01: Drift schema v6 adds `durable_submissions`
// (the shared durable-submission rows, SC-14) and `upload_intents` (Phase 7
// local transfer intents, fenced by `local_binding_id`, SC-01 rule 4). The
// upgrade starts from a real v5 file (generated schema_v5.dart) through
// production `onUpgrade`, keeps every existing row, and matches a fresh
// install. A reset wipes both new tables.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';

import '../drift/default/generated/schema_v5.dart' as v5;

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

Future<List<(String, int, int)>> _columns(AppDatabase db, String table) async =>
    [
      for (final c in await _rows(db, 'PRAGMA table_info($table)'))
        (c['name'] as String, c['notnull'] as int, c['pk'] as int),
    ];

Future<void> _insertSubmission(AppDatabase db, {required String state}) =>
    db.customStatement(
      'INSERT INTO durable_submissions (operation_uuid, kind, '
      'local_binding_id, frozen_body_json, state, created_at, updated_at) '
      "VALUES ('op-1', 'k', 'bind-1', '{\"a\":1}', ?, 1, 1)",
      [state],
    );

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('mig_v6'));
  tearDown(() => dir.delete(recursive: true));

  Future<File> v5File({bool withData = true}) async {
    final file = File('${dir.path}/app.db');
    final old = v5.DatabaseAtV5(NativeDatabase(file));
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
        'INSERT INTO tracks (uuid_id, file_path, created_at, last_updated, '
        'revision, file_size_bytes, downloaded_quality) '
        "VALUES ('u1', '/dl/u1.m4a', 10, 20, 7, 1234, '320')",
      );
      await old.customStatement(
        'INSERT INTO pending_edits (uuid_id, values_json, write_mode, '
        'base_revision, status, updated_at) '
        "VALUES ('u1', '{\"title\":null}', 'db_only', 7, 'pending', 30)",
      );
      await old.customStatement(
        "INSERT INTO sync_cursors (stream, value) VALUES ('catalog', 42)",
      );
    }
    await old.close();
    return file;
  }

  test('upgrade from a real v5 file keeps the binding, downloads, pending '
      'edits and cursors, and adds empty v6 tables', () async {
    final db = AppDatabase(NativeDatabase(await v5File()));
    addTearDown(db.close);
    expect(
      (await _rows(db, 'PRAGMA user_version')).single.values.single,
      db.schemaVersion, // the full chain runs to the current version
    );
    expect(
      await _rows(
        db,
        'SELECT instance_id, local_binding_id, last_base_url, bound_at, '
        'catalog_reconciled_at_binding, user_id FROM server_binding',
      ),
      [
        {
          'instance_id': 'inst-1',
          'local_binding_id': 'bind-1',
          'last_base_url': 'http://srv:1',
          'bound_at': 1000,
          'catalog_reconciled_at_binding': 1,
          'user_id': 7,
        },
      ],
    );
    expect(
      await _rows(db, 'SELECT uuid_id, file_path, revision FROM tracks'),
      [
        {'uuid_id': 'u1', 'file_path': '/dl/u1.m4a', 'revision': 7},
      ],
    );
    expect(
      await _rows(
        db,
        'SELECT uuid_id, values_json, base_revision, status FROM pending_edits',
      ),
      [
        {
          'uuid_id': 'u1',
          'values_json': '{"title":null}',
          'base_revision': 7,
          'status': 'pending',
        },
      ],
    );
    expect(await _rows(db, 'SELECT stream, value FROM sync_cursors'), [
      {'stream': 'catalog', 'value': 42},
    ]);
    expect(await _rows(db, 'SELECT * FROM durable_submissions'), isEmpty);
    expect(await _rows(db, 'SELECT * FROM upload_intents'), isEmpty);
  });

  test('the upgraded v6 tables match a fresh install and the fixture',
      () async {
    final upgraded = AppDatabase(NativeDatabase(await v5File(withData: false)));
    addTearDown(upgraded.close);
    final fresh = AppDatabase(NativeDatabase.memory());
    addTearDown(fresh.close);

    expect(await _columns(fresh, 'durable_submissions'), _submissionColumns);
    expect(await _columns(fresh, 'upload_intents'), _intentColumns);
    for (final table in ['durable_submissions', 'upload_intents']) {
      expect(await _columns(upgraded, table), await _columns(fresh, table),
          reason: table);
    }
    Future<List<Map<String, Object?>>> schemaSql(AppDatabase db) => _rows(
          db,
          "SELECT type, name, sql FROM sqlite_master WHERE tbl_name IN "
          "('durable_submissions', 'upload_intents') ORDER BY name",
        );
    expect(await schemaSql(upgraded), await schemaSql(fresh));
  });

  test('a second open of the upgraded file is a no-op', () async {
    final file = await v5File();
    final first = AppDatabase(NativeDatabase(file));
    await _insertSubmission(first, state: 'prepared');
    await first.close();

    final second = AppDatabase(NativeDatabase(file));
    addTearDown(second.close);
    expect(
      (await _rows(second, 'PRAGMA user_version')).single.values.single,
      second.schemaVersion, // the full chain runs to the current version
    );
    expect(
      await _rows(second, 'SELECT operation_uuid, state FROM durable_submissions'),
      [
        {'operation_uuid': 'op-1', 'state': 'prepared'},
      ],
    );
  });

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
}
