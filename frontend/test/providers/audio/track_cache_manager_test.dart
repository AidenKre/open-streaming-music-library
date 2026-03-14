import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/track_cache_manager.dart';

void main() {
  late Directory tempDirectory;
  HttpTrackCacheManager? manager;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('track-cache-test');
    ApiClient.init('http://test:8080');
  });

  tearDown(() async {
    await manager?.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('prefetch downloads a track and getCachedFile returns it', () async {
    manager = await HttpTrackCacheManager.create(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.toString(), 'http://test:8080/tracks/a/stream');
        return http.Response.bytes([1, 2, 3], 200);
      }),
      tempDirectoryProvider: () async => tempDirectory,
    );

    await manager!.prefetch(_track('a'));

    final file = manager!.getCachedFile('a');
    expect(file, isNotNull);
    expect(await file!.readAsBytes(), [1, 2, 3]);
  });

  test('create clears stale cache files from a previous app session', () async {
    final cacheDir = Directory(p.join(tempDirectory.path, 'track_cache'));
    await cacheDir.create(recursive: true);
    await File(p.join(cacheDir.path, 'old.audio')).writeAsBytes([1, 2, 3]);
    await File(p.join(cacheDir.path, 'old.part')).writeAsBytes([4, 5]);

    manager = await HttpTrackCacheManager.create(
      client: MockClient((request) async => http.Response('', 200)),
      tempDirectoryProvider: () async => tempDirectory,
    );

    expect(manager!.cacheDirectory.listSync(), isEmpty);
    expect(manager!.getCachedFile('old'), isNull);
  });

  test('cancelPrefetch cleans up a partial file', () async {
    final controller = StreamController<List<int>>();
    manager = await HttpTrackCacheManager.create(
      client: MockClient.streaming((request, _) async {
        return http.StreamedResponse(controller.stream, 200);
      }),
      tempDirectoryProvider: () async => tempDirectory,
    );

    final prefetchFuture = manager!.prefetch(_track('a'));
    await Future<void>.delayed(Duration.zero);
    controller.add([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);

    await manager!.cancelPrefetch();
    unawaited(controller.close());
    await prefetchFuture;

    expect(manager!.getCachedFile('a'), isNull);
    expect(
      File(p.join(tempDirectory.path, 'track_cache', 'a.part')).existsSync(),
      isFalse,
    );
  });

  test('clear and evict remove cached files', () async {
    manager = await HttpTrackCacheManager.create(
      client: MockClient((request) async {
        final uuid = request.url.pathSegments[1];
        return http.Response.bytes(uuid.codeUnits, 200);
      }),
      tempDirectoryProvider: () async => tempDirectory,
    );

    await manager!.prefetch(_track('a'));
    await manager!.prefetch(_track('b'));
    expect(manager!.getCachedFile('a'), isNotNull);
    expect(manager!.getCachedFile('b'), isNotNull);

    await manager!.evict('a');
    expect(manager!.getCachedFile('a'), isNull);
    expect(manager!.getCachedFile('b'), isNotNull);

    await manager!.clear();
    expect(manager!.getCachedFile('b'), isNull);
    expect(manager!.cacheDirectory.listSync(), isEmpty);
  });

  test('cancel racing with post-download finalization preserves completed file',
      () async {
    final streamController = StreamController<List<int>>();
    manager = await HttpTrackCacheManager.create(
      client: MockClient.streaming((request, _) async {
        return http.StreamedResponse(streamController.stream, 200);
      }),
      tempDirectoryProvider: () async => tempDirectory,
    );

    final prefetchFuture = manager!.prefetch(_track('a'));
    // Let the prefetch progress through HTTP request to stream listener
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // Complete the download
    streamController.add([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);
    await streamController.close();

    // Yield to let the stream completion propagate past the completer
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // Cancel while prefetch may be in the flush/rename phase
    await manager!.cancelPrefetch();
    await prefetchFuture;

    // The download completed fully — it should survive the cancel
    final cached = manager!.getCachedFile('a');
    expect(
      cached,
      isNotNull,
      reason: 'Fully downloaded file was lost to a cancel race',
    );
    if (cached != null) {
      expect(await cached.readAsBytes(), [1, 2, 3]);
    }

    // No orphaned partial files
    final partFiles = manager!.cacheDirectory
        .listSync()
        .where((e) => e.path.endsWith('.part'));
    expect(partFiles, isEmpty);
  });

  test('cancelPrefetch waits for completed download to finalize', () async {
    final streamController = StreamController<List<int>>();
    manager = await HttpTrackCacheManager.create(
      client: MockClient.streaming((request, _) async {
        return http.StreamedResponse(streamController.stream, 200);
      }),
      tempDirectoryProvider: () async => tempDirectory,
    );

    // Start prefetch and let it progress to the stream listener
    unawaited(manager!.prefetch(_track('a')));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // Complete the download — all data received
    streamController.add([1, 2, 3]);
    await streamController.close();

    // Cancel immediately after the stream closes.
    // cancelPrefetch must wait for the flush/rename to finish.
    await manager!.cancelPrefetch();

    // The download completed fully; the file should be available NOW.
    final cached = manager!.getCachedFile('a');
    expect(
      cached,
      isNotNull,
      reason:
          'Completed prefetch was not finalized before cancelPrefetch returned',
    );
    if (cached != null) {
      expect(await cached.readAsBytes(), [1, 2, 3]);
    }
  });

  test('concurrent prefetch cancels the previous download', () async {
    final firstController = StreamController<List<int>>();
    final secondController = StreamController<List<int>>();
    var requestCount = 0;

    manager = await HttpTrackCacheManager.create(
      client: MockClient.streaming((request, _) async {
        requestCount++;
        return switch (requestCount) {
          1 => http.StreamedResponse(firstController.stream, 200),
          2 => http.StreamedResponse(secondController.stream, 200),
          _ => throw StateError('Unexpected request count'),
        };
      }),
      tempDirectoryProvider: () async => tempDirectory,
    );

    final firstPrefetch = manager!.prefetch(_track('a'));
    await Future<void>.delayed(Duration.zero);
    firstController.add([1, 2]);
    await Future<void>.delayed(Duration.zero);

    final secondPrefetch = manager!.prefetch(_track('b'));
    await Future<void>.delayed(Duration.zero);
    secondController.add([9, 8, 7]);
    unawaited(secondController.close());

    await secondPrefetch;
    unawaited(firstController.close());
    await firstPrefetch;

    expect(manager!.getCachedFile('a'), isNull);
    expect(manager!.getCachedFile('b'), isNotNull);
    expect(await manager!.getCachedFile('b')!.readAsBytes(), [9, 8, 7]);
    expect(
      File(p.join(tempDirectory.path, 'track_cache', 'a.part')).existsSync(),
      isFalse,
    );
  });
  test('prefetch uses Content-Type header to determine file extension', () async {
    manager = await HttpTrackCacheManager.create(
      client: MockClient((request) async {
        return http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'audio/flac'},
        );
      }),
      tempDirectoryProvider: () async => tempDirectory,
    );

    await manager!.prefetch(_track('a'));

    final file = manager!.getCachedFile('a');
    expect(file, isNotNull);
    expect(file!.path, endsWith('.flac'));
  });

  test('getCachedFile finds files by UUID prefix regardless of extension', () async {
    manager = await HttpTrackCacheManager.create(
      client: MockClient((request) async => http.Response('', 200)),
      tempDirectoryProvider: () async => tempDirectory,
    );

    // Manually place a file with a .mp3 extension in the cache directory
    await File(p.join(manager!.cacheDirectory.path, 'my-uuid.mp3'))
        .writeAsBytes([1, 2, 3]);

    final file = manager!.getCachedFile('my-uuid');
    expect(file, isNotNull);
    expect(await file!.readAsBytes(), [1, 2, 3]);
  });
}

TrackUI _track(String uuidId) {
  return TrackUI(
    uuidId: uuidId,
    createdAt: 0,
    lastUpdated: 0,
    duration: 180,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: false,
  );
}
