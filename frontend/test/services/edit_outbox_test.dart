import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/edit_outbox.dart';

class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._v);
  final bool _v;
  @override
  bool build() => _v;
}

final _patchCalls = <({String method, Map<String, dynamic> body})>[];

Future<void> _seedTrack(
  AppDatabase db, {
  String uuid = 'u1',
  String title = 'Old',
  String artist = 'OldA',
  String album = 'OldAlb',
  int revision = 5,
}) async {
  await db.customStatement(
    'INSERT INTO tracks (uuid_id, created_at, last_updated, revision) '
    'VALUES (?, 0, 0, ?)',
    [uuid, revision],
  );
  await db.customStatement(
    'INSERT INTO trackmetadata (uuid_id, title, artist, album, duration, '
    'bitrate_kbps, sample_rate_hz, channels, has_album_art) '
    'VALUES (?, ?, ?, ?, 1, 1, 1, 2, 0)',
    [uuid, title, artist, album],
  );
  final rowid = (await db
          .customSelect('SELECT rowid AS r FROM trackmetadata WHERE uuid_id = ?',
              variables: [Variable.withString(uuid)])
          .getSingle())
      .read<int>('r');
  await db.customStatement(
    'INSERT INTO fts_tracks(rowid, title, artist_name, album_name) '
    'VALUES (?, ?, ?, ?)',
    [rowid, title, artist, album],
  );
}

ProviderContainer _container(
  AppDatabase db, {
  bool offline = false,
  required Future<http.Response> Function(Map<String, dynamic> body) onPatch,
}) {
  _patchCalls.clear();
  ApiClient.initForTest(
    'http://localhost:8000',
    MockClient((req) async {
      if (req.method == 'PATCH') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        _patchCalls.add((method: req.method, body: body));
        return onPatch(body);
      }
      // GET /changes (used by resolveTakeServer's sync) → empty page.
      return http.Response(
        jsonEncode({'changes': [], 'latestRevision': 0, 'nextCursor': null}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  final c = ProviderContainer(overrides: [
    databaseProvider.overrideWithValue(db),
    tracksApiProvider.overrideWithValue(TracksApi()),
    offlineModeProvider.overrideWith(() => _StubOffline(offline)),
  ]);
  addTearDown(c.dispose);
  return c;
}

http.Response _ok() => http.Response(
    jsonEncode({'uuid_id': 'u1', 'revision': 6, 'master_written': false}), 200,
    headers: {'content-type': 'application/json'});

http.Response _conflict(int current) => http.Response(
    jsonEncode({
      'detail': {'error': 'revision_conflict', 'current_revision': current}
    }),
    409,
    headers: {'content-type': 'application/json'});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('enqueue coalesces values, escalates write mode, keeps first base', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, revision: 5);
    final outbox = _container(db, onPatch: (_) async => _ok()).read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'A'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('artist', 'B'),
      writeMode: EditWriteMode.dbAndMaster,
      baseRevision: 99, // a later sync must NOT move the captured base
    );

    final row = await (db.select(db.pendingEdits)).getSingle();
    final values = jsonDecode(row.valuesJson) as Map<String, dynamic>;
    expect(values, {'title': 'A', 'artist': 'B'});
    expect(row.writeMode, 'db_and_master'); // escalated, never downgrades
    expect(row.baseRevision, 5); // first base of the batch

    // Optimistic local write applied to the denormalized columns.
    final meta = await db
        .customSelect("SELECT title, artist FROM trackmetadata WHERE uuid_id='u1'")
        .getSingle();
    expect(meta.read<String>('title'), 'A');
    expect(meta.read<String>('artist'), 'B');
  });

  test('flush 200 sends base_revision + write_mode then deletes the row', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, revision: 5);
    final outbox = _container(db, onPatch: (_) async => _ok()).read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'A'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await outbox.flush();

    expect(_patchCalls.single.method, 'PATCH');
    expect(_patchCalls.single.body['base_revision'], 5);
    expect(_patchCalls.single.body['write_mode'], 'db_only');
    expect(_patchCalls.single.body['title'], 'A');
    expect(await db.select(db.pendingEdits).get(), isEmpty);
  });

  test('flush 409 marks the row conflicted with the server revision', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, revision: 5);
    final outbox =
        _container(db, onPatch: (_) async => _conflict(9)).read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'A'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await outbox.flush();

    final row = await db.select(db.pendingEdits).getSingle();
    expect(row.status, 'conflicted');
    expect(row.serverRevision, 9);
  });

  test('flush 404 drops the row (track gone server-side)', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, revision: 5);
    final outbox = _container(db, onPatch: (_) async => http.Response('', 404))
        .read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'A'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await outbox.flush();
    expect(await db.select(db.pendingEdits).get(), isEmpty);
  });

  test('keep-mine rebases onto the server revision and re-flushes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, revision: 5);
    // First flush conflicts (server at 9); then the retry succeeds.
    var conflict = true;
    final outbox = _container(
      db,
      onPatch: (_) async => conflict ? _conflict(9) : _ok(),
    ).read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'A'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await outbox.flush(); // -> conflicted
    conflict = false;
    await outbox.resolveKeepMine('u1');

    expect(_patchCalls.last.body['base_revision'], 9); // rebased
    expect(await db.select(db.pendingEdits).get(), isEmpty); // applied
  });

  test('re-editing a conflicted row rebases base onto the server revision',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, revision: 5);
    final outbox =
        _container(db, onPatch: (_) async => _conflict(9)).read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'A'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await outbox.flush(); // -> conflicted, serverRevision 9

    // A fresh edit on the conflicted row clears the conflict and rebases onto
    // the server revision (not the stale 5) so the next flush won't re-conflict.
    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'B'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );

    final row = await db.select(db.pendingEdits).getSingle();
    expect(row.status, 'pending');
    expect(row.baseRevision, 9);
  });

  test('a failing row does not block the rest of the outbox flush', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, uuid: 'u1', revision: 5);
    await _seedTrack(db,
        uuid: 'u2', title: 'T2', artist: 'A2', album: 'Alb2', revision: 5);

    // u1's PATCH always 500s (reaches the rethrow); u2 succeeds.
    final outbox = _container(
      db,
      onPatch: (body) async =>
          body['title'] == 'fail' ? http.Response('', 500) : _ok(),
    ).read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'fail'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await outbox.enqueue(
      uuidId: 'u2',
      edit: const MetadataEdit.empty().set('title', 'ok'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await outbox.flush();

    // u1 stays pending (stuck), but u2 flushed despite u1 failing first.
    final remaining = await db.select(db.pendingEdits).get();
    expect(remaining.map((r) => r.uuidId), ['u1']);
  });

  test('take-server reverts the optimistic edit to the captured snapshot',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, title: 'Old', artist: 'OldA', revision: 5);
    final outbox =
        _container(db, onPatch: (_) async => _conflict(9)).read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'New'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    // Optimistic write took effect.
    expect(
      (await db
              .customSelect("SELECT title FROM trackmetadata WHERE uuid_id='u1'")
              .getSingle())
          .read<String>('title'),
      'New',
    );
    await outbox.flush(); // -> conflicted

    await outbox.resolveTakeServer('u1');

    // Reverted locally to the snapshot; the pending row is gone.
    final meta = await db
        .customSelect("SELECT title FROM trackmetadata WHERE uuid_id='u1'")
        .getSingle();
    expect(meta.read<String>('title'), 'Old');
    expect(await db.select(db.pendingEdits).get(), isEmpty);
    // FTS reflects the revert: the edited term is gone, the original is back.
    final newHits = await db
        .customSelect("SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH 'New'")
        .get();
    expect(newHits, isEmpty);
    final oldHits = await db
        .customSelect("SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH 'Old'")
        .get();
    expect(oldHits, hasLength(1));
  });

  test('flush is a no-op while offline', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, revision: 5);
    final outbox = _container(db, offline: true, onPatch: (_) async => _ok())
        .read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'A'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await outbox.flush();

    expect(_patchCalls, isEmpty);
    expect(await db.select(db.pendingEdits).get(), hasLength(1));
  });
}
