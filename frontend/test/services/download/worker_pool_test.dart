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
    bool Function()? isCancelled,
  }) async {
    final outcome = await super.download(
      job: job,
      generationCheck: generationCheck,
      onProgress: onProgress,
      registerCanceller: registerCanceller,
      unregisterCanceller: unregisterCanceller,
      isCancelled: isCancelled,
    );
    if (!finished.isCompleted) finished.complete(outcome);
    return outcome;
  }
}

/// The real downloader, holding its result until [release] completes: a
/// cancel landing then lands after the commit step finished.
class _HeldAfterDownload extends TrackDownloader {
  _HeldAfterDownload({
    required super.db,
    required super.coverArtStore,
    required super.directoryProvider,
    required super.apiClient,
  });

  final returned = Completer<void>();
  final release = Completer<void>();

  @override
  Future<DownloadOutcome> download({
    required DownloadJob job,
    required bool Function() generationCheck,
    required void Function(double progress) onProgress,
    required void Function(Future<void> Function() canceller)
        registerCanceller,
    required void Function() unregisterCanceller,
    bool Function()? isCancelled,
  }) async {
    final outcome = await super.download(
      job: job,
      generationCheck: generationCheck,
      onProgress: onProgress,
      registerCanceller: registerCanceller,
      unregisterCanceller: unregisterCanceller,
      isCancelled: isCancelled,
    );
    returned.complete();
    await release.future;
    return outcome;
  }
}

/// Waits in real time, at most [limit], until [done] holds: for work started
/// without being awaited that goes through real file I/O, which a fixed
/// number of event-queue turns does not bound. The expect after it reports a
/// condition that never came.
Future<void> _eventually(bool Function() done,
    {Duration limit = const Duration(seconds: 5)}) async {
  final elapsed = Stopwatch()..start();
  while (!done() && elapsed.elapsed < limit) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
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
    // A replacement download (Phase 8: a commit holds its file's path lock,
    // and the abandoned worker still holds the lock on `a.m4a`; a
    // replacement writes its own `a.new-<n>.m4a`).
    queue.addAll([
      DownloadJob(
        uuidId: 'a',
        title: 't',
        artist: 'a',
        quality: '320',
        status: const Queued(),
        replacesFilePath: '${tempDir.path}/tracks/a.m4a',
      ),
    ]);
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

  // Other-issues row 74: Cancel on a download in progress. The end state is
  // the cancelled queued row's: the row leaves the list, the slot is freed
  // for the next job, and no file of the download stays (partial or new).
  // A cancel that lands while the commit step runs: before the commit's last
  // check the cancel wins (that end state); after it the download wins (the
  // row is Completed and the file recorded). Both are clean.
  group('cancelActive', () {
    List<String> trackFiles() {
      final dir = Directory('${tempDir.path}/tracks');
      return dir.existsSync()
          ? [for (final f in dir.listSync()) f.uri.pathSegments.last]
          : const [];
    }

    Future<String?> recordedPath(String uuid) async =>
        (await (db.select(db.tracks)..where((t) => t.uuidId.equals(uuid)))
                .getSingle())
            .filePath;

    test('a download receiving its body: the row leaves, the slot goes to '
        'the next job, no partial file stays', () async {
      final gate = Completer<void>();
      final client = _GatedClient(gate);
      final dl = TrackDownloader(
        db: db,
        coverArtStore: coverStore,
        directoryProvider: () async => tempDir,
        apiClient: testApiClient('http://test:8080', client),
      );
      var completed = 0;
      final allCompleted = Completer<void>();
      final pool = WorkerPool(
        queue: queue,
        downloader: dl,
        isOffline: () => false,
        onCompleted: () {
          if (++completed == 4) allCompleted.complete();
        },
      );
      for (var i = 0; i < 5; i++) {
        await _insertTrack(db, 'u$i');
      }
      queue.addAll([for (var i = 0; i < 5; i++) _job('u$i')]);
      pool.pump();
      await client.sentAtLeast(4);
      // The partial file is created by real file I/O that nothing here
      // awaits: wait for it in real time, bounded.
      await _eventually(() => trackFiles().contains('u0.m4a.partial'));
      expect(trackFiles(), contains('u0.m4a.partial'));

      await pool.cancelActive('u0');
      expect(queue.state.jobs.map((j) => j.uuidId), isNot(contains('u0')));
      await client.sentAtLeast(5);
      expect(queue.state.jobs.singleWhere((j) => j.uuidId == 'u4').isActive,
          isTrue, reason: 'the freed slot runs the next queued job');
      expect(trackFiles().where((f) => f.startsWith('u0.')), isEmpty);

      gate.complete();
      await allCompleted.future;
      expect(queue.state.jobs.map((j) => j.uuidId),
          unorderedEquals(['u1', 'u2', 'u3', 'u4']));
      expect(queue.state.jobs.every((j) => j.isCompleted), isTrue);
      expect(await recordedPath('u0'), isNull);
      expect(trackFiles().where((f) => f.startsWith('u0.')), isEmpty);
    });

    test('a cancel landing in the commit step before its last check: the '
        'cancel wins, nothing is recorded and no file stays', () async {
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
      );
      await _insertTrack(db, 'a');
      queue.addAll([_job('a')]);
      pool.pump();
      await atRecord.future;

      final cancel = pool.cancelActive('a');
      hold.complete();
      await cancel;
      expect((await dl.finished.future).kind, DownloadOutcomeKind.cancelled);
      expect(queue.state.jobs, isEmpty);
      expect(await recordedPath('a'), isNull);
      expect(trackFiles(), isEmpty);
    });

    // Review F1: once the row swap of a re-download has committed, a cancel
    // loses: the new file is recorded and the replaced one goes, as for a
    // finished download (it must not end with neither file).
    test('a cancel landing after the row swap of a re-download: the download '
        'wins', () async {
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
      final pool = WorkerPool(
        queue: queue,
        downloader: dl,
        isOffline: () => false,
        onCompleted: () {},
      );
      await _insertTrack(db, 'a');
      final old = File('${tempDir.path}/tracks/a.m4a');
      await old.create(recursive: true);
      await old.writeAsBytes([9, 9]);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
          .write(TracksCompanion(filePath: Value(old.path)));
      Future<void>? cancel;
      dl.testHookAfterRecord = (_) async {
        cancel = pool.cancelActive('a');
      };
      queue.addAll([
        DownloadJob(
          uuidId: 'a',
          title: 't',
          artist: 'a',
          quality: '320',
          status: const Queued(),
          replacesFilePath: old.path,
        ),
      ]);
      pool.pump();
      expect((await dl.finished.future).kind, DownloadOutcomeKind.success);
      await cancel;
      expect(queue.state.jobs.single.isCompleted, isTrue);
      final path = await recordedPath('a');
      expect(path, isNotNull);
      expect(path, isNot(old.path));
      expect(File(path!).existsSync(), isTrue);
      expect(old.existsSync(), isFalse, reason: 'the replaced file goes');
    });

    test('a cancel landing after the commit step: the download wins, the '
        'row is Completed and the file recorded', () async {
      final dl = _HeldAfterDownload(
        db: db,
        coverArtStore: coverStore,
        directoryProvider: () async => tempDir,
        apiClient: testApiClient(
          'http://test:8080',
          MockClient((_) async => http.Response.bytes([1, 2, 3], 200,
              headers: {'x-audio-extension': 'm4a'})),
        ),
      );
      final pool = WorkerPool(
        queue: queue,
        downloader: dl,
        isOffline: () => false,
        onCompleted: () {},
      );
      await _insertTrack(db, 'a');
      queue.addAll([_job('a')]);
      pool.pump();
      await dl.returned.future;

      final cancel = pool.cancelActive('a');
      dl.release.complete();
      await cancel;
      expect(queue.state.jobs.single.isCompleted, isTrue);
      final path = await recordedPath('a');
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
      expect(trackFiles(), ['a.m4a']);
    });

    test('a cancel waiting for the response that then fails on the network: '
        'the row leaves instead of going back to the queue', () async {
      final answer = Completer<void>();
      final dl = TrackDownloader(
        db: db,
        coverArtStore: coverStore,
        directoryProvider: () async => tempDir,
        apiClient: testApiClient(
          'http://test:8080',
          MockClient((_) async {
            await answer.future;
            throw const SocketException('connection reset');
          }),
        ),
      );
      final pool = WorkerPool(
        queue: queue,
        downloader: dl,
        isOffline: () => false,
        onCompleted: () {},
      );
      await _insertTrack(db, 'a');
      queue.addAll([_job('a')]);
      pool.pump();
      await pumpEventQueue();

      final cancel = pool.cancelActive('a');
      answer.complete();
      await cancel;
      expect(queue.state.jobs, isEmpty);
      expect(trackFiles(), isEmpty);
    });

    test('a track that is not downloading: nothing happens', () async {
      final pool = WorkerPool(
        queue: queue,
        downloader: downloader,
        isOffline: () => true,
        onCompleted: () {},
      );
      queue.addAll([_job('q')]);
      await pool.cancelActive('q');
      await pool.cancelActive('missing');
      expect(queue.state.jobs.single.isQueued, isTrue);
    });
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
