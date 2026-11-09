// SC-01 rule 4/5 + SC-02 for the catalog stream:
//  * page application and the `sync_cursors.catalog` advance commit in ONE
//    Drift transaction, fenced by the binding token captured when the sync
//    started (a late page after a reset writes nothing);
//  * cursor semantics are unchanged: advance to the server's validated
//    nextCursor (even on an empty page), final page -> last entry revision,
//    empty final page -> unchanged;
//  * the legacy `lastRevision` pref is moved into the row on first use;
//  * best-effort restore detection compares latestRevision with the `after`
//    the client REQUESTED.
//  * refetchAndApplyTrack (take-server) is fenced too.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _track(
  String uuid,
  int revision, {
  int albumId = 1,
  String album = 'Album',
}) => {
  'uuid_id': uuid,
  'created_at': 1,
  'last_updated': 1,
  'revision': revision,
  'metadata': {
    'title': 'title-$uuid',
    'artist': 'Artist',
    'album': album,
    'artist_id': 1,
    'album_id': albumId,
    'codec': 'flac',
    'duration': 10.0,
    'bitrate_kbps': 900.0,
    'sample_rate_hz': 44100,
    'channels': 2,
    'has_album_art': false,
  },
};

Map<String, Object?> _upsert(String uuid, int rev, {int albumId = 1, String album = 'Album'}) => {
  'type': 'upsert',
  'revision': rev,
  'uuid_id': uuid,
  'track': _track(uuid, rev, albumId: albumId, album: album),
};

Map<String, Object?> _page(
  List<Map<String, Object?>> changes, {
  int? next,
  required int latest,
}) => {'changes': changes, 'nextCursor': next, 'latestRevision': latest};

void main() {
  late AppDatabase db;
  late ServerBindingRepository binding;
  late SyncCursorStore cursors;
  late String token;
  late Map<int, Map<String, Object?>> pages; // after_revision -> response
  late List<int> requestedAfters;
  Completer<void>? holdResponses;
  Completer<void>? requestArrived;
  Map<String, Object?>? trackResponse;

  Future<SyncService> service({Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    return SyncService(
      db: db,
      api: TracksApi(),
      queueRepository: QueueRepository(db),
      prefs: await SharedPreferences.getInstance(),
      bindingToken: token,
    );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    binding = ServerBindingRepository(db);
    cursors = SyncCursorStore(db);
    token = (await binding.ensureProvisional('http://test:8080')).localBindingId;
    pages = {};
    requestedAfters = [];
    holdResponses = null;
    requestArrived = null;
    trackResponse = null;
    ApiClient.initForTest(
      'http://test:8080',
      MockClient((req) async {
        final segs = req.url.pathSegments;
        requestArrived?.complete();
        requestArrived = null;
        if (holdResponses != null) await holdResponses!.future;
        if (segs.first == 'changes') {
          final after = int.parse(req.url.queryParameters['after_revision']!);
          requestedAfters.add(after);
          final page = pages[after];
          if (page == null) return http.Response('no page for $after', 500);
          return http.Response(jsonEncode(page), 200,
              headers: {'content-type': 'application/json'});
        }
        if (segs.first == 'tracks' && trackResponse != null) {
          return http.Response(jsonEncode(trackResponse), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('not found', 404);
      }),
    );
  });

  tearDown(() => db.close());

  Future<List<String>> trackUuids() async => [
    for (final r in await db
        .customSelect('SELECT uuid_id FROM tracks ORDER BY uuid_id')
        .get())
      r.read<String>('uuid_id'),
  ];

  group('cursor semantics (unchanged, now in sync_cursors)', () {
    test('advances to nextCursor per page; final page to its last entry',
        () async {
      pages[0] = _page([_upsert('u1', 3)], next: 5, latest: 9);
      pages[5] = _page([_upsert('u2', 7)], latest: 9);
      await (await service()).syncChanges();
      expect(requestedAfters, [0, 5]);
      expect(await cursors.read(SyncStream.catalog), 7);
      expect(await trackUuids(), ['u1', 'u2']);
    });

    test('an empty non-final page still advances to nextCursor', () async {
      pages[0] = _page([], next: 4, latest: 9);
      pages[4] = _page([_upsert('u1', 6)], latest: 9);
      await (await service()).syncChanges();
      expect(requestedAfters, [0, 4]);
      expect(await cursors.read(SyncStream.catalog), 6);
    });

    test('an empty final page leaves the cursor unchanged', () async {
      await binding.runFenced(token, () => cursors.write(SyncStream.catalog, 7));
      pages[7] = _page([], latest: 7);
      await (await service()).syncChanges();
      expect(requestedAfters, [7]);
      expect(await cursors.read(SyncStream.catalog), 7);
    });

    test('the legacy lastRevision pref is used once and removed', () async {
      pages[5] = _page([_upsert('u1', 6)], latest: 6);
      final s = await service(prefs: {'lastRevision': 5});
      await s.syncChanges();
      expect(requestedAfters, [5]);
      expect(await cursors.read(SyncStream.catalog), 6);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('lastRevision'), isFalse);
    });
  });

  test('a page and its cursor advance commit atomically', () async {
    // The third entry violates the unique (name, artist) regular-album
    // index, so applying the page fails after earlier runs of it.
    pages[0] = _page([
      _upsert('u1', 1, albumId: 10, album: 'Same'),
      {'type': 'delete', 'revision': 2, 'uuid_id': 'u-missing'},
      _upsert('u2', 3, albumId: 11, album: 'Same'),
    ], latest: 3);
    await expectLater((await service()).syncChanges(), throwsA(anything));
    expect(await trackUuids(), isEmpty, reason: 'no part of the page applied');
    expect(await cursors.read(SyncStream.catalog), 0);
  });

  group('fence', () {
    test('a sync started under a fenced binding writes nothing', () async {
      pages[0] = _page([_upsert('u1', 1)], latest: 1);
      final s = await service();
      await binding.fence();
      await expectLater(s.syncChanges(), throwsA(isA<BindingFencedException>()));
      expect(await trackUuids(), isEmpty);
      expect(await cursors.read(SyncStream.catalog), 0);
    });

    test('a page that arrives after a reset is a no-op', () async {
      pages[0] = _page([_upsert('u1', 1)], latest: 1);
      final s = await service();
      holdResponses = Completer<void>();
      requestArrived = Completer<void>();
      final arrived = requestArrived!.future;
      final syncing = s.syncChanges();
      await arrived;
      await binding.fence(); // reset step 1 while the request is in flight
      holdResponses!.complete();
      await expectLater(syncing, throwsA(isA<BindingFencedException>()));
      expect(await trackUuids(), isEmpty);
      expect(await db.customSelect('SELECT * FROM sync_cursors').get(), isEmpty);
    });

    test('a take-server refetch that lands after a reset is a no-op', () async {
      trackResponse = _track('u1', 4);
      final s = await service();
      holdResponses = Completer<void>();
      requestArrived = Completer<void>();
      final arrived = requestArrived!.future;
      final refetch = s.refetchAndApplyTrack('u1');
      await arrived;
      await binding.fence();
      holdResponses!.complete();
      await expectLater(refetch, throwsA(isA<BindingFencedException>()));
      expect(await trackUuids(), isEmpty);
    });

    test('a take-server refetch applies while bound', () async {
      trackResponse = _track('u1', 4);
      await (await service()).refetchAndApplyTrack('u1');
      expect(await trackUuids(), ['u1']);
    });
  });

  group('restore detection (best effort)', () {
    test('latestRevision below the requested after is reported', () async {
      await binding.runFenced(token, () => cursors.write(SyncStream.catalog, 100));
      pages[100] = _page([], latest: 50);
      await expectLater(
        (await service()).syncChanges(),
        throwsA(
          isA<ServerRegressedException>()
              .having((e) => e.requestedAfter, 'requestedAfter', 100)
              .having((e) => e.latestRevision, 'latestRevision', 50),
        ),
      );
      expect(await cursors.read(SyncStream.catalog), 100);
    });

    test('latestRevision equal to after is a normal caught-up page', () async {
      await binding.runFenced(token, () => cursors.write(SyncStream.catalog, 100));
      pages[100] = _page([], latest: 100);
      await (await service()).syncChanges();
      expect(await cursors.read(SyncStream.catalog), 100);
    });
  });

  // SC-04 / Phase 5 §3a: after binding, the first successful COMPLETE catalog
  // sync (caught up: no more pages) sets catalog_reconciled_at_binding, in the
  // same fenced transaction as its last page. Collection refs (Phase 6) are
  // resolved only once it is set.
  group('catalog_reconciled_at_binding', () {
    Future<bool> reconciled() async {
      final rows = await db
          .customSelect(
            'SELECT catalog_reconciled_at_binding AS r FROM server_binding',
          )
          .get();
      return rows.isNotEmpty && rows.single.read<bool>('r');
    }

    test('a fresh binding is not reconciled', () async {
      expect(await reconciled(), isFalse);
    });

    test('a sync that reaches the last page marks it', () async {
      pages[0] = _page([_upsert('a', 1)], next: 1, latest: 2);
      pages[1] = _page([_upsert('b', 2)], latest: 2);
      await (await service()).syncChanges();
      expect(await reconciled(), isTrue);
    });

    test('an empty catalog that is caught up marks it', () async {
      pages[0] = _page([], latest: 0);
      await (await service()).syncChanges();
      expect(await reconciled(), isTrue);
    });

    test('a sync interrupted before the last page does not', () async {
      pages[0] = _page([_upsert('a', 1)], next: 1, latest: 2);
      // No page for after=1: the second request fails.
      await expectLater((await service()).syncChanges(), throwsA(anything));
      expect(await cursors.read(SyncStream.catalog), 1, reason: 'page 1 kept');
      expect(await reconciled(), isFalse);
    });

    test('branch audit (5A.0 m4): a detected restore clears an earlier mark',
        () async {
      await binding.runFenced(token, () => binding.markCatalogReconciledInTransaction());
      expect(await reconciled(), isTrue);
      await db.transaction(() => cursors.write(SyncStream.catalog, 5));
      pages[5] = _page([], latest: 3);
      await expectLater(
        (await service()).syncChanges(),
        throwsA(isA<ServerRegressedException>()),
      );
      expect(await reconciled(), isFalse,
          reason: 'a restored server may reissue parent ids');
    });

    test('a regressed server does not', () async {
      await db.transaction(() => cursors.write(SyncStream.catalog, 5));
      pages[5] = _page([], latest: 3);
      await expectLater(
        (await service()).syncChanges(),
        throwsA(isA<ServerRegressedException>()),
      );
      expect(await reconciled(), isFalse);
    });

    test('a sync from the old binding never marks the new one', () async {
      pages[0] = _page([_upsert('a', 1)], latest: 1);
      holdResponses = Completer<void>();
      requestArrived = Completer<void>();
      final arrived = requestArrived!.future;
      final run = (await service()).syncChanges();
      await arrived;
      await binding.fence();
      await binding.ensureProvisional('http://test:8080'); // re-bound
      holdResponses!.complete();
      await expectLater(run, throwsA(isA<BindingFencedException>()));
      expect(await reconciled(), isFalse);
    });
  });

  // Audit 5A.0(a) #7: moving the legacy watermark is a durable write too.
  test('the legacy cursor move is fenced by the binding', () async {
    final sync = await service(prefs: {'lastRevision': 42});
    await binding.fence();
    await expectLater(sync.syncChanges(), throwsA(isA<BindingFencedException>()));
    final rows = await db.customSelect('SELECT * FROM sync_cursors').get();
    expect(rows, isEmpty);
    expect((await SharedPreferences.getInstance()).getInt('lastRevision'), 42);
  });

  // Audit 5A.0(c) #1 (SC-02): the page and its cursor commit TOGETHER. A
  // cursor write that fails must roll the page back, and so must a failed
  // reconciled-flag write on the final page.
  Future<int> trackCount() async =>
      (await db.customSelect('SELECT count(*) AS n FROM tracks').getSingle())
          .read<int>('n');

  test('a failing cursor write rolls the page back', () async {
    await db.customStatement(
      'CREATE TRIGGER no_cursor BEFORE INSERT ON sync_cursors '
      "BEGIN SELECT RAISE(ABORT, 'cursor write failed'); END",
    );
    pages[0] = _page([_upsert('a', 1)], latest: 1);
    await expectLater((await service()).syncChanges(), throwsA(anything));
    expect(await trackCount(), 0, reason: 'the page did not commit alone');
  });

  test('a failing reconciled-flag write rolls the final page back', () async {
    await db.customStatement(
      'CREATE TRIGGER no_flag BEFORE UPDATE ON server_binding '
      "BEGIN SELECT RAISE(ABORT, 'flag write failed'); END",
    );
    pages[0] = _page([_upsert('a', 1)], latest: 1);
    await expectLater((await service()).syncChanges(), throwsA(anything));
    expect(await trackCount(), 0);
    expect(await cursors.read(SyncStream.catalog), 0);
  });
}
