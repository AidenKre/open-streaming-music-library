import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/queue_warm_service.dart';

class _FakeQueueRepo implements QueueRepository {
  final List<QueuePlaybackEntry> entries;
  int callCount = 0;
  int? lastStartPlayPosition;
  int? lastLimit;
  _FakeQueueRepo(this.entries);

  @override
  Future<List<QueuePlaybackEntry>> getPlaybackEntries(
    int sessionId, {
    int startPlayPosition = 0,
    int? limit,
  }) async {
    callCount++;
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

void main() {
  setUp(() => ApiClient.init('http://test:8080'));

  test('scheduleWarm POSTs to /tracks/warm after the debounce', () async {
    Uri? capturedUrl;
    Map<String, dynamic>? capturedBody;
    final client = MockClient((req) async {
      capturedUrl = req.url;
      capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('', 204);
    });
    final service = QueueWarmService(
      queueRepo: _FakeQueueRepo([_entry('a', 0), _entry('b', 1)]),
      client: client,
    );
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 7, currentPlayPosition: 0, quality: '256');

    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect(capturedUrl?.path, '/tracks/warm');
    expect(capturedBody?['session_id'], '7');
    expect(capturedBody?['current_index'], 0);
    expect(capturedBody?['quality'], '256');
    expect(capturedBody?['track_uuids'], ['a', 'b']);
  });

  test('respects currentPlayPosition when fetching entries', () async {
    final repo = _FakeQueueRepo([
      _entry('a', 0),
      _entry('b', 1),
      _entry('c', 2),
    ]);
    Map<String, dynamic>? capturedBody;
    final service = QueueWarmService(
      queueRepo: repo,
      client: MockClient((req) async {
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }),
    );
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 1, currentPlayPosition: 1, quality: '192');
    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect(repo.lastStartPlayPosition, 1);
    // Should only contain entries from position 1 onward.
    expect(capturedBody?['track_uuids'], ['b', 'c']);
  });

  test('debounces rapid calls into a single POST', () async {
    var postCount = 0;
    final client = MockClient((req) async {
      postCount++;
      return http.Response('', 204);
    });
    final service = QueueWarmService(
      queueRepo: _FakeQueueRepo([_entry('a', 0)]),
      client: client,
    );
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');
    service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');
    service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');

    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(postCount, 1);
  });

  test('does nothing when sessionId is null', () async {
    var postCount = 0;
    final repo = _FakeQueueRepo([_entry('a', 0)]);
    final service = QueueWarmService(
      queueRepo: repo,
      client: MockClient((_) async {
        postCount++;
        return http.Response('', 204);
      }),
    );
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: null, currentPlayPosition: 0, quality: '320');
    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect(postCount, 0);
    expect(repo.callCount, 0);
  });

  test('does not POST when the queue is empty', () async {
    var postCount = 0;
    final service = QueueWarmService(
      queueRepo: _FakeQueueRepo([]),
      client: MockClient((_) async {
        postCount++;
        return http.Response('', 204);
      }),
    );
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(postCount, 0);
  });

  test('caps the request body at 50 track UUIDs', () async {
    Map<String, dynamic>? capturedBody;
    final repo = _FakeQueueRepo([
      for (var i = 0; i < 100; i++) _entry('uuid-$i', i),
    ]);
    final service = QueueWarmService(
      queueRepo: repo,
      client: MockClient((req) async {
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }),
    );
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');
    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect((capturedBody!['track_uuids'] as List).length, 50);
  });

  test('swallows POST errors so callers never see them', () async {
    final service = QueueWarmService(
      queueRepo: _FakeQueueRepo([_entry('a', 0)]),
      client: MockClient((_) async => throw const SocketExceptionLite()),
    );
    addTearDown(service.dispose);

    service.scheduleWarm(sessionId: 1, currentPlayPosition: 0, quality: '320');
    // Should NOT throw.
    await Future<void>.delayed(const Duration(milliseconds: 700));
  });

  group('scheduleWarmUuids', () {
    test('POSTs to /tracks/warm with session_id download-manager after debounce',
        () async {
      Uri? capturedUrl;
      Map<String, dynamic>? capturedBody;
      final service = QueueWarmService(
        queueRepo: _FakeQueueRepo([]),
        client: MockClient((req) async {
          capturedUrl = req.url;
          capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response('', 204);
        }),
      );
      addTearDown(service.dispose);

      service.scheduleWarmUuids(['uuid-1', 'uuid-2'], quality: '256');

      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(capturedUrl?.path, '/tracks/warm');
      expect(capturedBody?['session_id'], 'download-manager');
      expect(capturedBody?['quality'], '256');
      expect(capturedBody?['track_uuids'], ['uuid-1', 'uuid-2']);
    });

    test('respects the 50-UUID cap', () async {
      Map<String, dynamic>? capturedBody;
      final service = QueueWarmService(
        queueRepo: _FakeQueueRepo([]),
        client: MockClient((req) async {
          capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response('', 204);
        }),
      );
      addTearDown(service.dispose);

      final sixtyUuids = List.generate(60, (i) => 'uuid-$i');
      service.scheduleWarmUuids(sixtyUuids, quality: '128');

      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect((capturedBody!['track_uuids'] as List).length, 50);
    });

    test('debounces rapid calls into a single POST', () async {
      var postCount = 0;
      final service = QueueWarmService(
        queueRepo: _FakeQueueRepo([]),
        client: MockClient((_) async {
          postCount++;
          return http.Response('', 204);
        }),
      );
      addTearDown(service.dispose);

      service.scheduleWarmUuids(['a'], quality: '128');
      service.scheduleWarmUuids(['b'], quality: '128');
      service.scheduleWarmUuids(['c'], quality: '128');

      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(postCount, 1);
    });

    test('swallows POST errors', () async {
      final service = QueueWarmService(
        queueRepo: _FakeQueueRepo([]),
        client: MockClient((_) async => throw const SocketExceptionLite()),
      );
      addTearDown(service.dispose);

      service.scheduleWarmUuids(['uuid-1'], quality: '128');
      // Should NOT throw.
      await Future<void>.delayed(const Duration(milliseconds: 700));
    });

    test('does nothing when list is empty', () async {
      var postCount = 0;
      final service = QueueWarmService(
        queueRepo: _FakeQueueRepo([]),
        client: MockClient((_) async {
          postCount++;
          return http.Response('', 204);
        }),
      );
      addTearDown(service.dispose);

      service.scheduleWarmUuids([], quality: '128');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(postCount, 0);
    });
  });
}

class SocketExceptionLite implements Exception {
  const SocketExceptionLite();
  @override
  String toString() => 'simulated network failure';
}
