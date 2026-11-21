// Phase M §7.7 / SC-13 Phase M (M-U24 exit proof): a 401 is a wait for
// downloads. `TrackDownloader` maps it to `DownloadOutcomeKind.authRequired`,
// which leaves the job queued; the pool pauses on an explicit `authPaused`
// flag (not the offline flag), so a queue of N jobs keeps N queued jobs and
// never hot-loops. (The queue is dropped at the next scope rebuild, as on a
// restart: the pool is rebuilt with the scope.)
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

http.Response _status(int code) => http.Response(
  '{"detail":{"code":"invalid_token","message":"Sign in again."}}',
  code,
  headers: {'content-type': 'application/json'},
);

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late DownloadQueue queue;
  var requests = 0;
  var offline = false;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('worker_pool_auth_test_');
    queue = DownloadQueue();
    requests = 0;
    offline = false;
  });

  tearDown(() async {
    queue.dispose();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<TrackDownloader> downloader(int status) async {
    final api = testApiClient(
      'http://test:8080',
      MockClient((_) async {
        requests++;
        // A hot loop must end as a failed assertion, not a hung test: past
        // the cap the "server" errors, which fails the job and stops it.
        if (requests > 50) throw StateError('hot loop');
        return _status(status);
      }),
    );
    return TrackDownloader(
      db: db,
      coverArtStore: await LocalCoverArtStore.create(
        directoryProvider: () async => tempDir,
        apiClient: api,
      ),
      directoryProvider: () async => tempDir,
      apiClient: api,
    );
  }

  Future<DownloadOutcome> downloadOnce(int status) async =>
      (await downloader(status)).download(
        job: _job('abc'),
        generationCheck: () => true,
        onProgress: (_) {},
        registerCanceller: (_) {},
        unregisterCanceller: () {},
      );

  /// Waits until no job is active: the workers have settled. Event-driven:
  /// a queue listener completes the wait the moment the last active job
  /// leaves that state (a hung worker ends at the test timeout).
  Future<void> settle() async {
    if (queue.state.jobs.any((j) => j.isActive)) {
      final idle = Completer<void>();
      void check() {
        if (!idle.isCompleted && !queue.state.jobs.any((j) => j.isActive)) {
          idle.complete();
        }
      }

      queue.addListener(check);
      try {
        await idle.future;
      } finally {
        queue.removeListener(check);
      }
    }
    expect(queue.state.jobs.any((j) => j.isActive), isFalse);
    // A few more turns: a hot loop would keep sending requests here.
    await pumpEventQueue(times: 20);
  }

  test('the downloader maps a 401 to authRequired', () async {
    final outcome = await downloadOnce(401);
    expect(outcome.kind, DownloadOutcomeKind.authRequired);
  });

  test('a 403 is still a per-item failure', () async {
    final outcome = await downloadOnce(403);
    expect(outcome.kind, DownloadOutcomeKind.otherFailure);
  });

  test('a queue of N jobs keeps N queued while paused, with no loop',
      () async {
    const n = 7;
    for (var i = 0; i < n; i++) {
      await _insertTrack(db, 'u$i');
    }
    final pool = WorkerPool(
      queue: queue,
      downloader: await downloader(401),
      isOffline: () => offline,
      onCompleted: () {},
    );
    queue.addAll([for (var i = 0; i < n; i++) _job('u$i')]);
    expect(pool.authPaused, isFalse);

    pool.pump();
    await settle();

    expect(pool.authPaused, isTrue);
    expect(queue.state.jobs, hasLength(n));
    expect(queue.state.jobs.where((j) => j.isQueued), hasLength(n),
        reason: 'no job fails or is dropped on a 401');
    expect(requests, lessThanOrEqualTo(WorkerPool.maxConcurrent),
        reason: 'only the jobs already in flight were tried');
    final tried = requests;

    // Pumps (enqueue, back online) don't restart it: still paused.
    pool.pump();
    queue.addAll([_job('extra')]);
    pool.pump();
    await settle();
    expect(requests, tried, reason: 'paused: no further request');
    expect(queue.state.jobs.where((j) => j.isQueued), hasLength(n + 1));
  });

  // Another server at the address answered the 401. Once the bound server
  // is verified again, the session resumes the pool: the queued jobs go out
  // again in this scope.
  test('resumed after the bound server is back: the queued jobs are tried '
      'again', () async {
    await _insertTrack(db, 'a');
    final pool = WorkerPool(
      queue: queue,
      downloader: await downloader(401),
      isOffline: () => offline,
      onCompleted: () {},
    );
    queue.addAll([_job('a')]);
    pool.pump();
    await settle();
    expect(pool.authPaused, isTrue);
    expect(requests, 1);

    pool.resumeAfterBoundServerBack();
    await settle();
    expect(requests, 2, reason: 'the queued download proceeds');
  });

  test('authPaused is its own flag, not the offline flag', () async {
    await _insertTrack(db, 'a');
    final pool = WorkerPool(
      queue: queue,
      downloader: await downloader(401),
      isOffline: () => offline,
      onCompleted: () {},
    );
    queue.addAll([_job('a')]);
    pool.pump();
    await settle();
    expect(pool.authPaused, isTrue);
    expect(offline, isFalse);
    expect(requests, 1);

    // Offline then online again (a health poll): still paused.
    offline = true;
    pool.pump();
    offline = false;
    pool.pump();
    await settle();
    expect(requests, 1);
    expect(queue.state.jobs.single.isQueued, isTrue);
  });
}
