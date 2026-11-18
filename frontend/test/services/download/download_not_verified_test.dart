// Sign-off OPEN-M-11 (2026-11-17): while the server is not verified the token
// client withholds a download's request (TokenWithheldException). For the
// downloads that is a wait, like a 401 or an outage: the downloader reports
// `notVerified`, the job goes back to Queued (never Failed), the pool pauses
// without a loop, and the next verification resumes it by itself.
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/token_permit.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download/download_queue.dart';
import 'package:frontend/services/download/track_downloader.dart';
import 'package:frontend/services/download/worker_pool.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/queue_warm_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/settings_service.dart';

import '../../helpers/server_binding.dart';
import '../../helpers/test_credentials.dart';

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

TrackUI _track(String uuid) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: 'Title $uuid',
  artist: 'Artist',
  duration: 120,
  bitrateKbps: 320,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

/// A permit the test switches (the binding gate in production).
class _Permit implements TokenPermit {
  bool allow = false;
  int asked = 0;
  @override
  bool allowsTokenTo(Uri url) {
    asked++;
    return allow;
  }

  @override
  Future<void> verdictSettled() async {}
}

class _NoWarm extends Fake implements QueueWarmService {
  @override
  void scheduleWarmUuids(List<String> trackUuids, {required String quality}) {}
  @override
  void dispose() {}
}

/// Waits until [done] holds, woken by [manager]'s change notifications and
/// bounded. A download does real file and database work (the folder
/// preparation and leftover sweep, the partial file, the rename, the record)
/// that a fixed count of event-queue turns does not wait for under load.
Future<void> _until(
  DownloadManager manager,
  bool Function() done,
  String what,
) async {
  if (done()) return;
  final reached = Completer<void>();
  void check() {
    if (!reached.isCompleted && done()) reached.complete();
  }

  manager.addListener(check);
  try {
    await reached.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('timed out waiting until $what'),
    );
  } finally {
    manager.removeListener(check);
  }
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late DownloadQueue queue;
  late _Permit permit;
  late int requests;
  late int networkFailures;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('download_not_verified_');
    queue = DownloadQueue();
    permit = _Permit();
    requests = 0;
    networkFailures = 0;
  });

  tearDown(() async {
    queue.dispose();
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ApiClient api() => testApiClient(
    'http://test:8080',
    AuthenticatedClient(
      MockClient((_) async {
        requests++;
        if (requests > 50) throw StateError('hot loop');
        return http.Response.bytes([1, 2, 3], 200);
      }),
      testCredentials,
      permit: permit,
    ),
  );

  Future<TrackDownloader> downloader() async {
    final client = api();
    return TrackDownloader(
      db: db,
      coverArtStore: await LocalCoverArtStore.create(
        directoryProvider: () async => tempDir,
        apiClient: client,
      ),
      directoryProvider: () async => tempDir,
      apiClient: client,
      onNetworkFailure: () => networkFailures++,
    );
  }

  /// Waits until no job is active, then a few more turns (a loop would keep
  /// asking the permit here).
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
    await pumpEventQueue(times: 20);
  }

  test('the downloader maps a withheld request to notVerified, with no '
      'offline signal', () async {
    await _insertTrack(db, 'abc');
    final outcome = await (await downloader()).download(
      job: _job('abc'),
      generationCheck: () => true,
      onProgress: (_) {},
      registerCanceller: (_) {},
      unregisterCanceller: () {},
    );
    expect(outcome.kind, DownloadOutcomeKind.notVerified);
    expect(requests, 0);
    expect(networkFailures, 0);
  });

  test('a queue of N jobs stays queued (none failed) and pauses, with no '
      'loop; resuming after verification downloads them', () async {
    const n = 7;
    for (var i = 0; i < n; i++) {
      await _insertTrack(db, 'u$i');
    }
    final pool = WorkerPool(
      queue: queue,
      downloader: await downloader(),
      isOffline: () => false,
      onCompleted: () {},
    );
    queue.addAll([for (var i = 0; i < n; i++) _job('u$i')]);

    pool.pump();
    await settle();

    expect(pool.verifyPaused, isTrue);
    expect(queue.state.jobs.where((j) => j.isQueued), hasLength(n),
        reason: 'no job fails or is dropped while not verified');
    expect(requests, 0);
    expect(permit.asked, lessThanOrEqualTo(WorkerPool.maxConcurrent),
        reason: 'only the jobs already started asked');
    final asked = permit.asked;

    pool.pump(); // an enqueue, or back online
    await settle();
    expect(permit.asked, asked, reason: 'paused: nothing restarts');

    permit.allow = true;
    pool.resumeAfterVerified();
    await settle();
    expect(pool.verifyPaused, isFalse);
    expect(requests, n);
    expect(queue.state.jobs.where((j) => j.status is Completed), hasLength(n));
  });

  test('the manager: resumeIfPaused (recovery after verification) resumes '
      'paused downloads', () async {
    await _insertTrack(db, 'abc');
    final client = api();
    final manager = DownloadManager(
      db: db,
      coverArtStore: await LocalCoverArtStore.create(
        directoryProvider: () async => tempDir,
        apiClient: client,
      ),
      directoryProvider: () async => tempDir,
      apiClient: client,
    );
    addTearDown(manager.dispose);
    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _until(manager, () => manager.state.jobs.single.isQueued,
        'the withheld attempt put the job back in the queue');
    expect(requests, 0);

    permit.allow = true;
    manager.resumeIfPaused();
    await _until(manager, () => manager.state.jobs.single.status is Completed,
        'the resumed download completed');
    expect(requests, 1);
    expect(manager.state.jobs.single.status, isA<Completed>());
  });

  // The production wiring: the next BindingVerified of the scope's gate
  // resumes paused downloads by itself (no recovery edge needed, e.g. after
  // a failed check that its own retry turns into a verified one).
  test('the scope: a verification resumes paused downloads, with the token',
      () async {
    SharedPreferences.setMockInitialValues({});
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
    await _insertTrack(db, 'abc');
    final controlled = ControlledGate(db);
    addTearDown(controlled.dispose);
    final seen = <http.BaseRequest>[];
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      httpClientProvider.overrideWithValue(MockClient((req) async {
        seen.add(req);
        return http.Response.bytes([1, 2, 3], 200);
      })),
      sessionUrlProvider.overrideWithValue('http://s'),
      credentialsProvider.overrideWithValue(testCredentials),
      serverBindingGateProvider.overrideWithValue(controlled.gate),
      coverArtDirectoryProvider.overrideWithValue(tempDir),
      downloadDirectoryProvider.overrideWithValue(() async => tempDir),
      queueWarmServiceProvider.overrideWithValue(_NoWarm()),
      streamQualityProvider.overrideWithValue('320'),
    ]);
    addTearDown(c.dispose);

    unawaited(controlled.gate.startConnection('http://s'));
    await pumpEventQueue();
    controlled.fail(ApiException(500, 'app/info broke'));
    await pumpEventQueue();
    expect(controlled.gate.state, isA<BindingUnverified>());

    final manager = c.read(downloadManagerProvider);
    await manager.enqueueTracks([_track('abc')], quality: '320');
    await _until(manager, () => manager.state.jobs.single.isQueued,
        'the withheld attempt put the job back in the queue');
    expect(seen, isEmpty, reason: 'withheld while unverified');

    unawaited(controlled.gate.startConnection('http://s'));
    await pumpEventQueue();
    controlled.respond('inst-1');
    await _until(manager, () => manager.state.jobs.single.status is Completed,
        'the verification resumed the download and it completed');

    expect(seen.single.url.path, '/tracks/abc/stream');
    expect(seen.single.headers['Authorization'],
        'Bearer ${testCredentials.token}');
    expect(manager.state.jobs.single.status, isA<Completed>());
  });
}
