import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
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
          duration: const Value(120),
          bitrateKbps: const Value(320),
          sampleRateHz: const Value(44100),
          channels: const Value(2),
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
/// downloads in-flight as long as needed. Counts the requests it was sent
/// and the most bodies open at once, and lets the test await the n-th
/// request (no wall-clock waits).
class _GatedClient extends http.BaseClient {
  _GatedClient(this.gate);

  final Completer<void> gate;
  int sent = 0;
  int _open = 0;
  int maxOpen = 0;
  final _waiters = <int, Completer<void>>{};

  /// Completes once [n] requests have been sent.
  Future<void> sentAtLeast(int n) => sent >= n
      ? Future<void>.value()
      : (_waiters[n] ??= Completer<void>()).future;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent++;
    _open++;
    if (_open > maxOpen) maxOpen = _open;
    _waiters.remove(sent)?.complete();
    final controller = StreamController<List<int>>();
    // Emit a chunk only after the gate completes; until then the response
    // body stream sits open and the download stays "active".
    unawaited(
      gate.future.then((_) async {
        controller.add(const [1, 2, 3]);
        _open--;
        await controller.close();
      }),
    );
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: 3,
      headers: const {'x-audio-extension': 'm4a'},
    );
  }
}

/// The real queue, with a bound on how often the pool may look for the next
/// job: past it the lookup throws, so a pump that loops without end fails
/// by assertion instead of spinning the test for good.
class _BoundedQueue extends DownloadQueue {
  int lookups = 0;

  @override
  int findFirstQueuedIndex() {
    if (++lookups > 100) throw StateError('pump keeps looking for a job');
    return super.findFirstQueuedIndex();
  }
}

/// The real downloader, reporting the outcome of its first download.
class _ObservedDownloader extends TrackDownloader {
  _ObservedDownloader({
    required super.db,
    required super.coverArtStore,
    required super.directoryProvider,
    required super.apiClient,
  });

  final finished = Completer<DownloadOutcome>();

  @override
  Future<DownloadOutcome> download({
    required DownloadJob job,
    required bool Function() generationCheck,
    required void Function(double progress) onProgress,
    required void Function(Future<void> Function() canceller)
        registerCanceller,
    required void Function() unregisterCanceller,
  }) async {
    final outcome = await super.download(
      job: job,
      generationCheck: generationCheck,
      onProgress: onProgress,
      registerCanceller: registerCanceller,
      unregisterCanceller: unregisterCanceller,
    );
    if (!finished.isCompleted) finished.complete(outcome);
    return outcome;
  }
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore coverStore;
  late ApiClient api;
  late DownloadQueue queue;
  late TrackDownloader downloader;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('worker_pool_test_');
    api = testApiClient(
      'http://test:8080',
      MockClient((_) async => http.Response.bytes([1], 200)),
    );
    coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => tempDir,
      apiClient: api,
    );
    queue = DownloadQueue();
    downloader = TrackDownloader(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      apiClient: api,
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
      final client = _GatedClient(gate);
      // Rebuild downloader so it uses the gated client.
      final dl = TrackDownloader(
        db: db,
        coverArtStore: coverStore,
        directoryProvider: () async => tempDir,
        apiClient: testApiClient('http://test:8080', client),
      );

      var completedCount = 0;
      final allCompleted = Completer<void>();
      final pool = WorkerPool(
        queue: queue,
        downloader: dl,
        isOffline: () => false,
        onCompleted: () {
          if (++completedCount == 7) allCompleted.complete();
        },
      );

      for (var i = 0; i < 7; i++) {
        await _insertTrack(db, 'u$i');
      }
      queue.addAll([for (var i = 0; i < 7; i++) _job('u$i')]);

      pool.pump();

      // pump marks the jobs it dispatches Active synchronously.
      expect(
        queue.state.jobs.where((j) => j.isActive).length,
        WorkerPool.maxConcurrent,
      );
      // Once those downloads are in flight (held by the gate), nothing
      // more has started.
      await client.sentAtLeast(WorkerPool.maxConcurrent);
      expect(client.sent, WorkerPool.maxConcurrent);
      final activeCount = queue.state.jobs.where((j) => j.isActive).length;
      expect(activeCount, WorkerPool.maxConcurrent);
      expect(
        queue.state.jobs.where((j) => j.isQueued).length,
        7 - WorkerPool.maxConcurrent,
      );

      // Release the gate so all jobs finish, then wait for the last one.
      gate.complete();
      await allCompleted.future;
      expect(client.sent, 7);
      expect(client.maxOpen, WorkerPool.maxConcurrent);
      expect(completedCount, 7);
    },
  );

  test('reset cancels in-flight workers and clears queue', () async {
    final gate = Completer<void>();
    final client = _GatedClient(gate);
    final dl = TrackDownloader(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      apiClient: testApiClient('http://test:8080', client),
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
    // Both downloads are in flight, held by the gate.
    await client.sentAtLeast(2);
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

  // TR-SWITCH-07: a reset (log-out, server switch) waited without end for a
  // download worker that never finished, so the reset never completed. The
  // wait is bounded; a worker it gives up on must not record a download or
  // leave a file when it wakes up after the reset.
  test('reset gives up on a hung worker, whose late commit is refused',
      () async {
    final hold = Completer<void>();
    final atRecord = Completer<void>();
    final dl = _ObservedDownloader(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      apiClient: testApiClient(
        'http://test:8080',
        MockClient((_) async => http.Response.bytes([1, 2, 3], 200,
            headers: {'x-audio-extension': 'm4a'})),
      ),
    );
    // Hung between the rename and the record step (e.g. a stalled disk).
    dl.testHookBeforeDbWrite = (_) async {
      atRecord.complete();
      await hold.future;
    };
    final pool = WorkerPool(
      queue: queue,
      downloader: dl,
      isOffline: () => false,
      onCompleted: () {},
      resetWorkerWait: Duration.zero,
    );
    await _insertTrack(db, 'a');
    queue.addAll([_job('a')]);
    pool.pump();
    await atRecord.future;

    // Without the bound this never returns (the test times out).
    await pool.reset();
    expect(queue.state.jobs, isEmpty);
    // A delete afterwards does not wait for the worker the reset gave up on.
    await pool.fenceUuid('a');

    // The abandoned worker wakes up after the reset finished.
    hold.complete();
    expect((await dl.finished.future).kind, DownloadOutcomeKind.cancelled);
    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('a')))
        .getSingle();
    expect(row.filePath, isNull, reason: 'the late commit was recorded');
    final tracks = Directory('${tempDir.path}/tracks');
    expect(tracks.existsSync() ? tracks.listSync() : const [], isEmpty,
        reason: 'the late commit left a file');
    expect(queue.state.jobs, isEmpty);
  });

  // TR-SWITCH-07: the worker a reset gave up on finishes later. It must not
  // drop the entry of a newer worker for the same track, or a delete would
  // stop waiting for that one and its commit would undo the delete.
  test('an abandoned worker finishing late leaves a newer worker tracked',
      () async {
    final hold = Completer<void>();
    final atRecord = Completer<void>();
    final dl = _ObservedDownloader(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      apiClient: testApiClient(
        'http://test:8080',
        MockClient((_) async => http.Response.bytes([1, 2, 3], 200,
            headers: {'x-audio-extension': 'm4a'})),
      ),
    );
    dl.testHookBeforeDbWrite = (_) async {
      atRecord.complete();
      await hold.future;
    };
    final pool = WorkerPool(
      queue: queue,
      downloader: dl,
      isOffline: () => false,
      onCompleted: () {},
      resetWorkerWait: Duration.zero,
    );
    await _insertTrack(db, 'a');
    queue.addAll([_job('a')]);
    pool.pump();
    await atRecord.future;
    await pool.reset(); // gives up on the first worker

    // A new download of the same track, held just before its rename.
    final hold2 = Completer<void>();
    final atRename2 = Completer<void>();
    dl.testHookBeforeRename = (_) async {
      atRename2.complete();
      await hold2.future;
    };
    queue.addAll([_job('a')]);
    pool.pump();
    await atRename2.future;

    // The abandoned worker finishes now.
    hold.complete();
    expect((await dl.finished.future).kind, DownloadOutcomeKind.cancelled);
    await pumpEventQueue();

    // Deleting the track waits for the newer worker...
    var deleted = false;
    final delete = pool.fenceUuid('a').then((_) => deleted = true);
    await pumpEventQueue();
    expect(deleted, isFalse,
        reason: 'the delete stopped waiting for the running download');
    // ...which then sees the delete and commits nothing.
    hold2.complete();
    await delete;
    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('a')))
        .getSingle();
    expect(row.filePath, isNull);
  });

  // Review #4: a job started while the reset waits for the old workers is
  // not one the reset gave up on. A later delete must still wait for it, or
  // its commit would undo the delete.
  test('a worker started during the reset wait stays tracked', () async {
    final hold = Completer<void>();
    final atRecord = Completer<void>();
    final holdB = Completer<void>();
    final atRenameB = Completer<void>();
    final dl = _ObservedDownloader(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      apiClient: testApiClient(
        'http://test:8080',
        MockClient((_) async => http.Response.bytes([1, 2, 3], 200,
            headers: {'x-audio-extension': 'm4a'})),
      ),
    );
    dl.testHookBeforeDbWrite = (uuid) async {
      if (uuid != 'a') return;
      atRecord.complete();
      await hold.future;
    };
    dl.testHookBeforeRename = (uuid) async {
      if (uuid != 'b') return;
      atRenameB.complete();
      await holdB.future;
    };
    final pool = WorkerPool(
      queue: queue,
      downloader: dl,
      isOffline: () => false,
      onCompleted: () {},
      resetWorkerWait: Duration.zero,
    );
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });
    await _insertTrack(db, 'a');
    await _insertTrack(db, 'b');
    queue.addAll([_job('a')]);
    pool.pump();
    await atRecord.future;

    final reset = pool.reset(); // gives up on 'a' after the bound
    // While the reset waits, a new download starts.
    queue.addAll([_job('b')]);
    pool.pump();
    await reset;
    await atRenameB.future;

    var deleted = false;
    final delete = pool.fenceUuid('b').then((_) => deleted = true);
    await pumpEventQueue();
    expect(deleted, isFalse,
        reason: 'the delete stopped waiting for the running download');
    holdB.complete();
    await delete;
    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('b')))
        .getSingle();
    expect(row.filePath, isNull);
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
    // pump marks a dispatched job Active synchronously; offline, none is.
    expect(queue.state.jobs.single.isQueued, isTrue);
  });

  // 7-R1-UI-03: a queue that is disposed while it still holds queued jobs
  // refuses every transition (markJob is a no-op). pump must not keep
  // dispatching a job that never becomes Active: each such dispatch ran
  // _runJob, which found no active job, released the slot and pumped again,
  // without end (100 % CPU; seen when a failed test's tearDown disposed the
  // queue under a still-running pool).
  test('pump dispatches nothing from a disposed queue and returns', () {
    final bounded = _BoundedQueue();
    final pool = WorkerPool(
      queue: bounded,
      downloader: downloader,
      isOffline: () => false,
      onCompleted: () {},
    );
    bounded.addAll([_job('a'), _job('b')]);
    bounded.dispose();

    expect(pool.pump, returnsNormally);
    expect(bounded.lookups, lessThanOrEqualTo(2));
  });
}
