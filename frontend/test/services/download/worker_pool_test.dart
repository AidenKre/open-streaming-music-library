import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/download/download_queue.dart';
import 'package:frontend/services/download/track_downloader.dart';
import 'package:frontend/services/download/worker_pool.dart';
import 'package:frontend/services/local_cover_art_store.dart';

Future<void> _insertTrack(AppDatabase db, String uuid) async {
  await db
      .into(db.tracks)
      .insert(
        TracksCompanion.insert(uuidId: uuid, createdAt: 0, lastUpdated: 0),
      );
  await db
      .into(db.trackmetadata)
      .insert(
        TrackmetadataCompanion.insert(
          uuidId: uuid,
          duration: 120,
          bitrateKbps: 320,
          sampleRateHz: 44100,
          channels: 2,
        ),
      );
}

DownloadJob _job(String uuidId) => DownloadJob(
  uuidId: uuidId,
  title: 't',
  artist: 'a',
  quality: '320',
  status: const Queued(),
);

/// Streamed response whose body is gated by a Completer so the test can hold
/// downloads in-flight as long as needed.
class _GatedClient extends http.BaseClient {
  _GatedClient(this.gate);

  final Completer<void> gate;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final controller = StreamController<List<int>>();
    // Emit a chunk only after the gate completes; until then the response
    // body stream sits open and the download stays "active".
    Future<void>(() async {
      await gate.future;
      controller.add(const [1, 2, 3]);
      await controller.close();
    });
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: 3,
      headers: const {'x-audio-extension': 'm4a'},
    );
  }
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore coverStore;
  late DownloadQueue queue;
  late TrackDownloader downloader;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('worker_pool_test_');
    ApiClient.initForTest(
      'http://test:8080',
      MockClient((_) async => http.Response.bytes([1], 200)),
    );
    coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => tempDir,
    );
    queue = DownloadQueue();
    downloader = TrackDownloader(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      apiClient: ApiClient.instance,
    );
  });

  tearDown(() async {
    queue.dispose();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
    'pump dispatches at most maxConcurrent (4) jobs at once',
    () async {
      final gate = Completer<void>();
      ApiClient.initForTest('http://test:8080', _GatedClient(gate));
      // Rebuild downloader so it picks up the gated client via ApiClient.instance.
      final dl = TrackDownloader(
        db: db,
        coverArtStore: coverStore,
        directoryProvider: () async => tempDir,
        apiClient: ApiClient.instance,
      );

      var completedCount = 0;
      final pool = WorkerPool(
        queue: queue,
        downloader: dl,
        isOffline: () => false,
        onCompleted: () => completedCount++,
      );

      for (var i = 0; i < 7; i++) {
        await _insertTrack(db, 'u$i');
      }
      queue.addAll([for (var i = 0; i < 7; i++) _job('u$i')]);

      pool.pump();

      // Yield so workers transition to Active.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final activeCount = queue.state.jobs.where((j) => j.isActive).length;
      expect(activeCount, WorkerPool.maxConcurrent);
      expect(
        queue.state.jobs.where((j) => j.isQueued).length,
        7 - WorkerPool.maxConcurrent,
      );

      // Release the gate so all jobs finish, then drain.
      gate.complete();
      for (var i = 0; i < 300 && completedCount < 7; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(completedCount, 7);
    },
  );

  test('reset cancels in-flight workers and clears queue', () async {
    final gate = Completer<void>();
    ApiClient.initForTest('http://test:8080', _GatedClient(gate));
    final dl = TrackDownloader(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      apiClient: ApiClient.instance,
    );

    final pool = WorkerPool(
      queue: queue,
      downloader: dl,
      isOffline: () => false,
      onCompleted: () {},
    );

    await _insertTrack(db, 'a');
    await _insertTrack(db, 'b');
    queue.addAll([_job('a'), _job('b')]);
    pool.pump();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(queue.state.jobs.where((j) => j.isActive).length, 2);

    // Reset should cancel the in-flight HTTP stream and wipe the queue.
    final resetFuture = pool.reset();
    // Release the gate so any unblocked downloads can finish reacting to
    // the cancellation.
    if (!gate.isCompleted) gate.complete();
    await resetFuture;

    expect(queue.state.jobs, isEmpty);

    // No DB rows should have been persisted with a file_path.
    final rows = await db.select(db.tracks).get();
    expect(rows.where((r) => r.filePath != null), isEmpty);
  });

  test('pump is a no-op when offline', () async {
    final pool = WorkerPool(
      queue: queue,
      downloader: downloader,
      isOffline: () => true,
      onCompleted: () {},
    );
    await _insertTrack(db, 'a');
    queue.addAll([_job('a')]);
    pool.pump();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // No job ever transitioned to Active.
    expect(queue.state.jobs.single.isQueued, isTrue);
  });
}
