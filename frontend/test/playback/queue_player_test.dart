import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';

import 'package:frontend/models/history_intent.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_service_bridge.dart';
import 'package:frontend/playback/audio_focus.dart';
import 'package:frontend/playback/just_audio_engine.dart';
import 'package:frontend/playback/playback_engine.dart';

import 'audio_focus_test.dart' show FakeAudioSessionPort;
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/download/download_status_reader.dart';
import 'package:frontend/services/download/download_reconciliation_service.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/session_readiness.dart';
import 'package:frontend/ui/playback_wiring.dart';
import 'package:frontend/ui/player_controller.dart';
import '../helpers/fake_clock.dart';
import '../helpers/playback_submit.dart';
import '../helpers/server_binding.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/queue_warm_service.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/playback/now_playing_publisher.dart';
import 'package:frontend/playback/playback_issue_bus.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/playback/source_failure_classifier.dart';
import 'package:frontend/playback/queue_warm_listener.dart';

void main() {
  late AppDatabase db;
  late _ObservedStartupRepository repo;
  late _LibraryFixture fixture;
  ProviderContainer? container;
  late FakePlaybackEngine fakePlayer;
  late RecordingAudioServiceBridge bridge;
  late FakeAudioSessionPort sessionPort;
  late _RecordingWarm warm;
  late _FlakyHistory history;
  late FakeClock testClock;
  final trackStatuses = <String, int?>{};
  Completer<void>? probeGate;

  final Set<String> existingFiles = <String>{};
  Completer<void>? fileGate;
  late StreamController<int> downloadStatusController;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // The real settings and warm services are built by QueuePlayer.
    // Keep their incidental requests in memory: localhost might be a real
    // server, and connection failures/retry timing are not audio fixtures.
    ApiClient.initForTest('http://audio.test', MockClient((request) async {
      if (request.url.path == '/settings/quality') {
        return http.Response('{"quality":"original"}', 200);
      }
      if (request.url.path == '/tracks/warm') {
        return http.Response('{}', 200);
      }
      throw StateError('Unexpected audio-test request: ${request.url}');
    }));
    initCoverArtCache(CoverArtCacheManager.noop());
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
    existingFiles.clear();
    repo = _ObservedStartupRepository(db);
    fixture = _LibraryFixture(db);
    fakePlayer = FakePlaybackEngine();
    bridge = RecordingAudioServiceBridge();
    sessionPort = FakeAudioSessionPort();
    warm = _RecordingWarm(repo);
    history = _FlakyHistory(db);
    testClock = FakeClock();
    trackStatuses.clear();
    probeGate = null;
    downloadStatusController = StreamController<int>.broadcast();
  });

  tearDown(() async {
    await bridge.disposeBridge();
    container?.dispose();
    await sessionPort.controller.close();
    await downloadStatusController.close();
    await db.close();
  });

  ProviderContainer createContainer({
    bool offline = false,
    SessionReadiness? readiness,
    OfflineModeNotifier Function()? offlineNotifier,
    PlaybackEngine? engine,
    AudioFocus? focus,
    Clock? clock,
    bool observers = true,
    bool controllableQuality = false,
    bool failingReconcile = false,
    _ScriptedSync? sync,
  }) {
    container = ProviderContainer(
      overrides: [
        if (sync != null) trackSyncProvider.overrideWith(() => sync),
        // Most tests run inside an active session; B8 tests pass their own.
        sessionReadinessProvider.overrideWithValue(
          readiness ?? (SessionReadiness()..markReady()),
        ),
        if (offlineNotifier != null)
          offlineModeProvider.overrideWith(offlineNotifier),
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(engine ?? fakePlayer),
        if (focus != null) audioFocusProvider.overrideWithValue(focus),
        queueWarmServiceProvider.overrideWithValue(warm),
        historyRepositoryProvider.overrideWithValue(history),
        clockProvider.overrideWithValue(clock ?? testClock),
        if (controllableQuality) ...[
          streamQualityProvider.overrideWith((ref) => ref.watch(_testQuality)),
          streamQualityChangeKindProvider
              .overrideWith((ref) => QualityChangeKind.full),
        ],
        downloadReconciliationServiceProvider.overrideWith((ref) =>
            failingReconcile
                ? _FailingReconcile(db)
                : DownloadReconciliationService(
              db: db,
              statusReader: DownloadStatusReader(db: db),
              fileExists: (path) async => existingFiles.contains(path),
            )),
        sourceFailureClassifierProvider.overrideWith((ref) =>
            SourceFailureClassifier(
              fileExists: (path) async => existingFiles.contains(path),
              trackKnownLocally: (uuid) async =>
                  (await db.getTrackByUuid(uuid)).isNotEmpty,
              fetchTrackStatus: (uuid) async {
                await probeGate?.future;
                return trackStatuses[uuid];
              },
              isOffline: () => ref.read(offlineModeProvider),
            )),
        audioServiceProvider.overrideWithValue(bridge),
        audioSessionPortProvider.overrideWithValue(sessionPort),
        queueRepositoryProvider.overrideWithValue(repo),
        playbackTargetResolverProvider.overrideWith((ref) =>
          PlaybackTargetResolver(repo, fileExists: (path) async {
            await fileGate?.future;
            return existingFiles.contains(path);
          })),
        downloadStatusVersionProvider.overrideWith(
          (ref) => downloadStatusController.stream,
        ),
        if (offline) offlineModeProvider.overrideWith(() => _OfflineOn()),
      ],
    );
    // Hold a long-lived listener on the audio notifier so its in-build
    // ref.listen subscriptions stay active. Without this, riverpod 3 treats
    // the notifier as paused once the test stops reading it, which silently
    // suppresses downstream StreamProvider emissions.
    container!.listen(queuePlayerProvider, (_, _) {});
    if (observers) {
      // What playbackWiringProvider keeps alive in the app.
      container!.listen(nowPlayingPublisherProvider, (_, _) {});
      container!.listen(queueWarmListenerProvider, (_, _) {});
    }
    return container!;
  }

  /// The active session's tracks in play order, read from the repository
  /// (replaces the deleted test-only `queueTracksProvider`).
  Future<List<QueueTrackEntry>> sessionTracksOf(ProviderContainer c) async {
    final sessionId = c.read(queuePlayerProvider).queue.sessionId;
    if (sessionId == null) return const [];
    return repo.getSessionTracksInPlayOrder(sessionId);
  }

  Future<void> markDownloaded(String uuid, String path) async {
    await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid))).write(
      TracksCompanion(filePath: Value(path)),
    );
    existingFiles.add(path);
  }

  Future<void> markDeleted(String uuid, String path) async {
    await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid))).write(
      const TracksCompanion(filePath: Value(null)),
    );
    existingFiles.remove(path);
  }

  group('5B.0a characterization', () {
    test('the player fake seeds silently like the production adapter', () async {
      await fixture.insertSingles(['a', 'b']);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'test', trackUuids: ['a', 'b'],
      );
      final entries = await repo.getPlaybackEntries(sessionId, startPlayPosition: 0, limit: 2);
      final events = <int?>[];
      final sub = fakePlayer.currentItemIdStream.listen(events.add);
      addTearDown(sub.cancel);
      addTearDown(fakePlayer.dispose);
      await fakePlayer.setSeed(entries, currentItemId: entries.first.itemId);
      await pumpEventQueue();
      expect(fakePlayer.currentItemId, entries.first.itemId);
      expect(events, isEmpty, reason: 'structural seeding never emits a natural transition');
    });

    Future<ProviderContainer> start(List<String> uuids) async {
      await fixture.insertSingles(uuids.toSet().toList());
      final c = createContainer();
      await repo.startupRead.future;
      await playFromTrackList(c, uuids, await fixture.track(uuids.first), sourceType: 'test',
      );
      await pumpEventQueue();
      return c;
    }

    test('start, item change and stop publish the expected now-playing sequence', () async {
      final c = await start(['a', 'b']);
      expect(bridge.mediaItemEvents.map((e) => e?.id), [null, 'a']);
      await c.read(queuePlayerProvider.notifier).skipNext();
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(bridge.mediaItemEvents.map((e) => e?.id), [null, 'a', 'b']);
      await c.read(queuePlayerProvider.notifier).stop();
      await pumpEventQueue();
      expect(bridge.mediaItemEvents.map((e) => e?.id), [null, 'a', 'b', null]);
      expect(bridge.mediaItemEvents.last, isNull);
      expect(c.read(queuePlayerProvider).queue.sessionId, isNull);
      expect(await repo.getActiveSession(), isNull);
    });

    test('reconcile of an empty queue clears now-playing and persisted session', () async {
      final c = await start(['a']);
      final id = c.read(queuePlayerProvider).queue.sessionId!;
      await repo.removeTrackUuidsFromQueues(['a']);
      await c.read(queuePlayerProvider.notifier).reconcileAfterSyncQueueMutation({id});
      await pumpEventQueue();
      expect(bridge.mediaItemEvents.last, isNull);
      expect(c.read(currentTrackProvider), isNull);
      expect(c.read(queuePlayerProvider).queue.sessionId, isNull);
      expect(await repo.getActiveSession(), isNull);
    });

    test('duplicate track UUIDs retain distinct queue item identities', () async {
      final c = await start(['a', 'b', 'a']);
      final entries = await sessionTracksOf(c);
      expect(entries.map((e) => e.uuidId), ['a', 'b', 'a']);
      expect(entries.map((e) => e.itemId).toSet(), hasLength(3));
      await c.read(queuePlayerProvider.notifier).skipToTrack(entries.last.itemId);
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      expect(c.read(queuePlayerProvider).queue.currentItemId, entries.last.itemId);
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 2);
      expect((await repo.getActiveSession())?.currentItemId, entries.last.itemId);
    });

    test('a delayed startup snapshot cannot replace newer explicit playback', () async {
      await fixture.insertSingles(['a', 'b']);
      await repo.createSessionFromExplicitList(sourceType: 'saved', trackUuids: ['a']);
      final release = Completer<void>();
      repo.startupRelease = release;
      final c = createContainer();
      await repo.startupRead.future;
      await play(c, await fixture.track('b'));
      final currentSession = c.read(queuePlayerProvider).queue.sessionId;
      release.complete();
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(c.read(queuePlayerProvider).queue.sessionId, currentSession);
      expect(fakePlayer.seedCalls, hasLength(1));
      expect(fakePlayer.currentUuid, 'b');
      expect((await repo.getActiveSession())?.id, currentSession);
    });

    test('delayed artwork preserves the started identity and publishes once', () async {
      await fixture.insertSingles(['a']);
      await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals('a'))).write(
        const TrackmetadataCompanion(hasAlbumArt: Value(true), coverArtId: Value(7)),
      );
      final art = _GatedCoverArt();
      initCoverArtCache(art);
      final c = createContainer();
      await repo.startupRead.future;
      final starting = play(c, await fixture.track('a'));
      await art.entered.future;
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      expect(fakePlayer.currentUuid, 'a');
      expect(bridge.mediaItemEvents.whereType<MediaItem>(), isEmpty);
      final uri = Uri.parse('file:///test-art/a.png');
      art.release.complete(uri);
      await starting;
      await pumpEventQueue();
      final published = bridge.mediaItemEvents.whereType<MediaItem>().toList();
      expect(published, hasLength(1));
      expect(published.single.id, 'a');
      expect(published.single.artUri, uri);
    });
  });

  test('window coverage cannot advance while engine addition is pending', () async {
    final uuids = List.generate(100, (i) => 't$i');
    await fixture.insertSingles(uuids);
    final c = createContainer();
    await repo.startupRead.future;
    final notifier = c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, uuids, await fixture.track('t0'), sourceType: 'test');
    final window = c.read(queueWindowProvider);
    final before = fakePlayer.seedCalls.single.entries.last.playPosition + 1;
    expect(window.nextForwardHydrationPlayPosition, before);
    final release = Completer<void>();
    final entered = Completer<void>();
    fakePlayer.addEntriesRelease = release;
    fakePlayer.addEntriesEntered = entered;
    // 5B.0d: a far jump rebases; forward hydration is what extends the
    // window. Moving near its end schedules the next chunk.
    final target = (await sessionTracksOf(c))[40];
    final skipping = notifier.skipToTrack(target.itemId);
    await entered.future;
    try {
      expect(window.nextForwardHydrationPlayPosition, before,
          reason: 'unapplied sources do not count as coverage');
    } finally {
      release.complete();
      await skipping;
      await pumpEventQueue();
    }
    expect(window.nextForwardHydrationPlayPosition, 100);
    expect(fakePlayer.addedBatches.last.last.playPosition, 99);
    expect(c.read(queuePlayerProvider).queue.currentItemId, target.itemId);
  });

  group('5B.0d (SC-27 invariant 7): one contiguous engine window', () {
    void expectContiguous(String why) {
      final positions = fakePlayer.loadedPlayPositions;
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i], positions[i - 1] + 1, reason: why);
      }
    }

    Future<ProviderContainer> playing100({int start = 0}) async {
      final uuids = List.generate(100, (i) => 't$i');
      await fixture.insertSingles(uuids);
      final c = createContainer();
      await repo.startupRead.future;
      await playFromTrackList(c, uuids, await fixture.track('t$start'), sourceType: 'test');
      await pumpEventQueue();
      return c;
    }

    test('a distant jump rebases around its target; so does returning',
        () async {
      final c = await playing100();
      final notifier = c.read(queuePlayerProvider.notifier);
      final window = c.read(queueWindowProvider);
      final tracks = await sessionTracksOf(c);
      await notifier.skipToTrack(tracks[99].itemId);
      await pumpEventQueue();
      expect(fakePlayer.seedCalls.last.currentItemId, tracks[99].itemId);
      expectContiguous('after the jump');
      expect(window.windowStartPlayPosition, fakePlayer.loadedPlayPositions.first);
      expect(window.nextForwardHydrationPlayPosition,
          fakePlayer.loadedPlayPositions.last + 1);
      final seeds = fakePlayer.seedCalls.length;
      await notifier.skipToTrack(tracks[10].itemId);
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.seedCalls.last.currentItemId, tracks[10].itemId);
      expectContiguous('after returning');
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 10);
    });

    test('a chunk queued behind a replacing operation is not applied',
        () async {
      final c = await playing100();
      final notifier = c.read(queuePlayerProvider.notifier);
      final tracks = await sessionTracksOf(c);
      final read = repo.hydrationGate = Completer<void>();
      await notifier.skipToTrack(tracks[40].itemId);
      await repo.hydrationEntered.future;
      repo.hydrationGate = null;
      // A stop holds the lane; the chunk read finishes meanwhile, so its
      // application queues behind the stop.
      final stopGate = repo.deactivateGate = Completer<void>();
      final stopping = notifier.stop();
      await repo.deactivateEntered.future;
      final added = fakePlayer.addedBatches.length;
      read.complete();
      await pumpEventQueue();
      expect(fakePlayer.addedBatches, hasLength(added),
          reason: 'the application waits for the stop in the lane');
      stopGate.complete();
      await stopping;
      await pumpEventQueue();
      expect(fakePlayer.addedBatches, hasLength(added),
          reason: 'no session remains for the queued chunk');
    });

    test('removing an item before the window shifts the window with it',
        () async {
      final c = await playing100();
      final notifier = c.read(queuePlayerProvider.notifier);
      final window = c.read(queueWindowProvider);
      final tracks = await sessionTracksOf(c);
      await notifier.skipToTrack(tracks[99].itemId);
      await pumpEventQueue();
      final start = window.windowStartPlayPosition!;
      final end = window.nextForwardHydrationPlayPosition;
      await notifier.removeFromQueue(tracks[10].itemId);
      await pumpEventQueue();
      expect(window.windowStartPlayPosition, start - 1);
      expect(window.nextForwardHydrationPlayPosition, end - 1);
      expect(fakePlayer.loadedPlayPositions.first, start - 1,
          reason: 'the window matches what the engine holds');
    });

    test('a hydration proposal for a replaced session is discarded', () async {
      final c = await playing100();
      final notifier = c.read(queuePlayerProvider.notifier);
      final tracks = await sessionTracksOf(c);
      final gate = repo.hydrationGate = Completer<void>();
      // The seed holds positions 0..60; within 24 of its end, hydrate.
      await notifier.skipToTrack(tracks[40].itemId);
      await repo.hydrationEntered.future;
      repo.hydrationGate = null;
      await fixture.insertSingles(['x', 'y']);
      await playFromTrackList(c, const ['x', 'y'], await fixture.track('x'), sourceType: 'test');
      final added = fakePlayer.addedBatches.length;
      gate.complete();
      await pumpEventQueue();
      expect(fakePlayer.addedBatches, hasLength(added),
          reason: "the old session's chunk is not applied to the new one");
      expect(fakePlayer.loadedPlayPositions, [0, 1]);
    });

    test('repeat-all loops natively over a window that holds the queue',
        () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b', 'c'], await fixture.track('a'), sourceType: 'test');
      await notifier.cycleQueueRepeatMode();
      expect(fakePlayer.lastLoopMode, EngineLoopMode.all);
    });

    test('repeat-all does not loop natively over a partial window', () async {
      final c = await playing100();
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode();
      expect(c.read(queuePlayerProvider).queue.repeatMode, QueueRepeatMode.all);
      expect(fakePlayer.lastLoopMode, EngineLoopMode.off,
          reason: 'native wrap inside a partial window would skip positions');
    });

    test('repeat-all wraps to the first item at the end of the queue',
        () async {
      final c = await playing100(start: 99);
      final notifier = c.read(queuePlayerProvider.notifier);
      await notifier.cycleQueueRepeatMode();
      final tracks = await sessionTracksOf(c);
      final plays = fakePlayer.playCalls;
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(c.read(queuePlayerProvider).queue.currentItemId, tracks[0].itemId);
      expect(fakePlayer.hasItem(tracks[0].itemId), isTrue);
      expect(fakePlayer.playCalls, plays + 1);
      expectContiguous('after the wrap');
    });

    test('the end of a partial window continues to the next item', () async {
      final c = await playing100();
      final notifier = c.read(queuePlayerProvider.notifier);
      final tracks = await sessionTracksOf(c);
      repo.hydrationGate = Completer<void>(); // hydration lags behind
      await notifier.skipToTrack(tracks[60].itemId); // the window's last
      await pumpEventQueue();
      final plays = fakePlayer.playCalls;
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(c.read(queuePlayerProvider).queue.currentItemId, tracks[61].itemId);
      expect(fakePlayer.playCalls, plays + 1);
      expectContiguous('after continuing');
      repo.hydrationGate!.complete();
    });

    test('coverage is not acknowledged when the engine call fails', () async {
      final c = await playing100();
      c.read(queuePlayerProvider.notifier);
      final window = c.read(queueWindowProvider);
      final before = window.nextForwardHydrationPlayPosition;
      await fixture.insertSingles(['z']);
      fakePlayer.replaceFutureEntriesError = StateError('engine refused');
      await expectLater(playNext(c, [await fixture.track('z')]),
          throwsStateError);
      expect(window.nextForwardHydrationPlayPosition, before);
    });
  });

  group('5B.0d (SC-27): now-playing and queue warm are observers', () {
    test('the playback core itself publishes nothing to the OS or warm',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer(observers: false);
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      await notifier.skipNext();
      await notifier.stop();
      await pumpEventQueue();
      expect(bridge.mediaItemEvents.whereType<MediaItem>(), isEmpty);
      expect(bridge.playbackStateEvents, hasLength(1),
          reason: 'only the handler\'s initial state');
      expect(warm.calls, isEmpty);
    });

    test('artwork pending for a superseded item is dropped (latest wins)',
        () async {
      await fixture.insertSingles(['a', 'b']);
      await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals('a')))
          .write(const TrackmetadataCompanion(
              hasAlbumArt: Value(true), coverArtId: Value(7)));
      final art = _GatedCoverArt();
      initCoverArtCache(art);
      final c = createContainer();
      await repo.startupRead.future;
      final notifier = c.read(queuePlayerProvider.notifier);
      final starting = playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      await art.entered.future;
      final skipping = notifier.skipNext();
      await pumpEventQueue();
      art.release.complete(Uri.parse('file:///test-art/a.png'));
      await starting;
      await skipping;
      await pumpEventQueue();
      expect(bridge.mediaItemEvents.whereType<MediaItem>().map((m) => m.id),
          ['b']);
    });

    test('a clear drops artwork still pending for the cleared item',
        () async {
      await fixture.insertSingles(['a']);
      await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals('a')))
          .write(const TrackmetadataCompanion(
              hasAlbumArt: Value(true), coverArtId: Value(7)));
      final art = _GatedCoverArt();
      initCoverArtCache(art);
      final c = createContainer();
      await repo.startupRead.future;
      final notifier = c.read(queuePlayerProvider.notifier);
      final starting = play(c, await fixture.track('a'));
      await art.entered.future;
      final stopping = notifier.stop();
      await pumpEventQueue();
      art.release.complete(Uri.parse('file:///test-art/a.png'));
      await starting;
      await stopping;
      await pumpEventQueue();
      expect(bridge.mediaItemEvents.whereType<MediaItem>(), isEmpty);
      expect(bridge.mediaItemEvents.last, isNull);
    });

    test('queue warm follows the session, position and quality', () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      final sessionId = c.read(queuePlayerProvider).queue.sessionId;
      expect(warm.calls.last, (sessionId, 0));
      await notifier.skipNext();
      await pumpEventQueue();
      expect(warm.calls.last, (sessionId, 1));
    });
  });

  group('5B.0d (SC-06/SC-27): resolver issues are published by the core', () {
    Future<void> recordedButMissing(String uuid, String path) async {
      await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid)))
          .write(TracksCompanion(filePath: Value(path)));
    }

    test('offline, a missing download is published and playback falls back',
        () async {
      await fixture.insertSingles(['a', 'b']);
      await recordedButMissing('a', '/dl/a');
      await markDownloaded('b', '/dl/b');
      final c = createContainer(offline: true);
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(issues, const [LocalFileMissing('a', '/dl/a')]);
    });

    test('issues found by a rejected start are still published', () async {
      await fixture.insertSingles(['a']);
      await recordedButMissing('a', '/dl/a');
      final c = createContainer(offline: true);
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      await playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      expect(c.read(currentTrackProvider), isNull);
      expect(issues, const [LocalFileMissing('a', '/dl/a')]);
    });
  });

  group('5B.0d (SC-27 §2.9): honest failure classification, bounded recovery',
      () {
    late List<PlaybackIssue> issues;

    Future<ProviderContainer> playingList(List<String> uuids,
        {bool offline = false}) async {
      final c = createContainer(offline: offline);
      issues = [];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      await playFromTrackList(c, uuids, await fixture.track(uuids.first), sourceType: 'test');
      await pumpEventQueue();
      return c;
    }

    Future<void> fail({int? itemId, int? sourceId, bool uncertain = false}) async {
      fakePlayer.emitSourceFailure(
          itemId: itemId, sourceId: sourceId, uncertain: uncertain);
      await pumpEventQueue();
    }

    test('online, a missing local file falls back to the stream', () async {
      await fixture.insertSingles(['a', 'b']);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
          .write(const TracksCompanion(filePath: Value('/dl/a')));
      existingFiles.add('/dl/a'); // present at the start
      final c = await playingList(const ['a', 'b']);
      existingFiles.remove('/dl/a'); // then the file vanishes
      final seeks = fakePlayer.seekedItems.length;
      await fail();
      await fail(); // the same source reported again: handled once
      expect(issues, contains(const LocalFileMissing('a', '/dl/a')));
      expect(fakePlayer.refreshedSources.single.newHasFile, isFalse,
          reason: 'the current source is rebuilt as the stream, once');
      expect(fakePlayer.seekedItems, hasLength(seeks), reason: 'no skip');
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
    });

    test('offline, a missing local file skips to the next playable item',
        () async {
      await fixture.insertSingles(['a', 'b']);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
          .write(const TracksCompanion(filePath: Value('/dl/a')));
      await markDownloaded('b', '/dl/b');
      existingFiles.add('/dl/a'); // present when the start was resolved
      final c = await playingList(const ['a', 'b'], offline: true);
      existingFiles.remove('/dl/a'); // then deleted behind the app's back
      await fail();
      expect(issues, contains(const LocalFileMissing('a', '/dl/a')));
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(fakePlayer.seekCauses.last, PlaybackTransitionCause.naturalAdvance);
    });

    test('a track deleted on the server (404) is gone and skipped', () async {
      await fixture.insertSingles(['a', 'b']);
      trackStatuses['a'] = 404;
      final c = await playingList(const ['a', 'b']);
      await fail();
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind),
          [SourceFailureKind.gone]);
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
    });

    test('a track tombstoned by sync is gone without a network check',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final c = await playingList(const ['a', 'b']);
      await db.customStatement("DELETE FROM tracks WHERE uuid_id = 'a'");
      await fail();
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind),
          [SourceFailureKind.gone]);
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
    });

    test('a transient failure never skips; a repeat is not re-checked',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final c = await playingList(const ['a', 'b']);
      await fail(); // no answer from the track check
      await fail(); // the same source reported again
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind),
          [SourceFailureKind.transient]);
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      expect(fakePlayer.stopCalls, 0);
    });

    test('a failure of a track the server still has is unknown, no skip',
        () async {
      await fixture.insertSingles(['a', 'b']);
      trackStatuses['a'] = 200;
      final c = await playingList(const ['a', 'b']);
      await fail();
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind),
          [SourceFailureKind.unknown]);
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
    });

    test('an uncertain failure is unknown and never skips', () async {
      await fixture.insertSingles(['a', 'b']);
      trackStatuses['a'] = 404;
      final c = await playingList(const ['a', 'b']);
      await fail(uncertain: true);
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind),
          [SourceFailureKind.unknown]);
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
    });

    test('after a stream fallback, a failure is a stream failure', () async {
      await fixture.insertSingles(['a', 'b']);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
          .write(const TracksCompanion(filePath: Value('/dl/a')));
      existingFiles.add('/dl/a'); // present at the start
      trackStatuses['a'] = 404;
      final c = await playingList(const ['a', 'b']);
      existingFiles.remove('/dl/a'); // then the file vanishes
      await fail(); // the file is missing: fall back to the stream
      await fail(sourceId: 9999); // the stream source fails too: gone
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind), [
        SourceFailureKind.missingLocalFile,
        SourceFailureKind.gone,
      ]);
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
    });

    test('pause never waits behind a failure being classified', () async {
      await fixture.insertSingles(['a', 'b']);
      trackStatuses['a'] = 404;
      final c = await playingList(const ['a', 'b']);
      final notifier = c.read(queuePlayerProvider.notifier);
      final gate = probeGate = Completer<void>();
      fakePlayer.emitSourceFailure();
      await pumpEventQueue();
      var paused = false;
      unawaited(notifier.pause().then((_) => paused = true));
      await pumpEventQueue();
      expect(paused, isTrue, reason: 'the probe runs outside the lane');
      expect(fakePlayer.pauseCalls, 1);
      gate.complete();
      await pumpEventQueue();
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind),
          [SourceFailureKind.gone]);
      expect(c.read(currentTrackProvider)?.uuidId, 'b',
          reason: 'the decision still applies when it is current');
    });

    test('a recovery decision for a replaced item is not applied', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      trackStatuses['a'] = 404;
      final c = await playingList(const ['a', 'b', 'c']);
      final notifier = c.read(queuePlayerProvider.notifier);
      final tracks = await sessionTracksOf(c);
      final gate = probeGate = Completer<void>();
      fakePlayer.emitSourceFailure();
      await pumpEventQueue();
      final skipping = notifier.skipToTrack(tracks[2].itemId); // user moves on
      await pumpEventQueue();
      gate.complete();
      await skipping;
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'c',
          reason: "a's skip decision no longer applies");
      expect(fakePlayer.stopCalls, 0);
    });

    test('an all-gone repeat-all queue stops after one full cycle', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      for (final uuid in ['a', 'b', 'c']) {
        trackStatuses[uuid] = 410;
      }
      final c = await playingList(const ['a', 'b', 'c']);
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode();
      for (var i = 0; i < 4; i++) {
        await fail();
      }
      expect(issues.whereType<PlaybackRecoveryExhausted>(), hasLength(1));
      expect(fakePlayer.stopCalls, 1);
      expect(fakePlayer.seekedItems.length, lessThanOrEqualTo(2),
          reason: 'a and b are skipped once; c would wrap back to a');
    });

    test('branch audit (5B.0d m2): a user resume after exhaustion starts a '
        'new failure run', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      for (final uuid in ['a', 'b', 'c']) {
        trackStatuses[uuid] = 410;
      }
      final c = await playingList(const ['a', 'b', 'c']);
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode();
      for (var i = 0; i < 4; i++) {
        await fail();
      }
      expect(issues.whereType<PlaybackRecoveryExhausted>(), hasLength(1));
      final before = issues.whereType<PlaybackSourceFailed>().length;
      await c.read(queuePlayerProvider.notifier).resume(); // the user taps Play
      await fail(sourceId: 4242);
      expect(issues.whereType<PlaybackSourceFailed>().length, before + 1,
          reason: 'the new failure is classified and published, not silenced');
    });

    test('the same failure reported twice is handled once', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      trackStatuses['a'] = 404;
      final c = await playingList(const ['a', 'b', 'c']);
      final tracks = await sessionTracksOf(c);
      fakePlayer.emitSourceFailure(itemId: tracks[0].itemId);
      fakePlayer.emitSourceFailure(itemId: tracks[0].itemId);
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'b',
          reason: 'one skip, not two');
    });
  });

  group('5B.0d (SC-27 invariant 13): error sinks and commit-last', () {
    test('a failing listener task reports a diagnostic', () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer();
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      final tracks = await sessionTracksOf(c);
      repo.getTrackForItemError = StateError('db gone');
      await fakePlayer.seekToItem(tracks[1].itemId); // engine-side change
      await pumpEventQueue();
      expect(issues.whereType<PlaybackTaskFailed>(), isNotEmpty);
    });

    test('a start that cannot read its track leaves the engine untouched',
        () async {
      await fixture.insertSingles(['a']);
      final c = createContainer();
      await repo.startupRead.future;
      repo.getTrackForItemError = StateError('db gone');
      await expectLater(
          playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'test'),
          throwsStateError);
      expect(fakePlayer.seedCalls, isEmpty,
          reason: 'state is read before the engine is reseeded');
      expect(c.read(queuePlayerProvider).queue.sessionId, isNull);
    });
  });

  group('5B.0d audit (a) round 2', () {
    test("a rebase's failed load is attributed to the rebased target",
        () async {
      final uuids = List.generate(120, (i) => 'u$i');
      await fixture.insertSingles(uuids);
      trackStatuses['u99'] = 404;
      final c = createContainer();
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, uuids, await fixture.track('u0'),
          sourceType: 'test');
      final tracks = await sessionTracksOf(c);
      final gate = repo.trackReadGate = Completer<void>();
      repo.trackReadGateItem = tracks[99].itemId;
      final skipping = notifier.skipToTrack(tracks[99].itemId);
      await repo.trackReadEntered.future; // seeded; state not yet published
      fakePlayer.emitLoadEvent(EngineLoadEvent(
          playlistRevision: fakePlayer.playlistRevision,
          outcome: EngineLoadOutcome.failed));
      await pumpEventQueue();
      gate.complete();
      await skipping;
      await pumpEventQueue();
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.trackUuid),
          ['u99']);
      expect(c.read(currentTrackProvider)?.uuidId, 'u100');
    });

    test('a stream fallback stays remembered after the stream plays',
        () async {
      await fixture.insertSingles(['a', 'b']);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
          .write(const TracksCompanion(filePath: Value('/dl/a')));
      existingFiles.add('/dl/a'); // present at the start
      trackStatuses['a'] = 404;
      final c = createContainer();
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      existingFiles.remove('/dl/a'); // then the file vanishes
      fakePlayer.emitSourceFailure(); // missing file: fall back to stream
      await pumpEventQueue();
      fakePlayer.emitObservation(); // the stream plays ...
      await pumpEventQueue();
      fakePlayer.emitPlayingObservation();
      await pumpEventQueue();
      fakePlayer.emitSourceFailure(sourceId: 9999); // ... then fails: gone
      await pumpEventQueue();
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind), [
        SourceFailureKind.missingLocalFile,
        SourceFailureKind.gone,
      ]);
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
    });
  });

  group('5B.0d audit (a) round 3', () {
    test('a confirmed missing file is cleared from the catalog', () async {
      await fixture.insertSingles(['a', 'b']);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
          .write(const TracksCompanion(filePath: Value('/dl/a')));
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      fakePlayer.emitSourceFailure();
      await pumpEventQueue();
      final row = await (db.select(db.tracks)
            ..where((t) => t.uuidId.equals('a')))
          .getSingle();
      expect(row.filePath, isNull,
          reason: 'later rebuilds then load the stream, not the missing file');
    });

    test('after a fallback, a rebuild from the catalog stays a stream',
        () async {
      await fixture.insertSingles(['a', 'b']);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
          .write(const TracksCompanion(filePath: Value('/dl/a')));
      existingFiles.add('/dl/a'); // present at the start
      trackStatuses['a'] = 404;
      final c = createContainer();
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      existingFiles.remove('/dl/a'); // then the file vanishes
      fakePlayer.emitSourceFailure(); // missing: fall back to the stream
      await pumpEventQueue();
      fakePlayer.emitPlayingObservation(); // the stream plays
      await pumpEventQueue();
      downloadStatusController.add(1); // a download change refreshes sources
      downloadStatusController.add(2);
      await pumpEventQueue();
      expect(fakePlayer.refreshedSources.where((r) => r.newHasFile), isEmpty,
          reason: 'never back to the missing file');
      fakePlayer.emitSourceFailure(sourceId: 9999); // the stream fails: gone
      await pumpEventQueue();
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind), [
        SourceFailureKind.missingLocalFile,
        SourceFailureKind.gone,
      ]);
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
    });
  });

  group('5B.0d audit (a) round 4 minors', () {
    test('a failed catalog reconcile does not stop the recovery', () async {
      await fixture.insertSingles(['a', 'b']);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
          .write(const TracksCompanion(filePath: Value('/dl/a')));
      await markDownloaded('b', '/dl/b');
      existingFiles.add('/dl/a');
      final c = createContainer(offline: true, failingReconcile: true);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      existingFiles.remove('/dl/a');
      fakePlayer.emitSourceFailure();
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
    });

    test('an unavailable advance for an item no longer current is ignored',
        () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('a'), sourceType: 'test');
      final tracks = await sessionTracksOf(c);
      await notifier.skipToTrack(tracks[2].itemId);
      await notifier.pause();
      final seeks = fakePlayer.seekedItems.length;
      final plays = fakePlayer.playCalls;
      fakePlayer.emitUnavailableAdvance(UnavailableAdvance(
          itemId: tracks[0].itemId, playPosition: 0)); // stale
      await pumpEventQueue();
      expect(fakePlayer.seekedItems, hasLength(seeks));
      expect(fakePlayer.playCalls, plays, reason: 'a pause is not overridden');
      expect(fakePlayer.stopCalls, 0, reason: 'nor is c stopped');
    });
  });

  group('5B.0d audit (b) minors', () {
    test('the OS shows the measured duration when the catalog lacks it',
        () async {
      await fixture.insertSingles(['a']);
      await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals('a')))
          .write(const TrackmetadataCompanion(duration: Value(null)));
      final c = createContainer();
      await playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      expect(bridge.mediaItemEvents.last?.duration, isNull);
      fakePlayer.emitObservation(duration: const Duration(seconds: 200));
      await pumpEventQueue();
      expect(bridge.mediaItemEvents.last?.duration,
          const Duration(seconds: 200));
    });

    test('a quiesced core publishes a coherent empty state', () async {
      await fixture.insertSingles(['a']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'test');
      await notifier.seek(const Duration(seconds: 30));
      await notifier.quiesce();
      final playback = c.read(queuePlayerProvider).playback;
      expect(playback.currentTrack, isNull);
      expect(playback.position, Duration.zero);
      expect(playback.duration, isNull);
    });
  });

  group('5B.1 (SC-05): PlaybackRequests.submit', () {
    PlaybackRequests requestsOf(ProviderContainer c) =>
        c.read(playbackRequestsProvider);

    test('an accepted list request plays and names its session', () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer();
      final outcome = await requestsOf(c)
          .submit(const PlayList(['a', 'b'], 1, ListSource('search')));
      expect(outcome, isA<Accepted>());
      expect((outcome as Accepted).sessionId,
          c.read(queuePlayerProvider).queue.sessionId);
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect((await repo.getActiveSession())?.id, outcome.sessionId);
    });

    test('an empty request is rejected and changes nothing', () async {
      final c = createContainer();
      expect(await requestsOf(c).submit(
          const PlayList([], 0, ListSource('search'))), isA<RejectedEmpty>());
      expect(await requestsOf(c).submit(
          const Enqueue([], EnqueuePosition.end)), isA<RejectedEmpty>());
      expect(fakePlayer.seedCalls, isEmpty);
    });

    test('a rejected offline request leaves the current queue untouched',
        () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      final c = createContainer(offline: true);
      final requests = requestsOf(c);
      await requests.submit(const PlayList(['a'], 0, ListSource('search')));
      final before = c.read(queuePlayerProvider);
      final activeBefore = (await repo.getActiveSession())?.id;
      final seeds = fakePlayer.seedCalls.length;
      final outcome = await requests
          .submit(const PlayList(['b'], 0, ListSource('search')));
      expect(outcome, isA<RejectedUnplayableOffline>());
      expect((await repo.getActiveSession())?.id, activeBefore);
      expect(fakePlayer.seedCalls, hasLength(seeds), reason: 'audio untouched');
      expect(c.read(queuePlayerProvider).queue.sessionId, before.queue.sessionId);
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      expect(await repo.pruneInactiveSessions(), 0,
          reason: 'the prepared session was discarded');
    });

    test('the newest replacement wins; the older one is superseded',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer();
      final requests = requestsOf(c);
      final first =
          requests.submit(const PlayList(['a'], 0, ListSource('search')));
      final second =
          requests.submit(const PlayList(['b'], 0, ListSource('search')));
      expect(await first, isA<Superseded>());
      expect(await second, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(fakePlayer.seedCalls, hasLength(1),
          reason: 'the superseded request never reached the engine');
      expect(await repo.pruneInactiveSessions(), 0);
    });

    test('stop supersedes a request that has not activated yet', () async {
      await fixture.insertSingles(['a']);
      final c = createContainer();
      final pending =
          requestsOf(c).submit(const PlayList(['a'], 0, ListSource('search')));
      await c.read(queuePlayerProvider.notifier).stop();
      expect(await pending, isA<Superseded>());
      expect(fakePlayer.seedCalls, isEmpty);
    });

    test('an Enqueue behind a pending replacement targets its session',
        () async {
      await fixture.insertSingles(['a', 'b', 'x']);
      final c = createContainer();
      final requests = requestsOf(c);
      final replacing =
          requests.submit(const PlayList(['a', 'b'], 0, ListSource('search')));
      final enqueue =
          requests.submit(const Enqueue(['x'], EnqueuePosition.end));
      final accepted = await replacing as Accepted;
      expect(await enqueue, isA<Accepted>());
      final tracks = await repo.getSessionTracksInPlayOrder(accepted.sessionId);
      // Add to queue plays right after the current track (manual queue).
      expect(tracks.map((t) => t.track.uuidId), ['a', 'x', 'b']);
    });

    test('the no-session Enqueue starts a queue under the offline policy',
        () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('b', '/dl/b');
      final c = createContainer(offline: true);
      final outcome = await requestsOf(c)
          .submit(const Enqueue(['a', 'b'], EnqueuePosition.next));
      expect(outcome, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'b',
          reason: 'offline it lands on the playable item');
    });

    test('sticky shuffle applies when the session is created', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);
      final c = createContainer();
      await c.read(queuePlayerProvider.notifier).toggleShuffle(); // no session yet
      final outcome = await requestsOf(c).submit(
          const PlayList(['a', 'b', 'c', 'd'], 0, ListSource('search')));
      final session = await repo.getSessionSnapshot((outcome as Accepted).sessionId);
      expect(session?.session.shuffleEnabled, isTrue);
      expect(fakePlayer.rebuildCalls, isEmpty,
          reason: 'no start-then-shuffle rebuild');
      expect(c.read(shuffleProvider), isTrue);
    });

    test('startup prunes inactive sessions left by a previous run', () async {
      await fixture.insertSingles(['a', 'b']);
      final kept = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['a']);
      final stale = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['b'], activate: false);
      createContainer();
      await repo.startupRead.future;
      await pumpEventQueue();
      expect(await repo.getSessionSnapshot(stale), isNull,
          reason: 'a prepared session of the previous run is gone');
      expect((await repo.getActiveSession())?.id, kept);
    });

    test('an enqueue for a session that is no longer current is superseded',
        () async {
      await fixture.insertSingles(['a', 'x']);
      final c = createContainer();
      await requestsOf(c).submit(const PlayList(['a'], 0, ListSource('search')));
      final result = await c.read(queuePlayerProvider.notifier)
          .enqueue(const ['x'], EnqueuePosition.end, expectedSessionId: -1);
      expect(result, EnqueueResult.superseded);
    });
  });

  group('5B.1 (SC-05, Phase 5 §6): one accepted-intent emit site', () {
    Future<List<HistoryEvent>> clicks() => (db.select(db.historyEvents)
          ..where((e) => e.kind.equals('clicked'))
          ..orderBy([(e) => OrderingTerm(expression: e.localId)]))
        .get();

    test('an accepted request with an intent records exactly one click',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer();
      final outcome = await c.read(playbackRequestsProvider).submit(
          const PlayList(['a', 'b'], 1, ListSource('search'),
              intent: HistoryIntent.track('b')));
      expect(outcome, isA<Accepted>());
      await pumpEventQueue();
      final rows = await clicks();
      expect(rows, hasLength(1));
      expect(rows.single.entityType, 'track');
      expect(rows.single.entityRef, 'b');
      expect(rows.single.occurredAt, testClock.nowUtcMs());
      expect(rows.single.pendingUpload, isTrue);
      expect(rows.single.secondsPlayed, isNull);
    });

    test('rejected, superseded and intent-less requests record nothing',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer(offline: true);
      final requests = c.read(playbackRequestsProvider);
      expect(await requests.submit(const PlayList(['a'], 0, ListSource('s'),
          intent: HistoryIntent.track('a'))), isA<RejectedUnplayableOffline>());
      expect(await requests.submit(const PlayList([], 0, ListSource('s'),
          intent: HistoryIntent.track('a'))), isA<RejectedEmpty>());
      await markDownloaded('a', '/dl/a');
      final first = requests.submit(const PlayList(['a'], 0, ListSource('s'),
          intent: HistoryIntent.track('a')));
      final second =
          requests.submit(const PlayList(['a'], 0, ListSource('s')));
      expect(await first, isA<Superseded>());
      expect(await second, isA<Accepted>());
      await pumpEventQueue();
      expect(await clicks(), isEmpty);
    });

    test('two quick taps on different items play the second, one click',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer();
      final requests = c.read(playbackRequestsProvider);
      final first = requests.submit(const PlayList(['a', 'b'], 0,
          ListSource('search'), intent: HistoryIntent.track('a')));
      final second = requests.submit(const PlayList(['a', 'b'], 1,
          ListSource('search'), intent: HistoryIntent.track('b')));
      await first;
      await second;
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect((await clicks()).map((e) => e.entityRef), ['b']);
    });

    test('skips, advances and restore never record a click', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await c.read(playbackRequestsProvider)
          .submit(const PlayList(['a', 'b', 'c'], 0, ListSource('search')));
      await notifier.skipNext();
      await notifier.skipPrevious();
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(await clicks(), isEmpty);
    });

    test('a failed click write keeps playing and retries the same event',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer();
      final requests = c.read(playbackRequestsProvider);
      history.failNext = true;
      expect(await requests.submit(const PlayList(['a'], 0, ListSource('s'),
          intent: HistoryIntent.track('a'))), isA<Accepted>());
      await pumpEventQueue();
      expect(await clicks(), isEmpty);
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      final failedUuid = history.failedUuid;
      await requests.submit(const PlayList(['b'], 0, ListSource('s'),
          intent: HistoryIntent.track('b')));
      await pumpEventQueue();
      final rows = await clicks();
      expect(rows.map((e) => e.entityRef), ['a', 'b']);
      expect(rows.first.eventUuid, failedUuid, reason: 'never a new UUID');
    });
  });

  group('live gate: missing downloads confirmed by the resolver (D32)', () {
    test('an offline tap on a download whose file is gone is rejected and '
        'reconciles the catalog', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      existingFiles.remove('/dl/a'); // recorded; the file is gone
      final c = createContainer(offline: true);
      final outcome = await c.read(playbackRequestsProvider)
          .submit(const PlayList(['a'], 0, ListSource('search')));
      expect(outcome, isA<RejectedUnplayableOffline>());
      await pumpEventQueue();
      final a = await (db.select(db.tracks)..where((t) => t.uuidId.equals('a'))).getSingle();
      expect(a.filePath, isNull,
          reason: 'the stale Downloaded claim is cleared, not left forever');
    });

    test('a start that falls back past a missing download reconciles it '
        'before activation', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      existingFiles.remove('/dl/a'); // gone
      await markDownloaded('b', '/dl/b');
      final c = createContainer(offline: true);
      final outcome = await c.read(playbackRequestsProvider)
          .submit(const PlayList(['a', 'b'], 0, ListSource('search')));
      expect(outcome, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect((await (db.select(db.tracks)..where((t) => t.uuidId.equals('a'))).getSingle()).filePath, isNull);
      final seeded = fakePlayer.seedCalls.last.entries
          .firstWhere((e) => e.uuidId == 'a');
      expect(seeded.filePath, isNull,
          reason: 'the engine is never handed the dead path');
    });
  });

  group('branch audit (5B.0b F4): the scope, not the player, owns the engine '
      'and window', () {
    test('a rebuilt player gets a live engine and window', () async {
      await fixture.insertSingles(['a']);
      final c = createContainer();
      c.read(queuePlayerProvider);
      await repo.startupRead.future;
      await pumpEventQueue();
      final window = c.read(queueWindowProvider);
      c.invalidate(queuePlayerProvider);
      c.read(queuePlayerProvider);
      await pumpEventQueue();
      expect(fakePlayer.isDisposed, isFalse,
          reason: 'the engine provider outlives a player rebuild');
      expect(window.isDisposed, isFalse,
          reason: 'the window provider outlives a player rebuild');
      await playFromTrackList(c, const ['a'], await fixture.track('a'),
          sourceType: 'test');
      expect(fakePlayer.seedCalls, hasLength(1));
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
    });

    test('disposing the scope disposes the window once', () async {
      final c = createContainer();
      c.read(queuePlayerProvider);
      await repo.startupRead.future;
      await pumpEventQueue();
      final window = c.read(queueWindowProvider);
      c.dispose();
      container = null;
      expect(window.isDisposed, isTrue);
    });
  });

  group('branch audit (5B.0d m1): the OS playback state is not republished '
      'on every position tick', () {
    test('ticks at real-time pace publish nothing; a seek or a pause does',
        () async {
      await fixture.insertSingles(['a']);
      final clock = FakeClock();
      final c = createContainer(clock: clock);
      await playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'test');
      fakePlayer.emitPlayerState(const EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      final before = bridge.playbackStateEvents.length;
      for (var i = 1; i <= 10; i++) {
        clock.advance(const Duration(seconds: 1));
        fakePlayer.emitPosition(Duration(seconds: i));
        await pumpEventQueue();
      }
      expect(bridge.playbackStateEvents.length - before, lessThanOrEqualTo(1),
          reason: 'the OS extrapolates a playing position itself');
      final ticks = bridge.playbackStateEvents.length;
      fakePlayer.emitPosition(const Duration(seconds: 40)); // a seek
      await pumpEventQueue();
      expect(bridge.playbackStateEvents.length, ticks + 1, reason: 'a jump is published');
      expect(bridge.playbackStateEvents.last.updatePosition, const Duration(seconds: 40));
      await c.read(queuePlayerProvider.notifier).pause();
      await pumpEventQueue();
      expect(bridge.playbackStateEvents.last.playing, isFalse, reason: 'a pause is published');
    });
  });

  group('branch audit (5B.0d m4): removeFromQueue is commit-last', () {
    test('a failed metadata read after a removal leaves the window shifted',
        () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b', 'c', 'd'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      final window = c.read(queueWindowProvider);
      final end = window.nextForwardHydrationPlayPosition;
      final tracks = await sessionTracksOf(c);
      repo.metadataReadError = StateError('db busy');
      await c.read(queuePlayerProvider.notifier).removeFromQueue(tracks[2].itemId)
          .catchError((Object _) {});
      await pumpEventQueue();
      expect(window.nextForwardHydrationPlayPosition, end - 1,
          reason: 'the window follows the removal even if a later read fails');
    });
  });

  group('branch audit (5B.0a): characterization gaps', () {
    test('a full quality change rebuilds every source at the position then '
        '(M1)', () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer(controllableQuality: true);
      c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      fakePlayer.emitPosition(const Duration(seconds: 30));
      await pumpEventQueue();
      final current = c.read(queuePlayerProvider).queue.currentItemId;
      c.read(_testQuality.notifier).set('low');
      await pumpEventQueue();
      expect(fakePlayer.rebuilds, [('all', 'low', const Duration(seconds: 30), current)]);
    });

    test('a sync that empties the queue stops audio, and the engine\'s late '
        'transport echo does not resurrect a paused player (M3/M5)', () async {
      await fixture.insertSingles(['a']);
      final c = createContainer();
      await playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      final id = c.read(queuePlayerProvider).queue.sessionId!;
      final stops = fakePlayer.stopCalls;
      await repo.removeTrackUuidsFromQueues(['a']);
      await c.read(queuePlayerProvider.notifier).reconcileAfterSyncQueueMutation({id});
      await pumpEventQueue();
      expect(fakePlayer.stopCalls, stops + 1, reason: 'audio stops');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isFalse);
      // The real engine echoes the stop asynchronously.
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.ready));
      await pumpEventQueue();
      final playback = c.read(queuePlayerProvider).playback;
      expect(playback.status, PlayerStatus.idle,
          reason: 'no "paused" status without a track');
      expect(playback.currentTrack, isNull);
    });
  });

  group('branch audit (5B.0a M2): a sync reaches the player', () {
    test('a newer queue mutation version reconciles the affected session; '
        'a stale or equal one does nothing', () async {
      await fixture.insertSingles(['a', 'b']);
      final sync = _ScriptedSync();
      final c = createContainer(sync: sync);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      final id = c.read(queuePlayerProvider).queue.sessionId!;
      await repo.removeTrackUuidsFromQueues(['a', 'b']); // the server deleted them
      sync.push(const TrackSyncState(queueMutationVersion: 0, affectedQueueSessionIds: {}));
      await pumpEventQueue();
      expect(c.read(queuePlayerProvider).queue.sessionId, id, reason: 'no newer version: nothing');
      sync.push(TrackSyncState(queueMutationVersion: 1, affectedQueueSessionIds: {id + 1}));
      await pumpEventQueue();
      expect(c.read(queuePlayerProvider).queue.sessionId, id, reason: 'another session: nothing');
      sync.push(TrackSyncState(queueMutationVersion: 1, affectedQueueSessionIds: {id}));
      await pumpEventQueue();
      expect(c.read(queuePlayerProvider).queue.sessionId, id, reason: 'an equal version: nothing');
      sync.push(TrackSyncState(queueMutationVersion: 2, affectedQueueSessionIds: {id}));
      await pumpEventQueue();
      expect(c.read(queuePlayerProvider).queue.sessionId, isNull,
          reason: 'the emptied session is reconciled: the player stops');
    });
  });

  group('PR 5B audit (c)', () {
    Future<(ProviderContainer, QueuePlayer, int)> playingAB() async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      final notifier = c.read(queuePlayerProvider.notifier);
      return (c, notifier, c.read(queuePlayerProvider).queue.sessionId!);
    }

    Future<(int, QueuePlaybackEntry)> prepared(List<String> uuids) async {
      final id = await repo.createSessionFromExplicitList(
          sourceType: 's', trackUuids: uuids, activate: false);
      final snapshot = await repo.getSessionSnapshot(id);
      final entry = await repo.getPlaybackEntryForItem(
          id, snapshot!.currentItem!.itemId);
      return (id, entry!);
    }

    test('a stale request revision activates nothing (checked in the lane)',
        () async {
      final (c, notifier, s1) = await playingAB();
      final (s2, entry) = await prepared(['c']);
      final stale = notifier.admitReplacement();
      notifier.admitReplacement(); // a newer request was admitted
      final seeds = fakePlayer.seedCalls.length;
      final result = await notifier.activatePreparedSession(s2, entry,
          autoPlay: true, requestRevision: stale);
      expect(result, ActivationResult.superseded);
      expect(fakePlayer.seedCalls, hasLength(seeds));
      expect((await repo.getActiveSession())?.id, s1);
      expect(c.read(queuePlayerProvider).queue.sessionId, s1);
    });

    test('activating a session that is gone is stale and changes nothing',
        () async {
      final (c, notifier, s1) = await playingAB();
      final (s2, entry) = await prepared(['c']);
      await repo.discardSession(s2);
      final seeds = fakePlayer.seedCalls.length;
      final result = await notifier.activatePreparedSession(s2, entry,
          autoPlay: true, requestRevision: notifier.admitReplacement());
      expect(result, ActivationResult.stale);
      expect(fakePlayer.seedCalls, hasLength(seeds));
      expect((await repo.getActiveSession())?.id, s1);
      expect(c.read(queuePlayerProvider).queue.sessionId, s1);
    });

    test('a request superseded in the lane discards its prepared session',
        () async {
      final (c, notifier, s1) = await playingAB();
      final tracks = await sessionTracksOf(c);
      final gate = repo.removeGate = Completer<void>();
      final removing = notifier.removeFromQueue(tracks[1].itemId);
      await repo.removeEntered.future; // the lane is busy
      final request = c.read(playbackRequestsProvider)
          .submit(const PlayList(['c'], 0, ListSource('s')));
      for (var i = 0; i < 20; i++) {
        await pumpEventQueue(); // prepared and resolved; activation queued
      }
      final stopping = notifier.stop(); // admitted after the request
      repo.removeGate = null;
      gate.complete();
      await removing;
      expect(await request, isA<Superseded>());
      await stopping;
      final sessions = await db.select(db.queueSessions).get();
      expect(sessions.map((s) => s.id), [s1],
          reason: 'the prepared session was discarded');
    });

    for (final playing in [true, false]) {
      test('a restored engine keeps position and play state '
          '(${playing ? 'playing' : 'paused'})', () async {
        final (c, notifier, _) = await playingAB();
        if (!playing) await notifier.pause();
        fakePlayer.emitPosition(const Duration(seconds: 42));
        await pumpEventQueue();
        final before = c.read(queuePlayerProvider);
        expect(before.playback.position, const Duration(seconds: 42));
        fakePlayer.setLoopModeFailures = 1;
        await c.read(playbackRequestsProvider)
            .submit(const PlayList(['c'], 0, ListSource('s')));
        final seed = fakePlayer.seedCalls.last;
        expect(seed.initialPosition, const Duration(seconds: 42));
        expect(seed.autoPlay, playing);
        expect(c.read(queuePlayerProvider).playback.playWhenReady, playing);
      });
    }
  });

  group('PR 5B audit (a)', () {
    test('a failed activation leaves the current queue, status and audio '
        'untouched', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      final before = c.read(queuePlayerProvider);
      final stops = fakePlayer.stopCalls;
      final seeds = fakePlayer.seedCalls.length;
      repo.getTrackForItemError = StateError('db gone');
      final outcome = await c.read(playbackRequestsProvider)
          .submit(const PlayList(['c'], 0, ListSource('s')));
      repo.getTrackForItemError = null;
      expect(outcome, isA<Failed>());
      expect((fakePlayer.stopCalls, fakePlayer.seedCalls.length),
          (stops, seeds), reason: 'the engine was never touched');
      final after = c.read(queuePlayerProvider);
      expect(after.queue.sessionId, before.queue.sessionId);
      expect(after.playback.currentTrack?.uuidId, 'a');
      expect(after.playback.status, before.playback.status);
      expect((await repo.getActiveSession())?.id, before.queue.sessionId);
    });

    test('an activation failing after the engine was seeded restores the '
        'current queue to the engine', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      final before = c.read(queuePlayerProvider);
      fakePlayer.setLoopModeFailures = 1;
      final outcome = await c.read(playbackRequestsProvider)
          .submit(const PlayList(['c'], 0, ListSource('s')));
      expect(outcome, isA<Failed>());
      final seed = fakePlayer.seedCalls.last;
      expect((seed.sessionId, seed.currentItemId),
          (before.queue.sessionId, before.queue.currentItemId),
          reason: 'the engine holds the current queue again, not the '
              'discarded one');
      final after = c.read(queuePlayerProvider);
      expect(after.queue.sessionId, before.queue.sessionId);
      expect(after.playback.currentTrack?.uuidId, 'a');
      expect((await repo.getActiveSession())?.id, before.queue.sessionId);
    });

    test('an Enqueue is never superseded by an earlier Enqueue', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('b', '/dl/b');
      final c = createContainer(offline: true);
      final requests = c.read(playbackRequestsProvider);
      final e1 = requests.submit(const Enqueue(['a'], EnqueuePosition.end));
      final e2 = requests.submit(const Enqueue(['b'], EnqueuePosition.end));
      expect(await e1, isA<RejectedUnplayableOffline>());
      expect(await e2, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
    });

    test('a tap after an Enqueue still supersedes it', () async {
      await fixture.insertSingles(['a', 'x']);
      final c = createContainer();
      final requests = c.read(playbackRequestsProvider);
      final e1 = requests.submit(const Enqueue(['x'], EnqueuePosition.end));
      final p1 = requests.submit(const PlayList(['a'], 0, ListSource('s')));
      expect(await e1, isA<Superseded>());
      expect(await p1, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
    });

    test('the engine is restored even when reactivating the current '
        'session fails', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      final before = c.read(queuePlayerProvider);
      fakePlayer.setLoopModeFailures = 1;
      repo.failActivationOf = before.queue.sessionId;
      final outcome = await c.read(playbackRequestsProvider)
          .submit(const PlayList(['c'], 0, ListSource('s')));
      expect(outcome, isA<Failed>());
      expect(fakePlayer.seedCalls.last.sessionId, before.queue.sessionId,
          reason: 'never left on the discarded session');
      expect((await repo.getActiveSession())?.id, before.queue.sessionId);
    });

    test('an Enqueue submitted before a tap is superseded even if the tap '
        'activates first', () async {
      await fixture.insertSingles(['p', 'x', 'y']);
      await markDownloaded('x', '/dl/x');
      final c = createContainer();
      final requests = c.read(playbackRequestsProvider);
      final gate = fileGate = Completer<void>();
      final e1 = requests.submit(const Enqueue(['x'], EnqueuePosition.end));
      await pumpEventQueue(); // e1 starts a queue; its file check is held
      fileGate = null;
      final e2 = requests.submit(const Enqueue(['y'], EnqueuePosition.end));
      final p = requests.submit(const PlayList(['p'], 0, ListSource('s')));
      expect(await p, isA<Accepted>(), reason: 'the tap activates first');
      gate.complete();
      expect(await e1, isA<Superseded>());
      expect(await e2, isA<Superseded>(),
          reason: 'submitted before the tap: older, never added to its queue');
      expect((await sessionTracksOf(c)).map((t) => t.uuidId), ['p']);
    });

    test('a failed start whose reactivation also fails leaves no prepared '
        'session active', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      final before = c.read(queuePlayerProvider);
      repo.getTrackForItemError = StateError('db gone');
      repo.failActivationOf = before.queue.sessionId;
      final outcome = await c.read(playbackRequestsProvider)
          .submit(const PlayList(['c'], 0, ListSource('s')));
      repo.getTrackForItemError = null;
      expect(outcome, isA<Failed>());
      expect((await repo.getActiveSession())?.id, before.queue.sessionId,
          reason: 'the prepared session must not stay active; the playing '
              'one is active again');
      expect(await repo.pruneInactiveSessions(), 0,
          reason: 'the prepared session was discarded');
    });

    test('two quick no-session Enqueues queue both, in order', () async {
      await fixture.insertSingles(['x', 'y']);
      final c = createContainer();
      final requests = c.read(playbackRequestsProvider);
      final e1 = requests.submit(const Enqueue(['x'], EnqueuePosition.end));
      final e2 = requests.submit(const Enqueue(['y'], EnqueuePosition.end));
      expect(await e1, isA<Accepted>());
      expect(await e2, isA<Accepted>());
      expect((await sessionTracksOf(c)).map((t) => t.uuidId), ['x', 'y']);
    });
  });

  group('5B.1 audit (a)', () {
    test('a no-session Enqueue never supersedes a newer tap', () async {
      await fixture.insertSingles(['a', 'b', 'x']);
      final c = createContainer();
      final requests = c.read(playbackRequestsProvider);
      final r0 = requests.submit(const PlayList(['a'], 0, ListSource('s')));
      final e1 = requests.submit(const Enqueue(['x'], EnqueuePosition.end));
      final p1 = requests.submit(const PlayList(['b'], 0, ListSource('s')));
      expect(await r0, isA<Superseded>());
      expect(await e1, isA<Superseded>());
      expect(await p1, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'b',
          reason: 'the last tap wins');
    });

    test('a failed startup prune is skipped, not remembered', () async {
      await fixture.insertSingles(['a']);
      repo.pruneError = StateError('db busy');
      final c = createContainer();
      c.read(queuePlayerProvider.notifier);
      await repo.pruneFailed.future; // the restore's prune failed
      expect(repo.prunes, 1);
      final stale = await repo.createSessionFromExplicitList(
          sourceType: 'search', trackUuids: const ['a'], activate: false);
      expect(await c.read(playbackRequestsProvider)
              .submit(const PlayList(['a'], 0, ListSource('s'))),
          isA<Accepted>());
      expect(repo.prunes, 2, reason: 'the request retried the prune');
      expect(await repo.getSessionSnapshot(stale), isNull,
          reason: 'the skipped prune is retried by the next request');
    });

    test('a first start that fails leaves no active session behind',
        () async {
      await fixture.insertSingles(['a']);
      final c = createContainer();
      await repo.startupRead.future;
      repo.getTrackForItemError = StateError('db gone');
      final outcome = await c.read(playbackRequestsProvider)
          .submit(const PlayList(['a'], 0, ListSource('s')));
      expect(outcome, isA<Failed>());
      expect(await repo.getActiveSession(), isNull);
      repo.getTrackForItemError = null;
      expect(await repo.pruneInactiveSessions(), 0,
          reason: 'the prepared session was discarded too');
    });

    test('a request superseded while resolving publishes no issues',
        () async {
      await fixture.insertSingles(['a', 'b']);
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
          .write(const TracksCompanion(filePath: Value('/dl/a')));
      final c = createContainer();
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      final requests = c.read(playbackRequestsProvider);
      final gate = fileGate = Completer<void>(); // a's stat is slow
      final first = requests.submit(const PlayList(['a'], 0, ListSource('s')));
      await pumpEventQueue(); // a is resolving (its file check is pending)
      final second = requests.submit(const PlayList(['b'], 0, ListSource('s')));
      await pumpEventQueue();
      fileGate = null;
      gate.complete();
      expect(await first, isA<Superseded>());
      await second;
      expect(issues, isEmpty, reason: 'nothing is reported for a dropped play');
      // Branch audit (5B m2): the missing download is still a catalog fact.
      final a = await (db.select(db.tracks)..where((t) => t.uuidId.equals('a'))).getSingle();
      expect(a.filePath, isNull, reason: 'reconciled even though the request was dropped');
    });

    test('a no-session Enqueue honours sticky shuffle', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      await c.read(queuePlayerProvider.notifier).toggleShuffle();
      final outcome = await c.read(playbackRequestsProvider)
          .submit(const Enqueue(['a', 'b', 'c'], EnqueuePosition.end));
      final snapshot =
          await repo.getSessionSnapshot((outcome as Accepted).sessionId);
      expect(snapshot?.session.shuffleEnabled, isTrue);
      expect(c.read(shuffleProvider), isTrue);
    });
  });

  group('5B.0d audit (c) test gaps', () {
    test('a same-session chunk that a lane edit made stale is not applied',
        () async {
      final uuids = List.generate(100, (i) => 'w$i');
      await fixture.insertSingles(uuids);
      final c = createContainer();
      await repo.startupRead.future;
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, uuids, await fixture.track('w0'),
          sourceType: 'test');
      await pumpEventQueue();
      final tracks = await sessionTracksOf(c);
      final read = repo.hydrationGate = Completer<void>();
      await notifier.skipToTrack(tracks[40].itemId);
      await repo.hydrationEntered.future;
      repo.hydrationGate = null;
      final removeGate = repo.removeGate = Completer<void>();
      final removing = notifier.removeFromQueue(tracks[5].itemId);
      await repo.removeEntered.future;
      read.complete(); // the chunk was read before the positions shifted
      await pumpEventQueue();
      removeGate.complete();
      await removing;
      await pumpEventQueue();
      final positions = fakePlayer.loadedPlayPositions;
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i], positions[i - 1] + 1, reason: 'contiguous');
      }
      expect(c.read(queueWindowProvider).nextForwardHydrationPlayPosition,
          positions.last + 1);
    });

    test('an all-gone queue over a partial window stops after one cycle',
        () async {
      final uuids = List.generate(62, (i) => 'g$i');
      await fixture.insertSingles(uuids);
      for (final uuid in uuids) {
        trackStatuses[uuid] = 410;
      }
      final c = createContainer();
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, uuids, await fixture.track('g61'),
          sourceType: 'test');
      await notifier.cycleQueueRepeatMode();
      for (var i = 0; i < 70; i++) {
        fakePlayer.emitSourceFailure();
        await pumpEventQueue();
      }
      expect(issues.whereType<PlaybackRecoveryExhausted>(), hasLength(1));
      expect(fakePlayer.stopCalls, 1);
      expect(
          issues.whereType<PlaybackSourceFailed>().map((i) => i.trackUuid),
          unorderedEquals(uuids),
          reason: 'every item is tried once across rebases, none twice');
    });

    test('queue warm follows quality changes and queue edits', () async {
      await fixture.insertSingles(['a', 'b', 'x']);
      final c = createContainer(controllableQuality: true);
      c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      final before = warm.calls.length;
      c.read(_testQuality.notifier).set('low');
      await pumpEventQueue();
      expect(warm.qualities.last, 'low');
      expect(warm.calls.length, before + 1);
      await addToQueue(c, [await fixture.track('x')]);
      await pumpEventQueue();
      expect(warm.calls.length, greaterThan(before + 1),
          reason: 'a queue edit (same position) warms again');
    });

    test('disposing the publisher clears the OS now-playing', () async {
      await fixture.insertSingles(['a']);
      final c = createContainer();
      await repo.startupRead.future; // startup loads done before dispose
      await playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      expect(bridge.mediaItemEvents.last?.id, 'a');
      c.dispose();
      container = null;
      await pumpEventQueue();
      expect(bridge.mediaItemEvents.last, isNull);
    });

    test('the cursor throttle ignores wall-clock jumps', () async {
      await fixture.insertSingles(['a']);
      final clock = FakeClock();
      final c = createContainer(clock: clock);
      await playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      repo.cursorSaves.clear();
      fakePlayer.emitPosition(const Duration(seconds: 1));
      await pumpEventQueue();
      clock.jumpWallClock(const Duration(hours: 1));
      fakePlayer.emitPosition(const Duration(seconds: 2));
      await pumpEventQueue();
      expect(repo.cursorSaves, [1000], reason: 'monotonic time, not wall');
    });
  });

  group('5B.0d audit (a) minors', () {
    test('a queue edit decides native looping from the new total', () async {
      final uuids = List.generate(30, (i) => 'q$i');
      await fixture.insertSingles([...uuids, ...List.generate(30, (i) => 'r$i')]);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, uuids, await fixture.track('q0'),
          sourceType: 'test');
      await notifier.cycleQueueRepeatMode();
      expect(fakePlayer.lastLoopMode, EngineLoopMode.all,
          reason: 'the window holds the whole 30-track queue');
      await addToQueue(c, [
        for (var i = 0; i < 30; i++) await fixture.track('r$i'),
      ]);
      expect(c.read(queuePlayerProvider).queue.totalCount, 60);
      expect(fakePlayer.lastLoopMode, EngineLoopMode.off,
          reason: 'the window no longer holds the 60-track queue');
    });

    test("a seed's failed load is handled after a later revision bump",
        () async {
      await fixture.insertSingles(['a', 'b']);
      trackStatuses['a'] = 404;
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      final seedRevision = fakePlayer.playlistRevision;
      fakePlayer.playlistRevision++; // a download refresh since
      fakePlayer.emitLoadEvent(EngineLoadEvent(
          playlistRevision: seedRevision, outcome: EngineLoadOutcome.failed));
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
    });

    test('after exhaustion, a user skip starts a new failure run', () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      for (final uuid in ['a', 'b', 'c']) {
        trackStatuses[uuid] = 410;
      }
      final c = createContainer();
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('a'), sourceType: 'test');
      await notifier.cycleQueueRepeatMode();
      for (var i = 0; i < 3; i++) {
        fakePlayer.emitSourceFailure();
        await pumpEventQueue();
      }
      expect(issues.whereType<PlaybackRecoveryExhausted>(), hasLength(1));
      final failures = issues.whereType<PlaybackSourceFailed>().length;
      await notifier.skipToTrack((await sessionTracksOf(c))[1].itemId);
      fakePlayer.emitSourceFailure(sourceId: 4242);
      await pumpEventQueue();
      expect(issues.whereType<PlaybackSourceFailed>().length, failures + 1,
          reason: 'the new failure is classified, not dropped');
    });

    test('quiesce clears the OS now-playing', () async {
      await fixture.insertSingles(['a']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      expect(bridge.mediaItemEvents.last?.id, 'a');
      await notifier.quiesce();
      await pumpEventQueue();
      expect(bridge.mediaItemEvents.last, isNull);
    });

    test('changed metadata of the current item is republished', () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals('a')))
          .write(const TrackmetadataCompanion(title: Value('Renamed')));
      await repo.removeTrackUuidsFromQueues(const ['b']);
      await notifier.reconcileAfterSyncQueueMutation(
          {c.read(queuePlayerProvider).queue.sessionId!});
      await pumpEventQueue();
      expect(bridge.mediaItemEvents.last?.title, 'Renamed');
    });

    test('a failed startup restore reports a diagnostic', () async {
      repo.activeSnapshotError = StateError('db gone');
      final c = createContainer();
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      await repo.startupRead.future;
      await pumpEventQueue();
      expect(issues.whereType<PlaybackTaskFailed>(), isNotEmpty);
    });

    test('a quality rebuild runs in the lane, at the position then',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer(controllableQuality: true);
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      final gate = repo.deactivateGate = Completer<void>();
      final stopping = notifier.stop();
      await repo.deactivateEntered.future;
      c.read(_testQuality.notifier).set('low');
      await pumpEventQueue();
      expect(fakePlayer.rebuilds, isEmpty,
          reason: 'it waits for the stop already in the lane');
      gate.complete();
      await stopping;
      await pumpEventQueue();
      expect(fakePlayer.rebuilds, isEmpty,
          reason: 'it ran after the stop, when no session is left');
    });
  });

  group('5B.0d: cursor saves go through the lane', () {
    test('a position save never interleaves a lane operation', () async {
      await fixture.insertSingles(['a']);
      final c = createContainer(clock: FakeClock());
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'search');
      await pumpEventQueue();
      repo.cursorSaves.clear();
      final gate = repo.deactivateGate = Completer<void>();
      final stopping = notifier.stop();
      await repo.deactivateEntered.future;
      fakePlayer.emitPosition(const Duration(seconds: 30));
      await pumpEventQueue();
      expect(repo.cursorSaves, isEmpty,
          reason: 'the save waits for the stop already in the lane');
      gate.complete();
      await stopping;
      await pumpEventQueue();
      expect(repo.cursorSaves, isEmpty,
          reason: 'after the stop there is no session to save');
    });
  });

  group('5B.0d (SC-27 invariant 15): unknown duration is nullable', () {
    Future<void> unknownDuration(String uuid) =>
        (db.update(db.trackmetadata)..where((t) => t.uuidId.equals(uuid)))
            .write(const TrackmetadataCompanion(duration: Value(null)));

    test('an unknown catalog duration is published as unknown, never zero',
        () async {
      await fixture.insertSingles(['a']);
      await unknownDuration('a');
      final c = createContainer();
      await playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'search');
      expect(c.read(audioDurationProvider), isNull);
      expect(c.read(queuePlayerProvider).playback.catalogDuration, isNull);
    });

    test('a measured duration names its item; a stale one is ignored',
        () async {
      await fixture.insertSingles(['a', 'b']);
      await unknownDuration('a');
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b'],
          await fixture.track('a'), sourceType: 'search');
      final tracks = await sessionTracksOf(c);
      fakePlayer.emitObservation(duration: const Duration(seconds: 200));
      await pumpEventQueue();
      expect(c.read(audioDurationProvider), const Duration(seconds: 200));
      // An observation of the other item, or an uncertain one, is not ours.
      fakePlayer.emitObservation(
          itemId: tracks[1].itemId, duration: const Duration(seconds: 99));
      fakePlayer.emitObservation(
          duration: const Duration(seconds: 77), uncertain: true);
      await pumpEventQueue();
      expect(c.read(audioDurationProvider), const Duration(seconds: 200));
      // The engine no longer knows it: back to the (unknown) catalog value.
      fakePlayer.emitObservation(duration: null);
      await pumpEventQueue();
      expect(c.read(audioDurationProvider), isNull);
      // A new item starts with its own catalog duration, not the old one.
      fakePlayer.emitObservation(duration: const Duration(seconds: 200));
      await pumpEventQueue();
      await notifier.skipNext();
      await pumpEventQueue();
      expect(c.read(audioDurationProvider), const Duration(seconds: 180));
    });

    test('a refresh onto another item drops the old measured duration',
        () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('a'), sourceType: 'search');
      fakePlayer.emitObservation(duration: const Duration(seconds: 200));
      await pumpEventQueue();
      expect(c.read(audioDurationProvider), const Duration(seconds: 200));
      final tracks = await sessionTracksOf(c);
      fakePlayer.commitSilently(tracks[1].itemId);
      await notifier.removeFromQueue(tracks[2].itemId);
      expect(c.read(queuePlayerProvider).queue.currentItemId, tracks[1].itemId);
      expect(c.read(audioDurationProvider), const Duration(seconds: 180),
          reason: "b's catalog duration, not a's measured one");
    });

    test('an unknown duration is no seek bound and shows as unknown',
        () async {
      await fixture.insertSingles(['a']);
      await unknownDuration('a');
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'search');
      await notifier.seek(const Duration(hours: 2));
      expect(fakePlayer.position, const Duration(hours: 2));
      expect(bridge.mediaItemEvents.last?.duration, isNull);
    });
  });

  group('5B.0d (SC-20): the playback core reads the shared clock', () {
    test('position saves are throttled by the injected monotonic clock',
        () async {
      await fixture.insertSingles(['a']);
      final clock = FakeClock();
      final c = createContainer(clock: clock);
      await playFromTrackList(c, const ['a'], await fixture.track('a'), sourceType: 'search');
      await pumpEventQueue();
      repo.cursorSaves.clear();
      fakePlayer.emitPosition(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(repo.cursorSaves, [1000], reason: 'the first tick saves');
      clock.advance(const Duration(seconds: 3));
      fakePlayer.emitPosition(const Duration(seconds: 4));
      await pumpEventQueue();
      expect(repo.cursorSaves, [1000], reason: 'within 5 s: throttled');
      clock.advance(const Duration(seconds: 3));
      fakePlayer.emitPosition(const Duration(seconds: 7));
      await pumpEventQueue();
      expect(repo.cursorSaves, [1000, 7000], reason: '6 s later: saved');
    });
  });

  group('5B.0c (SC-27): the core carries session and cause in-band', () {
    test('seeds carry their session; a reconcile seeds as a continuation',
        () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('b'), sourceType: 'search');
      final sessionId = c.read(queuePlayerProvider).queue.sessionId!;
      expect(fakePlayer.seedCalls.last.sessionId, sessionId);
      expect(fakePlayer.seedCalls.last.cause,
          PlaybackTransitionCause.queueReplacement);
      await repo.removeTrackUuidsFromQueues(const ['c']);
      await notifier.reconcileAfterSyncQueueMutation({sessionId});
      expect(fakePlayer.seedCalls, hasLength(2));
      expect(fakePlayer.seedCalls.last.sessionId, sessionId);
      expect(fakePlayer.seedCalls.last.cause,
          PlaybackTransitionCause.reconcileContinuation);
    });

    test('a reconcile that loses the current item replaces, not continues',
        () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('b'), sourceType: 'search');
      final sessionId = c.read(queuePlayerProvider).queue.sessionId!;
      await repo.removeTrackUuidsFromQueues(const ['b']);
      await notifier.reconcileAfterSyncQueueMutation({sessionId});
      expect(fakePlayer.seedCalls.last.cause,
          PlaybackTransitionCause.queueReplacement);
    });

    test('user skips are user skips; an automatic hop is a natural advance',
        () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      await markDownloaded('a', '/dl/a');
      await markDownloaded('c', '/dl/c');
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('a'), sourceType: 'search');
      await notifier.skipNext();
      expect(fakePlayer.seekCauses.last, PlaybackTransitionCause.userSkip);
      final b = (await repo.getPlaybackEntries(
              c.read(queuePlayerProvider).queue.sessionId!))
          .firstWhere((e) => e.uuidId == 'b');
      fakePlayer.emitUnavailableAdvance(
          UnavailableAdvance(itemId: b.itemId, playPosition: b.playPosition));
      await pumpEventQueue();
      expect(fakePlayer.seekCauses.last,
          PlaybackTransitionCause.naturalAdvance);
    });
  });

  group('5B.0c (SC-27): single-owner audio focus routes OS events', () {
    Future<QueuePlayer> playingQueue(ProviderContainer c) async {
      await fixture.insertSingles(['a', 'b']);
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b'],
          await fixture.track('a'), sourceType: 'search');
      return notifier;
    }

    Future<void> emit(AudioSessionEvent event) async {
      sessionPort.emit(event);
      await pumpEventQueue();
    }

    test('an interruption pauses playback and its end resumes it', () async {
      final c = createContainer();
      await playingQueue(c);
      final plays = fakePlayer.playCalls;
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.pause));
      expect(fakePlayer.pauseCalls, 1);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
      await emit(const AudioInterruptionEnded(AudioInterruptionKind.pause));
      expect(fakePlayer.playCalls, plays + 1);
      expect(c.read(audioPlayWhenReadyProvider), isTrue);
    });

    test('a pause by the user during an interruption is never undone',
        () async {
      final c = createContainer();
      final notifier = await playingQueue(c);
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.pause));
      await notifier.pause();
      final plays = fakePlayer.playCalls;
      await emit(const AudioInterruptionEnded(AudioInterruptionKind.pause));
      expect(fakePlayer.playCalls, plays);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
    });

    test('an interruption of paused audio does not start it', () async {
      final c = createContainer();
      final notifier = await playingQueue(c);
      await notifier.pause();
      final plays = fakePlayer.playCalls;
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.pause));
      await emit(const AudioInterruptionEnded(AudioInterruptionKind.pause));
      expect(fakePlayer.playCalls, plays);
    });

    test('an interruption whose end may not resume stays paused', () async {
      final c = createContainer();
      await playingQueue(c);
      final plays = fakePlayer.playCalls;
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.unknown));
      await emit(const AudioInterruptionEnded(AudioInterruptionKind.unknown));
      expect(fakePlayer.playCalls, plays);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
    });

    test('unplugged headphones pause, and a later interruption end does not '
        'resume', () async {
      final c = createContainer();
      await playingQueue(c);
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.pause));
      await emit(const AudioBecameNoisy());
      final plays = fakePlayer.playCalls;
      await emit(const AudioInterruptionEnded(AudioInterruptionKind.pause));
      expect(fakePlayer.playCalls, plays);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
    });

    test('unplugged headphones pause playing audio', () async {
      final c = createContainer();
      await playingQueue(c);
      await emit(const AudioBecameNoisy());
      expect(fakePlayer.pauseCalls, 1);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
    });

    test('after quiesce, OS events change nothing', () async {
      final c = createContainer();
      final notifier = await playingQueue(c);
      await notifier.quiesce();
      final pauses = fakePlayer.pauseCalls;
      await emit(const AudioBecameNoisy());
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.pause));
      expect(fakePlayer.pauseCalls, pauses);
    });

    test('a disposed core releases the queue output', () async {
      final focus = AudioFocus(sessionPort);
      addTearDown(focus.dispose);
      final c = createContainer(focus: focus);
      c.read(queuePlayerProvider);
      expect(await focus.beforePlay(AudioOutput.queue), isTrue);
      // Let the container's startup loads (settings, restore) finish first.
      await repo.startupRead.future;
      await pumpEventQueue();
      c.dispose();
      container = null;
      expect(await focus.beforePlay(AudioOutput.queue), isFalse);
    });

    test('focus loss pauses at once while the real engine load is stalled',
        () async {
      final plugin = _StalledPlugin();
      final engine = JustAudioEngine(plugin);
      final c = createContainer(engine: engine);
      await fixture.insertSingles(['a']);
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a'], await fixture.track('a'),
          sourceType: 'search');
      expect(c.read(audioPlayWhenReadyProvider), isTrue);
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.pause));
      verify(() => plugin.pause()).called(1);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
      await emit(const AudioBecameNoisy());
      await notifier.resume();
      await emit(const AudioBecameNoisy());
      verify(() => plugin.pause()).called(1);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
    });

    test('the playback core owns the queue output while it lives', () async {
      final c = createContainer();
      c.read(queuePlayerProvider);
      final focus = c.read(audioFocusProvider);
      expect(await focus.beforePlay(AudioOutput.queue), isTrue);
    });
  });

  group('5A.0 (SC-27, SC-15): lifecycle, admission closure, quiesce', () {
    Future<QueuePlayer> playing(ProviderContainer c) async {
      await fixture.insertAlbum(
        artist: 'Artist',
        album: 'Album',
        uuids: ['a', 'b', 'c'],
      );
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromQueue(c, track: await fixture.track('a'),
        sourceType: 'album',
        artistId: 1,
        albumId: 1,
        orderParams: [OrderParameter(column: 'track_number')],
      );
      await Future<void>.delayed(Duration.zero);
      return notifier;
    }

    Future<int> sessionCount() async =>
        (await db.select(db.queueSessions).get()).length;

    test('lifecycle is none until the session is ready, then active', () async {
      final readiness = SessionReadiness();
      final c = createContainer(readiness: readiness);
      final notifier = c.read(queuePlayerProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      expect(notifier.lifecycle, PlaybackLifecycle.none);
      readiness.markReady();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(notifier.lifecycle, PlaybackLifecycle.active);
    });

    test('quiesce closes admission synchronously, then reaches quiesced',
        () async {
      final c = createContainer();
      final notifier = await playing(c);
      expect(notifier.lifecycle, PlaybackLifecycle.active);
      final quiescing = notifier.quiesce();
      expect(notifier.lifecycle, PlaybackLifecycle.stopping);
      // A command issued in the same turn, before quiesce settles, is refused.
      final sessionsBefore = await sessionCount();
      await playFromQueue(c, track: await fixture.track('b'),
        sourceType: 'album',
        artistId: 1,
        albumId: 1,
        orderParams: [OrderParameter(column: 'track_number')],
      );
      await quiescing;
      expect(notifier.lifecycle, PlaybackLifecycle.quiesced);
      expect(await sessionCount(), sessionsBefore);
    });

    // Audit 5A.0(a) #6: once the reset fence deleted the binding row, a
    // cursor save (admitted lane step or position tick) is a quiet no-op,
    // never an uncaught BindingFencedException.
    test('a cursor save after the reset fence is a quiet no-op', () async {
      final notifier = await playing(createContainer());
      await ServerBindingRepository(db).fence();
      await expectLater(notifier.pause(), completes);
    });

    test('quiesce stops audio', () async {
      final notifier = await playing(createContainer());
      final stopsBefore = fakePlayer.stopCalls;
      await notifier.quiesce();
      expect(fakePlayer.stopCalls, greaterThan(stopsBefore));
    });

    test('quiesced is terminal: every later command is a no-op', () async {
      final c = createContainer();
      final notifier = await playing(c);
      await notifier.quiesce();
      final state = c.read(queuePlayerProvider);
      final plays = fakePlayer.playCalls;
      final pauses = fakePlayer.pauseCalls;
      final seeds = fakePlayer.seedCalls.length;
      final sessions = await sessionCount();

      await notifier.resume();
      await play(c, await fixture.track('b'));
      await notifier.togglePlayPause();
      await notifier.skipNext();
      await notifier.skipPrevious();
      await notifier.seek(const Duration(seconds: 5));
      await notifier.toggleShuffle();
      await addToQueue(c, [await fixture.track('c')]);
      await playNext(c, [await fixture.track('c')]);
      await playFromQueue(c, track: await fixture.track('c'),
        sourceType: 'album',
        artistId: 1,
        albumId: 1,
        orderParams: [OrderParameter(column: 'track_number')],
      );
      final volumeBefore = fakePlayer.lastVolume;
      await notifier.setVolume(0.13); // audit 5A.0(c) #11
      await notifier.quiesce(); // idempotent
      expect(fakePlayer.lastVolume, volumeBefore);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('audioVolume'), isNot(0.13));

      expect(notifier.lifecycle, PlaybackLifecycle.quiesced);
      expect(c.read(queuePlayerProvider), state);
      expect(fakePlayer.playCalls, plays);
      expect(fakePlayer.pauseCalls, pauses);
      expect(fakePlayer.seedCalls.length, seeds);
      expect(await sessionCount(), sessions);
    });

    test('an OS media input after quiesce changes nothing', () async {
      final c = createContainer();
      final notifier = await playing(c);
      await notifier.quiesce();
      final plays = fakePlayer.playCalls;
      final controls = c.read(playerControlsProvider);
      await controls.click(MediaButton.media);
      await controls.togglePlayPause();
      await controls.skipNext();
      expect(fakePlayer.playCalls, plays);
      expect(notifier.lifecycle, PlaybackLifecycle.quiesced);
    });

    test('quiesce waits for lane work already admitted', () async {
      final c = createContainer();
      await fixture.insertAlbum(
        artist: 'Artist',
        album: 'Album',
        uuids: ['a', 'b', 'c'],
      );
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromQueue(c, track: await fixture.track('a'),
        sourceType: 'album',
        artistId: 1,
        albumId: 1,
        orderParams: [OrderParameter(column: 'track_number')],
      );
      // 5B.1: a play request prepares outside the lane, so lane work here
      // is a skip on the existing session; a request still preparing is
      // superseded by the closure instead.
      var skipped = false;
      final skip = notifier.skipNext().then((_) => skipped = true);
      final pending = c.read(playbackRequestsProvider).submit(
          const PlayList(['c'], 0, ListSource('search')));
      await notifier.quiesce();
      expect(skipped, isTrue, reason: 'admitted before closure, settled first');
      await skip;
      expect(await pending, isA<Superseded>());
    });

    test('the reset quiesces playback as its first participant', () async {
      final c = createContainer();
      final notifier = await playing(c);
      final participants = c.read(localQuiescablesProvider);
      expect(participants.first.quiesceName, 'playback');
      await participants.first.quiesce();
      expect(notifier.lifecycle, PlaybackLifecycle.quiesced);
    });
  });

  group('4A.0b: transport rules decided in the model', () {
    Future<QueuePlayer> playing(ProviderContainer c) async {
      await fixture.insertAlbum(
        artist: 'Artist',
        album: 'Album',
        uuids: ['a', 'b', 'c'],
      );
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromQueue(c, track: await fixture.track('a'),
        sourceType: 'album',
        artistId: 1,
        albumId: 1,
        orderParams: [OrderParameter(column: 'track_number')],
      );
      await Future<void>.delayed(Duration.zero);
      return notifier;
    }

    test('the playback model does not bind the OS bridge (the wiring does)',
        () async {
      createContainer();
      expect(bridge.onPlay, isNull);
      expect(bridge.onPause, isNull);
      expect(bridge.onClick, isNull);
    });

    test('togglePlayPause pauses while playing', () async {
      final notifier = await playing(createContainer());
      fakePlayer.emitPlayerState(EngineTransportState(true, EngineProcessingState.ready));
      await Future<void>.delayed(Duration.zero);
      final pausesBefore = fakePlayer.pauseCalls;
      final playsBefore = fakePlayer.playCalls;
      await notifier.togglePlayPause();
      expect(fakePlayer.pauseCalls, pausesBefore + 1);
      expect(fakePlayer.playCalls, playsBefore);
    });

    test('togglePlayPause resumes when paused', () async {
      final notifier = await playing(createContainer());
      await notifier.pause();
      final playsBefore = fakePlayer.playCalls;
      await notifier.togglePlayPause();
      expect(fakePlayer.playCalls, playsBefore + 1);
    });

    test('back-to-back toggles are decided at execution, not at call time',
        () async {
      final notifier = await playing(createContainer());
      fakePlayer.emitPlayerState(EngineTransportState(true, EngineProcessingState.ready));
      await Future<void>.delayed(Duration.zero);
      final pauses = fakePlayer.pauseCalls;
      final plays = fakePlayer.playCalls;
      // Both issued before either runs: the second must see the first.
      await Future.wait([notifier.togglePlayPause(), notifier.togglePlayPause()]);
      expect(fakePlayer.pauseCalls, pauses + 1);
      expect(fakePlayer.playCalls, plays + 1);
    });

    // D26 (5B.0c): re-specified from 4A.0b's "while loading, toggle
    // resumes, matching the play icon". The principle is kept -- the toggle
    // acts on what the play/pause control shows -- but the control now
    // shows the desired-transport axis: while loading with play desired it
    // shows pause, and a tap pauses.
    test('while loading with play desired, toggle pauses, matching the icon',
        () async {
      final c = createContainer();
      final notifier = await playing(c);
      fakePlayer.emitPlayerState(EngineTransportState(true, EngineProcessingState.loading));
      await Future<void>.delayed(Duration.zero);
      expect(c.read(audioStatusProvider), PlayerStatus.loading);
      expect(c.read(audioPlayWhenReadyProvider), isTrue);
      final pauses = fakePlayer.pauseCalls;
      final plays = fakePlayer.playCalls;
      await notifier.togglePlayPause();
      expect(fakePlayer.pauseCalls, pauses + 1);
      expect(fakePlayer.playCalls, plays);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
    });

    test('buffering while playing and while paused are distinct states',
        () async {
      final c = createContainer();
      final notifier = await playing(c);
      fakePlayer.emitPlayerState(
          EngineTransportState(true, EngineProcessingState.buffering));
      await pumpEventQueue();
      var playback = c.read(queuePlayerProvider).playback;
      expect(playback.playWhenReady, isTrue);
      expect(playback.processing, EngineProcessingState.buffering);
      await notifier.pause();
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.buffering));
      await pumpEventQueue();
      playback = c.read(queuePlayerProvider).playback;
      expect(playback.playWhenReady, isFalse);
      expect(playback.processing, EngineProcessingState.buffering);
      expect(c.read(queuePlayerProvider.notifier).lifecycle,
          PlaybackLifecycle.active, reason: 'lifecycle is a separate axis');
    });

    test('the OS media state reports desired transport while buffering',
        () async {
      final c = createContainer();
      await playing(c);
      fakePlayer.emitPlayerState(
          EngineTransportState(true, EngineProcessingState.buffering));
      await pumpEventQueue();
      expect(bridge.playbackStateEvents.last.playing, isTrue);
    });

    test('reaching the end of the queue clears desired transport', () async {
      final c = createContainer();
      final notifier = await playing(c);
      // At the queue's last item (5B.0d: an earlier engine end continues).
      final tracks = await sessionTracksOf(c);
      await notifier.skipToTrack(tracks.last.itemId);
      await pumpEventQueue();
      // The engine is the authoritative echo of desired transport: at the
      // end of the queue it reports desired play cleared (engine test
      // 'reaching the end pauses the plugin'). The core publishes it.
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      final playback = c.read(queuePlayerProvider).playback;
      expect(playback.playWhenReady, isFalse);
      expect(playback.processing, EngineProcessingState.completed);
      expect(playback.status, PlayerStatus.idle);
    });

    test('back-to-back toggles from paused alternate too', () async {
      final notifier = await playing(createContainer());
      await notifier.pause();
      final pauses = fakePlayer.pauseCalls;
      final plays = fakePlayer.playCalls;
      await Future.wait([notifier.togglePlayPause(), notifier.togglePlayPause()]);
      expect(fakePlayer.playCalls, plays + 1);
      expect(fakePlayer.pauseCalls, pauses + 1);
    });

    test('togglePlayPause with no session does nothing', () async {
      final c = createContainer();
      // Let the container's startup loads (settings, restore) finish first.
      await repo.startupRead.future;
      await c.read(queuePlayerProvider.notifier).togglePlayPause();
      expect(fakePlayer.playCalls + fakePlayer.pauseCalls, 0);
    });

    test('seek clamps a negative target to zero', () async {
      final notifier = await playing(createContainer());
      fakePlayer.emitDuration(const Duration(seconds: 100));
      await Future<void>.delayed(Duration.zero);
      await notifier.seek(const Duration(seconds: -5));
      expect(fakePlayer.position, Duration.zero);
    });

    test('seek clamps past the end to the known duration', () async {
      final notifier = await playing(createContainer());
      fakePlayer.emitDuration(const Duration(seconds: 100));
      await Future<void>.delayed(Duration.zero);
      await notifier.seek(const Duration(seconds: 250));
      expect(fakePlayer.position, const Duration(seconds: 100));
      expect(container!.read(audioPositionProvider),
          const Duration(seconds: 100), reason: 'published position agrees');
    });

    test('an unknown (zero) duration is not an upper bound', () async {
      final notifier = await playing(createContainer());
      fakePlayer.emitDuration(null);
      await Future<void>.delayed(Duration.zero);
      await notifier.seek(const Duration(seconds: 42));
      expect(fakePlayer.position, const Duration(seconds: 42));
    });
  });

  test('playFromQueue seeds only a bounded initial player queue', () async {
    await fixture.insertAlbum(
      artist: 'Artist',
      album: 'Album',
      uuids: List.generate(120, (i) => 'track-${i + 1}'),
    );
    final startTrack = await fixture.track('track-60');

    final c = createContainer();
    c.read(queuePlayerProvider.notifier);
    await playFromQueue(c, track: startTrack,
      sourceType: 'album',
      artistId: 1,
      albumId: 1,
      orderParams: [OrderParameter(column: 'track_number')],
    );
    await Future<void>.delayed(Duration.zero);

    final snapshot = await repo.getSessionSnapshot(
      c.read(queuePlayerProvider).queue.sessionId!,
    );
    final queueTracks = await sessionTracksOf(c);

    expect(fakePlayer.seedCalls, hasLength(1));
    expect(fakePlayer.seedCalls.single.entries.length, lessThan(120));
    expect(snapshot?.totalCount, 120);
    expect(queueTracks, hasLength(120));
    expect(c.read(currentTrackProvider)?.uuidId, 'track-60');
  });

  test(
    'toggleShuffle rewrites persisted play order without reseeding',
    () async {
      await fixture.insertAlbum(
        artist: 'Artist',
        album: 'Album',
        uuids: ['a', 'b', 'c', 'd', 'e', 'f'],
      );
      final startTrack = await fixture.track('c');

      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromQueue(c, track: startTrack,
        sourceType: 'album',
        artistId: 1,
        albumId: 1,
        orderParams: [OrderParameter(column: 'track_number')],
      );
      await Future<void>.delayed(Duration.zero);

      final currentItemId = c.read(queuePlayerProvider).queue.currentItemId;
      await notifier.toggleShuffle();
      await Future<void>.delayed(Duration.zero);

      final queueTracks = await sessionTracksOf(c);
      expect(fakePlayer.seedCalls, hasLength(1));
      expect(fakePlayer.rebuildCalls, hasLength(1));
      expect(c.read(queuePlayerProvider).queue.currentItemId, currentItemId);
      expect(queueTracks.take(3).map((entry) => entry.uuidId), ['a', 'b', 'c']);
      expect(queueTracks[2].itemId, currentItemId);
      expect(queueTracks.skip(3).map((entry) => entry.uuidId).toSet(), {
        'd',
        'e',
        'f',
      });
    },
  );

  test(
    'toggleShuffle off restores canonical order without reseeding',
    () async {
      await fixture.insertAlbum(
        artist: 'Artist',
        album: 'Album',
        uuids: ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
      );
      final startTrack = await fixture.track('d');

      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromQueue(c, track: startTrack,
        sourceType: 'album',
        artistId: 1,
        albumId: 1,
        orderParams: [OrderParameter(column: 'track_number')],
      );
      await Future<void>.delayed(Duration.zero);

      final canonicalOrder = (await sessionTracksOf(c)).map((entry) => entry.uuidId).toList(growable: false);
      final currentItemId = c.read(queuePlayerProvider).queue.currentItemId;

      await notifier.toggleShuffle();
      await Future<void>.delayed(Duration.zero);
      await notifier.toggleShuffle();
      await Future<void>.delayed(Duration.zero);

      final restoredOrder = (await sessionTracksOf(c)).map((entry) => entry.uuidId).toList(growable: false);

      expect(fakePlayer.seedCalls, hasLength(1));
      expect(fakePlayer.rebuildCalls, hasLength(2));
      expect(c.read(queuePlayerProvider).queue.currentItemId, currentItemId);
      expect(restoredOrder, canonicalOrder);
      expect(
        await _playOrderCount(db, c.read(queuePlayerProvider).queue.sessionId!),
        canonicalOrder.length,
      );
    },
  );

  test('skipToTrack hydrates and seeks to an unloaded far item', () async {
    await fixture.insertAlbum(
      artist: 'Artist',
      album: 'Album',
      uuids: List.generate(100, (i) => 'track-${i + 1}'),
    );
    final startTrack = await fixture.track('track-40');

    final c = createContainer();
    final notifier = c.read(queuePlayerProvider.notifier);
    await playFromQueue(c, track: startTrack,
      sourceType: 'album',
      artistId: 1,
      albumId: 1,
      orderParams: [OrderParameter(column: 'track_number')],
    );
    await Future<void>.delayed(Duration.zero);

    final queueTracks = await sessionTracksOf(c);
    final target = queueTracks.last;
    expect(fakePlayer.hasItem(target.itemId), isFalse);

    await notifier.skipToTrack(target.itemId);
    await Future<void>.delayed(Duration.zero);

    // D30 (5B.0d): the window is rebased around the far item (one
    // contiguous interval), not extended by a distant range.
    expect(fakePlayer.seedCalls.last.currentItemId, target.itemId);
    expect(fakePlayer.hasItem(target.itemId), isTrue);
    expect(c.read(queuePlayerProvider).queue.currentItemId, target.itemId);
    // Branch audit (5B.0a M4): the intent the re-spec dropped.
    expect(fakePlayer.seedCalls.last.cause, PlaybackTransitionCause.userSkip,
        reason: 'listen accounting reads the rebase seed\'s cause');
    expect((await repo.getActiveSession())?.currentItemId, target.itemId,
        reason: 'the cursor is saved');
    expect(fakePlayer.seedCalls.last.autoPlay || fakePlayer.playCalls > 0, isTrue,
        reason: 'the far item plays');
  });

  test('playNext inserts tracks immediately after the current item', () async {
    await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'x', 'y']);
    final queueTracks = ['a', 'b', 'c', 'd', 'e'];
    final startTrack = await fixture.track('b');
    final x = await fixture.track('x');
    final y = await fixture.track('y');

    final c = createContainer();
    c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, queueTracks,
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await playNext(c, [x, y]);
    await Future<void>.delayed(Duration.zero);

    final entries = await sessionTracksOf(c);
    expect(entries.map((entry) => entry.uuidId), [
      'a',
      'b',
      'x',
      'y',
      'c',
      'd',
      'e',
    ]);
    expect(fakePlayer.loadedItemIds.length, greaterThanOrEqualTo(7));
  });

  test(
    'playNext without an active session creates a main queue session',
    () async {
      await fixture.insertSingles(['x', 'y']);
      final x = await fixture.track('x');
      final y = await fixture.track('y');

      final c = createContainer();
      c.read(queuePlayerProvider.notifier);
      await playNext(c, [x, y]);
      await Future<void>.delayed(Duration.zero);

      final sessionId = c.read(queuePlayerProvider).queue.sessionId!;
      final entries = await sessionTracksOf(c);

      expect(entries.map((entry) => entry.uuidId), ['x', 'y']);
      expect(c.read(currentTrackProvider)?.uuidId, 'x');
      expect(
        await repo.getQueueTypeItemIds(sessionId, QueueItemTypes.main),
        hasLength(2),
      );
      expect(
        await repo.getQueueTypeItemIds(sessionId, QueueItemTypes.manual),
        isEmpty,
      );
    },
  );

  test(
    'addToQueue without an active session creates a main queue session',
    () async {
      await fixture.insertSingles(['x', 'y']);
      final x = await fixture.track('x');
      final y = await fixture.track('y');

      final c = createContainer();
      c.read(queuePlayerProvider.notifier);
      await addToQueue(c, [x, y]);
      await Future<void>.delayed(Duration.zero);

      final sessionId = c.read(queuePlayerProvider).queue.sessionId!;
      final entries = await sessionTracksOf(c);

      expect(entries.map((entry) => entry.uuidId), ['x', 'y']);
      expect(c.read(currentTrackProvider)?.uuidId, 'x');
      expect(
        await repo.getQueueTypeItemIds(sessionId, QueueItemTypes.main),
        hasLength(2),
      );
      expect(
        await repo.getQueueTypeItemIds(sessionId, QueueItemTypes.manual),
        isEmpty,
      );
    },
  );

  test('manual queued tracks stay next across shuffle on and off', () async {
    await fixture.insertSingles(['a', 'b', 'c', 'd', 'x']);
    final startTrack = await fixture.track('b');
    final queued = await fixture.track('x');

    final c = createContainer();
    final notifier = c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, const ['a', 'b', 'c', 'd'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await playNext(c, [queued]);
    await Future<void>.delayed(Duration.zero);
    expect(
      (await sessionTracksOf(c)).map((entry) => entry.uuidId),
      ['a', 'b', 'x', 'c', 'd'],
    );

    await notifier.toggleShuffle();
    await Future<void>.delayed(Duration.zero);
    expect(
      (await sessionTracksOf(c)).skip(2).first.uuidId,
      'x',
    );

    await notifier.toggleShuffle();
    await Future<void>.delayed(Duration.zero);
    expect(
      (await sessionTracksOf(c)).map((entry) => entry.uuidId),
      ['a', 'b', 'x', 'c', 'd'],
    );
  });

  test(
    'playNext while already shuffled inserts the manual item as next',
    () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'x']);

      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b', 'c', 'd', 'e'],
        currentIndex: 4,
      );
      final ordered = await repo.getSessionTracksInPlayOrder(sessionId);
      final idsByUuid = {
        for (final entry in ordered) entry.uuidId: entry.itemId,
      };
      await repo.replacePlayOrder(sessionId, [
        idsByUuid['a']!,
        idsByUuid['d']!,
        idsByUuid['c']!,
        idsByUuid['e']!,
        idsByUuid['b']!,
      ]);
      await repo.updateShuffleEnabled(sessionId, true);
      await repo.updatePlaybackCursor(
        sessionId: sessionId,
        currentItemId: idsByUuid['e']!,
        positionMs: 0,
        resumeMainItemId: idsByUuid['e']!,
        updateResumeMainItemId: true,
      );

      final queued = await fixture.track('x');
      final c = createContainer();
      c.read(queuePlayerProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      await playNext(c, [queued]);
      await Future<void>.delayed(Duration.zero);

      final entries = await sessionTracksOf(c);
      expect(entries.map((entry) => entry.uuidId), [
        'a',
        'd',
        'c',
        'e',
        'x',
        'b',
      ]);
      expect(c.read(currentTrackProvider)?.uuidId, 'e');

      await c.read(queuePlayerProvider.notifier).skipNext();
      await Future<void>.delayed(Duration.zero);

      expect(c.read(currentTrackProvider)?.uuidId, 'x');
    },
  );

  test(
    'toggleShuffle off restores the current main track to its canonical position',
    () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);

      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b', 'c', 'd', 'e'],
        currentIndex: 0,
      );
      final ordered = await repo.getSessionTracksInPlayOrder(sessionId);
      final idsByUuid = {
        for (final entry in ordered) entry.uuidId: entry.itemId,
      };
      await repo.replacePlayOrder(sessionId, [
        idsByUuid['a']!,
        idsByUuid['c']!,
        idsByUuid['b']!,
        idsByUuid['d']!,
        idsByUuid['e']!,
      ]);
      await repo.updateShuffleEnabled(sessionId, true);
      await repo.updatePlaybackCursor(
        sessionId: sessionId,
        currentItemId: idsByUuid['c']!,
        positionMs: 0,
      );

      final c = createContainer();
      c.read(queuePlayerProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(currentTrackProvider)?.uuidId, 'c');
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 1);

      await c.read(queuePlayerProvider.notifier).toggleShuffle();
      await Future<void>.delayed(Duration.zero);

      final entries = await sessionTracksOf(c);
      expect(entries.map((entry) => entry.uuidId), ['a', 'b', 'c', 'd', 'e']);
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 2);
    },
  );

  test(
    'toggleShuffle off while current item is manual keeps manual queue stable',
    () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'x', 'y']);
      final startTrack = await fixture.track('b');
      final x = await fixture.track('x');
      final y = await fixture.track('y');

      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b', 'c', 'd'],
        startTrack,
        sourceType: 'search',
      );
      await Future<void>.delayed(Duration.zero);

      await playNext(c, [x, y]);
      await Future<void>.delayed(Duration.zero);

      final afterInsert = await sessionTracksOf(c);
      await notifier.skipToTrack(afterInsert[2].itemId);
      await Future<void>.delayed(Duration.zero);

      final snapshotBeforeShuffle = await repo.getSessionSnapshot(
        c.read(queuePlayerProvider).queue.sessionId!,
      );
      expect(
        snapshotBeforeShuffle?.session.resumeMainItemId,
        afterInsert[1].itemId,
      );

      await notifier.toggleShuffle();
      await Future<void>.delayed(Duration.zero);
      await notifier.toggleShuffle();
      await Future<void>.delayed(Duration.zero);

      final restored = await sessionTracksOf(c);
      expect(restored.map((entry) => entry.uuidId), [
        'a',
        'b',
        'x',
        'y',
        'c',
        'd',
      ]);
      expect(c.read(currentTrackProvider)?.uuidId, 'x');
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 2);
    },
  );

  test(
    'removeFromQueue before the current item updates current play position',
    () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);
      final startTrack = await fixture.track('a');

      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b', 'c', 'd'],
        startTrack,
        sourceType: 'search',
      );
      await Future<void>.delayed(Duration.zero);

      var entries = await sessionTracksOf(c);
      await notifier.skipToTrack(entries[3].itemId);
      await Future<void>.delayed(Duration.zero);

      await notifier.removeFromQueue(entries[1].itemId);
      await Future<void>.delayed(Duration.zero);

      entries = await sessionTracksOf(c);
      expect(entries.map((entry) => entry.uuidId), ['a', 'c', 'd']);
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 2);
      expect(c.read(currentTrackProvider)?.uuidId, 'd');
    },
  );

  test('restores persisted current item and position on startup', () async {
    await fixture.insertSingles(['a', 'b', 'c', 'd']);
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: const ['a', 'b', 'c', 'd'],
      currentIndex: 2,
    );
    final snapshot = await repo.getSessionSnapshot(sessionId);
    await repo.updatePlaybackCursor(
      sessionId: sessionId,
      currentItemId: snapshot!.currentItem!.itemId,
      positionMs: 42000,
    );

    final c = createContainer();
    c.read(queuePlayerProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(fakePlayer.seedCalls, hasLength(1));
    expect(fakePlayer.seedCalls.single.autoPlay, isFalse);
    expect(c.read(currentTrackProvider)?.uuidId, 'c');
    expect(c.read(audioPositionProvider), const Duration(seconds: 42));
  });

  test('queue restore waits for the session to be ready, with offline known',
      () async {
    // An offline cold start: the wiring and queue player exist before the gate has
    // health-checked. Restore must not seed a streaming entry meanwhile.
    await fixture.insertSingles(['a', 'b']);
    await markDownloaded('b', '/dl/b');
    final sessionId = await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: const ['a', 'b'],
      currentIndex: 0,
    );
    final snapshot = await repo.getSessionSnapshot(sessionId);
    await repo.updatePlaybackCursor(
      sessionId: sessionId,
      currentItemId: snapshot!.currentItem!.itemId,
      positionMs: 1000,
    );
    final readiness = SessionReadiness();
    final offline = _MutableOffline();
    final c = createContainer(readiness: readiness, offlineNotifier: () => offline);
    c.read(queuePlayerProvider);
    await pumpEventQueue(times: 50);
    expect(fakePlayer.seedCalls, isEmpty, reason: 'no restore before ready');

    // The session host learns the server is unreachable, then activates.
    offline.set(true);
    readiness.markReady();
    for (var i = 0; i < 100 && fakePlayer.seedCalls.isEmpty; i++) {
      await pumpEventQueue();
    }
    expect(fakePlayer.seedCalls, hasLength(1));
    expect(c.read(currentTrackProvider)?.uuidId, 'b',
        reason: 'offline known: restore lands on the downloaded entry');
  });

  test('a scope disposed while waiting for the session never restores',
      () async {
    await fixture.insertSingles(['a']);
    await repo.createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: const ['a'],
    );
    final readiness = SessionReadiness();
    final c = createContainer(readiness: readiness);
    c.read(queuePlayerProvider);
    await pumpEventQueue(times: 50);
    c.dispose(); // e.g. a reset rebuilt the scope
    container = null;
    readiness.markReady();
    await pumpEventQueue(times: 50);
    expect(fakePlayer.seedCalls, isEmpty);
  });

  test('restores persisted volume on startup', () async {
    SharedPreferences.setMockInitialValues({'audioVolume': 0.35});

    final c = createContainer();
    c.read(queuePlayerProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(c.read(audioVolumeProvider), 0.35);
    expect(fakePlayer.lastVolume, 0.35);
  });

  test('setVolume persists volume preference', () async {
    final c = createContainer();
    c.read(queuePlayerProvider);
    await Future<void>.delayed(Duration.zero);

    await c.read(queuePlayerProvider.notifier).setVolume(0.42);

    final prefs = await SharedPreferences.getInstance();
    expect(c.read(audioVolumeProvider), 0.42);
    expect(fakePlayer.lastVolume, 0.42);
    expect(prefs.getDouble('audioVolume'), 0.42);
  });

  test('skipNext advances to next track', () async {
    await fixture.insertSingles(['a', 'b', 'c']);
    final startTrack = await fixture.track('a');

    final c = createContainer();
    final notifier = c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, const ['a', 'b', 'c'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    expect(c.read(currentTrackProvider)?.uuidId, 'a');

    await notifier.skipNext();
    await Future<void>.delayed(Duration.zero);

    expect(c.read(currentTrackProvider)?.uuidId, 'b');
    expect(
      fakePlayer.seekedItems.last,
      c.read(queuePlayerProvider).queue.currentItemId,
    );
  });

  test('skipNext at end with repeat off is a no-op', () async {
    await fixture.insertSingles(['a', 'b']);
    final startTrack = await fixture.track('b');

    final c = createContainer();
    final notifier = c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, const ['a', 'b'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    expect(c.read(currentTrackProvider)?.uuidId, 'b');
    expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 1);

    await notifier.skipNext();
    await Future<void>.delayed(Duration.zero);

    expect(c.read(currentTrackProvider)?.uuidId, 'b');
    expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 1);
  });

  test('skipNext with repeat-all wraps to first track', () async {
    await fixture.insertSingles(['a', 'b', 'c']);
    final startTrack = await fixture.track('c');

    final c = createContainer();
    final notifier = c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, const ['a', 'b', 'c'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.cycleQueueRepeatMode();
    await Future<void>.delayed(Duration.zero);
    expect(c.read(queuePlayerProvider).queue.repeatMode, QueueRepeatMode.all);

    await notifier.skipNext();
    await Future<void>.delayed(Duration.zero);

    expect(c.read(currentTrackProvider)?.uuidId, 'a');
    expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 0);
  });

  test('skipPrevious restarts when position > 3s', () async {
    await fixture.insertSingles(['a', 'b', 'c']);
    final startTrack = await fixture.track('b');

    final c = createContainer();
    final notifier = c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, const ['a', 'b', 'c'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.seek(const Duration(seconds: 30));
    await notifier.skipPrevious();
    await Future<void>.delayed(Duration.zero);

    expect(c.read(currentTrackProvider)?.uuidId, 'b');
    expect(fakePlayer.position, Duration.zero);
  });

  test('skipPrevious goes back when position <= 3s', () async {
    await fixture.insertSingles(['a', 'b', 'c']);
    final startTrack = await fixture.track('b');

    final c = createContainer();
    final notifier = c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, const ['a', 'b', 'c'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.seek(const Duration(seconds: 2));
    await notifier.skipPrevious();
    await Future<void>.delayed(Duration.zero);

    expect(c.read(currentTrackProvider)?.uuidId, 'a');
  });

  test('skipPrevious at start with repeat-all wraps to last track', () async {
    await fixture.insertSingles(['a', 'b', 'c']);
    final startTrack = await fixture.track('a');

    final c = createContainer();
    final notifier = c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, const ['a', 'b', 'c'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.cycleQueueRepeatMode();
    await Future<void>.delayed(Duration.zero);

    await notifier.skipPrevious();
    await Future<void>.delayed(Duration.zero);

    expect(c.read(currentTrackProvider)?.uuidId, 'c');
    expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 2);
  });

  test('cycleQueueRepeatMode cycles off → all → one → off', () async {
    await fixture.insertSingles(['a']);
    final startTrack = await fixture.track('a');

    final c = createContainer();
    final notifier = c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, const ['a'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    expect(c.read(queuePlayerProvider).queue.repeatMode, QueueRepeatMode.off);

    await notifier.cycleQueueRepeatMode();
    expect(c.read(queuePlayerProvider).queue.repeatMode, QueueRepeatMode.all);
    expect(fakePlayer.lastLoopMode, EngineLoopMode.all);

    await notifier.cycleQueueRepeatMode();
    expect(c.read(queuePlayerProvider).queue.repeatMode, QueueRepeatMode.one);
    expect(fakePlayer.lastLoopMode, EngineLoopMode.one);

    await notifier.cycleQueueRepeatMode();
    expect(c.read(queuePlayerProvider).queue.repeatMode, QueueRepeatMode.off);
    expect(fakePlayer.lastLoopMode, EngineLoopMode.off);
  });

  test('stop resets state and deactivates session', () async {
    await fixture.insertSingles(['a', 'b']);
    final startTrack = await fixture.track('a');

    final c = createContainer();
    final notifier = c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, const ['a', 'b'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.stop();

    expect(c.read(queuePlayerProvider).queue.sessionId, isNull);
    expect(c.read(queuePlayerProvider).playback.status, PlayerStatus.idle);
    expect(c.read(currentTrackProvider), isNull);
    expect(fakePlayer.stopCalls, 1);

    final snapshot = await repo.getActiveSessionSnapshot();
    expect(snapshot, isNull);
  });

  test('addToQueue with existing session appends manual items', () async {
    await fixture.insertSingles(['a', 'b', 'c', 'x', 'y']);
    final startTrack = await fixture.track('a');
    final x = await fixture.track('x');
    final y = await fixture.track('y');

    final c = createContainer();
    c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, const ['a', 'b', 'c'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await addToQueue(c, [x, y]);
    await Future<void>.delayed(Duration.zero);

    final entries = await sessionTracksOf(c);
    expect(entries.map((entry) => entry.uuidId), ['a', 'x', 'y', 'b', 'c']);
    expect(c.read(currentTrackProvider)?.uuidId, 'a');
  });

  test(
    'bridge media callbacks no-op after the playback scope is disposed',
    () async {
      // Bind the OS bridge through the wiring (4A.0b: the wiring owns it, not
      // the queue player), then tear down the scope. An OS notification tap
      // firing afterwards must NOT reach the disposed controller/player.
      await fixture.insertSingles(['a']);
      final c = createContainer();
      c.listen(playbackWiringProvider, (_, _) {});
      c.read(queuePlayerProvider.notifier); // build the queue player
      await repo.startupRead.future;
      expect(bridge.onPlay, isNotNull);

      container?.dispose();
      container = null;

      expect(bridge.onPlay, isNull);
      expect(bridge.onPause, isNull);
      expect(bridge.onSkipToNext, isNull);
      expect(bridge.onSkipToPrevious, isNull);
      expect(bridge.onSeek, isNull);
      expect(bridge.onStop, isNull);
      expect(bridge.onClick, isNull);

      // audio_service still routes media button events through the bridge.
      // After clearCallbacks they must be no-ops, not throws — this would
      // previously have called into a torn-down player.
      await bridge.play();
      await bridge.pause();
      await bridge.skipToNext();
      await bridge.skipToPrevious();
      await bridge.seek(const Duration(seconds: 5));
      await bridge.stop();
      await bridge.click(MediaButton.media);
    },
  );

  test(
    'a newer scope rebinding the bridge survives the old one disposing',
    () async {
      // Two queue players in sequence: scope A binds, scope B binds, then
      // scope A disposes. Owner-aware clearCallbacks must leave B's
      // callbacks intact.
      await fixture.insertSingles(['a']);

      final cA = createContainer();
      cA.listen(playbackWiringProvider, (_, _) {});
      cA.read(queuePlayerProvider.notifier);
      await repo.startupRead.future;
      final firstOnPlay = bridge.onPlay;
      expect(firstOnPlay, isNotNull);

      // Build a second container against the same bridge — its queue player
      // rebinds the callbacks.
      final cB = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playbackEngineProvider.overrideWithValue(
            FakePlaybackEngine(),
          ),
          audioServiceProvider.overrideWithValue(bridge),
        ],
      );
      addTearDown(cB.dispose);
      cB.listen(playbackWiringProvider, (_, _) {});
      // Wiring is lazy; proving owner-token isolation does not require
      // constructing a second engine or starting its restore work.
      expect(
        identical(bridge.onPlay, firstOnPlay),
        isFalse,
        reason: 'the second scope\'s wiring should have rebound onPlay',
      );

      // Disposing scope A must NOT clear scope B's callbacks.
      cA.dispose();
      container = null;
      expect(bridge.onPlay, isNotNull);
      expect(bridge.onPause, isNotNull);
    },
  );

  group('offline playback policy', () {
    test(
      'offline skipNext jumps past streaming-only entries to next downloaded',
      () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
        await markDownloaded('a', '/dl/a');
        await markDownloaded('d', '/dl/d');

        final c = createContainer(offline: true);
        final notifier = c.read(queuePlayerProvider.notifier);
        final startTrack = await fixture.track('a');
        await playFromTrackList(c, const ['a', 'b', 'c', 'd', 'e'],
          startTrack,
          sourceType: 'search',
        );
        await Future<void>.delayed(Duration.zero);

        await notifier.skipNext();
        await Future<void>.delayed(Duration.zero);

        expect(c.read(currentTrackProvider)?.uuidId, 'd');
        expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 3);
      },
    );

    test(
      'offline skipPrevious searches backward for a downloaded entry',
      () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
        await markDownloaded('a', '/dl/a');
        await markDownloaded('e', '/dl/e');

        final c = createContainer(offline: true);
        final notifier = c.read(queuePlayerProvider.notifier);
        final startTrack = await fixture.track('e');
        await playFromTrackList(c, const ['a', 'b', 'c', 'd', 'e'],
          startTrack,
          sourceType: 'search',
        );
        await Future<void>.delayed(Duration.zero);

        await notifier.skipPrevious();
        await Future<void>.delayed(Duration.zero);

        expect(c.read(currentTrackProvider)?.uuidId, 'a');
        expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 0);
      },
    );

    test(
      'offline repeat-all wraps to a downloaded entry on skipNext',
      () async {
        await fixture.insertSingles(['a', 'b', 'c']);
        await markDownloaded('a', '/dl/a');

        final c = createContainer(offline: true);
        final notifier = c.read(queuePlayerProvider.notifier);
        final startTrack = await fixture.track('a');
        await playFromTrackList(c, const ['a', 'b', 'c'],
          startTrack,
          sourceType: 'search',
        );
        await Future<void>.delayed(Duration.zero);

        await notifier.cycleQueueRepeatMode();
        await Future<void>.delayed(Duration.zero);

        await notifier.skipNext();
        await Future<void>.delayed(Duration.zero);

        expect(c.read(currentTrackProvider)?.uuidId, 'a');
      },
    );

    test(
      'offline skipNext finds a downloaded target outside the loaded window',
      () async {
        final uuids = List.generate(120, (i) => 'track-${i + 1}');
        await fixture.insertAlbum(
          artist: 'Artist',
          album: 'Album',
          uuids: uuids,
        );
        await markDownloaded('track-1', '/dl/1');
        await markDownloaded('track-119', '/dl/119');

        final c = createContainer(offline: true);
        final notifier = c.read(queuePlayerProvider.notifier);
        final startTrack = await fixture.track('track-1');
        await playFromQueue(c, track: startTrack,
          sourceType: 'album',
          artistId: 1,
          albumId: 1,
          orderParams: [OrderParameter(column: 'track_number')],
        );
        await Future<void>.delayed(Duration.zero);

        // Confirm the loaded window doesn't already contain track-119 — the
        // controller must consult the repository, not just its loaded entries.
        expect(fakePlayer.loadedItemIds.length, lessThan(120));

        await notifier.skipNext();
        await Future<void>.delayed(Duration.zero);

        expect(c.read(currentTrackProvider)?.uuidId, 'track-119');
      },
    );

    test(
      'natural advance onto an unavailable entry rescues forward to downloaded',
      () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd']);
        await markDownloaded('a', '/dl/a');
        await markDownloaded('d', '/dl/d');

        final c = createContainer(offline: true);
        c.read(queuePlayerProvider.notifier);
        final startTrack = await fixture.track('a');
        await playFromTrackList(c, const ['a', 'b', 'c', 'd'],
          startTrack,
          sourceType: 'search',
        );
        await Future<void>.delayed(Duration.zero);

        // Simulate just_audio naturally advancing into the streaming-only
        // entry "b" — the controller surfaces the bad index to the queue player
        // which must hop the queue forward to "d".
        final entries = await repo.getPlaybackEntries(
          c.read(queuePlayerProvider).queue.sessionId!,
        );
        final bEntry = entries.firstWhere((e) => e.uuidId == 'b');
        fakePlayer.emitUnavailableAdvance(
          UnavailableAdvance(
            itemId: bEntry.itemId,
            playPosition: bEntry.playPosition,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(c.read(currentTrackProvider)?.uuidId, 'd');
      },
    );

    test(
      'offline session restore lands on the nearest downloaded entry',
      () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd']);
        await markDownloaded('d', '/dl/d');

        final sessionId = await repo.createSessionFromExplicitList(
          sourceType: 'search',
          trackUuids: const ['a', 'b', 'c', 'd'],
          currentIndex: 0,
        );
        final snapshot = await repo.getSessionSnapshot(sessionId);
        await repo.updatePlaybackCursor(
          sessionId: sessionId,
          currentItemId: snapshot!.currentItem!.itemId,
          positionMs: 12345,
        );

        final c = createContainer(offline: true);
        c.read(queuePlayerProvider);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(fakePlayer.seedCalls, hasLength(1));
        expect(c.read(currentTrackProvider)?.uuidId, 'd');
        // Restoring onto a fallback resets the cursor to zero — the saved
        // position belonged to the unavailable original track, not this one.
        expect(c.read(audioPositionProvider), Duration.zero);
      },
    );

    test('offline session restore skips when no entry is downloaded', () async {
      await fixture.insertSingles(['a', 'b']);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b'],
        currentIndex: 0,
      );
      final snapshot = await repo.getSessionSnapshot(sessionId);
      await repo.updatePlaybackCursor(
        sessionId: sessionId,
        currentItemId: snapshot!.currentItem!.itemId,
        positionMs: 0,
      );

      final c = createContainer(offline: true);
      c.read(queuePlayerProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(fakePlayer.seedCalls, isEmpty);
      expect(c.read(currentTrackProvider), isNull);
    });

    test(
      'hydrated stream rebuilds to file when download lands, then advances offline',
      () async {
        await fixture.insertSingles(['a', 'b', 'c']);
        await markDownloaded('a', '/dl/a');

        final c = createContainer(offline: true);
        final notifier = c.read(queuePlayerProvider.notifier);
        final startTrack = await fixture.track('a');
        await playFromTrackList(c, const ['a', 'b', 'c'],
          startTrack,
          sourceType: 'search',
        );
        await Future<void>.delayed(Duration.zero);

        // 'b' is currently a streaming-only entry hydrated into the player.
        final bEntryBefore = fakePlayer.loadedItemIds.contains(
          (await repo.getPlaybackEntries(
            c.read(queuePlayerProvider).queue.sessionId!,
          )).firstWhere((e) => e.uuidId == 'b').itemId,
        );
        expect(bEntryBefore, isTrue);

        // Seed the version stream with a baseline so the next emission is a
        // genuine prev→next transition (the queue player suppresses the
        // synthetic loading→initial hop).
        downloadStatusController.add(0);
        await Future<void>.delayed(Duration.zero);

        // 'b' is downloaded mid-playback; download-status bump must rebuild
        // the in-flight source so the offline rescue picks 'b' next.
        await markDownloaded('b', '/dl/b');
        downloadStatusController.add(1);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          fakePlayer.refreshedSources.any((r) => !r.oldHadFile && r.newHasFile),
          isTrue,
          reason: 'refresh should report b flipping stream → file',
        );

        await notifier.skipNext();
        await Future<void>.delayed(Duration.zero);

        expect(c.read(currentTrackProvider)?.uuidId, 'b');
      },
    );

    test(
      'hydrated file rescues via UnavailableAdvance when current download is deleted',
      () async {
        await fixture.insertSingles(['a', 'b', 'c']);
        await markDownloaded('a', '/dl/a');
        await markDownloaded('c', '/dl/c');

        final c = createContainer(offline: true);
        c.read(queuePlayerProvider.notifier);
        final startTrack = await fixture.track('a');
        await playFromTrackList(c, const ['a', 'b', 'c'],
          startTrack,
          sourceType: 'search',
        );
        await Future<void>.delayed(Duration.zero);

        expect(c.read(currentTrackProvider)?.uuidId, 'a');

        downloadStatusController.add(0);
        await Future<void>.delayed(Duration.zero);

        // Tell the fake to treat the next file→null transition on the
        // current item as an offline rescue.
        fakePlayer.offlineForRefresh = true;
        await markDeleted('a', '/dl/a');
        downloadStatusController.add(1);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          fakePlayer.refreshedSources.any((r) => r.oldHadFile && !r.newHasFile),
          isTrue,
          reason: 'refresh should report a flipping file → stream',
        );
        expect(c.read(currentTrackProvider)?.uuidId, 'c');
      },
    );

    test(
      'offline skipToTrack on an unavailable entry redirects to nearest downloaded',
      () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd']);
        await markDownloaded('a', '/dl/a');
        await markDownloaded('d', '/dl/d');

        final c = createContainer(offline: true);
        final notifier = c.read(queuePlayerProvider.notifier);
        final startTrack = await fixture.track('a');
        await playFromTrackList(c, const ['a', 'b', 'c', 'd'],
          startTrack,
          sourceType: 'search',
        );
        await Future<void>.delayed(Duration.zero);

        final entries = await sessionTracksOf(c);
        final unavailable = entries.firstWhere((e) => e.uuidId == 'b');

        await notifier.skipToTrack(unavailable.itemId);
        await Future<void>.delayed(Duration.zero);

        expect(c.read(currentTrackProvider)?.uuidId, 'd');
      },
    );
  });

  test('seek persists playback cursor immediately', () async {
    await fixture.insertSingles(['a', 'b']);
    final startTrack = await fixture.track('a');

    final c = createContainer();
    final notifier = c.read(queuePlayerProvider.notifier);
    await playFromTrackList(c, const ['a', 'b'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.seek(const Duration(seconds: 75));

    final snapshot = await repo.getSessionSnapshot(
      c.read(queuePlayerProvider).queue.sessionId!,
    );
    expect(c.read(audioPositionProvider), const Duration(seconds: 75));
    expect(snapshot?.session.currentPositionMs, 75000);
  });

  test(
    'sync queue mutation clears deleted current item and loads fallback',
    () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final startTrack = await fixture.track('b');

      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b', 'c'],
        startTrack,
        sourceType: 'search',
      );
      await notifier.seek(const Duration(seconds: 45));

      final sessionId = c.read(queuePlayerProvider).queue.sessionId!;
      final firstCurrentItemId = c.read(queuePlayerProvider).queue.currentItemId;
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(c.read(audioPositionProvider), const Duration(seconds: 45));

      await repo.removeTrackUuidsFromQueues(const ['b']);
      await notifier.reconcileAfterSyncQueueMutation({sessionId});

      final sessionRow = await (db.select(
        db.queueSessions,
      )..where((s) => s.id.equals(sessionId))).getSingle();
      expect(await _playOrderCount(db, sessionId), 2);
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      expect(c.read(audioPositionProvider), Duration.zero);
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 0);
      expect(c.read(queuePlayerProvider).queue.totalCount, 2);
      expect(
        c.read(queuePlayerProvider).queue.currentItemId,
        isNot(firstCurrentItemId),
      );
      expect(fakePlayer.seedCalls, hasLength(2));
      expect(fakePlayer.seedCalls.last.initialPosition, Duration.zero);
      expect(fakePlayer.seedCalls.last.autoPlay, isTrue);
      expect(
        sessionRow.currentItemId,
        c.read(queuePlayerProvider).queue.currentItemId,
      );
      expect(sessionRow.currentPositionMs, 0);
    },
  );

  test(
    'sync queue mutation deleting the whole active queue clears session',
    () async {
      await fixture.insertSingles(['a', 'b']);
      final startTrack = await fixture.track('a');
      final nextTrack = await fixture.track('b');

      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a'],
        startTrack,
        sourceType: 'search',
      );
      await Future<void>.delayed(Duration.zero);

      final sessionId = c.read(queuePlayerProvider).queue.sessionId!;
      expect(c.read(currentTrackProvider)?.uuidId, 'a');

      await repo.removeTrackUuidsFromQueues(const ['a']);
      await notifier.reconcileAfterSyncQueueMutation({sessionId});

      expect(c.read(queuePlayerProvider).queue.sessionId, isNull);
      expect(c.read(queuePlayerProvider).queue.currentItemId, isNull);
      expect(c.read(currentTrackProvider), isNull);
      expect(await repo.getActiveSession(), isNull);

      await addToQueue(c, [nextTrack]);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(c.read(queuePlayerProvider).queue.sessionId, isNot(sessionId));
      expect(c.read(queuePlayerProvider).queue.currentItemId, isNotNull);
    },
  );

  test(
    'sync queue mutation preserves surviving current item position',
    () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final startTrack = await fixture.track('b');

      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b', 'c'],
        startTrack,
        sourceType: 'search',
      );
      await notifier.seek(const Duration(seconds: 45));

      final sessionId = c.read(queuePlayerProvider).queue.sessionId!;
      final currentItemId = c.read(queuePlayerProvider).queue.currentItemId;
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 1);

      await repo.removeTrackUuidsFromQueues(const ['a']);
      await notifier.reconcileAfterSyncQueueMutation({sessionId});

      final sessionRow = await (db.select(
        db.queueSessions,
      )..where((s) => s.id.equals(sessionId))).getSingle();
      expect(await _playOrderCount(db, sessionId), 2);
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(c.read(audioPositionProvider), const Duration(seconds: 45));
      expect(c.read(queuePlayerProvider).queue.currentItemId, currentItemId);
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 0);
      expect(fakePlayer.seedCalls, hasLength(2));
      expect(
        fakePlayer.seedCalls.last.initialPosition,
        const Duration(seconds: 45),
      );
      expect(sessionRow.currentItemId, currentItemId);
      expect(sessionRow.currentPositionMs, 45000);
    },
  );

  test(
    'sync queue mutation keeps autoplay while player is buffering',
    () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final startTrack = await fixture.track('b');

      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b', 'c'],
        startTrack,
        sourceType: 'search',
      );
      await notifier.seek(const Duration(seconds: 12));

      fakePlayer.emitPlayerState(
        EngineTransportState(true, EngineProcessingState.buffering),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.read(queuePlayerProvider).playback.status, PlayerStatus.loading);

      final sessionId = c.read(queuePlayerProvider).queue.sessionId!;
      final currentItemId = c.read(queuePlayerProvider).queue.currentItemId;

      await repo.removeTrackUuidsFromQueues(const ['c']);
      await notifier.reconcileAfterSyncQueueMutation({sessionId});

      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(c.read(audioPositionProvider), const Duration(seconds: 12));
      expect(c.read(queuePlayerProvider).queue.currentItemId, currentItemId);
      expect(fakePlayer.seedCalls, hasLength(2));
      expect(fakePlayer.seedCalls.last.autoPlay, isTrue);
    },
  );
}

Future<int> _playOrderCount(AppDatabase db, int sessionId) async {
  final row = await db
      .customSelect(
        'SELECT COUNT(*) AS c FROM queue_session_play_order WHERE session_id = ?',
        variables: [Variable.withInt(sessionId)],
      )
      .getSingle();
  return row.read<int>('c');
}

class _ObservedStartupRepository extends QueueRepository {
  _ObservedStartupRepository(super.db);

  final startupRead = Completer<void>();
  Completer<void>? startupRelease;
  final cursorSaves = <int>[];
  Object? pruneError;
  final pruneFailed = Completer<void>();
  int prunes = 0;

  @override
  Future<int> pruneInactiveSessions() async {
    prunes++;
    final error = pruneError;
    if (error != null) {
      pruneError = null;
      if (!pruneFailed.isCompleted) pruneFailed.complete();
      throw error;
    }
    return super.pruneInactiveSessions();
  }
  Object? getTrackForItemError;
  Object? activeSnapshotError;
  int? failActivationOf;

  @override
  Future<void> activateSession(int sessionId) async {
    if (sessionId == failActivationOf) {
      failActivationOf = null;
      throw StateError('db gone');
    }
    return super.activateSession(sessionId);
  }

  Completer<void>? trackReadGate;
  int? trackReadGateItem;
  final trackReadEntered = Completer<void>();

  @override
  Future<QueueTrackEntry?> getTrackForItem(int sessionId, int itemId) async {
    final error = getTrackForItemError;
    if (error != null) throw error;
    final gate = trackReadGate;
    if (gate != null && itemId == trackReadGateItem) {
      if (!trackReadEntered.isCompleted) trackReadEntered.complete();
      await gate.future;
    }
    return super.getTrackForItem(sessionId, itemId);
  }
  Completer<void>? deactivateGate;
  Completer<void>? removeGate;
  final removeEntered = Completer<void>();

  @override
  Future<void> removeItem(int sessionId, int itemId) async {
    final gate = removeGate;
    if (gate != null) {
      if (!removeEntered.isCompleted) removeEntered.complete();
      await gate.future;
    }
    return super.removeItem(sessionId, itemId);
  }
  Completer<void>? hydrationGate;
  final hydrationEntered = Completer<void>();

  Object? metadataReadError;
  @override
  Future<List<QueuePlaybackEntry>> getPlaybackEntriesForItemIds(
      int sessionId, Iterable<int> itemIds) async {
    final error = metadataReadError;
    if (error != null) {
      metadataReadError = null;
      throw error;
    }
    return super.getPlaybackEntriesForItemIds(sessionId, itemIds);
  }

  @override
  Future<List<QueuePlaybackEntry>> getPlaybackEntries(int sessionId,
      {int startPlayPosition = 0, int? limit}) async {
    final gate = hydrationGate;
    if (gate != null && limit == 50) {
      if (!hydrationEntered.isCompleted) hydrationEntered.complete();
      await gate.future;
    }
    return super.getPlaybackEntries(sessionId,
        startPlayPosition: startPlayPosition, limit: limit);
  }
  final deactivateEntered = Completer<void>();

  @override
  Future<void> deactivateAll() async {
    final gate = deactivateGate;
    if (gate != null) {
      if (!deactivateEntered.isCompleted) deactivateEntered.complete();
      await gate.future;
    }
    return super.deactivateAll();
  }

  @override
  Future<void> updatePlaybackCursor({
    required int sessionId,
    required int currentItemId,
    required int positionMs,
    int? resumeMainItemId,
    bool updateResumeMainItemId = false,
  }) {
    cursorSaves.add(positionMs);
    return super.updatePlaybackCursor(
      sessionId: sessionId,
      currentItemId: currentItemId,
      positionMs: positionMs,
      resumeMainItemId: resumeMainItemId,
      updateResumeMainItemId: updateResumeMainItemId,
    );
  }

  @override
  Future<QueueSessionSnapshot?> getActiveSessionSnapshot() async {
    final error = activeSnapshotError;
    if (error != null) {
      if (!startupRead.isCompleted) startupRead.complete();
      throw error;
    }
    final result = await super.getActiveSessionSnapshot();
    if (!startupRead.isCompleted) startupRead.complete();
    await startupRelease?.future;
    return result;
  }
}

class _GatedCoverArt extends CoverArtCacheManager {
  _GatedCoverArt() : super.noop();
  final entered = Completer<void>();
  final release = Completer<Uri?>();
  @override
  Future<Uri?> resolveArtUri({required bool hasAlbumArt, required int? coverArtId}) {
    if (!hasAlbumArt || coverArtId == null) return Future.value(null);
    entered.complete();
    return release.future;
  }
}

class FakePlaybackEngine
    implements PlaybackEngine {
  final _playerStateController = StreamController<EngineTransportState>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _currentItemIdController = StreamController<int?>.broadcast();
  final _unavailableAdvanceController =
      StreamController<UnavailableAdvance>.broadcast();

  List<QueuePlaybackEntry> _loadedEntries = const [];
  int? _currentLocalIndex;
  int? _committedCurrentItemId;
  Duration _position = Duration.zero;
  bool _disposed = false;
  bool get isDisposed => _disposed;
  Completer<void>? addEntriesEntered;
  Completer<void>? addEntriesRelease;

  final List<SeedCall> seedCalls = [];
  final List<List<QueuePlaybackEntry>> addedBatches = [];
  final List<List<QueuePlaybackEntry>> replacedFutureBatches = [];
  final List<List<QueuePlaybackEntry>> rebuildCalls = [];
  final List<int> removedItems = [];
  final List<int> seekedItems = [];
  final List<PlaybackTransitionCause> seekCauses = [];
  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  EngineLoopMode? lastLoopMode;
  double? lastVolume;
  String? lastStreamQuality;

  @override
  void setStreamQuality(String quality) {
    lastStreamQuality = quality;
  }

  @override
  Future<void> rebuildCurrentSource(String quality, Duration seekTo) async =>
      rebuilds.add(('current', quality, seekTo, _committedCurrentItemId));

  @override
  Future<void> rebuildAllSources(String quality, Duration seekTo) async =>
      rebuilds.add(('all', quality, seekTo, _committedCurrentItemId));

  final rebuilds = <(String, String, Duration, int?)>[];

  @override
  Future<void> setSeed(
    List<QueuePlaybackEntry> entries, {
    required int currentItemId,
    int? sessionId,
    PlaybackTransitionCause cause = PlaybackTransitionCause.queueReplacement,
    Duration initialPosition = Duration.zero,
    bool autoPlay = false,
    bool shuffleEnabled = false,
  }) async {
    playlistRevision++; // like the engine: every seed is a new revision
    _loadedEntries = _sorted(entries);
    _currentLocalIndex = _loadedEntries.indexWhere(
      (entry) => entry.itemId == currentItemId,
    );
    _committedCurrentItemId = currentItemId;
    _position = initialPosition;
    seedCalls.add(
      SeedCall(
        entries: List<QueuePlaybackEntry>.from(_loadedEntries),
        currentItemId: currentItemId,
        sessionId: sessionId,
        cause: cause,
        initialPosition: initialPosition,
        autoPlay: autoPlay,
        shuffleEnabled: shuffleEnabled,
      ),
    );
    // Like production's structural mutation: commit identity silently.
    if (autoPlay) {
      playCalls++;
    }
  }

  @override
  Future<void> addEntries(List<QueuePlaybackEntry> entries) async {
    final release = addEntriesRelease;
    if (release != null) {
      final entered = addEntriesEntered;
      addEntriesEntered = null;
      if (entered != null && !entered.isCompleted) entered.complete();
      await release.future;
      addEntriesRelease = null;
    }
    final additions = entries
        .where((entry) => !hasItem(entry.itemId))
        .toList(growable: false);
    if (additions.isEmpty) return;

    playlistRevision++;
    addedBatches.add(additions);
    for (final entry in _sorted(additions)) {
      final insertionIndex = _insertionIndexFor(entry.playPosition);
      if (_currentLocalIndex != null && insertionIndex <= _currentLocalIndex!) {
        _currentLocalIndex = _currentLocalIndex! + 1;
      }
      _loadedEntries = List<QueuePlaybackEntry>.from(_loadedEntries)
        ..insert(insertionIndex, entry);
    }
  }

  @override
  void replaceLoadedEntriesMetadata(List<QueuePlaybackEntry> updatedEntries) {
    final byItemId = {for (final entry in updatedEntries) entry.itemId: entry};
    _loadedEntries = _loadedEntries
        .map((entry) => byItemId[entry.itemId] ?? entry)
        .toList(growable: false);
  }

  /// Set by the test harness so the fake can decide, on a per-itemId basis,
  /// whether the simulated local file is currently considered present. The
  /// production controller goes through dart:io File.existsSync() — in tests
  /// we steer it through the same external set the QueueRepository fixture
  /// uses to decide playability.
  bool Function(QueuePlaybackEntry entry) sourceAvailability = (entry) =>
      entry.filePath != null && entry.filePath!.isNotEmpty;

  bool offlineForRefresh = false;

  final List<RefreshedSource> refreshedSources = [];
  final List<int> rescuedItemIds = [];

  @override
  Future<void> refreshLoadedSourcesForAvailabilityChanges(
    List<QueuePlaybackEntry> updatedEntries,
  ) async {
    final byItemId = {for (final entry in updatedEntries) entry.itemId: entry};
    final nextEntries = <QueuePlaybackEntry>[];
    int? rescueItemId;
    int? rescuePlayPosition;
    for (final oldEntry in _loadedEntries) {
      final newEntry = byItemId[oldEntry.itemId] ?? oldEntry;
      nextEntries.add(newEntry);
      final oldHadFile = sourceAvailability(oldEntry);
      final newHasFile = sourceAvailability(newEntry);
      if (oldHadFile == newHasFile && oldEntry.filePath == newEntry.filePath) {
        continue;
      }
      refreshedSources.add(
        RefreshedSource(
          itemId: newEntry.itemId,
          oldHadFile: oldHadFile,
          newHasFile: newHasFile,
        ),
      );
      if (newEntry.itemId == _committedCurrentItemId &&
          oldHadFile &&
          !newHasFile &&
          offlineForRefresh) {
        rescueItemId = newEntry.itemId;
        rescuePlayPosition = newEntry.playPosition;
      }
    }
    _loadedEntries = nextEntries;
    if (rescueItemId != null && rescuePlayPosition != null) {
      rescuedItemIds.add(rescueItemId);
      _unavailableAdvanceController.add(
        UnavailableAdvance(
          itemId: rescueItemId,
          playPosition: rescuePlayPosition,
        ),
      );
    }
  }

  @override
  Future<void> replaceFutureEntries({
    required int currentItemId,
    required List<QueuePlaybackEntry> entries,
  }) async {
    final error = replaceFutureEntriesError;
    if (error != null) {
      replaceFutureEntriesError = null;
      throw error;
    }
    final currentIndex = _loadedEntries.indexWhere(
      (entry) => entry.itemId == currentItemId,
    );
    if (currentIndex < 0) {
      throw StateError('Current item $currentItemId is not loaded');
    }

    playlistRevision++;
    replacedFutureBatches.add(List<QueuePlaybackEntry>.from(entries));
    _loadedEntries = List<QueuePlaybackEntry>.from(
      _loadedEntries.take(currentIndex + 1),
    );
    for (final entry in _sorted(entries)) {
      final insertionIndex = _insertionIndexFor(entry.playPosition);
      _loadedEntries = List<QueuePlaybackEntry>.from(_loadedEntries)
        ..insert(insertionIndex, entry);
    }
  }

  @override
  Future<void> rebuildAroundCurrent({
    required int currentItemId,
    required List<QueuePlaybackEntry> entries,
  }) async {
    final sorted = _sorted(entries);
    final nextIndex = sorted.indexWhere(
      (entry) => entry.itemId == currentItemId,
    );
    if (nextIndex < 0) {
      throw StateError('Current item $currentItemId is not in rebuilt queue');
    }

    playlistRevision++;
    rebuildCalls.add(List<QueuePlaybackEntry>.from(sorted));
    _loadedEntries = sorted;
    _currentLocalIndex = nextIndex;
    _committedCurrentItemId = currentItemId;
  }

  @override
  Future<void> removeItem(int itemId) async {
    final index = _loadedEntries.indexWhere((entry) => entry.itemId == itemId);
    if (index < 0) return;
    playlistRevision++;
    removedItems.add(itemId);
    _loadedEntries = List<QueuePlaybackEntry>.from(_loadedEntries)
      ..removeAt(index);
    if (_currentLocalIndex != null && index < _currentLocalIndex!) {
      _currentLocalIndex = _currentLocalIndex! - 1;
    }
  }

  @override
  Future<void> seekToItem(
    int itemId, {
    Duration position = Duration.zero,
    PlaybackTransitionCause cause = PlaybackTransitionCause.userSkip,
  }) async {
    final index = _loadedEntries.indexWhere((entry) => entry.itemId == itemId);
    if (index < 0) {
      throw StateError('Item $itemId is not loaded');
    }
    seekedItems.add(itemId);
    seekCauses.add(cause);
    _currentLocalIndex = index;
    // Like the engine: an item change is emitted only when it changes.
    final changed = _committedCurrentItemId != itemId;
    _committedCurrentItemId = itemId;
    _position = position;
    if (changed) _currentItemIdController.add(itemId);
  }

  int? get currentIndex => _currentLocalIndex;

  @override
  int? get currentItemId => _committedCurrentItemId;

  String? get currentUuid {
    if (_currentLocalIndex == null ||
        _currentLocalIndex! < 0 ||
        _currentLocalIndex! >= _loadedEntries.length) {
      return null;
    }
    return _loadedEntries[_currentLocalIndex!].uuidId;
  }

  @override
  Duration get position => _position;

  @override
  int playlistRevision = 0;

  final _loadEventsController = StreamController<EngineLoadEvent>.broadcast();

  @override
  Stream<EngineLoadEvent> get loadEvents => _loadEventsController.stream;

  void emitLoadEvent(EngineLoadEvent event) => _loadEventsController.add(event);

  final _sourceFailuresController =
      StreamController<EngineSourceFailure>.broadcast();

  @override
  Stream<EngineSourceFailure> get sourceFailures =>
      _sourceFailuresController.stream;

  /// A raw failure of [itemId] (default: the current item) as the real
  /// engine reports it.
  void emitSourceFailure(
      {int? itemId, int? sourceId, bool uncertain = false, int code = 0}) {
    final item = itemId ?? _committedCurrentItemId;
    final entry = _loadedEntries.where((e) => e.itemId == item).firstOrNull;
    _sourceFailuresController.add(EngineSourceFailure(
      playlistRevision: playlistRevision,
      source: uncertain || entry == null
          ? null
          : EngineSourceIdentity(
              // Like the engine: a source keeps its id across reports.
              sourceId: sourceId ?? entry.itemId + _failureSourceIds,
              sessionId: null,
              itemId: entry.itemId,
              trackUuid: entry.uuidId),
      uncertain: uncertain,
      errorCode: code,
    ));
  }

  static const _failureSourceIds = 1000;

  @override
  final int runtimeId = 1;

  @override
  Stream<PlaybackObservation> get observations =>
      _observationsController.stream;

  @override
  int get queueLength => _loadedEntries.length;

  @override
  List<int> get loadedItemIds =>
      _loadedEntries.map((entry) => entry.itemId).toList(growable: false);

  @override
  bool hasItem(int itemId) =>
      _loadedEntries.any((entry) => entry.itemId == itemId);

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    _positionController.add(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    lastVolume = volume;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  int setLoopModeFailures = 0;

  @override
  Future<void> setLoopMode(EngineLoopMode mode) async {
    if (setLoopModeFailures > 0) {
      setLoopModeFailures--;
      throw StateError('engine refused the loop mode');
    }
    lastLoopMode = mode;
  }

  @override
  Stream<EngineTransportState> get transportStateStream =>
      _playerStateController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;


  @override
  Stream<int?> get currentItemIdStream => _currentItemIdController.stream;

  @override
  Stream<UnavailableAdvance> get unavailableAdvanceStream =>
      _unavailableAdvanceController.stream;

  void emitPlayerState(EngineTransportState state) {
    _playerStateController.add(state);
  }

  List<int> get loadedPlayPositions =>
      _loadedEntries.map((entry) => entry.playPosition).toList();

  Object? replaceFutureEntriesError;

  /// The engine moved to [itemId] but its item-change event has not been
  /// processed yet (it is still in flight).
  void commitSilently(int itemId) {
    _committedCurrentItemId = itemId;
    _currentLocalIndex = _loadedEntries.indexWhere((e) => e.itemId == itemId);
  }

  void emitPosition(Duration position) {
    _position = position;
    _positionController.add(position);
  }

  void emitDuration(Duration? duration) {
    emitObservation(duration: duration);
  }

  final _observationsController =
      StreamController<PlaybackObservation>.broadcast();
  int _observationSequence = 0;

  /// A settled playing+ready observation of the current item.
  void emitPlayingObservation() => emitObservation(playing: true);

  /// A settled observation of [itemId] (default: the committed current item).
  void emitObservation(
      {int? itemId, Duration? duration, bool uncertain = false, bool playing = false}) {
    final item = itemId ?? _committedCurrentItemId;
    final entry = _loadedEntries.where((e) => e.itemId == item).firstOrNull;
    _observationsController.add(PlaybackObservation(
      runtimeId: runtimeId,
      sequence: ++_observationSequence,
      playlistRevision: playlistRevision,
      source: entry == null
          ? null
          : EngineSourceIdentity(
              sourceId: entry.itemId,
              sessionId: null,
              itemId: entry.itemId,
              trackUuid: entry.uuidId),
      position: _position,
      duration: duration,
      playing: playing,
      processingState: EngineProcessingState.ready,
      transitionCause: null,
      rate: 1.0,
      uncertain: uncertain,
    ));
  }

  void emitUnavailableAdvance(UnavailableAdvance event) {
    _unavailableAdvanceController.add(event);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _playerStateController.close();
    _positionController.close();
    _observationsController.close();
    _sourceFailuresController.close();
    _loadEventsController.close();
    _currentItemIdController.close();
    _unavailableAdvanceController.close();
  }

  static List<QueuePlaybackEntry> _sorted(List<QueuePlaybackEntry> entries) {
    final sorted = List<QueuePlaybackEntry>.from(entries);
    sorted.sort((a, b) => a.playPosition.compareTo(b.playPosition));
    return sorted;
  }

  int _insertionIndexFor(int playPosition) {
    for (var i = 0; i < _loadedEntries.length; i++) {
      if (_loadedEntries[i].playPosition > playPosition) {
        return i;
      }
    }
    return _loadedEntries.length;
  }
}

class RefreshedSource {
  final int itemId;
  final bool oldHadFile;
  final bool newHasFile;

  const RefreshedSource({
    required this.itemId,
    required this.oldHadFile,
    required this.newHasFile,
  });
}

class SeedCall {
  final List<QueuePlaybackEntry> entries;
  final int currentItemId;
  final int? sessionId;
  final PlaybackTransitionCause cause;
  final Duration initialPosition;
  final bool autoPlay;
  final bool shuffleEnabled;

  const SeedCall({
    required this.entries,
    required this.currentItemId,
    required this.sessionId,
    required this.cause,
    required this.initialPosition,
    required this.autoPlay,
    required this.shuffleEnabled,
  });
}

class RecordingAudioServiceBridge extends AudioServiceBridge {
  final List<MediaItem?> mediaItemEvents = [];
  final List<PlaybackState> playbackStateEvents = [];
  late final StreamSubscription<MediaItem?> _mediaSub;
  late final StreamSubscription<PlaybackState> _playbackSub;

  RecordingAudioServiceBridge() {
    _mediaSub = mediaItem.listen(mediaItemEvents.add);
    _playbackSub = playbackState.listen(playbackStateEvents.add);
  }

  Future<void> disposeBridge() async {
    await _mediaSub.cancel();
    await _playbackSub.cancel();
  }
}

class _MutableOffline extends OfflineModeNotifier {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

class _OfflineOn extends OfflineModeNotifier {
  @override
  bool build() => true;
}

class _LibraryFixture {
  final AppDatabase db;
  int _nextArtistId = 1;
  int _nextAlbumId = 1;
  final Map<String, int> _artistIds = {};
  final Map<String, int> _albumIds = {};

  _LibraryFixture(this.db);

  Future<void> insertAlbum({
    required String artist,
    required String album,
    required List<String> uuids,
  }) async {
    final artistId = await _ensureArtist(artist);
    final albumId = await _ensureAlbum(artistId, album);
    for (var i = 0; i < uuids.length; i++) {
      await _insertTrack(
        uuid: uuids[i],
        artist: artist,
        artistId: artistId,
        album: album,
        albumId: albumId,
        trackNumber: i + 1,
      );
    }
  }

  Future<void> insertSingles(List<String> uuids) async {
    for (var i = 0; i < uuids.length; i++) {
      final artistName = 'Artist ${i + 1}';
      final artistId = await _ensureArtist(artistName);
      final albumId = await _ensureAlbum(artistId, 'Singles ${i + 1}');
      await _insertTrack(
        uuid: uuids[i],
        artist: artistName,
        artistId: artistId,
        album: 'Singles ${i + 1}',
        albumId: albumId,
        trackNumber: 1,
      );
    }
  }

  Future<TrackUI> track(String uuid) async {
    final rows = await db.getTrackByUuid(uuid);
    return TrackUI.fromQueryRow(rows.single);
  }

  Future<int> _ensureArtist(String name) async {
    final key = name.toLowerCase();
    final existing = _artistIds[key];
    if (existing != null) return existing;

    final id = _nextArtistId++;
    await db
        .into(db.artists)
        .insert(ArtistsCompanion(id: Value(id), name: Value(name)));
    _artistIds[key] = id;
    return id;
  }

  Future<int> _ensureAlbum(int artistId, String name) async {
    final key = '$artistId:${name.toLowerCase()}';
    final existing = _albumIds[key];
    if (existing != null) return existing;

    final id = _nextAlbumId++;
    await db
        .into(db.albums)
        .insert(
          AlbumsCompanion(
            id: Value(id),
            name: Value(name),
            artistId: Value(artistId),
            year: const Value(2024),
            isSingleGrouping: const Value(false),
          ),
        );
    _albumIds[key] = id;
    return id;
  }

  Future<void> _insertTrack({
    required String uuid,
    required String artist,
    required int artistId,
    required String album,
    required int albumId,
    required int trackNumber,
  }) async {
    final dto = ClientTrackDto.fromJson({
      'uuid_id': uuid,
      'created_at': 1700000000 + trackNumber,
      'last_updated': 1700000100 + trackNumber,
      'revision': 1700000000 + trackNumber,
      'metadata': {
        'title': 'Track $uuid',
        'artist': artist,
        'album': album,
        'artist_id': artistId,
        'album_id': albumId,
        'track_number': trackNumber,
        'disc_number': 1,
        'duration': 180.0,
        'bitrate_kbps': 320.0,
        'sample_rate_hz': 44100,
        'channels': 2,
        'has_album_art': false,
      },
    });

    await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
    await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
  }
}

/// A just_audio player whose load never completes (5-A18's stalled stream).
class _StalledPlugin extends Mock implements ja.AudioPlayer {
  _StalledPlugin() {
    registerFallbackValue(_FakeAudioSource());
    registerFallbackValue(Duration.zero);
    registerFallbackValue(ja.LoopMode.off);
    when(() => setAudioSources(any(),
            initialIndex: any(named: 'initialIndex'),
            initialPosition: any(named: 'initialPosition')))
        .thenAnswer((_) => Completer<Duration?>().future);
    when(() => this.play()).thenAnswer((_) => Completer<void>().future);
    when(() => pause()).thenAnswer((_) => Completer<void>().future);
    when(() => stop()).thenAnswer((_) => Completer<void>().future);
    when(() => setLoopMode(any())).thenAnswer((_) async {});
    when(() => setVolume(any())).thenAnswer((_) async {});
    when(() => dispose()).thenAnswer((_) async {});
    when(() => playing).thenReturn(false);
    when(() => processingState).thenReturn(ja.ProcessingState.loading);
    when(() => duration).thenReturn(null);
    when(() => position).thenReturn(Duration.zero);
    when(() => speed).thenReturn(1.0);
    when(() => currentIndex).thenReturn(0);
    when(() => currentIndexStream).thenAnswer((_) => const Stream.empty());
    when(() => playerStateStream).thenAnswer((_) => const Stream.empty());
    when(() => positionStream).thenAnswer((_) => const Stream.empty());
    when(() => durationStream).thenAnswer((_) => const Stream.empty());
    when(() => positionDiscontinuityStream)
        .thenAnswer((_) => const Stream.empty());
    when(() => errorStream).thenAnswer((_) => const Stream.empty());
  }
}

class _FakeAudioSource extends Fake implements ja.AudioSource {}

class _RecordingWarm extends QueueWarmService {
  _RecordingWarm(QueueRepository repo) : super(queueRepo: repo);
  final calls = <(int?, int)>[];
  final qualities = <String>[];

  @override
  void scheduleWarm({
    required int? sessionId,
    required int currentPlayPosition,
    required String quality,
  }) {
    calls.add((sessionId, currentPlayPosition));
    qualities.add(quality);
  }
}

final _testQuality = NotifierProvider<_TestQuality, String>(_TestQuality.new);

class _TestQuality extends Notifier<String> {
  @override
  String build() => 'original';
  void set(String quality) => state = quality;
}

class _FailingReconcile extends DownloadReconciliationService {
  _FailingReconcile(AppDatabase db)
      : super(db: db, statusReader: DownloadStatusReader(db: db));
  @override
  Future<bool> reconcileTrack(String trackUuid) async =>
      throw StateError('db locked');
}

class _FlakyHistory extends HistoryRepository {
  _FlakyHistory(super.db);
  bool failNext = false;
  String? failedUuid;

  @override
  Future<void> insertLocal(String bindingToken, HistoryEventPayload event) {
    if (failNext) {
      failNext = false;
      failedUuid = event.eventUuid;
      throw StateError('disk full');
    }
    return super.insertLocal(bindingToken, event);
  }
}

class _ScriptedSync extends TrackSyncNotifier {
  @override
  Future<TrackSyncState> build() async => const TrackSyncState();
  void push(TrackSyncState next) => state = AsyncData(next);
}
