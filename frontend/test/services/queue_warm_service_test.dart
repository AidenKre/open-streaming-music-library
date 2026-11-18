import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/token_permit.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/queue_warm_service.dart';

class _FakeQueueRepo implements QueueRepository {
  final List<QueuePlaybackEntry> entries;
  int callCount = 0;
  int? lastStartPlayPosition;
  int? lastLimit;
  Object? readError;
  _FakeQueueRepo(this.entries);

  @override
  Future<List<QueuePlaybackEntry>> getPlaybackEntries(
    int sessionId, {
    int startPlayPosition = 0,
    int? limit,
  }) async {
    callCount++;
    final error = readError;
    if (error != null) throw error;
    lastStartPlayPosition = startPlayPosition;
    lastLimit = limit;
    return entries
        .where((e) => e.playPosition >= startPlayPosition)
        .take(limit ?? entries.length)
        .toList();
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

QueuePlaybackEntry _entry(String uuid, int itemId) => QueuePlaybackEntry(
      itemId: itemId,
      queueType: QueueItemTypes.main,
      canonicalPosition: itemId,
      playPosition: itemId,
      uuidId: uuid,
    );

ApiClient _api = testApiClient(
  'http://test:8080',
  MockClient((_) async => throw StateError('no client installed')),
);

void _installMockClient(http.Client client) {
  _api = testApiClient('http://test:8080', client);
}

/// Runs [body] in testWidgets' FakeAsync zone so the service's 500 ms debounce
/// timers fire in virtual time via tester.pump(duration). Uncaught async
/// errors still fail the test.
void _fakeTest(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, body);
}

/// Refuses the token: the server is not verified (sign-off OPEN-M-11).
class _Refuse implements TokenPermit {
  @override
  bool allowsTokenTo(Uri url) => false;
  @override
  Future<void> verdictSettled() async {}
}

void main() {
  // Sign-off OPEN-M-11: while the server is not verified the token client
  // withholds the warm-up. It is advisory: one log line, no retry, and no
  // unhandled error (testWidgets fails on one).
  group('while the server is not verified', () {
    late int requests;
    setUp(() {
      requests = 0;
      _api = testApiClient(
        'http://test:8080',
        AuthenticatedClient(
          MockClient((req) async {
            requests++;
            return http.Response('', 204);
          }),
          const Credentials(
              token: 't', mediaToken: 'm', userId: 1, username: 'u'),
          permit: _Refuse(),
        ),
      );
    });

    _fakeTest('scheduleWarm sends nothing and raises no error',
        (tester) async {
      final service = QueueWarmService(
        apiClient: _api,
        queueRepo: _FakeQueueRepo([_entry('a', 0), _entry('b', 1)]),
      );
      addTearDown(service.dispose);
      service.scheduleWarm(sessionId: 7, currentPlayPosition: 0, quality: '256');
      await tester.pump(const Duration(milliseconds: 700));
      expect(requests, 0);
    });

    _fakeTest('scheduleWarmUuids sends nothing and raises no error',
        (tester) async {
      final service = QueueWarmService(
        apiClient: _api,
        queueRepo: _FakeQueueRepo(const []),
      );
      addTearDown(service.dispose);
      service.scheduleWarmUuids(['a', 'b'], quality: '256');
      await tester.pump(const Duration(milliseconds: 700));
      expect(requests, 0);
    });
  });

  // U20-FE-QUEUE-B-10: warming is advisory; nothing in it may raise an
  // unhandled error from its timer (testWidgets fails on one).
  _fakeTest('U20-FE-QUEUE-B-10: a failing queue read is logged, not raised',
      (tester) async {
    var requests = 0;
    _installMockClient(MockClient((req) async {
      requests++;
      return http.Response('', 204);
    }));
    final repo = _FakeQueueRepo([_entry('a', 0)])
      ..readError = StateError('database closed');
    final service = QueueWarmService(apiClient: _api, queueRepo: repo);
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 7, currentPlayPosition: 0, quality: '256');
    await tester.pump(const Duration(milliseconds: 700));

    expect(repo.callCount, 1);
    expect(requests, 0);
  });

  _fakeTest('U20-FE-QUEUE-B-10: an unexpected error from the request is '
      'logged, not raised', (tester) async {
    _installMockClient(MockClient((req) async => throw StateError('boom')));
    final service = QueueWarmService(
      apiClient: _api,
      queueRepo: _FakeQueueRepo([_entry('a', 0)]),
    );
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 7, currentPlayPosition: 0, quality: '256');
    await tester.pump(const Duration(milliseconds: 700));
  });

  _fakeTest('scheduleWarm POSTs to /tracks/warm after the debounce', (tester) async {
    Uri? capturedUrl;
    Map<String, dynamic>? capturedBody;
    _installMockClient(MockClient((req) async {
      capturedUrl = req.url;
      capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('', 204);
    }));
    final service = QueueWarmService(
      apiClient: _api,
      queueRepo: _FakeQueueRepo([_entry('a', 0), _entry('b', 1)]),
    );
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 7, currentPlayPosition: 0, quality: '256');

    await tester.pump(const Duration(milliseconds: 700));

    expect(capturedUrl?.path, '/tracks/warm');
    expect(capturedBody?['session_id'], '7');
    expect(capturedBody?['current_index'], 0);
    expect(capturedBody?['quality'], '256');
    expect(capturedBody?['track_uuids'], ['a', 'b']);
  });

  // Review r1 m-R1-30: the queue-path warm also waits while offline or
  // signed out (the 401 signed-out reason turns offline on); with a queue
  // that has entries, only the guard stops the POST.
  _fakeTest('scheduleWarm sends nothing while offline or signed out', (tester) async {
    var requests = 0;
    _installMockClient(MockClient((req) async {
      requests++;
      return http.Response('', 204);
    }));
    final service = QueueWarmService(
      apiClient: _api,
      queueRepo: _FakeQueueRepo([_entry('a', 0), _entry('b', 1)]),
      isOfflineFn: () => true,
    );
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 7, currentPlayPosition: 0, quality: '256');
    await tester.pump(const Duration(milliseconds: 700));

    expect(requests, 0);
  });

  _fakeTest('respects currentPlayPosition when fetching entries', (tester) async {
    final repo = _FakeQueueRepo([
      _entry('a', 0),
      _entry('b', 1),
      _entry('c', 2),
    ]);
    Map<String, dynamic>? capturedBody;
    _installMockClient(MockClient((req) async {
      capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('', 204);
    }));
    final service = QueueWarmService(apiClient: _api, queueRepo: repo);
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 1, currentPlayPosition: 1, quality: '192');
    await tester.pump(const Duration(milliseconds: 700));

    expect(repo.lastStartPlayPosition, 1);
    expect(capturedBody?['track_uuids'], ['b', 'c']);
  });

  _fakeTest('debounces rapid calls into a single POST', (tester) async {
    var postCount = 0;
    _installMockClient(MockClient((req) async {
      postCount++;
      return http.Response('', 204);
    }));
    final service = QueueWarmService(
      apiClient: _api,
      queueRepo: _FakeQueueRepo([_entry('a', 0)]),
    );
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');
    service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');
    service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');

    await tester.pump(const Duration(milliseconds: 700));
    expect(postCount, 1);
  });

  _fakeTest('does nothing when sessionId is null', (tester) async {
    var postCount = 0;
    final repo = _FakeQueueRepo([_entry('a', 0)]);
    _installMockClient(MockClient((_) async {
      postCount++;
      return http.Response('', 204);
    }));
    final service = QueueWarmService(apiClient: _api, queueRepo: repo);
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: null, currentPlayPosition: 0, quality: '320');
    await tester.pump(const Duration(milliseconds: 700));

    expect(postCount, 0);
    expect(repo.callCount, 0);
  });

  _fakeTest('does not POST when the queue is empty', (tester) async {
    var postCount = 0;
    _installMockClient(MockClient((_) async {
      postCount++;
      return http.Response('', 204);
    }));
    final service = QueueWarmService(apiClient: _api, queueRepo: _FakeQueueRepo([]));
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');
    await tester.pump(const Duration(milliseconds: 700));
    expect(postCount, 0);
  });

  _fakeTest('caps the request body at 50 track UUIDs', (tester) async {
    Map<String, dynamic>? capturedBody;
    final repo = _FakeQueueRepo([
      for (var i = 0; i < 100; i++) _entry('uuid-$i', i),
    ]);
    _installMockClient(MockClient((req) async {
      capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('', 204);
    }));
    final service = QueueWarmService(apiClient: _api, queueRepo: repo);
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');
    await tester.pump(const Duration(milliseconds: 700));

    expect((capturedBody!['track_uuids'] as List).length, 50);
  });

  _fakeTest('swallows POST errors so callers never see them', (tester) async {
    _installMockClient(MockClient((_) async {
      throw const SocketException('simulated network failure');
    }));
    final service = QueueWarmService(
      apiClient: _api,
      queueRepo: _FakeQueueRepo([_entry('a', 0)]),
    );
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');
    // Retries run instantly (delay mocked to no-op via initForTest), then the
    // NetworkException is caught and swallowed inside the service.
    await tester.pump(const Duration(milliseconds: 700));
  });

  group('scheduleWarmUuids', () {
    _fakeTest('POSTs to /tracks/warm with null session_id after debounce',
        (tester) async {
      Uri? capturedUrl;
      Map<String, dynamic>? capturedBody;
      _installMockClient(MockClient((req) async {
        capturedUrl = req.url;
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }));
      final service = QueueWarmService(apiClient: _api, queueRepo: _FakeQueueRepo([]));
      addTearDown(service.dispose);

      service.scheduleWarmUuids(['uuid-1', 'uuid-2'], quality: '256');

      await tester.pump(const Duration(milliseconds: 700));

      expect(capturedUrl?.path, '/tracks/warm');
      // The download-driven path must NOT send a magic string here; the
      // backend ignores session_id, and a literal like 'download-manager'
      // could collide with a real session id.
      expect(capturedBody?.containsKey('session_id'), isTrue);
      expect(capturedBody?['session_id'], isNull);
      expect(capturedBody?['quality'], '256');
      expect(capturedBody?['track_uuids'], ['uuid-1', 'uuid-2']);
      // count tells the backend to warm the whole batch, not just its default
      // look-ahead window.
      expect(capturedBody?['count'], 2);
    });

    _fakeTest('respects the 50-UUID cap', (tester) async {
      Map<String, dynamic>? capturedBody;
      _installMockClient(MockClient((req) async {
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }));
      final service = QueueWarmService(apiClient: _api, queueRepo: _FakeQueueRepo([]));
      addTearDown(service.dispose);

      final sixtyUuids = List.generate(60, (i) => 'uuid-$i');
      service.scheduleWarmUuids(sixtyUuids, quality: '128');

      await tester.pump(const Duration(milliseconds: 700));

      expect((capturedBody!['track_uuids'] as List).length, 50);
    });

    _fakeTest('debounces rapid calls into one POST that accumulates all uuids',
        (tester) async {
      var postCount = 0;
      Map<String, dynamic>? capturedBody;
      _installMockClient(MockClient((req) async {
        postCount++;
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }));
      final service = QueueWarmService(apiClient: _api, queueRepo: _FakeQueueRepo([]));
      addTearDown(service.dispose);

      service.scheduleWarmUuids(['a'], quality: '128');
      service.scheduleWarmUuids(['b'], quality: '128');
      service.scheduleWarmUuids(['c'], quality: '128');

      await tester.pump(const Duration(milliseconds: 700));
      expect(postCount, 1);
      // Earlier batches must NOT be dropped — all three uuids are warmed.
      expect(capturedBody?['track_uuids'], ['a', 'b', 'c']);
      expect(capturedBody?['count'], 3);
    });

    _fakeTest('dedupes repeated uuids across rapid calls', (tester) async {
      Map<String, dynamic>? capturedBody;
      _installMockClient(MockClient((req) async {
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }));
      final service = QueueWarmService(apiClient: _api, queueRepo: _FakeQueueRepo([]));
      addTearDown(service.dispose);

      service.scheduleWarmUuids(['a', 'b'], quality: '128');
      service.scheduleWarmUuids(['b', 'c'], quality: '128');

      await tester.pump(const Duration(milliseconds: 700));
      expect(capturedBody?['track_uuids'], ['a', 'b', 'c']);
    });

    _fakeTest('accumulated uuids at different qualities fire one POST each',
        (tester) async {
      final captured = <Map<String, dynamic>>[];
      _installMockClient(MockClient((req) async {
        captured.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response('', 204);
      }));
      final service = QueueWarmService(apiClient: _api, queueRepo: _FakeQueueRepo([]));
      addTearDown(service.dispose);

      service.scheduleWarmUuids(['a'], quality: '128');
      service.scheduleWarmUuids(['b'], quality: '256');

      await tester.pump(const Duration(milliseconds: 700));
      expect(captured.length, 2);
      final lo = captured.firstWhere((b) => b['quality'] == '128');
      final hi = captured.firstWhere((b) => b['quality'] == '256');
      expect(lo['track_uuids'], ['a']);
      expect(hi['track_uuids'], ['b']);
    });

    _fakeTest('swallows POST errors', (tester) async {
      _installMockClient(MockClient((_) async {
        throw const SocketException('simulated network failure');
      }));
      final service = QueueWarmService(apiClient: _api, queueRepo: _FakeQueueRepo([]));
      addTearDown(service.dispose);

      service.scheduleWarmUuids(['uuid-1'], quality: '128');
      await tester.pump(const Duration(milliseconds: 700));
    });

    _fakeTest('does nothing when list is empty', (tester) async {
      var postCount = 0;
      _installMockClient(MockClient((_) async {
        postCount++;
        return http.Response('', 204);
      }));
      final service = QueueWarmService(apiClient: _api, queueRepo: _FakeQueueRepo([]));
      addTearDown(service.dispose);

      service.scheduleWarmUuids([], quality: '128');
      await tester.pump(const Duration(milliseconds: 700));
      expect(postCount, 0);
    });

    _fakeTest('does not retry on a transient 503 (warm is single-shot, advisory)',
        (tester) async {
      var calls = 0;
      _installMockClient(MockClient((_) async {
        calls++;
        return http.Response('try again', 503);
      }));
      final service = QueueWarmService(apiClient: _api, queueRepo: _FakeQueueRepo([]));
      addTearDown(service.dispose);

      service.scheduleWarmUuids(['uuid-1'], quality: '128');
      await tester.pump(const Duration(milliseconds: 700));

      // Warm POSTs do NOT opt into retry — a transient 503 surfaces once,
      // is logged and swallowed by the service. The server may still warm
      // on the next debounced schedule; we don't burn attempts here.
      expect(calls, 1);
    });

    _fakeTest('queue warm scheduled first does not cancel a later uuids warm; both fire',
        (tester) async {
      final captured = <Map<String, dynamic>>[];
      _installMockClient(MockClient((req) async {
        captured.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response('', 204);
      }));
      final service = QueueWarmService(
        apiClient: _api,
        queueRepo: _FakeQueueRepo([_entry('a', 0)]),
      );
      addTearDown(service.dispose);

      // Schedule a queue warm, then within the debounce window schedule a
      // uuids warm. Both must fire — they use independent timers now.
      service.scheduleWarm(sessionId: 7, currentPlayPosition: 0, quality: '320');
      await tester.pump(const Duration(milliseconds: 100));
      service.scheduleWarmUuids(['dl-1', 'dl-2'], quality: '320');

      await tester.pump(const Duration(milliseconds: 800));

      expect(captured.length, 2);
      // Identify each by session_id: queue path stringifies its int, the
      // uuids path sends null.
      final queueBody = captured.firstWhere((b) => b['session_id'] == '7');
      final uuidsBody = captured.firstWhere((b) => b['session_id'] == null);
      expect(queueBody['track_uuids'], ['a']);
      expect(uuidsBody['track_uuids'], ['dl-1', 'dl-2']);
    });

    _fakeTest('uuids warm scheduled first does not cancel a later queue warm; both fire',
        (tester) async {
      final captured = <Map<String, dynamic>>[];
      _installMockClient(MockClient((req) async {
        captured.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response('', 204);
      }));
      final service = QueueWarmService(
        apiClient: _api,
        queueRepo: _FakeQueueRepo([_entry('a', 0)]),
      );
      addTearDown(service.dispose);

      service.scheduleWarmUuids(['dl-1'], quality: '320');
      await tester.pump(const Duration(milliseconds: 100));
      service.scheduleWarm(sessionId: 9, currentPlayPosition: 0, quality: '320');

      await tester.pump(const Duration(milliseconds: 800));

      expect(captured.length, 2);
      final queueBody = captured.firstWhere((b) => b['session_id'] == '9');
      final uuidsBody = captured.firstWhere((b) => b['session_id'] == null);
      expect(queueBody['track_uuids'], ['a']);
      expect(uuidsBody['track_uuids'], ['dl-1']);
    });

    _fakeTest('back-to-back queue warms still coalesce to one POST (debounce intact)',
        (tester) async {
      var postCount = 0;
      _installMockClient(MockClient((_) async {
        postCount++;
        return http.Response('', 204);
      }));
      final service = QueueWarmService(
        apiClient: _api,
        queueRepo: _FakeQueueRepo([_entry('a', 0)]),
      );
      addTearDown(service.dispose);

      service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');
      service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');
      service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');

      await tester.pump(const Duration(milliseconds: 700));
      expect(postCount, 1);
    });

    _fakeTest('queue warm sends session_id as a stringified int (no magic source)',
        (tester) async {
      Map<String, dynamic>? capturedBody;
      _installMockClient(MockClient((req) async {
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }));
      final service = QueueWarmService(
        apiClient: _api,
        queueRepo: _FakeQueueRepo([_entry('a', 0)]),
      );
      addTearDown(service.dispose);

      service.scheduleWarm(sessionId: 42, currentPlayPosition: 0, quality: '320');
      await tester.pump(const Duration(milliseconds: 700));

      expect(capturedBody?['session_id'], '42');
    });

    _fakeTest('does not retry on SocketException; failure is swallowed', (tester) async {
      var calls = 0;
      _installMockClient(MockClient((_) async {
        calls++;
        throw const SocketException('simulated network failure');
      }));
      final service = QueueWarmService(apiClient: _api, queueRepo: _FakeQueueRepo([]));
      addTearDown(service.dispose);

      service.scheduleWarmUuids(['uuid-1'], quality: '128');
      await tester.pump(const Duration(milliseconds: 700));

      // No retry on the warm path. NetworkException (attemptsMade: 1) is
      // caught and swallowed inside the service's timer callback.
      expect(calls, 1);
    });
  });
}
