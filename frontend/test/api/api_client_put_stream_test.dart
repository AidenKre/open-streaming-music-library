// Phase 7B.1c (plan D25): ApiClient.putStream sends a streamed request body
// (the upload content PUT) with its exact Content-Length, reports progress
// as the transport pulls the body, runs once (a transfer retry restarts the
// file under the caller's control), has no per-attempt timeout (a large file
// takes longer than any request timeout), checks the server instance stamp
// like every other response, and classifies failures like every request.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:http/http.dart' as http;

/// A scripted transport: reads the streamed body as a socket would, then
/// answers with [respond]. [onChunk] runs after each body chunk is read
/// (await it to model a slow socket).
class _StreamTransport extends http.BaseClient {
  _StreamTransport(this.respond);

  Future<http.StreamedResponse> Function(http.BaseRequest request) respond;
  Future<void> Function(int chunkIndex)? onChunk;

  /// When set, the body is never read (a server that never answers).
  bool ignoreBody = false;

  final requests = <http.BaseRequest>[];
  final received = <int>[];
  Object? bodyError;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (!ignoreBody) {
      var index = 0;
      try {
        await for (final chunk in request.finalize()) {
          received.addAll(chunk);
          await onChunk?.call(index++);
        }
      } catch (e) {
        bodyError = e;
        rethrow;
      }
    }
    return respond(request);
  }
}

http.StreamedResponse _json(
  int status,
  Object? body, {
  Map<String, String> headers = const {},
}) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

Stream<List<int>> _chunks(int count, int size) async* {
  for (var i = 0; i < count; i++) {
    yield List<int>.filled(size, i % 256);
  }
}

/// A body stream that records whether its producer was cancelled.
class _TrackedBody {
  _TrackedBody(int count, int size) {
    controller = StreamController<List<int>>(
      onListen: () async {
        for (var i = 0; i < count; i++) {
          if (cancelled) return;
          controller.add(List<int>.filled(size, 7));
          await Future<void>(() {});
        }
        if (!cancelled) await controller.close();
      },
      onCancel: () => cancelled = true,
    );
  }

  late final StreamController<List<int>> controller;
  bool cancelled = false;
  Stream<List<int>> get stream => controller.stream;
}

void main() {
  late _StreamTransport transport;
  late ApiClient client;

  setUp(() {
    transport = _StreamTransport(
      (_) async => _json(200, {'item_uuid': 'i1', 'state': 'validating'}),
    );
    client = testApiClient('http://s/api', transport);
  });

  group('putStream sends', () {
    test('a PUT of the whole body with its exact Content-Length', () async {
      final result = await client.putStream(
        ['tracks', 'uploads', 'items', 'i1', 'content'],
        body: _chunks(3, 1000),
        length: 3000,
      );

      expect(result, {'item_uuid': 'i1', 'state': 'validating'});
      expect(transport.requests, hasLength(1));
      final request = transport.requests.single;
      expect(request.method, 'PUT');
      expect(request.url.toString(),
          'http://s/api/tracks/uploads/items/i1/content');
      expect(request.contentLength, 3000);
      expect(request.headers['Content-Type'], 'application/octet-stream');
      expect(request.headers['Accept'], 'application/json');
      expect(transport.received, hasLength(3000));
    });

    test('progress is monotonic and ends at the full length', () async {
      final progress = <int>[];

      await client.putStream(
        ['x'],
        body: _chunks(5, 400),
        length: 2000,
        onProgress: progress.add,
      );

      expect(progress, isNotEmpty);
      expect(progress.first, greaterThan(0));
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
      expect(progress.last, 2000);
    });

    test('progress follows what the transport has read, not what exists',
        () async {
      final progress = <int>[];
      final seenAtChunk = <int>[];
      transport.onChunk = (i) async => seenAtChunk.add(progress.lastOrNull ?? 0);

      await client.putStream(
        ['x'],
        body: _chunks(4, 100),
        length: 400,
        onProgress: progress.add,
      );

      // When the transport had read chunk i, progress said (i + 1) * 100.
      expect(seenAtChunk, [100, 200, 300, 400]);
    });

    test('a long transfer is not cut by the per-attempt timeout', () async {
      // Zero-length timers run in order: with a zero per-attempt timeout any
      // timeout would fire before this transport answers.
      client.setPerAttemptTimeoutForTest(Duration.zero);
      transport.onChunk = (_) async {
        for (var i = 0; i < 5; i++) {
          await Future<void>(() {});
        }
      };

      final result = await client.putStream(
        ['x'],
        body: _chunks(3, 10),
        length: 30,
      );

      expect(result['state'], 'validating');
    });
  });

  group('putStream failures', () {
    test('an error answer is an ApiException with the SC-22 envelope',
        () async {
      transport.respond = (_) async => _json(409, {
        'detail': {
          'error': 'upload_transfer_in_progress',
          'message': 'busy',
          'retryable': true,
        },
      });

      await expectLater(
        client.putStream(['x'], body: _chunks(1, 10), length: 10),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'status', 409)
              .having((e) => e.errorCode, 'code', 'upload_transfer_in_progress')
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });

    test('a busy answer (503) is not retried: one request only', () async {
      transport.respond = (_) async => _json(
        503,
        {
          'detail': {
            'error': 'upload_slots_busy',
            'message': 'busy',
            'retryable': true,
            'retry_after_s': 5,
          },
        },
        headers: {'retry-after': '5'},
      );

      await expectLater(
        client.putStream(['x'], body: _chunks(1, 10), length: 10),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'status', 503)
              .having((e) => e.details?['retry_after_s'], 'retry_after_s', 5),
        ),
      );
      expect(transport.requests, hasLength(1));
    });

    test('a transport failure is a NetworkException after one attempt',
        () async {
      transport.respond = (_) async => throw const SocketException('reset');
      var offline = 0;
      client.addNetworkFailureListener(() => offline++);

      await expectLater(
        client.putStream(['x'], body: _chunks(1, 10), length: 10),
        throwsA(
          isA<NetworkException>()
              .having((e) => e.attemptsMade, 'attempts', 1),
        ),
      );
      expect(transport.requests, hasLength(1));
      expect(offline, 1);
    });

    test('an error from the body stream surfaces as itself', () async {
      Stream<List<int>> failing() async* {
        yield [1, 2, 3];
        throw const _SourceGone();
      }
      final body = failing();

      await expectLater(
        client.putStream(['x'], body: body, length: 10),
        throwsA(isA<_SourceGone>()),
      );
    });

    test('an oversized error body is not read whole', () async {
      final huge = Stream<List<int>>.fromIterable([
        for (var i = 0; i < 64; i++) List<int>.filled(64 * 1024, 0x61),
      ]);
      transport.respond = (_) async => http.StreamedResponse(huge, 500);

      await expectLater(
        client.putStream(['x'], body: _chunks(1, 10), length: 10),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'status', 500)
              .having((e) => e.message.length, 'kept', lessThanOrEqualTo(1 << 20)),
        ),
      );
    });
  });

  group('putStream abort', () {
    test('review r1 #3: an abort while the answer is read is an abort, '
        'not a network failure', () async {
      final abort = Completer<void>();
      final answer = StreamController<List<int>>();
      transport.respond = (_) async => http.StreamedResponse(answer.stream, 200);
      var offline = 0;
      client.addNetworkFailureListener(() => offline++);

      final result = client.putStream(
        ['x'],
        body: _chunks(1, 10),
        length: 10,
        abortTrigger: abort.future,
      );
      await pumpEventQueue();
      answer.add(utf8.encode('{"state":'));
      await pumpEventQueue();
      abort.complete();

      await expectLater(result, throwsA(isA<UploadTransferAborted>()));
      expect(offline, 0);
      await answer.close();
    });

    test('review r1 #6: an abort trigger that fails still aborts, '
        'and leaves no unhandled error', () async {
      final abort = Completer<void>();
      final never = Completer<http.StreamedResponse>();
      transport.respond = (_) => never.future;

      final result = client.putStream(
        ['x'],
        body: _chunks(1, 10),
        length: 10,
        abortTrigger: abort.future,
      );
      await pumpEventQueue();
      abort.completeError(StateError('watchdog gone'));

      await expectLater(result, throwsA(isA<UploadTransferAborted>()));
    });

    test('an abort mid-body stops the body and is UploadTransferAborted',
        () async {
      final abort = Completer<void>();
      final blocked = Completer<void>();
      transport.onChunk = (i) async {
        if (i == 0) {
          abort.complete();
          await blocked.future; // a socket that stopped draining
        }
      };
      final body = _TrackedBody(10, 100);

      final result = client.putStream(
        ['x'],
        body: body.stream,
        length: 1000,
        abortTrigger: abort.future,
      );

      await expectLater(result, throwsA(isA<UploadTransferAborted>()));
      expect(body.cancelled, isTrue);
      expect(transport.received.length, lessThan(1000));
    });

    test('an abort while the server holds the answer ends the call', () async {
      final abort = Completer<void>();
      final never = Completer<http.StreamedResponse>();
      transport.respond = (_) => never.future;

      final result = client.putStream(
        ['x'],
        body: _chunks(2, 10),
        length: 20,
        abortTrigger: abort.future,
      );
      await pumpEventQueue();
      abort.complete();

      await expectLater(result, throwsA(isA<UploadTransferAborted>()));
    });

    test('an abort before the transport reads anything sends no bytes',
        () async {
      final abort = Completer<void>()..complete();
      final body = _TrackedBody(3, 10);
      transport.ignoreBody = true;
      transport.respond = (_) => Completer<http.StreamedResponse>().future;

      await expectLater(
        client.putStream(
          ['x'],
          body: body.stream,
          length: 30,
          abortTrigger: abort.future,
        ),
        throwsA(isA<UploadTransferAborted>()),
      );
      expect(transport.received, isEmpty);
    });

    test('the request handed to the transport carries the abort trigger',
        () async {
      final abort = Completer<void>();

      await client.putStream(
        ['x'],
        body: _chunks(1, 10),
        length: 10,
        abortTrigger: abort.future,
      );

      expect(transport.requests.single, isA<http.Abortable>());
      expect(
        (transport.requests.single as http.Abortable).abortTrigger,
        isNotNull,
      );
    });
  });

  group('putStream instance stamp (SC-01 rule 6)', () {
    test('a foreign stamp throws the check error, never an ApiException',
        () async {
      final checked = <String>[];
      final bound = client.withInstanceCheck((stamp) async {
        checked.add(stamp);
        throw const _Foreign();
      });
      transport.respond = (_) async => _json(
        409,
        {'detail': {'error': 'x', 'retryable': true}},
        headers: {'x-server-instance-id': 'other'},
      );

      await expectLater(
        bound.putStream(['x'], body: _chunks(1, 10), length: 10),
        throwsA(isA<_Foreign>()),
      );
      expect(checked, ['other']);
      expect(transport.requests, hasLength(1));
    });

    test('a matching stamp returns the body', () async {
      final bound = client.withInstanceCheck((_) async {});
      transport.respond = (_) async => _json(
        200,
        {'state': 'validating'},
        headers: {'x-server-instance-id': 'mine'},
      );

      final result =
          await bound.putStream(['x'], body: _chunks(1, 10), length: 10);

      expect(result['state'], 'validating');
    });
  });
}

class _SourceGone implements Exception {
  const _SourceGone();
}

class _Foreign implements Exception {
  const _Foreign();
}
