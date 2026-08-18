import 'dart:async';
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

/// Counts calls to the (small, cheap, but redundant-when-batched)
/// parent-FTS rebuild so a test can assert it runs once per batch, not
/// once per row.
class _CountingDb extends AppDatabase {
  _CountingDb() : super(NativeDatabase.memory());
  int parentFtsRebuilds = 0;

  @override
  Future<void> rebuildParentFtsIndexes() {
    parentFtsRebuilds++;
    return super.rebuildParentFtsIndexes();
  }
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
  Future<http.Response> Function(String uuidId)? onGetTrack,
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
      // GET /tracks/{uuid} — single-track refetch (resolveTakeServer / gone).
      final segs = req.url.pathSegments;
      if (req.method == 'GET' && segs.length == 2 && segs.first == 'tracks') {
        return onGetTrack?.call(segs[1]) ?? http.Response('', 404);
      }
      // GET /changes (legacy fallback) → empty page.
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

/// A single-track GET payload (the `ClientTrack` shape) for refetch mocks.
http.Response _trackResponse({
  String uuid = 'u1',
  String? title = 'Server',
  String? artist = 'ServerA',
  String? album = 'ServerAlb',
  int revision = 9,
}) =>
    http.Response(
      jsonEncode({
        'uuid_id': uuid,
        'created_at': 0,
        'last_updated': 0,
        'revision': revision,
        'metadata': {
          'title': title,
          'artist': artist,
          'album': album,
          'duration': 1,
          'bitrate_kbps': 1,
          'sample_rate_hz': 1,
          'channels': 2,
          'has_album_art': false,
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

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

  test('flush 404 marks the row rejected until dismissed (track gone)', () async {
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

    // The edit didn't land — it stays visible as a rejection (the "Saved"
    // toast already fired) until the user dismisses it; it never re-flushes.
    final row = await db.select(db.pendingEdits).getSingle();
    expect(row.status, 'rejected');
    expect(row.rejectionReason, contains('no longer exists'));
    await outbox.flush();
    expect(_patchCalls, hasLength(1)); // rejected rows are not re-sent

    await outbox.dismissRejected('u1');
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

  test('master-write toggle with no field edits queues an empty-field re-tag',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, revision: 5);
    final outbox =
        _container(db, onPatch: (_) async => _ok()).read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty(), // no field changes — just escalate mode
      writeMode: EditWriteMode.dbAndMaster,
      baseRevision: 5,
    );
    await outbox.flush();

    final body = _patchCalls.single.body;
    expect(body['write_mode'], 'db_and_master');
    expect(body['base_revision'], 5);
    // Only the control fields are sent — no field columns.
    expect(body.keys.toSet(), {'base_revision', 'write_mode'});
  });

  test('take-server lands on current server truth via single-track refetch',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, title: 'Old', artist: 'OldA', revision: 5);
    // The server moved on to "Server" (revision 9) — exactly the value the
    // refetch must converge to, NOT the pre-edit snapshot. This is robust even
    // if a prior `/changes` pull had already advanced the watermark past 9,
    // because the refetch ignores the watermark.
    final outbox = _container(
      db,
      onPatch: (_) async => _conflict(9),
      onGetTrack: (_) async =>
          _trackResponse(title: 'Server', artist: 'ServerA', revision: 9),
    ).read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'New'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await outbox.flush(); // -> conflicted

    await outbox.resolveTakeServer('u1');

    // Converged to the server's current value (not 'Old', not 'New'); the
    // pending row is gone and the local revision matches the server.
    final meta = await db
        .customSelect(
            "SELECT title FROM trackmetadata WHERE uuid_id='u1'")
        .getSingle();
    expect(meta.read<String>('title'), 'Server');
    expect(await db.select(db.pendingEdits).get(), isEmpty);
    final rev = (await db
            .customSelect("SELECT revision AS r FROM tracks WHERE uuid_id='u1'")
            .getSingle())
        .read<int>('r');
    expect(rev, 9);
    // FTS reflects server truth: the edited term gone, the server term present.
    final newHits = await db
        .customSelect("SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH 'New'")
        .get();
    expect(newHits, isEmpty);
    final serverHits = await db
        .customSelect(
            "SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH 'Server'")
        .get();
    expect(serverHits, hasLength(1));
  });

  test('flush 200 records the returned revision so the next edit rebases',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, revision: 5);
    // Tiny server model: an edit succeeds only when base_revision matches, and
    // bumps the revision it returns. A stale base would 409 here.
    var serverRev = 5;
    final outbox = _container(db, onPatch: (body) async {
      if (body['base_revision'] != serverRev) return _conflict(serverRev);
      serverRev += 1;
      return http.Response(
        jsonEncode(
            {'uuid_id': 'u1', 'revision': serverRev, 'master_written': false}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }).read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'A'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await outbox.flush();

    // The 200 recorded the new revision locally.
    final revAfterFirst = (await db
            .customSelect("SELECT revision AS r FROM tracks WHERE uuid_id='u1'")
            .getSingle())
        .read<int>('r');
    expect(revAfterFirst, 6);

    // A second edit reads the fresh local revision as its base, so it flushes
    // without 409-ing against this client's own prior edit.
    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'B'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: revAfterFirst,
    );
    await outbox.flush();

    expect(await db.select(db.pendingEdits).get(), isEmpty);
    final revAfterSecond = (await db
            .customSelect("SELECT revision AS r FROM tracks WHERE uuid_id='u1'")
            .getSingle())
        .read<int>('r');
    expect(revAfterSecond, 7);
  });

  test('flush 422 reverts the optimistic write and surfaces a rejection',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, title: 'Old', revision: 5);
    // FastAPI-style string detail (e.g. the empty-track guard) — it becomes
    // the user-visible reason.
    final outbox = _container(
      db,
      onPatch: (_) async => http.Response(
        jsonEncode({'detail': 'Edit would leave the track with no title'}),
        422,
        headers: {'content-type': 'application/json'},
      ),
    ).read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'Rejected'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    // Optimistic write applied the (to-be-rejected) value.
    expect(
      (await db
              .customSelect("SELECT title FROM trackmetadata WHERE uuid_id='u1'")
              .getSingle())
          .read<String>('title'),
      'Rejected',
    );

    await outbox.flush(); // -> 422, permanent rejection

    // The rejected value did not linger: reverted to the snapshot — and the
    // rejection is user-visible (row kept with the server's reason) instead
    // of a silent developer.log.
    final meta = await db
        .customSelect("SELECT title FROM trackmetadata WHERE uuid_id='u1'")
        .getSingle();
    expect(meta.read<String>('title'), 'Old');
    final row = await db.select(db.pendingEdits).getSingle();
    expect(row.status, 'rejected');
    expect(row.rejectionReason, contains('no title'));

    await outbox.dismissRejected('u1');
    expect(await db.select(db.pendingEdits).get(), isEmpty);
  });

  test('flush 422 must not revert over newer server truth pulled while pending',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, title: 'Old', revision: 5);
    final outbox = _container(db, onPatch: (_) async => http.Response('', 422))
        .read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'Mine'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    // While the row waits (e.g. its first flush hit a transient network
    // error), a `/changes` pull lands: the blind full-row upsert overwrites
    // the optimistic value with newer server truth and advances the
    // watermark past it.
    await db.customStatement(
        "UPDATE trackmetadata SET title = 'ServerNew' WHERE uuid_id = 'u1'");
    await db.customStatement(
        "UPDATE tracks SET revision = 9 WHERE uuid_id = 'u1'");

    await outbox.flush(); // -> 422, permanent rejection

    // The revert must not resurrect the pre-edit snapshot over server truth
    // that is at/below the watermark — no pull will ever re-send it.
    final title = (await db
            .customSelect(
                "SELECT title FROM trackmetadata WHERE uuid_id = 'u1'")
            .getSingle())
        .read<String>('title');
    expect(title, 'ServerNew',
        reason: 'the 422 revert clobbered already-synced server truth with '
            'the stale pre-edit snapshot');
  });

  test('a committed PATCH whose response was lost must not conflict with itself',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, revision: 5);
    // Tiny server model: attempt 1 COMMITS (revision 5 -> 6) but the
    // response is lost at transport level — the documented Future.timeout
    // caveat: the server may finish although the client saw an error.
    // ApiClient's retry (patchTrack passes retry: true) then re-sends the
    // identical body with the now-stale base_revision 5 and gets a 409
    // against the client's own already-applied edit.
    var serverRev = 5;
    var serverTitle = 'Old';
    var attempts = 0;
    final outbox = _container(
      db,
      onPatch: (body) async {
        attempts += 1;
        if (attempts == 1) {
          serverRev += 1; // committed server-side...
          serverTitle = body['title'] as String;
          throw http.ClientException('connection reset'); // ...response lost
        }
        if (body['base_revision'] != serverRev) return _conflict(serverRev);
        serverRev += 1;
        serverTitle = body['title'] as String;
        return http.Response(
          jsonEncode({
            'uuid_id': 'u1',
            'revision': serverRev,
            'master_written': false,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
      onGetTrack: (_) async => _trackResponse(
        title: serverTitle,
        artist: 'OldA',
        album: 'OldAlb',
        revision: serverRev,
      ),
    ).read(editOutboxProvider);

    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('title', 'A'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 5,
    );
    await outbox.flush();

    // The edit IS applied server-side; the user must not be asked to resolve
    // a conflict against their own values. The row resolves away and the
    // local revision catches up to the server's.
    final conflicted = await (db.select(db.pendingEdits)
          ..where((t) => t.status.equals('conflicted')))
        .get();
    expect(conflicted, isEmpty,
        reason: 'the transport-retried PATCH manufactured a 409 conflict '
            'prompt against the client\'s own committed edit');
    expect(await db.select(db.pendingEdits).get(), isEmpty);
    final rev = (await db
            .customSelect("SELECT revision AS r FROM tracks WHERE uuid_id='u1'")
            .getSingle())
        .read<int>('r');
    expect(rev, 6);
  });

  test('take-server while offline must not permanently lose server truth',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, title: 'Old', revision: 5);
    // Simulate the state after a prior ONLINE session: the flush 409ed (row
    // conflicted, server at revision 9) and the same session's `/changes`
    // pull already upserted the server truth locally and advanced the
    // watermark past 9 — so no future pull will ever re-send this track.
    await db.customStatement(
        "UPDATE trackmetadata SET title = 'Server' WHERE uuid_id = 'u1'");
    await db.customStatement(
        "UPDATE tracks SET revision = 9 WHERE uuid_id = 'u1'");
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, '
      'base_revision, status, server_revision, original_values_json, '
      'updated_at) VALUES '
      '(\'u1\', \'{"title":"Mine"}\', \'db_only\', 5, \'conflicted\', 9, '
      '\'{"title":"Old"}\', 0)',
    );
    final offlineOutbox =
        _container(db, offline: true, onPatch: (_) async => _ok())
            .read(editOutboxProvider);

    await offlineOutbox.resolveTakeServer('u1');

    // Offline, the authoritative refetch cannot run: the already-synced
    // server truth must not be reverted to the stale pre-edit snapshot, and
    // the resolution must survive as a retryable marker.
    final titleOffline = (await db
            .customSelect(
                "SELECT title FROM trackmetadata WHERE uuid_id = 'u1'")
            .getSingle())
        .read<String>('title');
    expect(titleOffline, 'Server',
        reason: 'take-server offline reverted to the stale pre-edit snapshot');
    final marker = await db.select(db.pendingEdits).getSingle();
    expect(marker.status, 'take_server',
        reason: 'the resolution was dropped — nothing would ever reconcile '
            'this track back to server truth');

    // Reconnect: the next sync finishes the deferred resolution via the
    // single-track refetch (the server has meanwhile moved to rev 10, which
    // proves the value came from the refetch, not local state).
    final online = _container(
      db,
      onPatch: (_) async => _ok(),
      onGetTrack: (_) async => _trackResponse(title: 'ServerV2', revision: 10),
    );
    await online.read(trackSyncProvider.notifier).sync();

    final titleOnline = (await db
            .customSelect(
                "SELECT title FROM trackmetadata WHERE uuid_id = 'u1'")
            .getSingle())
        .read<String>('title');
    expect(titleOnline, 'ServerV2');
    expect(await db.select(db.pendingEdits).get(), isEmpty);
  });

  test('re-editing a track with an outstanding take-server marker starts fresh',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, title: 'Mine', revision: 5); // optimistic value lingers
    // A take-server resolution made offline: the refetch couldn't run, so the
    // marker survives. Its values/base belong to the batch the user DISCARDED.
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, '
      'base_revision, status, original_values_json, updated_at) VALUES '
      '(\'u1\', \'{"title":"Mine"}\', \'db_and_master\', 5, \'take_server\', '
      '\'{"title":"Old"}\', 0)',
    );
    final outbox = _container(db, offline: true, onPatch: (_) async => _ok())
        .read(editOutboxProvider);

    // The user edits the track again while the marker is outstanding.
    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('artist', 'NewArtist'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 9,
    );

    // The new batch must not resurrect the discarded values, inherit the
    // discarded batch's write mode, or coalesce onto its stale base.
    final row = await db.select(db.pendingEdits).getSingle();
    expect(row.status, 'pending');
    expect(jsonDecode(row.valuesJson), {'artist': 'NewArtist'},
        reason: 'values the user explicitly discarded via take-server were '
            'coalesced into their new edit');
    expect(row.baseRevision, 9,
        reason: 'the new edit coalesced onto the discarded batch\'s stale base');
    expect(row.writeMode, 'db_only',
        reason: 'the discarded batch\'s master-write escalation leaked into '
            'the new batch');
  });

  test('re-editing a track with a rejected edit starts fresh', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, title: 'Mine', revision: 5);
    // A permanently-rejected batch: the optimistic write was already
    // reverted, but the row itself (with its stale, refused values) is left
    // around as a visible rejection until dismissed.
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, '
      'base_revision, status, rejection_reason, original_values_json, '
      'updated_at) VALUES '
      '(\'u1\', \'{"title":null,"artist":null}\', \'db_and_master\', 5, '
      '\'rejected\', \'empty edit\', \'{"title":"Old","artist":"OldA"}\', 0)',
    );
    final outbox = _container(db, offline: true, onPatch: (_) async => _ok())
        .read(editOutboxProvider);

    // The user makes an unrelated edit on the same track.
    await outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('album', 'Greatest Hits'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 9,
    );

    final row = await db.select(db.pendingEdits).getSingle();
    expect(row.status, 'pending');
    expect(jsonDecode(row.valuesJson), {'album': 'Greatest Hits'},
        reason: 'the rejected batch\'s discarded title/artist:null values '
            'were coalesced into a save the user never made');
    expect(row.baseRevision, 9);
    expect(row.writeMode, 'db_only',
        reason: 'the rejected batch\'s master-write escalation leaked into '
            'the new edit');
  });

  test(
      'resolveTakeServer marker write cannot be raced by a concurrent enqueue',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, title: 'Mine', revision: 5);
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, '
      'base_revision, status, server_revision, original_values_json, '
      'updated_at) VALUES '
      '(\'u1\', \'{"title":"Mine"}\', \'db_only\', 5, \'conflicted\', 9, '
      '\'{"title":"Old"}\', 0)',
    );
    final outbox = _container(
      db,
      onPatch: (_) async => _ok(),
      onGetTrack: (_) async => _trackResponse(title: 'Server', revision: 9),
    ).read(editOutboxProvider);

    // Fire both without awaiting between them: resolveTakeServer's marker
    // write and enqueue's read-modify-write both go through the shared
    // mutex now, so — with the fix — enqueue's mutex.run() call (issued
    // second, in this synchronous order) is guaranteed to be queued behind
    // resolveTakeServer's, and so must observe the marker already written.
    final resolve = outbox.resolveTakeServer('u1');
    final enqueueFuture = outbox.enqueue(
      uuidId: 'u1',
      edit: const MetadataEdit.empty().set('album', 'NewAlbum'),
      writeMode: EditWriteMode.dbOnly,
      baseRevision: 9,
    );
    await enqueueFuture;
    await resolve;

    final rows = await db.select(db.pendingEdits).get();
    expect(rows, hasLength(1));
    expect(jsonDecode(rows.single.valuesJson), {'album': 'NewAlbum'},
        reason: 'enqueue coalesced onto the pre-marker conflicted row '
            'instead of observing the take_server marker already written');
    expect(rows.single.baseRevision, 9,
        reason: 'enqueue rebased onto the stale conflicted batch instead of '
            'starting fresh');
  });

  test('retryTakeServerResolutions rebuilds parent FTS once, not per row',
      () async {
    final db = _CountingDb();
    addTearDown(db.close);
    await _seedTrack(db, uuid: 'u1', title: 'Mine', revision: 5);
    await _seedTrack(db, uuid: 'u2', title: 'Yours', revision: 5);
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, '
      'base_revision, status, original_values_json, updated_at) VALUES '
      '(\'u1\', \'{"title":"Mine"}\', \'db_only\', 5, \'take_server\', '
      '\'{"title":"Old1"}\', 0), '
      '(\'u2\', \'{"title":"Yours"}\', \'db_only\', 5, \'take_server\', '
      '\'{"title":"Old2"}\', 0)',
    );
    final outbox = _container(
      db,
      onPatch: (_) async => _ok(),
      onGetTrack: (uuid) async => _trackResponse(
        uuid: uuid,
        title: 'Server$uuid',
        revision: 9,
      ),
    ).read(editOutboxProvider);

    await outbox.retryTakeServerResolutions();

    expect(await db.select(db.pendingEdits).get(), isEmpty);
    expect(db.parentFtsRebuilds, 1,
        reason: 'each queued take-server row triggered its own redundant '
            'parent-FTS rebuild instead of one rebuild for the whole batch');
  });

  test('take-server marker reaping must not race a concurrent re-edit',
      () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await _seedTrack(db, title: 'Mine', revision: 5);
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, '
      'base_revision, status, original_values_json, updated_at) VALUES '
      '(\'u1\', \'{"title":"Mine"}\', \'db_only\', 5, \'take_server\', '
      '\'{"title":"Old"}\', 0)',
    );
    // Gate the single-track GET so the refetch holds the edit-sync mutex
    // while we queue a concurrent enqueue behind it.
    final getArrived = Completer<void>();
    final releaseGet = Completer<void>();
    final container = _container(
      db,
      onPatch: (_) async => _ok(),
      onGetTrack: (_) async {
        if (!getArrived.isCompleted) getArrived.complete();
        await releaseGet.future;
        return _trackResponse(title: 'Server', revision: 9);
      },
    );
    final outbox = container.read(editOutboxProvider);

    // The post-sync retry starts the refetch (mutex held during the GET)...
    final retry = outbox.retryTakeServerResolutions();
    await getArrived.future;
    // ...and the user re-edits the same track meanwhile. A real enqueue
    // queues behind the mutex and can land in the microtask window between
    // the refetch releasing the mutex and the marker delete executing —
    // which side wins is scheduler-dependent, so pin the losing-side state
    // directly: by the time the reap runs, the row is a fresh pending edit,
    // not the marker anymore.
    await db.customStatement(
      'UPDATE pending_edits SET values_json = \'{"artist":"NewArtist"}\', '
      'write_mode = \'db_only\', base_revision = 9, status = \'pending\' '
      'WHERE uuid_id = \'u1\'',
    );
    releaseGet.complete();
    await retry;

    // The fresh edit must survive the marker reap intact — deleting it here
    // silently discards a save the user was already told succeeded.
    final rows = await db.select(db.pendingEdits).get();
    expect(rows, hasLength(1),
        reason: 'the take-server reap deleted the user\'s fresh edit');
    expect(rows.single.status, 'pending');
    expect(jsonDecode(rows.single.valuesJson), {'artist': 'NewArtist'});
    expect(rows.single.baseRevision, 9);
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
