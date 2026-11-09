// PR 5A (5-U05, 5-T08, 5-T11, 5-T15 model): one history pass = upload, then
// pull (Phase 5 §5).
//
//  * offline / unverified / no server support: no /history request; the
//    right backoff reason (capability-missing is "waiting for server history
//    support", not offline).
//  * upload: up to maxBatchesPerPass batches; ACK applied; a 409 quarantines
//    exactly the conflicting events and the healthy ones continue; a 413/422
//    quarantines the rejected batch (retained, not retried in a loop); a
//    malformed ACK clears nothing; a server/network error stops uploading
//    but the pull still runs.
//  * pull: pages from the history cursor up to maxPagesPerPass (budget ->
//    more work); a payload conflict blocks with the server events kept for
//    "Keep server version"; a regressed server is flagged; malformed pages
//    are transient failures.
//  * a fenced write (reset) ends the pass quietly.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/history_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/history/history_sync_service.dart';
import 'package:http/testing.dart';

import '../../helpers/server_binding.dart';

HistoryEventPayload _event(String uuid, {double seconds = 30.5}) =>
    HistoryEventPayload(
      eventUuid: uuid,
      kind: 'play',
      entityType: 'track',
      entityRef: 't-1',
      occurredAt: 1000,
      secondsPlayed: seconds,
    );

HistoryServerEvent _server(String uuid, int revision, {double seconds = 30.5}) =>
    HistoryServerEvent(payload: _event(uuid, seconds: seconds), revision: revision, receivedAt: 9);

/// Scripted /history server.
class _FakeApi extends HistoryApi {
  _FakeApi() : super(api: null);
  final posted = <List<String>>[];
  final pulledAfter = <int>[];
  Object? Function(HistoryUploadBatch batch) onPost = (b) => b.eventUuids;
  HistoryPage Function(int after) onChanges = (_) =>
      const HistoryPage(events: [], nextCursor: null, latestRevision: 0);

  @override
  Future<Object?> post(HistoryUploadBatch batch) async {
    posted.add(batch.eventUuids);
    return onPost(batch);
  }

  @override
  Future<HistoryPage> changes({required int after, int limit = 200}) async {
    pulledAfter.add(after);
    return onChanges(after);
  }
}

ApiException _http(int status, Map<String, Object?> detail) =>
    ApiException(status, jsonEncode({'detail': detail}));

void main() {
  late AppDatabase db;
  late String token;
  late HistoryRepository repo;
  late _FakeApi api;
  late SyncCursorStore cursors;
  var offline = false;
  var verified = true;
  var supported = true;

  setUp(() async {
    // The fake API never uses the client; any request would be a test bug.
    ApiClient.initForTest(
      'http://srv',
      MockClient((_) async => throw StateError('no real requests')),
    );
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db);
    repo = HistoryRepository(db);
    api = _FakeApi();
    cursors = SyncCursorStore(db);
    offline = false;
    verified = true;
    supported = true;
  });

  tearDown(() => db.close());

  HistorySyncService service({int batches = 10, int pages = 10, int pageSize = 200}) =>
      HistorySyncService(
        repository: repo,
        api: api,
        cursors: cursors,
        verifiedToken: () => verified ? token : null,
        isOffline: () => offline,
        supportsHistory: () async => supported,
        maxBatchesPerPass: batches,
        maxPagesPerPass: pages,
        pageSize: pageSize,
      );

  Future<Map<String, int>> pending() async => {
    for (final r in await db
        .customSelect('SELECT event_uuid, pending_upload FROM history_events')
        .get())
      r.read<String>('event_uuid'): r.read<int>('pending_upload'),
  };

  Future<Map<String, String>> failures() async => {
    for (final r in await db
        .customSelect('SELECT event_uuid, reason FROM history_sync_failures')
        .get())
      r.read<String>('event_uuid'): r.read<String>('reason'),
  };

  group('preconditions', () {
    test('offline: no request, offline wait', () async {
      offline = true;
      await repo.insertLocal(token, _event('a'));
      final out = await service().runPass({'timer'});
      expect(out, isA<PassFailed>().having((f) => f.reason, 'reason', BackoffReason.offline));
      expect(api.posted, isEmpty);
      expect(api.pulledAfter, isEmpty);
    });

    test('an unverified connection: no request, and the pass does not block',
        () async {
      verified = false;
      final out = await service().runPass({'timer'});
      expect(out, isA<PassFailed>());
      expect(api.posted, isEmpty);
      expect(api.pulledAfter, isEmpty);
    });

    test('no server support: capability wait, capture kept, status says so',
        () async {
      supported = false;
      await repo.insertLocal(token, _event('a'));
      final s = service();
      final out = await s.runPass({'coldStart'});
      expect(out, isA<PassFailed>().having((f) => f.reason, 'reason', BackoffReason.capabilityMissing));
      expect(api.posted, isEmpty);
      expect(api.pulledAfter, isEmpty);
      expect(s.status.value.waitingForServerSupport, isTrue);
      expect(await pending(), {'a': 1});
      supported = true;
      expect(await s.runPass({'appInfo'}), isA<PassDone>());
      expect(s.status.value.waitingForServerSupport, isFalse);
      expect(await pending(), {'a': 0}, reason: 'the backlog uploads once supported');
    });
  });

  // Audit 5A(a) #1: an unknown capability (app info not loaded) is a short
  // transient wait, never "the server lacks history".
  test('an unknown capability is transient, not "waiting for support"',
      () async {
    final s = HistorySyncService(
      repository: repo,
      api: api,
      cursors: cursors,
      verifiedToken: () => token,
      isOffline: () => false,
      supportsHistory: () async => null,
    );
    final out = await s.runPass({'coldStart'});
    expect(out, isA<PassFailed>().having((f) => f.reason, 'reason', BackoffReason.transient));
    expect(s.status.value.waitingForServerSupport, isFalse);
    expect(api.posted, isEmpty);
  });

  for (final loseVerification in [true, false]) {
    test('connection changes during capability load: gate=$loseVerification', () async {
      await repo.insertLocal(token, _event('waiting'));
      final entered = Completer<void>();
      final capability = Completer<bool?>();
      final s = HistorySyncService(
        repository: repo, api: api, cursors: cursors,
        verifiedToken: () => verified ? token : null,
        isOffline: () => offline,
        supportsHistory: () {
          entered.complete();
          return capability.future;
        },
      );
      final pass = s.runPass({'coldStart'});
      await entered.future;
      if (loseVerification) {
        verified = false;
      } else {
        offline = true;
      }
      capability.complete(true);
      expect(await pass, isA<PassFailed>().having(
        (f) => f.reason, 'reason', BackoffReason.offline,
      ));
      expect(api.posted, isEmpty);
      expect(api.pulledAfter, isEmpty);
      expect(await pending(), {'waiting': 1});
    });
  }

  test('losing verification after an upload prevents subsequent requests', () async {
    await repo.insertLocal(token, _event('a'));
    api.onPost = (batch) {
      verified = false;
      return batch.eventUuids;
    };
    final out = await service().runPass({'poll'});
    expect(out, isA<PassFailed>().having(
      (f) => f.reason, 'reason', BackoffReason.offline,
    ));
    expect(api.posted, [['a']]);
    expect(api.pulledAfter, isEmpty);
  });

  group('upload', () {
    test('a partial ACK stops upload for this pass but still pulls', () async {
      await repo.insertLocal(token, _event('a'));
      await repo.insertLocal(token, _event('b'));
      api.onPost = (_) => ['a'];
      final out = await service().runPass({'poll'});
      expect(out, isA<PassFailed>().having(
        (f) => f.reason, 'reason', BackoffReason.transient,
      ));
      expect(api.posted, [['a', 'b']], reason: 'no immediate resend loop');
      expect(api.pulledAfter, [0]);
      expect(await pending(), {'a': 0, 'b': 1});
    });
    test('uploads pending batches, applies the ACK, then pulls', () async {
      for (final id in ['a', 'b', 'c']) {
        await repo.insertLocal(token, _event(id));
      }
      final out = await service().runPass({'localInsert'});
      expect(out, isA<PassDone>());
      expect(api.posted, [['a', 'b', 'c']]);
      expect(await pending(), {'a': 0, 'b': 0, 'c': 0});
      expect(api.pulledAfter, [0]);
    });

    test('a 409 quarantines exactly the conflicting events; others continue',
        () async {
      for (final id in ['a', 'bad', 'c']) {
        await repo.insertLocal(token, _event(id));
      }
      api.onPost = (batch) {
        if (batch.eventUuids.contains('bad')) {
          throw _http(409, {
            'error': 'history_event_conflict',
            'message': 'conflict',
            'retryable': false,
            'conflicting_event_uuids': ['bad'],
          });
        }
        return batch.eventUuids;
      };
      final s = service();
      await s.runPass({'timer'});
      expect(await failures(), {'bad': 'conflict'});
      expect(await pending(), {'a': 0, 'bad': 1, 'c': 0}, reason: 'retained, never regenerated');
      expect(api.posted.last, ['a', 'c']);
      expect(s.status.value.lastError, isNotNull);
    });

    for (final status in [413, 422]) {
      test('a $status rejection quarantines the batch (retained, no loop)',
          () async {
        await repo.insertLocal(token, _event('a'));
        api.onPost = (_) => throw _http(status, {
          'error': 'rejected', 'message': 'no', 'retryable': false,
        });
        await service().runPass({'timer'});
        expect(await failures(), {'a': 'rejected'});
        expect(await pending(), {'a': 1});
        expect(api.posted, hasLength(1), reason: 'not resubmitted in the pass');
      });
    }

    // Audit 5A(a) #5: only the events the server names are held back.
    test('a 422 quarantines only the indexed event', () async {
      for (final id in ['a', 'bad', 'c']) {
        await repo.insertLocal(token, _event(id));
      }
      var calls = 0;
      api.onPost = (batch) {
        calls++;
        if (batch.eventUuids.contains('bad')) {
          throw ApiException(422, jsonEncode({
            'detail': [
              {'type': 'x', 'loc': ['body', 'events', batch.eventUuids.indexOf('bad'), 'kind'], 'msg': 'bad'},
            ],
          }));
        }
        return batch.eventUuids;
      };
      await service().runPass({'timer'});
      expect(await failures(), {'bad': 'rejected'});
      expect(await pending(), {'a': 0, 'bad': 1, 'c': 0});
      expect(calls, 2);
    });

    test('a 409 that names none of the batch is a protocol error, not a loop',
        () async {
      await repo.insertLocal(token, _event('a'));
      api.onPost = (_) => throw _http(409, {
        'error': 'history_event_conflict', 'message': 'x', 'retryable': false,
        'conflicting_event_uuids': ['not-in-batch'],
      });
      final out = await service().runPass({'timer'});
      expect(out, isA<PassFailed>().having((f) => f.reason, 'reason', BackoffReason.transient));
      expect(api.posted, hasLength(1));
      expect(await failures(), isEmpty);
    });

    test('a 409 without a conflict list is a protocol error too', () async {
      await repo.insertLocal(token, _event('a'));
      api.onPost = (_) => throw _http(409, {'error': 'history_event_conflict', 'message': 'x', 'retryable': false});
      final out = await service().runPass({'timer'});
      expect(out, isA<PassFailed>().having((f) => f.reason, 'reason', BackoffReason.transient));
      expect(await failures(), isEmpty);
    });

    test('a malformed ACK clears nothing and the pass fails transiently',
        () async {
      await repo.insertLocal(token, _event('a'));
      api.onPost = (_) => {'nope': 1};
      final out = await service().runPass({'timer'});
      expect(out, isA<PassFailed>().having((f) => f.reason, 'reason', BackoffReason.transient));
      expect(await pending(), {'a': 1});
      expect(await failures(), isEmpty);
    });

    test('a server error stops uploading but the pull still runs', () async {
      await repo.insertLocal(token, _event('a'));
      api.onPost = (_) => throw ApiException(503, 'busy');
      api.onChanges = (_) => HistoryPage(
        events: [_server('x', 4)], nextCursor: null, latestRevision: 4,
      );
      final out = await service().runPass({'timer'});
      expect(out, isA<PassFailed>().having((f) => f.reason, 'reason', BackoffReason.transient));
      expect(await pending(), {'a': 1, 'x': 0});
      expect(await cursors.read(SyncStream.history), 4);
    });

    test('the batch budget yields with work left', () async {
      for (var i = 0; i < 5; i++) {
        await repo.insertLocal(token, _event('e$i'));
      }
      final s = HistorySyncService(
        repository: _SmallBatchRepository(db),
        api: api,
        cursors: cursors,
        verifiedToken: () => token,
        isOffline: () => false,
        supportsHistory: () async => true,
        maxBatchesPerPass: 2,
      );
      final out = await s.runPass({'timer'});
      expect(out, isA<PassMoreWork>());
      expect(api.posted, [['e0'], ['e1']]);
    });
  });

  group('pull', () {
    test('pages from the cursor until caught up', () async {
      api.onChanges = (after) => switch (after) {
        0 => HistoryPage(events: [_server('x1', 3)], nextCursor: 3, latestRevision: 7),
        3 => HistoryPage(events: [_server('x2', 7)], nextCursor: null, latestRevision: 7),
        _ => throw StateError('unexpected after=$after'),
      };
      expect(await service().runPass({'poll'}), isA<PassDone>());
      expect(api.pulledAfter, [0, 3]);
      expect(await cursors.read(SyncStream.history), 7);
    });

    test('the page budget yields with work left', () async {
      var rev = 0;
      api.onChanges = (after) {
        rev++;
        return HistoryPage(events: [_server('x$rev', after + 1)], nextCursor: after + 1, latestRevision: 99);
      };
      final out = await service(pages: 3).runPass({'poll'});
      expect(out, isA<PassMoreWork>());
      expect(api.pulledAfter, [0, 1, 2]);
    });

    test('a payload conflict blocks the pull with the server version kept',
        () async {
      await repo.insertLocal(token, _event('mine', seconds: 30.5));
      api.onPost = (_) => <String>[]; // not acknowledged yet
      api.onChanges = (_) => HistoryPage(
        events: [_server('mine', 5, seconds: 99)], nextCursor: null, latestRevision: 5,
      );
      final s = service();
      final out = await s.runPass({'poll'});
      // Audit 5A(a) #2: a diagnostic, not a 30-minute wait that would park
      // uploads of everything else.
      expect(out, isA<PassDone>());
      expect(s.status.value.blockedConflicts.single.payload.secondsPlayed, 99);
      expect(await cursors.read(SyncStream.history), 0);
      // After "Keep server version" the next pass pages on and clears it.
      await repo.keepServerVersion(token, s.status.value.blockedConflicts.single);
      expect(await s.runPass({'retry'}), isA<PassDone>());
      expect(s.status.value.blockedConflicts, isEmpty);
      expect(await cursors.read(SyncStream.history), 5);
    });

    test('a regressed server is flagged', () async {
      await db.transaction(() => cursors.write(SyncStream.history, 50));
      api.onChanges = (_) => const HistoryPage(events: [], nextCursor: null, latestRevision: 10);
      final s = service();
      final out = await s.runPass({'poll'});
      expect(out, isA<PassDone>(), reason: 'a diagnostic; uploads continue');
      expect(s.status.value.serverRegressed, isTrue);
    });

    test('a malformed page is a transient failure', () async {
      api.onChanges = (_) => throw const FormatException('bad page');
      final s = service();
      final out = await s.runPass({'poll'});
      expect(out, isA<PassFailed>().having((f) => f.reason, 'reason', BackoffReason.transient));
      expect(s.status.value.lastError, contains('bad page'));
    });

    test('a later successful pass clears the last error', () async {
      api.onChanges = (_) => throw const FormatException('bad page');
      final s = service();
      await s.runPass({'poll'});
      api.onChanges = (_) => const HistoryPage(events: [], nextCursor: null, latestRevision: 0);
      expect(await s.runPass({'poll'}), isA<PassDone>());
      expect(s.status.value.lastError, isNull);
    });
  });

  test('a fenced write (reset) ends the pass quietly', () async {
    await repo.insertLocal(token, _event('a'));
    api.onPost = (batch) {
      return batch.eventUuids;
    };
    await ServerBindingRepository(db).fence();
    final out = await service().runPass({'timer'});
    expect(out, isA<PassDone>());
    expect(api.posted, isEmpty, reason: 'the fenced batch read stops it first');
  });
}

/// One event per batch, to exercise the batch budget.
class _SmallBatchRepository extends HistoryRepository {
  _SmallBatchRepository(super.db);
  @override
  Future<HistoryUploadBatch?> nextUploadBatch(
    String bindingToken, {
    int maxEvents = HistoryRepository.maxBatchEvents,
    int maxBytes = HistoryRepository.maxBatchBytes,
  }) => super.nextUploadBatch(bindingToken, maxEvents: 1, maxBytes: maxBytes);
}
