// Phase 9A.1b (spec §3 para 1, SC-11, 9-U11 trigger row): the
// `catalog_attribution` counter in `local_counters` is kept by SQLite
// triggers on `trackmetadata`, never by increments in Dart writers. Every
// assertion here goes through a REAL writer:
//
//  * the catalog sync's page apply (`SyncService.syncChanges`: insert, the
//    `DoUpdate` upsert that rewrites every column, and tombstone deletes);
//  * the take-server single-track refetch (`refetchAndApplyTrack`: upsert,
//    and delete on 404);
//  * the optimistic edit and its revert (`EditOutbox.enqueue`, and a 422
//    flush that reverts to the pre-edit snapshot);
//  * the local reset (`AppDatabase.resetLocalData`), which must leave the
//    counters cleared with the database.
//
// Only a change of title, artist, album, album_artist, artist_id or album_id
// is an attribution change; a resumed sync that re-applies identical values
// must not bump (the WHEN guard). Null to a value is a change; null to null
// is not (null-safe `IS NOT`).
import 'dart:convert';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/services/sync_service.dart';

import '../helpers/server_binding.dart';

class _Online extends OfflineModeNotifier {
  @override
  bool build() {
    super.build();
    return false;
  }
}

/// Server-side metadata of one track. Absent keys are sent as null.
Map<String, Object?> _meta({
  String? title = 'T',
  String? artist = 'A',
  String? album = 'Alb',
  String? albumArtist,
  int? artistId = 1,
  int? albumId = 1,
  String? genre,
  int? year,
}) => {
  'title': title,
  'artist': artist,
  'album': album,
  'album_artist': albumArtist,
  'artist_id': artistId,
  'album_id': albumId,
  'genre': genre,
  'year': year,
  'codec': 'flac',
  'duration': 10.0,
  'bitrate_kbps': 900.0,
  'sample_rate_hz': 44100,
  'channels': 2,
  'has_album_art': false,
};

Map<String, Object?> _track(String uuid, int rev, Map<String, Object?> meta) =>
    {
      'uuid_id': uuid,
      'created_at': 1,
      'last_updated': rev,
      'revision': rev,
      'metadata': meta,
    };

Map<String, Object?> _upsert(String uuid, int rev, Map<String, Object?> meta) =>
    {
      'type': 'upsert',
      'revision': rev,
      'uuid_id': uuid,
      'track': _track(uuid, rev, meta),
    };

Map<String, Object?> _delete(String uuid, int rev) =>
    {'type': 'delete', 'revision': rev, 'uuid_id': uuid};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  late AppDatabase db;
  late String token;
  late Map<int, List<Map<String, Object?>>> pages; // after_revision -> changes
  late Map<String, Map<String, Object?>> serverTracks; // GET /tracks/{uuid}
  late http.Response Function(Map<String, dynamic> body) onPatch;
  late ApiClient api;
  late int rev;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db);
    pages = {};
    serverTracks = {};
    rev = 0;
    onPatch = (_) => _json({'uuid_id': 'u1', 'revision': 99,
        'master_written': false});
    api = testApiClient(
      'http://test',
      MockClient((req) async {
        final segs = req.url.pathSegments;
        if (req.method == 'PATCH') {
          return onPatch(jsonDecode(req.body) as Map<String, dynamic>);
        }
        if (segs.first == 'changes') {
          final after = int.parse(req.url.queryParameters['after_revision']!);
          final changes = pages[after] ?? const [];
          return _json({
            'changes': changes,
            'nextCursor': null,
            'latestRevision': changes.isEmpty
                ? after
                : changes.last['revision'],
          });
        }
        if (segs.first == 'tracks' && segs.length == 2) {
          final t = serverTracks[segs[1]];
          return t == null ? http.Response('gone', 404) : _json(t);
        }
        return http.Response('not found', 404);
      }),
    );
  });

  tearDown(() => db.close());

  Future<SyncService> sync() async => SyncService(
    db: db,
    api: TracksApi(api: api),
    queueRepository: QueueRepository(db),
    prefs: await SharedPreferences.getInstance(),
    bindingToken: token,
  );

  /// Serves [changes] as the next page after the current cursor and runs
  /// one real catalog sync.
  Future<void> applyPage(List<Map<String, Object?>> changes) async {
    final cursor = await SyncCursorStore(db).read(SyncStream.catalog);
    pages[cursor] = changes;
    await (await sync()).syncChanges();
  }

  /// One page upserting [uuid] with [meta] at a fresh revision.
  Future<void> upsert(String uuid, Map<String, Object?> meta) =>
      applyPage([_upsert(uuid, ++rev, meta)]);

  EditOutbox outbox() {
    final c = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      databaseProvider.overrideWithValue(db),
      autoVerifiedGateOverride(),
      tracksApiProvider.overrideWithValue(TracksApi(api: api)),
      offlineModeProvider.overrideWith(_Online.new),
    ]);
    addTearDown(c.dispose);
    return c.read(editOutboxProvider);
  }

  Future<void> edit(EditOutbox o, String field, Object? value) => o.enqueue(
    uuidId: 'u1',
    edit: const MetadataEdit.empty().set(field, value),
    writeMode: EditWriteMode.dbOnly,
    baseRevision: rev,
  );

  /// Rewinds the catalog cursor, as a re-bind or an interrupted sync does,
  /// so the next sync re-applies pages this client already holds.
  Future<void> rewindCursor() => ServerBindingRepository(db).runFenced(
    token,
    () => SyncCursorStore(db).write(SyncStream.catalog, 0),
  );

  /// The counter's stored value; null when the row does not exist.
  Future<int?> attribution() async {
    final rows = await db
        .customSelect(
          'SELECT value FROM local_counters WHERE key = ?',
          variables: [Variable.withString('catalog_attribution')],
        )
        .get();
    return rows.isEmpty ? null : rows.single.read<int>('value');
  }

  /// Runs [write] and reports whether it moved the counter.
  Future<bool> bumps(Future<void> Function() write) async {
    final before = await attribution();
    await write();
    final after = await attribution();
    return after != before;
  }

  Future<Map<String, Object?>> row(String uuid) async => (await db
          .customSelect(
            'SELECT * FROM trackmetadata WHERE uuid_id = ?',
            variables: [Variable.withString(uuid)],
          )
          .getSingle())
      .data;

  group('catalog sync page apply', () {
    test('a page that inserts a new track bumps the counter', () async {
      expect(await attribution(), isNull, reason: 'fresh database');
      expect(await bumps(() => upsert('u1', _meta())), isTrue);
      expect(await attribution(), isNotNull);
      expect((await row('u1'))['title'], 'T', reason: 'the row was written');
    });

    test('a tombstone delete bumps the counter', () async {
      await upsert('u1', _meta());
      expect(await bumps(() => applyPage([_delete('u1', ++rev)])), isTrue);
      expect(
        await db.customSelect('SELECT * FROM trackmetadata').get(),
        isEmpty,
      );
    });

    test('a tombstone for a track this client never had does not bump',
        () async {
      await upsert('u1', _meta());
      expect(await bumps(() => applyPage([_delete('u-unknown', ++rev)])),
          isFalse);
    });
  });

  group('take-server single-track refetch', () {
    test('a 404 deletes the local track and bumps the counter', () async {
      await upsert('u1', _meta());
      expect(
        await bumps(() async => (await sync()).refetchAndApplyTrack('u1')),
        isTrue,
      );
      expect(
        await db.customSelect('SELECT * FROM trackmetadata').get(),
        isEmpty,
      );
    });
  });

  group('local reset', () {
    test('a reset leaves the counters cleared with the database', () async {
      await upsert('u1', _meta());
      await upsert('u2', _meta(title: 'T2'));
      expect(await attribution(), isNotNull);
      await db.resetLocalData();
      expect(await db.customSelect('SELECT * FROM trackmetadata').get(),
          isEmpty);
      expect(
        await db.customSelect('SELECT * FROM local_counters').get(),
        isEmpty,
        reason: 'SC-11: reset clears the counters with the database; the '
            'per-row DELETE trigger must not re-create them',
      );
    });
  });

  group('resumed sync (the WHEN guard)', () {
    test('a resumed sync re-applying identical values does not bump',
        () async {
      await applyPage([
        _upsert('u1', 1, _meta()),
        _upsert('u2', 2, _meta(title: null, albumArtist: 'AA')),
      ]);
      rev = 2;
      await rewindCursor();
      expect(await bumps(() async => (await sync()).syncChanges()), isFalse,
          reason: 'the DoUpdate upsert rewrote every column with equal values');
      expect((await row('u2'))['album_artist'], 'AA');
    });

    test('the same values at a later revision do not bump', () async {
      await upsert('u1', _meta(title: null, albumArtist: null));
      expect(await bumps(() => upsert('u1', _meta(title: null))), isFalse,
          reason: 'null to null is not a change');
    });

    test('changes outside the attribution columns do not bump', () async {
      await upsert('u1', _meta());
      expect(
        await bumps(() => upsert('u1', _meta(genre: 'Jazz', year: 1999))),
        isFalse,
      );
      expect((await row('u1'))['genre'], 'Jazz', reason: 'the row did change');
    });
  });

  group('each attribution column, through a page apply', () {
    test('title', () async {
      await upsert('u1', _meta());
      expect(await bumps(() => upsert('u1', _meta(title: 'T2'))), isTrue);
    });

    test('artist', () async {
      await upsert('u1', _meta());
      expect(await bumps(() => upsert('u1', _meta(artist: 'A2'))), isTrue);
    });

    test('album', () async {
      await upsert('u1', _meta());
      expect(await bumps(() => upsert('u1', _meta(album: 'Alb2'))), isTrue);
    });

    test('album_artist, null to a value and back to null', () async {
      await upsert('u1', _meta());
      expect(await bumps(() => upsert('u1', _meta(albumArtist: 'AA'))), isTrue,
          reason: 'null to a value is a change');
      expect(await bumps(() => upsert('u1', _meta())), isTrue,
          reason: 'a value to null is a change');
    });

    test('title, null to a value', () async {
      await upsert('u1', _meta(title: null));
      expect(await bumps(() => upsert('u1', _meta())), isTrue);
    });

    test('artist_id alone', () async {
      // No artist text on u1, so the page upserts no artist row for it and
      // only its artist_id moves; artists 1 and 2 come from other tracks.
      await upsert('u2', _meta(artist: 'P', artistId: 1, albumId: null));
      await upsert('u3', _meta(artist: 'Q', artistId: 2, albumId: null));
      Map<String, Object?> u1(int artistId) => _meta(
        artist: null,
        album: null,
        artistId: artistId,
        albumId: null,
      );
      await upsert('u1', u1(1));
      expect(await bumps(() => upsert('u1', u1(2))), isTrue);
      expect((await row('u1'))['artist_id'], 2);
    });

    test('album_id alone', () async {
      // No artist_id on u1, so the page upserts no album row for it and only
      // its album_id moves; albums 1 and 2 come from other tracks.
      await upsert('u2', _meta(artist: 'P', album: 'X', albumId: 1));
      await upsert('u3', _meta(artist: 'P', album: 'Y', albumId: 2));
      Map<String, Object?> u1(int albumId) =>
          _meta(artist: 'P', album: 'X', artistId: null, albumId: albumId);
      await upsert('u1', u1(1));
      expect(await bumps(() => upsert('u1', u1(2))), isTrue);
      expect((await row('u1'))['album_id'], 2);
    });
  });

  // No writer today updates artist_id or album_id alone (the page apply
  // rewrites every column); a future one through drift's update API must
  // still be counted (spec §3: the trigger "cannot be forgotten by a future
  // writer").
  group('a writer touching only a parent id', () {
    test('artist_id alone, through drift\'s update API', () async {
      await upsert('u2', _meta(artist: 'Q', artistId: 2, albumId: null));
      await upsert('u1', _meta(albumId: null));
      expect(
        await bumps(() => (db.update(db.trackmetadata)
              ..where((t) => t.uuidId.equals('u1')))
            .write(const TrackmetadataCompanion(artistId: Value(2)))),
        isTrue,
      );
    });

    test('album_id alone, through drift\'s update API', () async {
      await upsert('u2', _meta(album: 'Y', albumId: 2));
      await upsert('u1', _meta());
      expect(
        await bumps(() => (db.update(db.trackmetadata)
              ..where((t) => t.uuidId.equals('u1')))
            .write(const TrackmetadataCompanion(albumId: Value(2)))),
        isTrue,
      );
    });
  });

  group('take-server single-track refetch upsert', () {
    test('landing a changed title bumps; identical values do not', () async {
      await upsert('u1', _meta());
      serverTracks['u1'] = _track('u1', ++rev, _meta());
      expect(
        await bumps(() async => (await sync()).refetchAndApplyTrack('u1')),
        isFalse,
      );
      serverTracks['u1'] = _track('u1', ++rev, _meta(title: 'Server'));
      expect(
        await bumps(() async => (await sync()).refetchAndApplyTrack('u1')),
        isTrue,
      );
    });
  });

  group('optimistic edit and its revert', () {
    test('an optimistic title edit bumps', () async {
      await upsert('u1', _meta());
      final o = outbox();
      expect(await bumps(() => edit(o, 'title', 'Mine')), isTrue);
      expect((await row('u1'))['title'], 'Mine');
    });

    // The edit writes only the touched column, so the trigger's UPDATE OF
    // list (not just its WHEN guard) decides; a page apply rewrites every
    // column and cannot tell the two apart.
    for (final field in ['title', 'artist', 'album', 'album_artist']) {
      test('an optimistic edit of $field alone bumps', () async {
        await upsert('u1', _meta());
        final o = outbox();
        expect(await bumps(() => edit(o, field, 'Mine')), isTrue);
        expect((await row('u1'))[field], 'Mine');
      });
    }

    test('an optimistic edit of a non-attribution field does not bump',
        () async {
      await upsert('u1', _meta());
      final o = outbox();
      expect(await bumps(() => edit(o, 'genre', 'Jazz')), isFalse);
      expect((await row('u1'))['genre'], 'Jazz');
    });

    test('a 422 revert to the pre-edit value bumps', () async {
      await upsert('u1', _meta());
      onPatch = (_) => _json({'detail': 'refused'}, 422);
      final o = outbox();
      await edit(o, 'album', 'Rejected');
      expect(await bumps(o.flush), isTrue);
      expect((await row('u1'))['album'], 'Alb', reason: 'reverted');
    });
  });

  group('stream propagation (SC-11)', () {
    /// Every value a `local_counters` watcher sees for the counter.
    Future<List<int?>> watchCounter() async {
      final seen = <int?>[];
      final sub = db
          .customSelect(
            'SELECT (SELECT value FROM local_counters WHERE key = ?) AS v',
            variables: [Variable.withString('catalog_attribution')],
            readsFrom: {db.localCounters},
          )
          .watchSingle()
          .listen((r) => seen.add(r.read<int?>('v')));
      addTearDown(sub.cancel);
      await pumpEventQueue();
      return seen;
    }

    test('a page apply makes a local_counters watcher emit', () async {
      await upsert('u1', _meta());
      final seen = await watchCounter();
      final before = await attribution();
      expect(seen, [before]);
      await upsert('u1', _meta(title: 'T2'));
      await pumpEventQueue();
      expect(seen.length, 2, reason: 'the trackmetadata write reached '
          'local_counters watchers');
      expect(seen.last, await attribution());
      expect(seen.last, isNot(before));
    });

    test('a tombstone delete makes a local_counters watcher emit', () async {
      await upsert('u1', _meta());
      final seen = await watchCounter();
      await applyPage([_delete('u1', ++rev)]);
      await pumpEventQueue();
      expect(seen.last, await attribution());
      expect(seen, hasLength(greaterThanOrEqualTo(2)));
      expect(seen.first, isNot(seen.last));
    });

    test('an optimistic edit makes a local_counters watcher emit', () async {
      await upsert('u1', _meta());
      final o = outbox();
      final seen = await watchCounter();
      await edit(o, 'artist', 'Mine');
      await pumpEventQueue();
      expect(seen.last, await attribution());
      expect(seen.first, isNot(seen.last));
    });
  });
}
