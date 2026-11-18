// Phase 7B.2c S2: the review requests of /tracks/uploads (spec §4, server as
// built in 7A.2c / 7A.3a / 7A.3b): commit, resolve-duplicate and retry, and
// the HTTP review transport the upload manager sends commit and
// resolve-duplicate through.
//  * Every request waits for the binding gate and goes through the bound
//    client: an answer stamped by another instance is never returned, the
//    gate's different-server flow runs, nothing further is sent (SC-01).
//  * One attempt each: a mutation is never resent by the transport.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/uploads/upload_review_transport.dart';
import 'package:http/http.dart' as http;

import '../helpers/server_binding.dart';
import '../helpers/stamped_server.dart';

const _item = '11111111-1111-4111-8111-111111111111';
const _batch = '22222222-2222-4222-8222-222222222222';
const _track = '33333333-3333-4333-8333-333333333333';
const _op = '55555555-5555-4555-8555-555555555555';

Map<String, dynamic> _itemJson({
  String state = 'committing',
  int reviewVersion = 1,
  String? resultTrack,
}) => {
  'item_uuid': _item,
  'batch_uuid': _batch,
  'parent_item_uuid': null,
  'filename': 'Song.flac',
  'selection_index': 0,
  'member_order_key': '',
  'state': state,
  'expected_bytes': 6,
  'expected_sha256': null,
  'received_bytes': 6,
  'review_version': reviewVersion,
  'error': null,
  'created_at': 1,
  'updated_at': 2,
  'result_track_uuid': resultTrack,
};

const _commitBody =
    '{"base_review_version":1,"edits":{"title":"A"},"write_tags":false,'
    '"acknowledged_duplicates":{"library_tracks":[],"staged_items":[]},'
    '"operation_uuid":"$_op"}';
const _resolveBody =
    '{"expected_review_version":1,"existing_track_uuid":"$_track",'
    '"operation_uuid":"$_op"}';

/// Records every request and answers with [answer], stamped with [stamp].
class _Server extends http.BaseClient {
  String? stamp = boundInstance;
  (int, Object?) Function(String method, Uri url) answer =
      (_, _) => (202, _itemJson());
  final requests = <({String method, Uri url, String body})>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().bytesToString();
    requests.add((method: request.method, url: request.url, body: body));
    final (status, json) = answer(request.method, request.url);
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(json))),
      status,
      headers: {
        'content-type': 'application/json',
        'x-server-instance-id': ?stamp,
      },
    );
  }
}

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late _Server server;
  late UploadsApi api;

  Future<void> verify() async {
    unawaited(controlled.gate.startConnection('http://s'));
    await pumpEventQueue();
    controlled.respond(boundInstance);
    await pumpEventQueue();
    expect(controlled.gate.state, isA<BindingVerified>());
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: boundInstance);
    controlled = ControlledGate(db);
    server = _Server();
    api = UploadsApi(
      api: testApiClient(
        'http://s',
        server,
      ).withInstanceCheck(ServerBindingRepository(db).checkServedBy),
      gate: controlled.gate,
    );
  });

  tearDown(() async {
    controlled.dispose();
    await db.close();
  });

  Map<String, Future<Object?> Function()> calls() => {
    'commit': () => api.commit(_item, _commitBody),
    'resolveDuplicate': () => api.resolveDuplicate(_item, _resolveBody),
    'retry': () => api.retry(_item, expectedReviewVersion: 3),
  };

  group('the gate', () {
    for (final name in ['commit', 'resolveDuplicate', 'retry']) {
      test('$name sends nothing while the gate is unverified, then goes',
          () async {
        var done = false;
        final call = calls()[name]!().whenComplete(() => done = true);
        await pumpEventQueue();
        expect(server.requests, isEmpty);
        expect(done, isFalse);

        await verify();
        await call;
        expect(server.requests, hasLength(1));
      });
    }
  });

  group('routes (server as built)', () {
    setUp(verify);

    test('commit POSTs the frozen body to the item commit route and reads '
        'the accepted item (202)', () async {
      server.answer = (_, _) => (202, _itemJson(state: 'committing'));

      final item = await api.commit(_item, _commitBody);

      final r = server.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/tracks/uploads/items/$_item/commit');
      expect(jsonDecode(r.body), jsonDecode(_commitBody));
      expect(item.rawState, 'committing');
    });

    test('a commit replay once ended (200) reads the final item', () async {
      server.answer = (_, _) =>
          (200, _itemJson(state: 'imported', resultTrack: _track));

      final item = await api.commit(_item, _commitBody);

      expect(item.rawState, 'imported');
      expect(item.resultTrackUuid, _track);
    });

    test('resolve-duplicate POSTs the frozen body to its route', () async {
      server.answer = (_, _) =>
          (200, _itemJson(state: 'duplicate', resultTrack: _track));

      final item = await api.resolveDuplicate(_item, _resolveBody);

      final r = server.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/tracks/uploads/items/$_item/resolve-duplicate');
      expect(jsonDecode(r.body), jsonDecode(_resolveBody));
      expect(item.rawState, 'duplicate');
    });

    test('retry POSTs the expected review version and reads the item',
        () async {
      server.answer = (_, _) =>
          (200, _itemJson(state: 'validating', reviewVersion: 4));

      final item = await api.retry(_item, expectedReviewVersion: 3);

      final r = server.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/tracks/uploads/items/$_item/retry');
      expect(jsonDecode(r.body), {'expected_review_version': 3});
      expect(item.reviewVersion, 4);
    });

    test('a stale version is an ApiException with its code and the current '
        'version', () async {
      server.answer = (_, _) => (409, {
        'detail': {
          'error': 'upload_review_version_conflict',
          'message': 'changed',
          'retryable': false,
          'review_version': 2,
        },
      });

      await expectLater(
        api.commit(_item, _commitBody),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'status', 409)
            .having((e) => e.errorCode, 'code',
                'upload_review_version_conflict')),
      );
    });

    for (final name in ['commit', 'resolveDuplicate', 'retry']) {
      test('$name is sent once (no transport retry of a mutation)', () async {
        server.answer = (_, _) => (503, {'detail': 'down'});

        await expectLater(calls()[name]!(), throwsA(isA<ApiException>()));
        expect(server.requests, hasLength(1));
      });
    }
  });

  group('another server answers (SC-01 rule 6)', () {
    setUp(verify);

    for (final name in ['commit', 'resolveDuplicate', 'retry']) {
      test('$name: the answer is not returned and the gate blocks', () async {
        server.stamp = otherInstance;

        await expectLater(
          calls()[name]!(),
          throwsA(isA<ServerInstanceChangedException>()),
        );
        expect(controlled.gate.state, isA<BindingDifferentServer>());

        final sent = server.requests.length;
        unawaited(api
            .getItem(_item)
            .then<Object?>((_) => null, onError: (_) => null));
        await pumpEventQueue();
        expect(server.requests.length, sent);
      });
    }
  });

  group('the HTTP review transport', () {
    setUp(verify);

    test('a commit goes to the commit route and answers the item JSON',
        () async {
      server.answer = (_, _) => (202, _itemJson(state: 'committing'));

      final json = await HttpUploadReviewTransport(api)
          .send(ReviewActionKind.commit, _item, _commitBody);

      expect(server.requests.single.url.path,
          '/tracks/uploads/items/$_item/commit');
      expect(json['state'], 'committing');
      expect(json['item_uuid'], _item);
    });

    test('a resolve-duplicate goes to its route', () async {
      server.answer = (_, _) =>
          (200, _itemJson(state: 'duplicate', resultTrack: _track));

      final json = await HttpUploadReviewTransport(api)
          .send(ReviewActionKind.resolveDuplicate, _item, _resolveBody);

      expect(server.requests.single.url.path,
          '/tracks/uploads/items/$_item/resolve-duplicate');
      expect(json['state'], 'duplicate');
    });

    test('an abort before the gate verifies sends nothing', () async {
      controlled.dispose();
      controlled = ControlledGate(db);
      api = UploadsApi(
        api: testApiClient('http://s', server),
        gate: controlled.gate,
      );
      final abort = Completer<void>();
      final call = HttpUploadReviewTransport(api).send(
        ReviewActionKind.commit,
        _item,
        _commitBody,
        abortTrigger: abort.future,
      );
      abort.complete();
      await expectLater(call, throwsA(anything));
      expect(server.requests, isEmpty);
    });

    test('the provider default is the HTTP transport on the scope API',
        () async {
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(testApiClient('http://s', server)),
          serverBindingGateProvider.overrideWithValue(controlled.gate),
        ],
      );
      addTearDown(c.dispose);

      final json = await c
          .read(uploadReviewTransportProvider)
          .send(ReviewActionKind.commit, _item, _commitBody);

      expect(json['state'], 'committing');
      expect(server.requests.single.url.path,
          '/tracks/uploads/items/$_item/commit');
    });
  });
}
