// PR 5A (5-T01 client, SC-11): Drift schema v3 — the local history store.
//
//  * history_events: local_id autoincrement PK (stable snapshot boundary),
//    unique event_uuid, the immutable payload, nullable unique
//    server_revision, nullable received_at, pending_upload; indexes
//    (pending_upload, local_id) and (kind, occurred_at DESC, event_uuid DESC).
//  * local_counters + the history_content trigger: bumps on UPDATE of a
//    payload column only when a value actually changes (WHEN guards); writes
//    through Drift propagate to watchers of local_counters.
//  * history_sync_failures (quarantine/diagnostics), history_conflict_archive
//    (original local payloads, excluded from upload/analytics), active_listens
//    (listen drafts; at most one accumulating).
// The upgrade starts from a real v2 file (generated schema_v2.dart), is one
// transaction (D9), preserves data, and matches a fresh install.
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';

import '../drift/default/generated/schema_v2.dart' as v2;

const _fts = [
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_tracks USING fts5("
      "title, artist_name, album_name, "
      "content='', content_rowid='id', tokenize='unicode61')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_artists USING fts5("
      "name, content='', content_rowid='id', tokenize='unicode61')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_albums USING fts5("
      "name, artist_name, content='', content_rowid='id', tokenize='unicode61')",
];

Future<void> _createV2File(File file, {List<String> extra = const []}) async {
  final db = v2.DatabaseAtV2(NativeDatabase(file));
  for (final s in _fts) {
    await db.customStatement(s);
  }
  Future<void> exec(String sql) => db.customStatement(sql);
  await exec("INSERT INTO artists (id, name) VALUES (1, 'Artist')");
  await exec(
    'INSERT INTO tracks (uuid_id, created_at, last_updated, revision) '
    "VALUES ('u1', 10, 20, 7)",
  );
  await exec(
    'INSERT INTO server_binding (id, instance_id, local_binding_id, '
    "last_base_url, bound_at, catalog_reconciled_at_binding) VALUES "
    "(1, 'inst-1', 'tok-1', 'http://s', 5, 1)",
  );
  await exec("INSERT INTO sync_cursors (stream, value) VALUES ('catalog', 42)");
  for (final s in extra) {
    await exec(s);
  }
  await db.close();
}

Future<List<Map<String, Object?>>> _rows(AppDatabase db, String sql) async =>
    [for (final r in await db.customSelect(sql).get()) r.data];

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

const _newTables = [
  'history_events',
  'local_counters',
  'history_sync_failures',
  'history_conflict_archive',
  'active_listens',
];

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('mig_v3'));
  tearDown(() => dir.delete(recursive: true));

  group('upgrade from a real v2 file', () {
    test('creates the history store and preserves data', () async {
      final file = File('${dir.path}/app.db');
      await _createV2File(file);
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      expect(
        (await _rows(db, 'PRAGMA user_version')).single.values.single,
        3,
      );
      final tables = {
        for (final r in await _rows(
          db,
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        ))
          r['name'],
      };
      expect(tables, containsAll(_newTables));
      expect(await _rows(db, 'SELECT uuid_id FROM tracks'), [
        {'uuid_id': 'u1'},
      ]);
      expect(
        (await _rows(db, 'SELECT local_binding_id FROM server_binding')).single,
        {'local_binding_id': 'tok-1'},
      );
      expect(
        await _rows(db, "SELECT value FROM sync_cursors WHERE stream='catalog'"),
        [
          {'value': 42},
        ],
      );
      expect(await _counter(db), 0);
    });

    test('a failed upgrade rolls back completely (version stays 2)', () async {
      final file = File('${dir.path}/app.db');
      // Fail late, after earlier history DDL has already succeeded.
      await _createV2File(
        file,
        extra: ['CREATE INDEX active_listens ON tracks (uuid_id)'],
      );
      final db = AppDatabase(NativeDatabase(file));
      await expectLater(db.customSelect('SELECT 1').get(), throwsA(anything));
      await db.close();
      final raw = v2.DatabaseAtV2(NativeDatabase(file));
      addTearDown(raw.close);
      final version = await raw.customSelect('PRAGMA user_version').getSingle();
      expect(version.data.values.single, 2);
      final names = {
        for (final r in await raw
            .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get())
          r.data['name'],
      };
      expect(names.intersection(_newTables.toSet()), isEmpty);
      expect(await raw.customSelect(
        "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE '%history%'",
      ).get(), isEmpty);
      expect((await raw.customSelect('SELECT local_binding_id FROM server_binding').getSingle())
          .read<String>('local_binding_id'), 'tok-1');
      expect((await raw.customSelect("SELECT value FROM sync_cursors WHERE stream='catalog'")
          .getSingle()).read<int>('value'), 42);
      final tracks = await raw.customSelect('SELECT uuid_id FROM tracks').get();
      expect(tracks.single.data, {'uuid_id': 'u1'});
    });
  });

  group('the v3 history store', () {
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
}
