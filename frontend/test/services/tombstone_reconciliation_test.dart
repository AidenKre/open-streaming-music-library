// Phase 8B.2b / 8-U08, 8-C03 and 8-C05 (unit halves), spec §6 last
// paragraph: what a sync tombstone does to the local state that still holds
// the deleted track's UUID, over real Drift (in-memory SQLite) and the real
// `SyncService`.
//
// - D26: "Resolve pending metadata outbox entries as deleted/rejected with
//   user-visible status, never PATCH-recreate." A pending or conflicted edit
//   of a tombstoned track becomes `rejected` in the tombstone's own fenced
//   transaction; no PATCH is sent for it.
// - "History play finalization for a deleted current track follows Phase 5;
//   recents skips unresolved refs, stats retains time." The tombstone never
//   touches the listening history or a listen draft; Recently Played omits
//   the deleted track.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/recently_played_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';
import 'package:frontend/services/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../repositories/catalog_seed.dart';

Map<String, Object?> _delete(String uuid, int rev) =>
    {'type': 'delete', 'revision': rev, 'uuid_id': uuid, 'track': null};

Map<String, Object?> _page(List<Map<String, Object?>> changes, int latest) =>
    {'changes': changes, 'nextCursor': null, 'latestRevision': latest};

/// The user-visible reason, written out here (not read from production).
const _gone = 'Track no longer exists on the server';

void main() {
  late AppDatabase db;
  late CatalogSeed seed;
  late String token;
  late Map<String, Object?> changes;
  late List<String> requests;
  Completer<void>? holdResponses;
  Completer<void>? requestArrived;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    seed = CatalogSeed(db);
    token = (await ServerBindingRepository(db)
            .ensureProvisional('http://test:8080'))
        .localBindingId;
    changes = _page([], 0);
    requests = [];
    holdResponses = null;
    requestArrived = null;
    await seed.artist(1, 'Aria');
    await seed.album(1, artistId: 1, name: 'One');
  });

  tearDown(() => db.close());

  Future<SyncService> service() async {
    SharedPreferences.setMockInitialValues({});
    final api = testApiClient(
      'http://test:8080',
      MockClient((req) async {
        requests.add('${req.method} ${req.url.path}');
        requestArrived?.complete();
        requestArrived = null;
        if (holdResponses != null) await holdResponses!.future;
        if (req.url.pathSegments.first == 'changes') {
          return http.Response(jsonEncode(changes), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('gone', 404);
      }),
    );
    return SyncService(
      db: db,
      api: TracksApi(api: api),
      queueRepository: QueueRepository(db),
      prefs: await SharedPreferences.getInstance(),
      bindingToken: token,
      ownedFileCleanup: OwnedFileCleanup(
        db: db,
        documentsDirectory: () async => Directory.systemTemp, // no files
        locks: OwnedPathLocks(),
      ),
    );
  }

  Future<void> edit(String uuid, String status, {String? reason}) =>
      db.into(db.pendingEdits).insert(PendingEditsCompanion.insert(
            uuidId: uuid,
            valuesJson: jsonEncode({'title': 'Mine $uuid'}),
            writeMode: 'db_only',
            baseRevision: const Value(1),
            status: Value(status),
            serverRevision: Value(status == 'conflicted' ? 7 : null),
            rejectionReason: Value(reason),
            updatedAt: 1,
          ));

  Future<Map<String, (String, String?, int?)>> edits() async => {
        for (final r in await db.select(db.pendingEdits).get())
          r.uuidId: (r.status, r.rejectionReason, r.serverRevision),
      };

  group('D26: outbox entries of a tombstoned track', () {
    setUp(() async {
      for (final u in ['u1', 'u2', 'u3', 'u4']) {
        await seed.track(u, artistId: 1, albumId: 1);
      }
    });

    test('pending and conflicted edits become rejected with the visible '
        'reason; no PATCH is sent; other tracks keep theirs', () async {
      await edit('u1', 'pending');
      await edit('u2', 'conflicted');
      await edit('u3', 'pending');
      changes = _page([_delete('u1', 2), _delete('u2', 3)], 3);

      await (await service()).syncChanges();

      expect(await edits(), {
        'u1': ('rejected', _gone, null),
        'u2': ('rejected', _gone, null),
        'u3': ('pending', null, null),
      });
      expect(requests, ['GET /changes'], reason: 'nothing but the pull');
    });

    test('an edit already rejected for another reason keeps its reason',
        () async {
      await edit('u1', 'rejected', reason: 'Field is locked');
      changes = _page([_delete('u1', 2)], 2);
      await (await service()).syncChanges();
      expect(await edits(), {'u1': ('rejected', 'Field is locked', null)});
    });

    test('a single-track refetch answering 404 rejects the same way',
        () async {
      await edit('u4', 'pending');
      await db.rebuildFtsIndexes(); // the refetch applies an FTS delta
      await (await service()).refetchAndApplyTrack('u4');
      expect(await edits(), {'u4': ('rejected', _gone, null)});
      expect(requests.where((r) => r.startsWith('PATCH')), isEmpty);
    });

    test('a page arriving after a reset fence changes no edit', () async {
      await edit('u1', 'pending');
      changes = _page([_delete('u1', 2)], 2);
      holdResponses = Completer<void>();
      final arrived = requestArrived = Completer<void>();
      final sync = (await service()).syncChanges();
      await arrived.future;
      await db.customStatement('DELETE FROM server_binding'); // reset fence
      holdResponses!.complete();
      await expectLater(sync, throwsA(isA<BindingFencedException>()));
      expect(await edits(), {'u1': ('pending', null, null)});
    });
  });

  group('history and recents', () {
    setUp(() async {
      for (final u in ['t1', 't2']) {
        await seed.track(u, artistId: 1, albumId: 1);
      }
    });

    test('the tombstone keeps every history event and the listen draft of '
        'the deleted track', () async {
      await seed.click('track', 't1', at: 100, eventUuid: 'e-click');
      await seed.click('track', 't1', at: 150, eventUuid: 'e-play',
          kind: 'play');
      await HistoryRepository(db).checkpointDraft(
        token,
        const ListenDraft(
          listenUuid: '11111111-1111-4111-8111-111111111111',
          queueSessionId: 1,
          queueItemId: 2,
          trackUuid: 't1',
          startedAt: 1800000000000,
          durationSeconds: 180,
          accumulatedMicros: 30000000,
          lastCheckpointAt: 10,
        ),
      );
      changes = _page([_delete('t1', 2)], 2);

      await (await service()).syncChanges();

      expect(await db.getTrackByUuid('t1'), isEmpty);
      expect(
        [for (final e in await db.select(db.historyEvents).get())
          (e.eventUuid, e.entityRef)],
        [('e-click', 't1'), ('e-play', 't1')],
      );
      expect(
        [for (final d in await HistoryRepository(db).drafts()) d.trackUuid],
        ['t1'],
      );
    });

    test('a draft of the deleted current track still finalizes one play',
        () async {
      const listen = '22222222-2222-4222-8222-222222222222';
      final history = HistoryRepository(db);
      await history.checkpointDraft(
        token,
        const ListenDraft(
          listenUuid: listen,
          queueSessionId: 1,
          queueItemId: 2,
          trackUuid: 't1',
          startedAt: 1800000000000,
          durationSeconds: 180,
          accumulatedMicros: 40000000,
          lastCheckpointAt: 10,
        ),
      );
      changes = _page([_delete('t1', 2)], 2);
      await (await service()).syncChanges();

      final result = await history.finalizeDraft(
        token,
        const HistoryEventPayload(
          eventUuid: listen,
          kind: 'play',
          entityType: 'track',
          entityRef: 't1',
          occurredAt: 1800000000000,
          secondsPlayed: 40,
          trackLength: 180,
        ),
      );

      expect(result, DraftFinalization.inserted);
      final plays = await db.select(db.historyEvents).get();
      expect([for (final e in plays) (e.eventUuid, e.entityRef, e.secondsPlayed)],
          [(listen, 't1', 40.0)]);
      expect(await history.drafts(), isEmpty);
    });

    test('Recently Played omits the deleted track; its clicks stay', () async {
      await seed.click('track', 't1', at: 200, eventUuid: 'e1');
      await seed.click('track', 't2', at: 100, eventUuid: 'e2');
      final recents = RecentlyPlayedRepository(db, BrowseRepository(db));
      List<String> refs(List<RecentRef> r) => [for (final x in r) x.ref];
      expect(refs(await recents.eligibleRefs(limit: 20)), ['t1', 't2']);

      changes = _page([_delete('t1', 2)], 2);
      await (await service()).syncChanges();

      expect(refs(await recents.eligibleRefs(limit: 20)), ['t2']);
      expect(
        [for (final e in await db.select(db.historyEvents).get()) e.eventUuid],
        ['e1', 'e2'],
      );
    });
  });
}
