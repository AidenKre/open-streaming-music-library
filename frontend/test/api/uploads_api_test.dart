// Phase 7B.1c: UploadsApi, the client of /tracks/uploads (spec §4, server as
// built in 7A.1d/7A.2b).
//  * OPEN-M-11 / plan §6: every request waits for the binding gate's
//    verification; while the gate is unverified no upload request is built
//    or sent.
//  * SC-01 rule 6 (DEV-7-09): every request goes through the bound client;
//    an answer stamped by another instance is never returned, the gate's
//    different-server flow runs for the connection the request used, and
//    nothing further is sent.
//  * The content PUT streams the verified source body (a changed source
//    never completes the body).
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/uploads/upload_source.dart';
import 'package:http/http.dart' as http;

import '../helpers/memory_upload_source.dart';
import '../helpers/server_binding.dart';
import '../helpers/stamped_server.dart';

const _abcdefSha256 =
    'bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721';
const _item = '11111111-1111-4111-8111-111111111111';
const _batch = '22222222-2222-4222-8222-222222222222';
const _frozenForAbort =
    '{"batch_uuid":"$_batch","items":[{"item_uuid":"$_item","filename":"a","byte_length":6,"sha256":"$_abcdefSha256"}]}';

Map<String, dynamic> _itemJson({String state = 'allocated'}) => {
  'item_uuid': _item,
  'batch_uuid': _batch,
  'parent_item_uuid': null,
  'filename': 'Song.flac',
  'selection_index': 0,
  'member_order_key': '',
  'state': state,
  'expected_bytes': 6,
  'expected_sha256': _abcdefSha256,
  'received_bytes': 0,
  'review_version': 0,
  'error': null,
  'created_at': 1,
  'updated_at': 2,
};

Map<String, dynamic> _batchJson() => {
  'batch_uuid': _batch,
  'label': null,
  'created_at': 1,
  'updated_at': 2,
  'item_count': 1,
  'state_counts': {'allocated': 1},
  'items_path': '/tracks/uploads/$_batch/items',
};

/// A scripted server: records every request (method, path+query, body
/// bytes) and answers with [answer], stamped with [stamp].
class _UploadServer extends http.BaseClient {
  String? stamp = boundInstance;
  (int, Object?) Function(String method, Uri url) answer =
      (_, _) => (200, _itemJson());
  final requests = <({String method, Uri url, List<int> body})>[];

  /// Completes when the next body chunk may be read (null: no wait).
  Future<void> Function(int chunk)? onBodyChunk;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = <int>[];
    var i = 0;
    await for (final chunk in request.finalize()) {
      body.addAll(chunk);
      await onBodyChunk?.call(i++);
    }
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
  late _UploadServer server;
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
    server = _UploadServer();
    final plain = testApiClient('http://s', server);
    api = UploadsApi(
      api: plain.withInstanceCheck(ServerBindingRepository(db).checkServedBy),
      gate: controlled.gate,
    );
  });

  tearDown(() async {
    controlled.dispose();
    await db.close();
  });

  String frozen() => AllocationRequest(
    batchUuid: _batch,
    items: const [
      AllocationItem(
        itemUuid: _item,
        filename: 'Song.flac',
        byteLength: 6,
        sha256: _abcdefSha256,
      ),
    ],
  ).toFrozenJson();

  /// Every call of the API, by name.
  Map<String, Future<Object?> Function()> calls() => {
    'allocate': () => api.allocate(frozen()),
    'getItem': () => api.getItem(_item),
    'getBatch': () => api.getBatch(_batch),
    'listBatches': () => api.listBatches(),
    'listItems': () => api.listItems(_batch),
    'cancelItem': () => api.cancelItem(_item),
    'putContent': () => api.putContent(
      _item,
      MemoryUploadSource(['abcdef'.codeUnits]),
      expectedLength: 6,
      expectedSha256: _abcdefSha256,
    ),
  };

  group('the gate (OPEN-M-11)', () {
    for (final name in [
      'allocate',
      'getItem',
      'getBatch',
      'listBatches',
      'listItems',
      'cancelItem',
      'putContent',
    ]) {
      test('$name sends nothing while the gate is unverified, then goes',
          () async {
        server.answer = (method, url) => switch (name) {
          'allocate' => (201, {
            'batch': _batchJson(),
            'items': [_itemJson()],
            'limits': <String, Object?>{},
          }),
          'getBatch' => (200, _batchJson()),
          'listBatches' => (200, {'batches': [], 'next_after': null}),
          'listItems' => (200, {'items': [], 'next_after': null}),
          _ => (200, _itemJson()),
        };
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

    test('a probe that fails keeps every request unsent', () async {
      final pending = calls()['getItem']!();
      unawaited(controlled.gate.startConnection('http://s'));
      await pumpEventQueue();
      controlled.fail(Exception('unreachable'));
      await pumpEventQueue();

      expect(controlled.gate.state, isNot(isA<BindingVerified>()));
      expect(server.requests, isEmpty);
      unawaited(pending.then<Object?>((_) => null, onError: (_) => null));
    });
  });

  group('routes (server as built)', () {
    setUp(verify);

    test('allocate POSTs the frozen body to /tracks/uploads', () async {
      server.answer = (_, _) => (201, {
        'batch': _batchJson(),
        'items': [_itemJson()],
        'limits': {'max_files_per_batch': 100},
      });

      final result = await api.allocate(frozen());

      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/tracks/uploads');
      expect(jsonDecode(utf8.decode(request.body)), jsonDecode(frozen()));
      expect(result.items.single.itemUuid, _item);
      expect(result.limits.maxFilesPerBatch, 100);
    });

    test('an exact replay (200) answers the same allocation', () async {
      server.answer = (_, _) => (200, {
        'batch': _batchJson(),
        'items': [_itemJson()],
        'limits': <String, Object?>{},
      });

      final result = await api.allocate(frozen());

      expect(result.batch.batchUuid, _batch);
    });

    test('allocate does not resend on its own (one attempt)', () async {
      server.answer = (_, _) => (503, {'detail': 'down'});

      await expectLater(api.allocate(frozen()), throwsA(isA<ApiException>()));
      expect(server.requests, hasLength(1));
    });

    test('a different body for the same batch is a 409 operation_conflict',
        () async {
      server.answer = (_, _) => (409, {
        'detail': {
          'error': 'operation_conflict',
          'message': 'different',
          'retryable': false,
        },
      });

      await expectLater(
        api.allocate(frozen()),
        throwsA(isA<ApiException>()
            .having((e) => e.errorCode, 'code', 'operation_conflict')
            .having((e) => e.retryable, 'retryable', false)),
      );
    });

    test('a limit refusal is a 413 naming the limit', () async {
      server.answer = (_, _) => (413, {
        'detail': {
          'error': 'upload_limit_exceeded',
          'message': 'too many',
          'retryable': false,
          'limit': 'max_files_per_batch',
          'limit_value': 100,
        },
      });

      await expectLater(
        api.allocate(frozen()),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'status', 413)
            .having((e) => e.details?['limit'], 'limit', 'max_files_per_batch')),
      );
    });

    test('getItem and getBatch GET their resources', () async {
      server.answer = (_, url) => url.path.contains('/items/')
          ? (200, _itemJson(state: 'validating'))
          : (200, _batchJson());

      final item = await api.getItem(_item);
      final batch = await api.getBatch(_batch);

      expect(item.state, UploadItemState.validating);
      expect(batch.itemCount, 1);
      expect(server.requests.map((r) => '${r.method} ${r.url.path}'), [
        'GET /tracks/uploads/items/$_item',
        'GET /tracks/uploads/$_batch',
      ]);
    });

    test('lists send after and limit only when given', () async {
      server.answer = (_, url) => url.path.endsWith('/items')
          ? (200, {'items': [_itemJson()], 'next_after': 'c2'})
          : (200, {'batches': [_batchJson()], 'next_after': null});

      await api.listBatches();
      final batches = await api.listBatches(after: 'c1', limit: 100);
      final items = await api.listItems(_batch, after: 'c1', limit: 50);

      expect(server.requests[0].url.path, '/tracks/uploads');
      expect(server.requests[0].url.queryParameters, isEmpty);
      expect(server.requests[1].url.queryParameters,
          {'after': 'c1', 'limit': '100'});
      expect(server.requests[2].url.path, '/tracks/uploads/$_batch/items');
      expect(server.requests[2].url.queryParameters,
          {'after': 'c1', 'limit': '50'});
      expect(batches.nextAfter, isNull);
      expect(items.nextAfter, 'c2');
      expect(items.items.single.itemUuid, _item);
    });

    test('an unknown item is a 404 upload_item_not_found', () async {
      server.answer = (_, _) => (404, {
        'detail': {
          'error': 'upload_item_not_found',
          'message': 'Upload item not found.',
          'retryable': false,
        },
      });

      await expectLater(
        api.getItem(_item),
        throwsA(isA<ApiException>()
            .having((e) => e.errorCode, 'code', 'upload_item_not_found')),
      );
    });

    test('cancelItem DELETEs the item and returns it', () async {
      server.answer = (_, _) => (200, _itemJson(state: 'cancelled'));

      final item = await api.cancelItem(_item);

      expect(server.requests.single.method, 'DELETE');
      expect(server.requests.single.url.path, '/tracks/uploads/items/$_item');
      expect(item.state, UploadItemState.cancelled);
    });

    test('putContent streams the source to the content route', () async {
      server.answer = (_, _) => (200, _itemJson(state: 'validating'));
      final progress = <int>[];

      final item = await api.putContent(
        _item,
        MemoryUploadSource(['ab'.codeUnits, 'cd'.codeUnits, 'ef'.codeUnits]),
        expectedLength: 6,
        expectedSha256: _abcdefSha256,
        onProgress: progress.add,
      );

      final request = server.requests.single;
      expect(request.method, 'PUT');
      expect(request.url.path, '/tracks/uploads/items/$_item/content');
      expect(String.fromCharCodes(request.body), 'abcdef');
      expect(progress.last, 6);
      expect(item.state, UploadItemState.validating);
    });

    test('putContent of a changed source never completes the body', () async {
      final received = <int>[];
      server.onBodyChunk = (_) async {};
      final source =
          MemoryUploadSource(['ab'.codeUnits, 'cd'.codeUnits, 'eX'.codeUnits]);

      await expectLater(
        api.putContent(
          _item,
          source,
          expectedLength: 6,
          expectedSha256: _abcdefSha256,
        ),
        throwsA(isA<UploadSourceChanged>()
            .having((e) => e.change, 'change', SourceChange.digest)),
      );
      for (final r in server.requests) {
        received.addAll(r.body);
      }
      expect(received.length, lessThan(6));
    });

    test('a busy slot answer carries retryable and retry_after_s', () async {
      server.answer = (_, _) => (503, {
        'detail': {
          'error': 'upload_slots_busy',
          'message': 'busy',
          'retryable': true,
          'retry_after_s': 5,
        },
      });

      await expectLater(
        api.putContent(
          _item,
          MemoryUploadSource(['abcdef'.codeUnits]),
          expectedLength: 6,
          expectedSha256: _abcdefSha256,
        ),
        throwsA(isA<ApiException>()
            .having((e) => e.retryable, 'retryable', true)
            .having((e) => e.retryAfter, 'after', const Duration(seconds: 5))),
      );
      expect(server.requests, hasLength(1));
    });

    test('an abort stops the content transfer', () async {
      final abort = Completer<void>();
      final hold = Completer<void>();
      server.onBodyChunk = (i) async {
        if (i == 0) {
          abort.complete();
          await hold.future;
        }
      };
      final source = MemoryUploadSource([
        for (var i = 0; i < 6; i++) 'x'.codeUnits,
      ]);

      await expectLater(
        api.putContent(
          _item,
          source,
          expectedLength: 6,
          expectedSha256: _abcdefSha256,
          abortTrigger: abort.future,
        ),
        throwsA(isA<UploadTransferAborted>()),
      );
      await pumpEventQueue();
      expect(source.openStreams, 0);
    });
  });

  group('review r1 #2: an abort reaches a call waiting at the gate', () {
    final cases = <String, Future<Object?> Function(UploadsApi, Future<void>)>{
      'allocate': (a, abort) => a.allocate(_frozenForAbort, abortTrigger: abort),
      'getItem': (a, abort) => a.getItem(_item, abortTrigger: abort),
      'getBatch': (a, abort) => a.getBatch(_batch, abortTrigger: abort),
      'listBatches': (a, abort) => a.listBatches(abortTrigger: abort),
      'listItems': (a, abort) => a.listItems(_batch, abortTrigger: abort),
      'cancelItem': (a, abort) => a.cancelItem(_item, abortTrigger: abort),
      'putContent': (a, abort) => a.putContent(
        _item,
        MemoryUploadSource(['abcdef'.codeUnits]),
        expectedLength: 6,
        expectedSha256: _abcdefSha256,
        abortTrigger: abort,
      ),
    };
    for (final MapEntry(key: name, value: call) in cases.entries) {
      test('$name ends as aborted and sends nothing', () async {
        final abort = Completer<void>();
        final result = call(api, abort.future);
        await pumpEventQueue();
        abort.complete();

        await expectLater(result, throwsA(isA<UploadTransferAborted>()));
        await verify();
        await pumpEventQueue();
        expect(server.requests, isEmpty);
      });
    }

    test('an abort that already fired sends nothing even once verified',
        () async {
      await verify();
      final abort = Completer<void>()..complete();

      await expectLater(
        api.getItem(_item, abortTrigger: abort.future),
        throwsA(isA<UploadTransferAborted>()),
      );
      expect(server.requests, isEmpty);
    });
  });

  group('another server answers (SC-01 rule 6)', () {
    setUp(verify);

    for (final name in ['allocate', 'getItem', 'cancelItem', 'putContent']) {
      test('$name: the answer is not returned and the gate blocks', () async {
        server.stamp = otherInstance;
        server.answer = (_, _) => (200, _itemJson());

        await expectLater(
          calls()[name]!(),
          throwsA(isA<ServerInstanceChangedException>()),
        );
        expect(
          controlled.gate.state,
          isA<BindingDifferentServer>()
              .having((s) => s.serverInstanceId, 'server', otherInstance),
        );

        // Nothing further goes out: the next call waits at the gate.
        final sent = server.requests.length;
        unawaited(calls()['getItem']!().then<Object?>((_) => null, onError: (_) => null));
        await pumpEventQueue();
        expect(server.requests.length, sent);
      });
    }

    test('an error status from another server is not an ApiException',
        () async {
      server.stamp = otherInstance;
      server.answer = (_, _) => (409, {
        'detail': {'error': 'operation_conflict', 'retryable': false},
      });

      await expectLater(
        api.allocate(frozen()),
        throwsA(isA<ServerInstanceChangedException>()),
      );
    });

    test('a pre-Phase-7 server (no stamp) is accepted', () async {
      server.stamp = null;

      final item = await api.getItem(_item);

      expect(item.itemUuid, _item);
      expect(controlled.gate.state, isA<BindingVerified>());
    });
  });

  group('provider', () {
    test('uploadsApiProvider uses the bound client and the scope gate',
        () async {
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(testApiClient('http://s', server)),
          serverBindingGateProvider.overrideWithValue(controlled.gate),
        ],
      );
      addTearDown(c.dispose);
      await verify();
      server.stamp = otherInstance;

      await expectLater(
        c.read(uploadsApiProvider).getItem(_item),
        throwsA(isA<ServerInstanceChangedException>()),
      );
      expect(controlled.gate.state, isA<BindingDifferentServer>());
    });
  });
}
