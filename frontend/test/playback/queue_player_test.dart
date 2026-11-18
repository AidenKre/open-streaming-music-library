import 'dart:async';
import 'dart:math' show Random;

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';

import 'package:frontend/models/history_intent.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_service_bridge.dart';
import 'package:frontend/playback/audio_focus.dart';
import 'package:frontend/playback/just_audio_engine.dart';
import 'package:frontend/playback/local_source_policy.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/playback/queue_window.dart';

import '../helpers/fake_audio_focus.dart' show FakeAudioSessionPort;
import '../helpers/fake_audio_focus.dart' show FakeTimers, RelinquishingOwner;
import '../helpers/fake_preview_engine.dart' show FakePreviewEngine;
import '../helpers/fake_playback_engine.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/services/history/click_recorder.dart';
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
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/playback_wiring.dart';
import 'package:frontend/ui/player_controller.dart';
import 'package:frontend/ui/preview_controller.dart';
import '../helpers/fake_clock.dart';
import '../helpers/playback_submit.dart';
import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/services/server_binding_gate.dart';
import '../helpers/server_binding.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/queue_warm_service.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/playback/now_playing_publisher.dart';
import 'package:frontend/playback/playback_issue_bus.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/playback/source_failure_classifier.dart';
import 'package:frontend/playback/queue_warm_listener.dart';
import '../helpers/no_server_api.dart';
import '../helpers/test_offline.dart';
import '../helpers/library_fixture.dart';

void main() {
  late AppDatabase db;
  late _ObservedStartupRepository repo;
  late LibraryFixture fixture;
  ProviderContainer? container;
  late FakePlaybackEngine fakePlayer;
  late RecordingAudioServiceBridge bridge;
  late FakeAudioSessionPort sessionPort;
  late _RecordingWarm warm;
  late _FlakyHistory history;
  late FakeClock testClock;
  final trackStatuses = <String, int?>{};
  Completer<void>? probeGate;
  // Holds the failure classifier's file check (U17-FE-PB-CORE-B-04).
  Completer<void>? classifyGate;

  final Set<String> existingFiles = <String>{};
  Completer<void>? fileGate;
  late StreamController<int> downloadStatusController;

  var coverArt = CoverArtCacheManager.noop();
  late ApiClient audioApi;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // The real settings and warm services are built by QueuePlayer.
    // Keep their incidental requests in memory: localhost might be a real
    // server, and connection failures/retry timing are not audio fixtures.
    audioApi = testApiClient('http://audio.test', MockClient((request) async {
      if (request.url.path == '/settings/quality') {
        return http.Response('{"quality":"original"}', 200);
      }
      if (request.url.path == '/tracks/warm') {
        return http.Response('{}', 200);
      }
      throw StateError('Unexpected audio-test request: ${request.url}');
    }));
    coverArt = CoverArtCacheManager.noop();
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
    existingFiles.clear();
    repo = _ObservedStartupRepository(db);
    fixture = LibraryFixture(db);
    fakePlayer = FakePlaybackEngine();
    bridge = RecordingAudioServiceBridge();
    sessionPort = FakeAudioSessionPort();
    warm = _RecordingWarm(repo);
    history = _FlakyHistory(db);
    testClock = FakeClock();
    trackStatuses.clear();
    probeGate = null;
    classifyGate = null;
    fileGate = null;
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
    QualityChangeKind qualityChangeKind = QualityChangeKind.full,
    bool failingReconcile = false,
    _ScriptedSync? sync,
    Random? random,
    List<Override> extraOverrides = const [],
  }) {
    container = ProviderContainer(
      overrides: [
        ...extraOverrides,
        if (random != null) queueRandomProvider.overrideWithValue(random),
        apiClientProvider.overrideWithValue(audioApi),
        coverArtCacheProvider.overrideWithValue(coverArt),
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
              .overrideWith((ref) => qualityChangeKind),
        ],
        downloadReconciliationServiceProvider.overrideWith((ref) =>
            failingReconcile
                ? _FailingReconcile(db)
                : DownloadReconciliationService(
              db: db,
              statusReader: DownloadStatusReader(),
              fileExists: (path) async => existingFiles.contains(path),
            )),
        sourceFailureClassifierProvider.overrideWith((ref) =>
            SourceFailureClassifier(
              fileExists: (path) async {
                await classifyGate?.future;
                return existingFiles.contains(path);
              },
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
        if (offline) offlineModeProvider.overrideWith(() => TestOffline(true)),
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

    // Pre-merge D5-03 / A6-08 and A6-07: two more ways the fake now behaves
    // like `JustAudioEngine`.
    test('the player fake rejects a seed whose current item is missing, '
        'before anything changes, like the production adapter', () async {
      await fixture.insertSingles(['a', 'b']);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'test', trackUuids: ['a', 'b'],
      );
      final entries = await repo.getPlaybackEntries(sessionId, startPlayPosition: 0, limit: 2);
      addTearDown(fakePlayer.dispose);
      await expectLater(
          fakePlayer.setSeed([entries.first], currentItemId: entries.last.itemId),
          throwsStateError);
      expect(fakePlayer.seedCalls, isEmpty);
      expect(fakePlayer.playlistRevision, 0);
      expect(fakePlayer.currentItemId, isNull);
      expect(fakePlayer.queueLength, 0);
    });

    test('the player fake reports a pause and a stop inside the call, once '
        'per change, like the production adapter', () async {
      await fixture.insertSingles(['a']);
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'test', trackUuids: ['a'],
      );
      final entries = await repo.getPlaybackEntries(sessionId, startPlayPosition: 0, limit: 1);
      final reports = <EngineTransportState>[];
      final sub = fakePlayer.transportStateStream.listen(reports.add);
      addTearDown(sub.cancel);
      await fakePlayer.setSeed(entries,
          currentItemId: entries.single.itemId, autoPlay: true);
      fakePlayer.emitSettledTransport();
      await fakePlayer.pause();
      await fakePlayer.pause(); // nothing changed: no second report
      await fakePlayer.play(); // (the fake leaves the play report to the test)
      await fakePlayer.pause(); // a pause after a play reports again
      await fakePlayer.stop();
      await pumpEventQueue();
      expect(reports, const [
        EngineTransportState(true, EngineProcessingState.ready),
        EngineTransportState(false, EngineProcessingState.ready),
        EngineTransportState(false, EngineProcessingState.ready),
        EngineTransportState(false, EngineProcessingState.idle),
      ]);
      fakePlayer.dispose();
      await fakePlayer.pause(); // after dispose: no report, no error
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

    Future<_GatedCoverArt> withArt(List<String> uuids, {Uri? local}) async {
      await fixture.insertSingles(uuids);
      for (final (i, uuid) in uuids.indexed) {
        await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals(uuid)))
            .write(TrackmetadataCompanion(
                hasAlbumArt: const Value(true), coverArtId: Value(7 + i)));
      }
      final art = _GatedCoverArt(local: local);
      coverArt = art;
      return art;
    }

    // Decision 7 (user, 2026-11-07): the OS gets the metadata at once; the
    // art follows when its location resolves (it never holds the title).
    test('delayed artwork: metadata publishes at once, the art follows',
        () async {
      final art = await withArt(['a']);
      final c = createContainer();
      await repo.startupRead.future;
      final starting = play(c, await fixture.track('a'));
      await art.entered.future;
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      final early = bridge.mediaItemEvents.whereType<MediaItem>().toList();
      expect(early.map((m) => (m.id, m.artUri)), [('a', null)]);
      final uri = Uri.parse('file:///test-art/a.png');
      art.release.complete(uri);
      await starting;
      await pumpEventQueue();
      final published = bridge.mediaItemEvents.whereType<MediaItem>().toList();
      expect(published.map((m) => (m.id, m.artUri)), [('a', null), ('a', uri)]);
    });

    test('review: a same-item republish (measured duration) keeps the art',
        () async {
      final art = await withArt(['a']);
      final c = createContainer();
      await repo.startupRead.future;
      final starting = play(c, await fixture.track('a'));
      await art.entered.future;
      final uri = Uri.parse('file:///test-art/a.png');
      art.release.complete(uri);
      await starting;
      await pumpEventQueue();
      fakePlayer.emitObservation(duration: const Duration(seconds: 201));
      await pumpEventQueue();
      final published = bridge.mediaItemEvents.whereType<MediaItem>().toList();
      expect(published.last.duration, const Duration(seconds: 201));
      expect(published.last.artUri, uri, reason: 'no blank art on an edit');
    });

    test('artwork that never resolves still publishes the metadata', () async {
      final art = await withArt(['a']);
      final c = createContainer();
      await repo.startupRead.future;
      unawaited(play(c, await fixture.track('a')));
      await art.entered.future;
      await pumpEventQueue();
      final published = bridge.mediaItemEvents.whereType<MediaItem>().toList();
      expect(published.map((m) => (m.id, m.artUri)), [('a', null)]);
      expect(published.single.title, isNotEmpty);
    });

    test('locally stored artwork publishes once, with the art', () async {
      final uri = Uri.parse('file:///local-art/7.png');
      final art = await withArt(['a'], local: uri);
      final c = createContainer();
      await repo.startupRead.future;
      await play(c, await fixture.track('a'));
      await pumpEventQueue();
      final published = bridge.mediaItemEvents.whereType<MediaItem>().toList();
      expect(published.map((m) => (m.id, m.artUri)), [('a', uri)]);
      expect(art.resolveCalls, 0, reason: 'no async lookup for local art');
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
      coverArt = art;
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
      // The metadata never waited for the art (decision 7): a was shown at
      // once; its late art must not replace b.
      expect(
          bridge.mediaItemEvents
              .whereType<MediaItem>()
              .map((m) => (m.id, m.artUri)),
          [('a', null), ('b', null)]);
    });

    test('a clear drops artwork still pending for the cleared item',
        () async {
      await fixture.insertSingles(['a']);
      await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals('a')))
          .write(const TrackmetadataCompanion(
              hasAlbumArt: Value(true), coverArtId: Value(7)));
      final art = _GatedCoverArt();
      coverArt = art;
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
      // a's metadata was published at once (decision 7); its late art is
      // not published after the clear.
      expect(
          bridge.mediaItemEvents
              .whereType<MediaItem>()
              .map((m) => (m.id, m.artUri)),
          [('a', null)]);
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
      // A recovery skip re-seeds at the target (live gate: a seek after a
      // failed load never loads on macOS).
      expect(
          (fakePlayer.seedCalls.last.currentItemId,
              fakePlayer.seedCalls.last.cause),
          ((await sessionTracksOf(c)).firstWhere((e) =>
                  e.uuidId == c.read(currentTrackProvider)?.uuidId).itemId,
              PlaybackTransitionCause.naturalAdvance));
    });

    // Decision 6 (user, 2026-11-07): a download on disk that fails to play
    // is damaged. It is kept, stops being claimed as a download, and the
    // undecided play streams online or skips offline.
    Future<String?> damagedPathOf(String uuid) async =>
        (await (db.select(db.tracks)..where((t) => t.uuidId.equals(uuid)))
                .getSingle())
            .damagedFilePath;

    // Review major 1 (user, 2026-11-09): marked only with evidence. Online
    // the failing download streams and is marked once that stream plays;
    // offline it is skipped and never marked.
    test('online, a damaged download streams and is marked once the stream '
        'plays', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals('a')))
          .write(const TrackmetadataCompanion(codec: Value('alac')));
      existingFiles.add('/dl/a');
      final c = await playingList(const ['a', 'b']);
      final seeks = fakePlayer.seekedItems.length;
      await fail();
      await fail(); // the same source reported again: handled once
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind),
          [SourceFailureKind.damagedLocalFile]);
      expect(await damagedPathOf('a'), isNull, reason: 'no evidence yet');
      expect(c.read(localSourcePolicyProvider).isSuspect('a', '/dl/a'), isTrue,
          reason: 'every rebuild streams it meanwhile');
      expect(fakePlayer.refreshedSources.single.newHasFile, isFalse,
          reason: 'the current source is rebuilt as the stream, once');
      expect(fakePlayer.refreshedSources.single.entry?.sourceCodec, 'alac',
          reason: 'the stand-in keeps its codecs (an undecodable "original" '
              'streams transcoded)');
      expect(fakePlayer.seekedItems, hasLength(seeks), reason: 'no skip');
      expect(c.read(currentTrackProvider)?.uuidId, 'a');

      fakePlayer.emitObservation(playing: true); // the stream plays
      await pumpEventQueue();
      expect(await damagedPathOf('a'), '/dl/a');
      expect((await fixture.track('a')).filePath, '/dl/a',
          reason: 'kept with its details; the mark makes it unusable');
      expect(existingFiles, contains('/dl/a'), reason: 'never deleted');
      expect(c.read(localSourcePolicyProvider).isSuspect('a', '/dl/a'), isFalse,
          reason: 'the mark took over');
    });

    test('online, when the stream fails too, nothing is marked', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      existingFiles.add('/dl/a');
      trackStatuses['a'] = 200;
      final c = await playingList(const ['a', 'b']);
      await fail();
      await fail(sourceId: 4242); // the stream standing in fails as well
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind),
          [SourceFailureKind.damagedLocalFile, SourceFailureKind.unknown]);
      expect(c.read(localSourcePolicyProvider).isSuspect('a', '/dl/a'), isFalse,
          reason: 'no evidence against the file: it is tried again later');
      fakePlayer.emitObservation(playing: true); // a later play proves nothing
      await pumpEventQueue();
      expect(await damagedPathOf('a'), isNull);
    });

    test('online, moving on before the stream plays marks nothing', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      existingFiles.add('/dl/a');
      final c = await playingList(const ['a', 'b']);
      await fail();
      await c.read(queuePlayerProvider.notifier).skipNext();
      await pumpEventQueue();
      fakePlayer.emitObservation(playing: true); // b plays
      await pumpEventQueue();
      expect(await damagedPathOf('a'), isNull);
      expect(c.read(localSourcePolicyProvider).isSuspect('a', '/dl/a'), isFalse);
    });

    test('review: a stream failing after its download committed never marks '
        'the new download damaged', () async {
      await fixture.insertSingles(['a', 'b']);
      trackStatuses['a'] = 200; // the server still has it
      final c = await playingList(const ['a', 'b']); // a streams
      await markDownloaded('a', '/dl/a'); // its download commits meanwhile
      await fail(); // then the (stream) source fails
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind),
          [SourceFailureKind.unknown],
          reason: 'classified as the stream it was, not the new file');
      expect((await fixture.track('a')).filePath, '/dl/a', reason: 'kept');
      expect(await damagedPathOf('a'), isNull);
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
    });

    test('offline, a damaged download is skipped and never marked', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      await markDownloaded('b', '/dl/b');
      existingFiles.addAll(['/dl/a', '/dl/b']);
      final c = await playingList(const ['a', 'b'], offline: true);
      await fail();
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind),
          [SourceFailureKind.damagedLocalFile]);
      expect(await damagedPathOf('a'), isNull);
      expect(c.read(localSourcePolicyProvider).isSuspect('a', '/dl/a'), isFalse);
      expect(existingFiles, contains('/dl/a'));
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      // A recovery skip re-seeds at the target (live gate: a seek after a
      // failed load never loads on macOS).
      expect(
          (fakePlayer.seedCalls.last.currentItemId,
              fakePlayer.seedCalls.last.cause),
          ((await sessionTracksOf(c)).firstWhere((e) =>
                  e.uuidId == c.read(currentTrackProvider)?.uuidId).itemId,
              PlaybackTransitionCause.naturalAdvance));
    });

    test('offline, a platform failure of every download marks none and stops '
        'after one pass (major 1 cascade)', () async {
      const uuids = ['a', 'b', 'c', 'd'];
      await fixture.insertSingles(uuids);
      for (final u in uuids) {
        await markDownloaded(u, '/dl/$u');
        existingFiles.add('/dl/$u');
      }
      final c = await playingList(uuids, offline: true);
      for (var i = 0; i < uuids.length + 2; i++) {
        await fail();
      }
      for (final u in uuids) {
        expect(await damagedPathOf(u), isNull, reason: u);
      }
      expect(issues.whereType<PlaybackSourceFailed>(), hasLength(uuids.length),
          reason: 'the loop guard stops the run after one pass');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isFalse);
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

    // Decision 1 (user, 2026-11-07; 5B.0d M2): offline, a failed stream is
    // treated like an unavailable item and playback moves on to the next
    // downloaded one. Online behaviour is unchanged.
    Future<(ProviderContainer, TestOffline)> streamingOnline() async {
      await fixture.insertSingles(['a', 'b', 'c']);
      await markDownloaded('c', '/dl/c');
      existingFiles.add('/dl/c');
      final offline = TestOffline(false);
      final c = createContainer(offlineNotifier: () => offline);
      issues = [];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      return (c, offline);
    }

    test('offline, a failed stream skips to the next downloaded item',
        () async {
      final (c, offline) = await streamingOnline();
      offline.set(true); // the network dropped
      await pumpEventQueue();
      await fail(); // then the stream errors
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind),
          [SourceFailureKind.transient]);
      expect(c.read(currentTrackProvider)?.uuidId, 'c',
          reason: 'b is not downloaded; c is');
      // A recovery skip re-seeds at the target (live gate: a seek after a
      // failed load never loads on macOS).
      expect(
          (fakePlayer.seedCalls.last.currentItemId,
              fakePlayer.seedCalls.last.cause),
          ((await sessionTracksOf(c)).firstWhere((e) =>
                  e.uuidId == c.read(currentTrackProvider)?.uuidId).itemId,
              PlaybackTransitionCause.naturalAdvance));
    });

    test('a stream failing as the network drops is rescued once offline is '
        'known', () async {
      final (c, offline) = await streamingOnline();
      final gate = probeGate = Completer<void>();
      final failing = fail(); // the track check is waiting for an answer
      await pumpEventQueue();
      offline.set(true); // the check's own network failure enters offline
      gate.complete(); // no answer
      await failing;
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
    });

    test('a transient stream failure online is rescued when the app goes '
        'offline later', () async {
      final (c, offline) = await streamingOnline();
      await fail(); // no answer, still online: no skip
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      offline.set(true);
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
    });

    test('going offline rescues nothing once the user moved on', () async {
      final (c, offline) = await streamingOnline();
      await fail();
      final notifier = c.read(queuePlayerProvider.notifier);
      await notifier.skipToTrack((await sessionTracksOf(c))[1].itemId);
      await pumpEventQueue();
      offline.set(true);
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'b',
          reason: "b's stream did not fail; it is not skipped");
    });

    test('going offline rescues nothing once the failed stream played',
        () async {
      final (c, offline) = await streamingOnline();
      await fail();
      fakePlayer.emitObservation(playing: true); // the stream recovered
      await pumpEventQueue();
      offline.set(true);
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
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

    // Review r2 OPEN-r1be-01: a stream the server refuses with 503 (a
    // permission or I/O error on the master, a pruned transcode) fails in the
    // player with no HTTP status; the track check answers 200, so the track
    // is kept: no skip, no stop, no source rebuilt, no second check.
    test('a refused stream of a track the server still has (track check 200) '
        'is kept: no skip, no stop', () async {
      await fixture.insertSingles(['a', 'b']);
      trackStatuses['a'] = 200;
      final c = await playingList(const ['a', 'b']);
      final seeks = fakePlayer.seekedItems.length;
      final seeds = fakePlayer.seedCalls.length;
      await fail();
      await fail(); // the same source reported again
      expect(issues.whereType<PlaybackSourceFailed>().map((i) => i.kind),
          [SourceFailureKind.unknown]);
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      expect(fakePlayer.seekedItems, hasLength(seeks));
      expect(fakePlayer.seedCalls, hasLength(seeds));
      expect(fakePlayer.refreshedSources, isEmpty);
      expect(fakePlayer.stopCalls, 0);
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
      expect(fakePlayer.stopCalls, 1);
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isFalse);
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
      expect(fakePlayer.stopCalls, 1, reason: 'the failure run stopped');
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

  // Was "5B.0d audit (a) round 2".
  group(
      'failure recovery: a rebased target and a remembered stream fallback',
      () {
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

  // Was "5B.0d audit (a) round 3".
  group(
      'a confirmed missing file: catalog clean-up and the stream fallback',
      () {
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

  // Was "5B.0d audit (a) round 4 minors".
  group('recovery after a failed reconcile or a stale unavailable advance', () {
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

  // Was "5B.0d audit (b) minors".
  group('the OS duration and the quiesced state', () {
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

    test('U17-FE-PB-CORE-A-04: an empty request does not cancel a valid one '
        'still in flight', () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer();
      final requests = requestsOf(c);
      final first =
          requests.submit(const PlayList(['a', 'b'], 0, ListSource('search')));
      final emptyList =
          requests.submit(const PlayList([], 0, ListSource('search')));
      final emptyCollection = requests.submit(const PlayCollection(
          AlbumScope(artistId: 1, albumId: 1), [],
          shuffle: ShuffleStart.canonical));
      expect(await emptyList, isA<RejectedEmpty>());
      expect(await emptyCollection, isA<RejectedEmpty>());
      expect(await first, isA<Accepted>(),
          reason: 'nothing was admitted by the empty requests');
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
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

  // Was "live gate: missing downloads confirmed by the resolver (D32)".
  group('missing downloads confirmed by the resolver', () {
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

  // Was "branch audit (5B.0b F4): the scope, not the player, owns the engine and window".
  group('the scope, not the player, owns the engine and window', () {
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

  // Was "branch audit (5B.0d m1): the OS playback state is not republished on every position tick".
  group('the OS playback state is not republished on every position tick', () {
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

  // Was "branch audit (5B.0d m4): removeFromQueue is commit-last".
  group('removeFromQueue is commit-last', () {
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

  // Was "branch audit (5B.0a): characterization gaps".
  group('quality changes and a sync that empties the queue', () {
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

    test('a "this session only" quality change rebuilds only the current '
        'source, at the position then', () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer(
          controllableQuality: true,
          qualityChangeKind: QualityChangeKind.temporary);
      c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      fakePlayer.emitPosition(const Duration(seconds: 30));
      await pumpEventQueue();
      final current = c.read(queuePlayerProvider).queue.currentItemId;
      c.read(_testQuality.notifier).set('low');
      await pumpEventQueue();
      expect(fakePlayer.rebuilds,
          [('current', 'low', const Duration(seconds: 30), current)]);
      expect(fakePlayer.lastStreamQuality, 'low');
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

  // Was "branch audit (5B.0a M2): a sync reaches the player".
  group('a sync reaches the player', () {
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

  // Was "PR 5B audit (c)".
  group(
      'stale and superseded activations; an engine restored after a failed seed',
      () {
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
      final result = await notifier.activatePreparedSession(
          s2, PlaybackTarget(entry, PlaybackSourceKind.remote),
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
      final result = await notifier.activatePreparedSession(
          s2, PlaybackTarget(entry, PlaybackSourceKind.remote),
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
        fakePlayer.seedFailuresAfterReplacing = 1;
        await c.read(playbackRequestsProvider)
            .submit(const PlayList(['c'], 0, ListSource('s')));
        final seed = fakePlayer.seedCalls.last;
        expect(seed.initialPosition, const Duration(seconds: 42));
        expect(seed.autoPlay, playing);
        expect(c.read(queuePlayerProvider).playback.playWhenReady, playing);
      });
    }
  });

  // Was "PR 5B audit (a)".
  group('failed activations and the order of Enqueues and taps', () {
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
      fakePlayer.seedFailuresAfterReplacing = 1;
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
      fakePlayer.seedFailuresAfterReplacing = 1;
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

  // Was "5B.1 audit (a)".
  group(
      'no-session Enqueues, the startup prune, a failed first start and a superseded request',
      () {
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

  // Was "5B.0d audit (c) test gaps".
  group(
      'stale chunks, an all-gone queue, queue warm, the OS now-playing and the cursor throttle',
      () {
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
      expect(fakePlayer.stopCalls, 1);
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isFalse);
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

  // Was "5B.0d audit (a) minors".
  group(
      'native looping, late load failures, failure runs, the OS now-playing, startup restore and quality rebuilds',
      () {
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
      expect(fakePlayer.stopCalls, 1, reason: 'the failure run stopped');
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
    // Sign-off DEV-6-01 (owner, 2026-11-17): back to the Phase 5 rule (6A.1b
    // had changed it to "keeps the played prefix"). The two shuffled plays
    // stay, so the whole order is proven restored, behind and ahead.
    'toggleShuffle off restores canonical order without reseeding',
    () async {
      await fixture.insertAlbum(
        artist: 'Artist',
        album: 'Album',
        uuids: ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
      );
      final startTrack = await fixture.track('d');

      final c = createContainer(random: Random(1));
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
      // Two shuffled plays after d: the prefix is no longer canonical.
      await notifier.skipNext();
      await pumpEventQueue();
      await notifier.skipNext();
      await pumpEventQueue();
      final shuffled = (await sessionTracksOf(c)).map((entry) => entry.uuidId).toList(growable: false);
      final played = shuffled.take(6).toList(growable: false);
      expect(played.take(4), ['a', 'b', 'c', 'd']);
      expect(played.skip(4), isNot(['e', 'f']),
          reason: 'seeded so the shuffled plays are not the canonical ones');
      final playedItemId = c.read(queuePlayerProvider).queue.currentItemId;
      await notifier.toggleShuffle();
      await Future<void>.delayed(Duration.zero);

      final restoredOrder = (await sessionTracksOf(c)).map((entry) => entry.uuidId).toList(growable: false);

      expect(fakePlayer.seedCalls, hasLength(1));
      expect(fakePlayer.rebuildCalls, hasLength(2));
      expect(currentItemId, isNotNull);
      expect(c.read(queuePlayerProvider).queue.currentItemId, playedItemId);
      expect(restoredOrder, canonicalOrder);
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition,
          canonicalOrder.indexOf(played.last),
          reason: 'the current track sits at its album position');
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
    // Sign-off DEV-6-01 (owner, 2026-11-17): back to the Phase 5 rule (6A.1b
    // had changed it to "keeps the current main track where it was played",
    // a, c, b, d, e at 1).
    'toggleShuffle off restores the current main track to its canonical '
    'position',
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
      // 6-R1-10: resume_main_item_id is no longer written (nothing reads it).
      expect(snapshotBeforeShuffle?.session.resumeMainItemId, isNull);

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
    final offline = TestOffline(false);
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
          coverArtCacheProvider.overrideWithValue(coverArt),
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
        final plays = fakePlayer.playCalls;
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
        expect(fakePlayer.playCalls, plays + 1,
            reason: 'it was playing: the next downloaded track plays');
        expect(c.read(audioPlayWhenReadyProvider), isTrue);
      },
    );

    // Pre-merge A6-01: the rule of sign-off DEV-8-09 (paused lands paused)
    // also holds when the current track's download goes away offline.
    test(
      'paused: when the current download is deleted offline, the next '
      'downloaded track becomes current and stays paused',
      () async {
        await fixture.insertSingles(['a', 'b', 'c']);
        await markDownloaded('a', '/dl/a');
        await markDownloaded('c', '/dl/c');

        final c = createContainer(offline: true);
        final notifier = c.read(queuePlayerProvider.notifier);
        await playFromTrackList(c, const ['a', 'b', 'c'],
            await fixture.track('a'), sourceType: 'search');
        await pumpEventQueue();
        await notifier.pause();
        await pumpEventQueue();
        expect(c.read(audioPlayWhenReadyProvider), isFalse);

        downloadStatusController.add(0);
        await pumpEventQueue();
        fakePlayer.offlineForRefresh = true;
        final plays = fakePlayer.playCalls;
        await markDeleted('a', '/dl/a');
        downloadStatusController.add(1);
        await pumpEventQueue();

        expect(fakePlayer.rescuedItemIds, hasLength(1),
            reason: 'the engine handed the missing current file to the core');
        expect(c.read(currentTrackProvider)?.uuidId, 'c');
        expect(fakePlayer.playCalls, plays,
            reason: 'a paused player never starts by itself');
        expect(fakePlayer.wantsPlaying, isFalse);
        expect(c.read(audioPlayWhenReadyProvider), isFalse);
      },
    );

    // Pre-merge A6-01, review R1: only the rescue of the current item keeps
    // a pause. A natural advance onto a track that is not downloaded plays
    // on, even when the engine reports "not playing" for that track (its
    // stream cannot load) before the core has moved past it.
    test(
      'playing: a natural advance onto a track that is not downloaded plays '
      'the next downloaded one, whatever the engine reports meanwhile',
      () async {
        await fixture.insertSingles(['a', 'b', 'c']);
        await markDownloaded('a', '/dl/a');
        await markDownloaded('c', '/dl/c');

        final c = createContainer(offline: true);
        await playFromTrackList(c, const ['a', 'b', 'c'],
            await fixture.track('a'), sourceType: 'search');
        await pumpEventQueue();
        final b = (await repo.getPlaybackEntries(
                c.read(queuePlayerProvider).queue.sessionId!))
            .firstWhere((e) => e.uuidId == 'b');
        final plays = fakePlayer.playCalls;

        fakePlayer.emitUnavailableAdvance(
            UnavailableAdvance(itemId: b.itemId, playPosition: b.playPosition));
        fakePlayer.emitPlayerState(
            const EngineTransportState(false, EngineProcessingState.completed));
        await pumpEventQueue();

        expect(c.read(currentTrackProvider)?.uuidId, 'c');
        expect(fakePlayer.playCalls, plays + 1,
            reason: 'the person was listening: playback goes on');
        expect(fakePlayer.wantsPlaying, isTrue);
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

  // 8-fix-r1 U20-B-01 (deliberately changed, was: lands on the first entry
  // 'a' at play position 0): playback goes on with the next survivor.
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
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
      expect(c.read(audioPositionProvider), Duration.zero);
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 1);
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

  // 8B.2b / 8-C01 (unit half), spec §6: "Existing tombstone path removes
  // local metadata, queue entries and managed downloads, and `QueuePlayer`
  // reconciles the current track (SC-27)." No playback-core change: the
  // tombstone's queue edit and the sync state reach the player as in the
  // app (`SyncService._deleteTracks` → `TrackSyncState` → reconcile).
  /// What `SyncService._deleteTracks` does to the database for a tombstone,
  /// in its order (the sync state it publishes is up to the caller).
  Future<QueueTrackRemovalResult> deleteTracksAsSync(
      List<String> uuids) async {
    final removal = await repo.removeTrackUuidsFromQueues(uuids);
    for (final u in uuids) {
      await db.customStatement(
          'DELETE FROM trackmetadata WHERE uuid_id = ?', [u]);
      await db.customStatement('DELETE FROM tracks WHERE uuid_id = ?', [u]);
    }
    return removal;
  }

  group('8B.2b: a sync tombstone of queued tracks', () {
    Future<void> tombstone(List<String> uuids) => deleteTracksAsSync(uuids);

    test('the playing downloaded track and a future entry: both leave the '
        'queue, the player lands on a survivor, and no seed names the '
        'deleted file', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);
      await markDownloaded('b', '/dl/b');
      final sync = _ScriptedSync();
      final c = createContainer(sync: sync);
      await playFromTrackList(c, const ['a', 'b', 'c', 'd'],
          await fixture.track('b'), sourceType: 'test');
      await pumpEventQueue();
      final id = c.read(queuePlayerProvider).queue.sessionId!;
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
      final seeds = fakePlayer.seedCalls.length;

      await tombstone(['b', 'd']);
      sync.push(TrackSyncState(
        queueMutationVersion: 1,
        affectedQueueSessionIds: {id},
        downloadMutationVersion: 1,
        deletedTrackUuids: const {'b', 'd'},
      ));
      await pumpEventQueue();

      expect((await sessionTracksOf(c)).map((e) => e.uuidId), ['a', 'c'],
          reason: 'the surviving queue, in order');
      final state = c.read(queuePlayerProvider);
      expect(state.queue.sessionId, id);
      expect(state.queue.totalCount, 2);
      // 8-fix-r1 U20-B-01 (deliberately strengthened, was isIn(['a', 'c'])):
      // the next survivor after b, not the first entry.
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
      expect((await repo.getActiveSession())?.currentItemId,
          state.queue.currentItemId,
          reason: 'state and the persisted cursor agree');
      expect(state.playback.playWhenReady, isTrue, reason: 'playback goes on');
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      final seed = fakePlayer.seedCalls.last;
      expect(seed.cause, PlaybackTransitionCause.queueReplacement,
          reason: 'a genuine boundary: the deleted listen closes once');
      expect(seed.entries.map((e) => e.uuidId), isNot(contains('b')));
      expect(seed.entries.map((e) => e.uuidId), isNot(contains('d')));
      expect(seed.entries.map((e) => e.filePath), isNot(contains('/dl/b')));
    });

    test('a future entry only: the current item continues where it was',
        () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      await markDownloaded('a', '/dl/a');
      final sync = _ScriptedSync();
      final c = createContainer(sync: sync);
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('a'), sourceType: 'test');
      await c.read(queuePlayerProvider.notifier)
          .seek(const Duration(seconds: 40));
      final id = c.read(queuePlayerProvider).queue.sessionId!;
      final item = c.read(queuePlayerProvider).queue.currentItemId;

      await tombstone(['c']);
      sync.push(TrackSyncState(
          queueMutationVersion: 1, affectedQueueSessionIds: {id}));
      await pumpEventQueue();

      expect((await sessionTracksOf(c)).map((e) => e.uuidId), ['a', 'b']);
      expect(c.read(queuePlayerProvider).queue.currentItemId, item);
      expect(c.read(audioPositionProvider), const Duration(seconds: 40));
      expect(fakePlayer.seedCalls.last.cause,
          PlaybackTransitionCause.reconcileContinuation);
      expect(fakePlayer.seedCalls.last.entries.map((e) => e.uuidId),
          isNot(contains('c')));
    });
  });

  // 8-fix-r1 U20-B-01 (coordinator decision, logged major deviation): when a
  // sync removes the playing track, playback lands on the next survivor in
  // play order; only repeat-all wraps; at the end otherwise it stops there
  // (no restart from the first track, no autoplay).
  // Was "U20-B-01: where playback lands after a sync removes the playing track".
  group('where playback lands after a sync removes the playing track', () {
    var version = 0;
    setUp(() => version = 0);

    /// The tombstone as `SyncService._deleteTracks` applies it, and the sync
    /// state it publishes.
    Future<void> tombstone(_ScriptedSync sync, List<String> uuids) async {
      final removal = await deleteTracksAsSync(uuids);
      version++;
      sync.push(TrackSyncState(
        queueMutationVersion: version,
        affectedQueueSessionIds: removal.affectedSessionIds,
        endedQueueSessionIds: removal.endedSessionIds,
      ));
      await pumpEventQueue();
    }

    Future<ProviderContainer> playing(
        _ScriptedSync sync, List<String> uuids, String current) async {
      await fixture.insertSingles(uuids);
      final c = createContainer(sync: sync);
      await playFromTrackList(c, uuids, await fixture.track(current),
          sourceType: 'test');
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, current);
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
      return c;
    }

    Future<void> setRepeat(ProviderContainer c, QueueRepeatMode mode) async {
      final notifier = c.read(queuePlayerProvider.notifier);
      while (c.read(queuePlayerProvider).queue.repeatMode != mode) {
        await notifier.cycleQueueRepeatMode();
      }
    }

    test('the last track with repeat off: stops on the end of the queue, '
        'paused, not on the first track', () async {
      final sync = _ScriptedSync();
      final c = await playing(sync, const ['a', 'b', 'c'], 'c');
      final id = c.read(queuePlayerProvider).queue.sessionId!;
      final seeds = fakePlayer.seedCalls.length;

      await tombstone(sync, const ['c']);

      final state = c.read(queuePlayerProvider);
      expect(state.queue.sessionId, id, reason: 'the queue is kept');
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(state.playback.playWhenReady, isFalse, reason: 'no autoplay');
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.seedCalls.last.autoPlay, isFalse);
      expect(fakePlayer.seedCalls.last.cause,
          PlaybackTransitionCause.queueReplacement);
      expect((await repo.getActiveSession())?.currentItemId,
          state.queue.currentItemId);
    });

    // Sign-off OPEN-8-11 (owner, 2026-11-17: "Follow the recommendation"):
    // an end landing rests paused even when an OS interruption had paused
    // playback first; a landing that plays on keeps resuming as before.
    Future<void> interruption(AudioSessionEvent event) async {
      sessionPort.emit(event);
      await pumpEventQueue();
    }

    test('OPEN-8-11: interrupted, then the playing last track is deleted: '
        'the end of the interruption does not start the new last track',
        () async {
      final sync = _ScriptedSync();
      final c = await playing(sync, const ['a', 'b', 'c'], 'c');
      await interruption(
          const AudioInterruptionBegan(AudioInterruptionKind.pause));
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isFalse);

      await tombstone(sync, const ['c']);
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      final plays = fakePlayer.playCalls;

      await interruption(
          const AudioInterruptionEnded(AudioInterruptionKind.pause));
      expect(fakePlayer.playCalls, plays, reason: 'rests paused (DEV-8-09)');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isFalse);
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
    });

    test('OPEN-8-11 (unchanged): interrupted, then the playing middle track '
        'is deleted: the next track plays when the interruption ends',
        () async {
      final sync = _ScriptedSync();
      final c = await playing(sync, const ['a', 'b', 'c'], 'b');
      await interruption(
          const AudioInterruptionBegan(AudioInterruptionKind.pause));
      await tombstone(sync, const ['b']);
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isFalse,
          reason: 'still interrupted');
      final plays = fakePlayer.playCalls;

      await interruption(
          const AudioInterruptionEnded(AudioInterruptionKind.pause));
      expect(fakePlayer.playCalls, plays + 1);
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
    });

    test('OPEN-8-11 (unchanged): interrupted, then a track that is not '
        'playing is deleted: the interruption end resumes the same track',
        () async {
      final sync = _ScriptedSync();
      final c = await playing(sync, const ['a', 'b', 'c'], 'c');
      await interruption(
          const AudioInterruptionBegan(AudioInterruptionKind.pause));
      await tombstone(sync, const ['a']);
      final plays = fakePlayer.playCalls;

      await interruption(
          const AudioInterruptionEnded(AudioInterruptionKind.pause));
      expect(fakePlayer.playCalls, plays + 1);
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
    });

    test('F903-B-03: the playing last track is deleted and the landing\'s '
        'queue read fails: nothing changes, the engine is not paused',
        () async {
      final sync = _ScriptedSync();
      final c = await playing(sync, const ['a', 'b', 'c'], 'c');
      final before = c.read(queuePlayerProvider);
      final pauses = fakePlayer.pauseCalls;
      final seeds = fakePlayer.seedCalls.length;

      repo.getTrackForItemError = StateError('db busy'); // the seed's read
      await tombstone(sync, const ['c']);
      repo.getTrackForItemError = null;

      expect(fakePlayer.pauseCalls, pauses,
          reason: 'commit last: a failed read leaves the engine as it was');
      expect(fakePlayer.seedCalls, hasLength(seeds));
      final state = c.read(queuePlayerProvider);
      expect(state.playback.playWhenReady, isTrue);
      expect(state.queue.currentItemId, before.queue.currentItemId);
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
    });

    test('the last track under repeat-all: wraps to the first and plays on',
        () async {
      final sync = _ScriptedSync();
      final c = await playing(sync, const ['a', 'b', 'c'], 'c');
      await setRepeat(c, QueueRepeatMode.all);

      await tombstone(sync, const ['c']);

      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
      expect(fakePlayer.seedCalls.last.autoPlay, isTrue);
    });

    test('repeat-one: the next track plays in the middle; at the end it '
        'stops', () async {
      final sync = _ScriptedSync();
      final c = await playing(sync, const ['a', 'b', 'c'], 'b');
      await setRepeat(c, QueueRepeatMode.one);

      await tombstone(sync, const ['b']);
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);

      await tombstone(sync, const ['c']);
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isFalse);
      expect(fakePlayer.seedCalls.last.autoPlay, isFalse);
    });

    test('shuffled: the next track of the shuffled order', () async {
      final sync = _ScriptedSync();
      final c = await playing(sync, const ['a', 'b', 'c', 'd', 'e'], 'a');
      final notifier = c.read(queuePlayerProvider.notifier);
      await notifier.toggleShuffle();
      await notifier.skipNext();
      await pumpEventQueue();
      final order = (await sessionTracksOf(c)).map((e) => e.uuidId).toList();
      expect(c.read(currentTrackProvider)?.uuidId, order[1]);

      await tombstone(sync, [order[1]]);

      expect(c.read(currentTrackProvider)?.uuidId, order[2],
          reason: 'the next of the shuffled order, not its first entry');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
    });

    test('a removed track that is not playing changes nothing about what '
        'plays', () async {
      final sync = _ScriptedSync();
      final c = await playing(sync, const ['a', 'b', 'c'], 'b');
      await c.read(queuePlayerProvider.notifier)
          .seek(const Duration(seconds: 30));
      final item = c.read(queuePlayerProvider).queue.currentItemId;

      await tombstone(sync, const ['a']);

      expect(c.read(queuePlayerProvider).queue.currentItemId, item);
      expect(c.read(audioPositionProvider), const Duration(seconds: 30));
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
      expect(fakePlayer.seedCalls.last.cause,
          PlaybackTransitionCause.reconcileContinuation);
    });

    // Review r1-fe-a #1: the sync publishes only at the end of its run;
    // a cursor save of the removed item in between (here a pause) must not
    // send playback back to the first track.
    test('a cursor save between the removal and the reconcile keeps the '
        'landing', () async {
      final sync = _ScriptedSync();
      final c = await playing(sync, const ['a', 'b', 'c'], 'b');
      final id = c.read(queuePlayerProvider).queue.sessionId!;

      final removal = await repo.removeTrackUuidsFromQueues(const ['b']);
      await c.read(queuePlayerProvider.notifier).pause();
      sync.push(TrackSyncState(
        queueMutationVersion: 1,
        affectedQueueSessionIds: removal.affectedSessionIds,
        endedQueueSessionIds: removal.endedSessionIds,
      ));
      await pumpEventQueue();

      expect(c.read(queuePlayerProvider).queue.sessionId, id);
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
    });

    test('an ended report never pauses an item that is still current (the '
        'reconcile ran after the cursor moved on)', () async {
      final sync = _ScriptedSync();
      final c = await playing(sync, const ['a', 'b', 'c'], 'b');
      final id = c.read(queuePlayerProvider).queue.sessionId!;
      final item = c.read(queuePlayerProvider).queue.currentItemId;
      await repo.removeTrackUuidsFromQueues(const ['c']);

      sync.push(TrackSyncState(
        queueMutationVersion: 1,
        affectedQueueSessionIds: {id},
        endedQueueSessionIds: {id},
      ));
      await pumpEventQueue();

      expect(c.read(queuePlayerProvider).queue.currentItemId, item);
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
    });

    // 8-fix-r3 8-L-02 (live gate B1, PD.c): the real engine keeps a play it
    // already issued across a seed without autoplay, so the end landing
    // played on once the engine reported its load. These tests let the fake
    // engine report its desired transport after the reconcile's seed, as the
    // adapter does, and judge what the engine was left wanting.
    group('with the engine reporting its transport (8-L-02)', () {
      Future<void> enginePlaying() async {
        fakePlayer.emitPlayerState(const EngineTransportState(
            true, EngineProcessingState.ready));
        await pumpEventQueue();
      }

      Future<void> engineSettles() async {
        fakePlayer.emitSettledTransport();
        await pumpEventQueue();
      }

      test('(c) the last track, playing, repeat off: the engine is stopped on '
          'the last survivor, not left playing it', () async {
        final sync = _ScriptedSync();
        final c = await playing(sync, const ['a', 'b', 'c', 'd', 'e'], 'e');
        await enginePlaying();
        expect(fakePlayer.wantsPlaying, isTrue);

        await tombstone(sync, const ['e']);
        await engineSettles();

        final state = c.read(queuePlayerProvider);
        expect(c.read(currentTrackProvider)?.uuidId, 'd');
        expect(fakePlayer.wantsPlaying, isFalse,
            reason: 'no autoplay: the engine must not keep playing');
        expect(state.playback.playWhenReady, isFalse);
        expect(state.playback.status, isNot(PlayerStatus.playing));
        expect(c.read(audioPositionProvider), Duration.zero);
      });

      test('(a) the playing track mid-queue: the next track plays on',
          () async {
        final sync = _ScriptedSync();
        final c = await playing(sync, const ['a', 'b', 'c', 'd'], 'b');
        await enginePlaying();

        await tombstone(sync, const ['b']);
        await engineSettles();

        expect(c.read(currentTrackProvider)?.uuidId, 'c');
        expect(fakePlayer.wantsPlaying, isTrue);
        expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
      });

      test('(b) paused after a seek: lands on the next track, paused, at the '
          'start', () async {
        final sync = _ScriptedSync();
        final c = await playing(sync, const ['a', 'b', 'c', 'd'], 'b');
        await enginePlaying();
        final notifier = c.read(queuePlayerProvider.notifier);
        await notifier.pause();
        await notifier.seek(const Duration(seconds: 3));
        fakePlayer.emitPlayerState(const EngineTransportState(
            false, EngineProcessingState.ready));
        await pumpEventQueue();

        await tombstone(sync, const ['b']);
        await engineSettles();

        expect(c.read(currentTrackProvider)?.uuidId, 'c');
        expect(fakePlayer.wantsPlaying, isFalse);
        expect(c.read(queuePlayerProvider).playback.playWhenReady, isFalse);
        expect(c.read(audioPositionProvider), Duration.zero);
      });
    });
  });

  group('6A.1b (SC-27, D3): the queue order uses the injected generator', () {
    test('toggling shuffle on draws from the overridden generator', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'f']);
      final random = _RecordingRandom(Random(3));
      final c = createContainer(random: random);
      await c.read(playbackRequestsProvider).submit(const PlayList(
          ['a', 'b', 'c', 'd', 'e', 'f'], 0, ListSource('search')));
      expect(random.draws, 0, reason: 'nothing shuffled yet');

      await c.read(queuePlayerProvider.notifier).toggleShuffle();

      expect(random.draws, greaterThan(0));
      final order = (await sessionTracksOf(c)).map((e) => e.uuidId).toList();
      expect(order.first, 'a');
      expect(order.toSet(), {'a', 'b', 'c', 'd', 'e', 'f'});
      expect(order, hasLength(6));
    });

    test('the same seed gives the same shuffled order', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']);
      Future<List<String>> shuffledWith(int seed) async {
        final c = createContainer(random: Random(seed));
        await c.read(playbackRequestsProvider).submit(const PlayList(
            ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'], 0, ListSource('search')));
        await c.read(queuePlayerProvider.notifier).toggleShuffle();
        final order =
            (await sessionTracksOf(c)).map((e) => e.uuidId).toList();
        c.dispose();
        container = null;
        return order;
      }

      final first = await shuffledWith(11);
      final second = await shuffledWith(11);
      expect(second, first);
      // Fixed expectation for seed 11 is not pinned: the generator, not the
      // test, decides the order; equality across runs proves injection.
    });
  });

  group('6A.1b (SC-05, spec §5 Play): PlayCollection', () {
    const albumIntent = HistoryIntent('album', 'inst-1:1');
    const albumScope = AlbumScope(artistId: 1, albumId: 1);

    Future<List<HistoryEvent>> clicks() => (db.select(db.historyEvents)
          ..where((e) => e.kind.equals('clicked'))
          ..orderBy([(e) => OrderingTerm(expression: e.localId)]))
        .get();

    /// A playing list queue with sticky shuffle on and repeat all.
    Future<ProviderContainer> playingShuffledRepeatAll(
        {bool offline = false}) async {
      final c = createContainer(offline: offline);
      await c.read(playbackRequestsProvider)
          .submit(const PlayList(['x', 'y'], 0, ListSource('search')));
      final notifier = c.read(queuePlayerProvider.notifier);
      await notifier.toggleShuffle();
      await notifier.cycleQueueRepeatMode(); // off -> all
      expect(c.read(shuffleProvider), isTrue);
      expect(c.read(repeatModeProvider), QueueRepeatMode.all);
      return c;
    }

    test('Play is canonical whatever the sticky shuffle, keeps repeat, '
        'names the album and records one album click', () async {
      await fixture.insertSingles(['x', 'y']);
      await fixture.insertAlbum(
          artist: 'Artist', album: 'Album', uuids: ['a', 'b', 'c', 'd', 'e']);
      final c = await playingShuffledRepeatAll();
      final albumScope = AlbumScope(
          artistId: (await fixture.track('a')).artistId!,
          albumId: (await fixture.track('a')).albumId!);

      final outcome = await c.read(playbackRequestsProvider).submit(
          PlayCollection(albumScope, const ['a', 'b', 'c', 'd', 'e'],
              shuffle: ShuffleStart.canonical, intent: albumIntent));

      expect(outcome, isA<Accepted>());
      final sessionId = (outcome as Accepted).sessionId;
      expect(c.read(queuePlayerProvider).queue.sessionId, sessionId);
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      expect(c.read(shuffleProvider), isFalse);
      expect(c.read(repeatModeProvider), QueueRepeatMode.all);
      final session = (await repo.getSessionSnapshot(sessionId))!.session;
      expect(session.shuffleEnabled, isFalse);
      expect(session.repeatMode, 'all');
      expect(session.sourceType, 'album');
      expect(session.sourceArtistId, albumScope.artistId);
      expect(session.sourceAlbumId, albumScope.albumId);
      expect((await repo.getSessionTracksInPlayOrder(sessionId))
          .map((e) => e.uuidId), ['a', 'b', 'c', 'd', 'e']);
      expect(fakePlayer.seedCalls.last.autoPlay, isTrue);
      await pumpEventQueue();
      final rows = await clicks();
      expect(rows, hasLength(1));
      expect((rows.single.entityType, rows.single.entityRef),
          ('album', 'inst-1:1'));
    });

    test('an artist collection names the artist only', () async {
      await fixture.insertAlbum(
          artist: 'Artist', album: 'Album', uuids: ['a', 'b']);
      final artistId = (await fixture.track('a')).artistId!;
      final c = createContainer();
      final outcome = await c.read(playbackRequestsProvider).submit(
          PlayCollection(ArtistScope(artistId: artistId), const ['b', 'a'],
              shuffle: ShuffleStart.canonical));
      final session = (await repo
              .getSessionSnapshot((outcome as Accepted).sessionId))!
          .session;
      expect(session.sourceType, 'artist');
      expect(session.sourceArtistId, artistId);
      expect(session.sourceAlbumId, isNull);
      expect(c.read(currentTrackProvider)?.uuidId, 'b',
          reason: 'the given (canonical) order is the queue order');
      await pumpEventQueue();
      expect(await clicks(), isEmpty, reason: 'no intent, no click');
    });

    test('an empty collection is rejected: queue untouched, no click',
        () async {
      await fixture.insertSingles(['x', 'y']);
      final c = await playingShuffledRepeatAll();
      final before = c.read(queuePlayerProvider);
      final seeds = fakePlayer.seedCalls.length;
      final outcome = await c.read(playbackRequestsProvider).submit(
          const PlayCollection(albumScope, [],
              shuffle: ShuffleStart.random, intent: albumIntent));
      expect(outcome, isA<RejectedEmpty>());
      expect(c.read(queuePlayerProvider).queue.sessionId,
          before.queue.sessionId);
      expect(c.read(shuffleProvider), isTrue, reason: 'state untouched');
      expect(fakePlayer.seedCalls, hasLength(seeds));
      await pumpEventQueue();
      expect(await clicks(), isEmpty);
    });

    test('a scope that is not an album or artist fails without a click',
        () async {
      await fixture.insertSingles(['a']);
      final c = createContainer();
      final outcome = await c.read(playbackRequestsProvider).submit(
          const PlayCollection(TracksScope([]), ['a'],
              shuffle: ShuffleStart.canonical, intent: albumIntent));
      expect(outcome, isA<Failed>());
      expect(fakePlayer.seedCalls, isEmpty);
      await pumpEventQueue();
      expect(await clicks(), isEmpty);
    });

    test('offline with nothing playable: rejected, queue untouched, no click',
        () async {
      await fixture.insertSingles(['x', 'y']);
      await fixture.insertAlbum(
          artist: 'Artist', album: 'Album', uuids: ['a', 'b']);
      await markDownloaded('x', '/dl/x');
      await markDownloaded('y', '/dl/y');
      final c = await playingShuffledRepeatAll(offline: true);
      final before = c.read(queuePlayerProvider);
      final activeBefore = (await repo.getActiveSession())?.id;
      final seeds = fakePlayer.seedCalls.length;
      final outcome = await c.read(playbackRequestsProvider).submit(
          const PlayCollection(albumScope, ['a', 'b'],
              shuffle: ShuffleStart.canonical, intent: albumIntent));
      expect(outcome, isA<RejectedUnplayableOffline>());
      expect((await repo.getActiveSession())?.id, activeBefore);
      expect(c.read(queuePlayerProvider).queue.sessionId,
          before.queue.sessionId);
      expect(c.read(currentTrackProvider)?.uuidId,
          before.playback.currentTrack?.uuidId);
      expect(c.read(shuffleProvider), isTrue);
      expect(fakePlayer.seedCalls, hasLength(seeds));
      expect(await repo.pruneInactiveSessions(), 0,
          reason: 'the prepared session was discarded');
      await pumpEventQueue();
      expect(await clicks(), isEmpty);
    });

    test('a superseded collection request never reaches the queue or the '
        'engine and records nothing', () async {
      await fixture.insertSingles(['x', 'y']);
      await fixture.insertAlbum(
          artist: 'Artist', album: 'Album', uuids: ['a', 'b']);
      final c = createContainer();
      final requests = c.read(playbackRequestsProvider);
      final collection = requests.submit(const PlayCollection(
          albumScope, ['a', 'b'],
          shuffle: ShuffleStart.random, intent: albumIntent));
      final list =
          requests.submit(const PlayList(['x', 'y'], 0, ListSource('search')));
      expect(await collection, isA<Superseded>());
      expect(await list, isA<Accepted>());
      expect(fakePlayer.seedCalls, hasLength(1));
      expect(c.read(currentTrackProvider)?.uuidId, 'x');
      expect(await repo.pruneInactiveSessions(), 0);
      await pumpEventQueue();
      expect(await clicks(), isEmpty);
    });

    test('a collection with a missing download publishes LocalFileMissing '
        'and falls back', () async {
      await fixture.insertAlbum(
          artist: 'Artist', album: 'Album', uuids: ['a', 'b', 'c']);
      await markDownloaded('a', '/dl/a');
      existingFiles.remove('/dl/a'); // recorded, but gone from disk
      await markDownloaded('b', '/dl/b');
      final c = createContainer(offline: true);
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      final outcome = await c.read(playbackRequestsProvider).submit(
          const PlayCollection(albumScope, ['a', 'b'],
              shuffle: ShuffleStart.canonical, intent: albumIntent));
      await pumpEventQueue();
      expect(outcome, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(issues, const [LocalFileMissing('a', '/dl/a')]);
      expect((await clicks()).map((e) => e.entityType), ['album'],
          reason: 'one collection click, never a member track click');
    });
  });

  group('6A.1b (spec §5 Shuffle, SC-27): PlayCollection random start', () {
    const albumIntent = HistoryIntent('album', 'inst-1:1');

    Future<AlbumScope> album(List<String> uuids) async {
      await fixture.insertAlbum(artist: 'Artist', album: 'Album', uuids: uuids);
      final first = await fixture.track(uuids.first);
      return AlbumScope(artistId: first.artistId!, albumId: first.albumId!);
    }

    test('the full permutation is persisted before audio; the scripted first '
        'pick starts the last canonical member', () async {
      final scope = await album(['a', 'b', 'c', 'd', 'e', 'f']);
      // Two members share a title (spec: duplicate titles included).
      await (db.update(db.trackmetadata)
            ..where((t) => t.uuidId.isIn(['b', 'd'])))
          .write(const TrackmetadataCompanion(title: Value('Same')));
      final c = createContainer(
          random: _FirstPickRandom((max) => max - 1, Random(4)));
      List<(int, int, String)>? rowsAtFirstSeed;
      int? playsAtFirstSeed;
      fakePlayer.beforeSeed = (sessionId) async {
        if (rowsAtFirstSeed != null || sessionId == null) return;
        playsAtFirstSeed = fakePlayer.playCalls;
        rowsAtFirstSeed = await _orderRows(db, sessionId);
      };

      final outcome = await c.read(playbackRequestsProvider).submit(
          PlayCollection(scope, const ['a', 'b', 'c', 'd', 'e', 'f'],
              shuffle: ShuffleStart.random, intent: albumIntent));

      expect(outcome, isA<Accepted>());
      final sessionId = (outcome as Accepted).sessionId;
      expect(playsAtFirstSeed, 0, reason: 'no audio before the order row');
      final rows = rowsAtFirstSeed!;
      expect(rows.map((r) => r.$1), [0, 1, 2, 3, 4, 5]);
      expect(rows.first, (0, 5, 'f'), reason: 'forced first = last canonical');
      expect(rows.map((r) => r.$2).toSet(), {0, 1, 2, 3, 4, 5});
      expect(rows.map((r) => r.$3).toList()..sort(),
          ['a', 'b', 'c', 'd', 'e', 'f'], reason: 'no duplicates, none missing');
      expect(await _orderRows(db, sessionId), rows,
          reason: 'activation and start never reorder it');
      expect(fakePlayer.seedCalls.single.autoPlay, isTrue);
      expect(c.read(currentTrackProvider)?.uuidId, 'f',
          reason: 'the first audible item is the persisted first');
      expect(c.read(shuffleProvider), isTrue);
      expect((await repo.getSessionSnapshot(sessionId))!.session.shuffleEnabled,
          isTrue);
      await pumpEventQueue();
      final clickRows = await (db.select(db.historyEvents)
            ..where((e) => e.kind.equals('clicked')))
          .get();
      expect(clickRows.map((e) => (e.entityType, e.entityRef)),
          [('album', 'inst-1:1')]);
    });

    test('seeded: the session is the permutation of exactly the members',
        () async {
      final uuids = List.generate(15, (i) => 't$i');
      final scope = await album(uuids);
      final c = createContainer(random: Random(99));
      final outcome = await c.read(playbackRequestsProvider).submit(
          PlayCollection(scope, uuids, shuffle: ShuffleStart.random));
      final rows = await _orderRows(db, (outcome as Accepted).sessionId);
      expect(rows.map((r) => r.$1), List.generate(15, (i) => i));
      expect(rows.map((r) => r.$2).toList()..sort(), List.generate(15, (i) => i));
      expect(rows.map((r) => r.$3).toSet(), uuids.toSet());
      expect(rows.map((r) => r.$3), isNot(orderedEquals(uuids)));
      expect(c.read(currentTrackProvider)?.uuidId, rows.first.$3);
    });

    test('Shuffle keeps the repeat mode and turns shuffle on even when sticky '
        'shuffle was off', () async {
      await fixture.insertSingles(['x']);
      final scope = await album(['a', 'b', 'c']);
      final c = createContainer(random: Random(1));
      await c.read(playbackRequestsProvider)
          .submit(const PlayList(['x'], 0, ListSource('search')));
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode(); // all
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode(); // one
      expect(c.read(shuffleProvider), isFalse);
      await c.read(playbackRequestsProvider).submit(
          PlayCollection(scope, const ['a', 'b', 'c'],
              shuffle: ShuffleStart.random));
      expect(c.read(shuffleProvider), isTrue);
      expect(c.read(repeatModeProvider), QueueRepeatMode.one);
    });
  });

  // Was "Sign-off DEV-6-01 (owner, 2026-11-17): shuffle off restores the whole original order, on every queue".
  group('shuffle off restores the whole original order, on every queue', () {
    // Replaces the 6A.1b group "shuffle toggles keep the played prefix".
    const canonical = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];

    Future<List<String>> orderOf(ProviderContainer c) async =>
        (await sessionTracksOf(c)).map((e) => e.uuidId).toList();

    String? current(ProviderContainer c) =>
        c.read(currentTrackProvider)?.uuidId;

    Future<void> skip(ProviderContainer c, int times) async {
      for (var i = 0; i < times; i++) {
        await c.read(queuePlayerProvider.notifier).skipNext();
        await pumpEventQueue();
      }
    }

    /// A shuffled collection queue over [canonical] after [plays] skips.
    Future<(ProviderContainer, List<String>)> shuffledAlbum(int plays) async {
      await fixture.insertAlbum(
          artist: 'Artist', album: 'Album', uuids: canonical);
      final first = await fixture.track('a');
      final c = createContainer(random: Random(5));
      await c.read(playbackRequestsProvider).submit(PlayCollection(
          AlbumScope(artistId: first.artistId!, albumId: first.albumId!),
          canonical,
          shuffle: ShuffleStart.random));
      final initial = await orderOf(c);
      await skip(c, plays);
      expect(current(c), initial[plays]);
      expect(initial.take(plays + 1),
          isNot(canonical.take(plays + 1)),
          reason: 'precondition: the heard tracks are not the album start');
      return (c, initial);
    }

    test('collection Shuffle, several plays: OFF puts the whole queue in '
        'album order with the current track at its album position; Previous '
        'walks back through the album', () async {
      final (c, initial) = await shuffledAlbum(3);
      final playing = initial[3];
      final notifier = c.read(queuePlayerProvider.notifier);

      await notifier.toggleShuffle(); // off
      expect(await orderOf(c), canonical);
      expect(current(c), playing);
      final at = canonical.indexOf(playing);
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, at);
      expect(c.read(shuffleProvider), isFalse);

      for (var i = at - 1; i >= 0; i--) {
        await notifier.skipPrevious();
        await pumpEventQueue();
        expect(current(c), canonical[i]);
      }
    });

    test('ON in the middle of the album shuffles only what is ahead: the '
        'tracks before the current one stay behind (Phase 5)', () async {
      final (c, initial) = await shuffledAlbum(3);
      final notifier = c.read(queuePlayerProvider.notifier);
      await notifier.toggleShuffle(); // off: album order
      final at = c.read(queuePlayerProvider).queue.currentPlayPosition;

      await notifier.toggleShuffle(); // on
      final on = await orderOf(c);
      expect(on.take(at + 1), canonical.take(at + 1),
          reason: 'behind and current stay in album order');
      expect(on.skip(at + 1).toSet(), canonical.skip(at + 1).toSet());
      expect(current(c), initial[3]);
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, at);
      expect(c.read(shuffleProvider), isTrue);
    });

    test('a list queue follows the same rule (every queue)', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'f']);
      final c = createContainer(random: Random(2));
      final notifier = c.read(queuePlayerProvider.notifier);
      await c.read(playbackRequestsProvider).submit(const PlayList(
          ['a', 'b', 'c', 'd', 'e', 'f'], 2, ListSource('search')));
      await notifier.toggleShuffle(); // on: a, b, c, then shuffled d e f
      final on = await orderOf(c);
      expect(on.take(3), ['a', 'b', 'c']);
      await skip(c, 1);
      await notifier.toggleShuffle(); // off
      expect(await orderOf(c), ['a', 'b', 'c', 'd', 'e', 'f']);
      expect(current(c), on[3]);
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition,
          ['a', 'b', 'c', 'd', 'e', 'f'].indexOf(on[3]));
    });

    test('the playing track keeps playing: no seed, seek, play or pause, '
        'and its position is kept', () async {
      final (c, _) = await shuffledAlbum(2);
      final notifier = c.read(queuePlayerProvider.notifier);
      fakePlayer.emitPlayerState(
          EngineTransportState(true, EngineProcessingState.ready));
      await notifier.seek(const Duration(seconds: 42));
      await pumpEventQueue();
      final seeds = fakePlayer.seedCalls.length;
      final seeks = fakePlayer.seekedItems.length;
      final plays = fakePlayer.playCalls;
      final pauses = fakePlayer.pauseCalls;
      final rebuilds = fakePlayer.rebuildCalls.length;
      final item = c.read(queuePlayerProvider).queue.currentItemId;

      await notifier.toggleShuffle(); // off
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds));
      expect(fakePlayer.seekedItems, hasLength(seeks));
      expect(fakePlayer.playCalls, plays);
      expect(fakePlayer.pauseCalls, pauses);
      expect(fakePlayer.rebuildCalls, hasLength(rebuilds + 1),
          reason: 'the engine is reordered around the playing source');
      expect(fakePlayer.rebuildCalls.last.map((e) => e.uuidId),
          canonical.take(fakePlayer.rebuildCalls.last.length));
      expect(c.read(queuePlayerProvider).queue.currentItemId, item);
      expect(c.read(audioPositionProvider), const Duration(seconds: 42));
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
    });

    test('a queued track heard in the shuffled pass comes back right after '
        'the track it followed', () async {
      final (c, initial) = await shuffledAlbum(1);
      await fixture.insertSingles(['x']);
      await playNext(c, [await fixture.track('x')]);
      await skip(c, 2); // x, then the next shuffled track
      final playing = initial[2];
      expect(current(c), playing);
      await c.read(queuePlayerProvider.notifier).toggleShuffle(); // off
      final expected = [
        for (final u in canonical) ...[u, if (u == initial[1]) 'x'],
      ];
      expect(await orderOf(c), expected);
      expect(current(c), playing);
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition,
          expected.indexOf(playing));
    });

    test('repeat-all: right after shuffle off the engine loops natively over '
        'the album order', () async {
      final (c, _) = await shuffledAlbum(2);
      final notifier = c.read(queuePlayerProvider.notifier);
      await notifier.cycleQueueRepeatMode(); // all
      expect(c.read(repeatModeProvider), QueueRepeatMode.all);
      await notifier.toggleShuffle(); // off
      expect(await orderOf(c), canonical);
      expect(fakePlayer.lastLoopMode, EngineLoopMode.all);
    });

    test('after a relaunch, shuffle off restores the album order the same '
        'way', () async {
      final (c, initial) = await shuffledAlbum(2);
      await c.read(queuePlayerProvider.notifier).pause(); // saves the cursor
      final sessionId = c.read(queuePlayerProvider).queue.sessionId;
      c.dispose();
      fakePlayer = FakePlaybackEngine();
      final r = createContainer(random: Random(5));
      for (var i = 0;
          i < 50 && r.read(queuePlayerProvider).queue.sessionId == null;
          i++) {
        await pumpEventQueue();
      }
      expect(r.read(queuePlayerProvider).queue.sessionId, sessionId);
      expect(r.read(shuffleProvider), isTrue);
      expect(await orderOf(r), initial, reason: 'restored as stored');

      await r.read(queuePlayerProvider.notifier).toggleShuffle(); // off
      expect(await orderOf(r), canonical);
      expect(current(r), initial[2]);
      expect(r.read(queuePlayerProvider).queue.currentPlayPosition,
          canonical.indexOf(initial[2]));
    });
  });

  // Sign-off DEV-6-01 (owner, 2026-11-17) replaces 6-R1-01/6-R2-*: shuffle
  // off restores the album order at once, so the repeat-all wrap needs no
  // canonical rewrite of its own. The tests that built a "kept shuffled
  // prefix" by turning shuffle off (a state the toggle no longer makes)
  // were removed with that machinery; the rest are kept or rewritten here.
  // Was "Repeat-all and repeat-one with the shuffle toggle (DEV-6-01; was 6-R1-01)".
  group('repeat-all and repeat-one with the shuffle toggle', () {
    const canonical = ['a', 'b', 'c', 'd', 'e'];

    /// A shuffled collection queue under repeat-all, at its first track.
    Future<(ProviderContainer, List<String>)> shuffledRepeatAll() async {
      await fixture.insertAlbum(
          artist: 'Artist', album: 'Album', uuids: canonical);
      final first = await fixture.track('a');
      final c = createContainer(random: Random(5));
      await c.read(playbackRequestsProvider).submit(PlayCollection(
          AlbumScope(artistId: first.artistId!, albumId: first.albumId!),
          canonical,
          shuffle: ShuffleStart.random));
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode();
      expect(c.read(repeatModeProvider), QueueRepeatMode.all);
      final shuffled =
          (await sessionTracksOf(c)).map((e) => e.uuidId).toList();
      expect(shuffled, isNot(canonical),
          reason: 'precondition: the seed shuffles the queue');
      return (c, shuffled);
    }

    Future<List<String>> orderOf(ProviderContainer c) async =>
        (await sessionTracksOf(c)).map((e) => e.uuidId).toList();

    String? current(ProviderContainer c) =>
        c.read(currentTrackProvider)?.uuidId;

    Future<void> skip(ProviderContainer c, int times) async {
      for (var i = 0; i < times; i++) {
        await c.read(queuePlayerProvider.notifier).skipNext();
        await pumpEventQueue();
      }
    }

    test('turned off at the last shuffled track: album order at once, the '
        'track at its album position; the rest of the album, then the wrap '
        'to a with no rewrite', () async {
      final (c, shuffled) = await shuffledRepeatAll();
      await skip(c, 4);
      expect(current(c), shuffled.last);
      await c.read(queuePlayerProvider.notifier).toggleShuffle(); // off
      expect(await orderOf(c), canonical);
      final at = canonical.indexOf(shuffled.last);
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, at);
      expect(fakePlayer.lastLoopMode, EngineLoopMode.all);

      await skip(c, canonical.length - 1 - at);
      expect(current(c), 'e');
      final rebuilds = fakePlayer.rebuildCalls.length;
      await skip(c, 1); // the wrap
      expect(current(c), 'a');
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 0);
      expect(await orderOf(c), canonical);
      expect(fakePlayer.rebuildCalls, hasLength(rebuilds),
          reason: 'the wrap rewrites nothing');
    });

    test('with shuffle on the wrap replays the same shuffled order '
        '(Phase 5)', () async {
      final (c, shuffled) = await shuffledRepeatAll();
      await skip(c, 4);
      await skip(c, 1); // the wrap
      expect(c.read(shuffleProvider), isTrue);
      expect(await orderOf(c), shuffled);
      expect(current(c), shuffled.first);
    });

    test('repeat-all chosen after shuffle was turned off loops natively',
        () async {
      final (c, _) = await shuffledRepeatAll();
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode(); // one
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode(); // off
      await skip(c, 2);
      await c.read(queuePlayerProvider.notifier).toggleShuffle(); // off
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode(); // all
      expect(c.read(repeatModeProvider), QueueRepeatMode.all);
      expect(fakePlayer.lastLoopMode, EngineLoopMode.all);
    });

    test('repeat-one: shuffle off reorders the queue; Next still restarts '
        'the current track and changes no order', () async {
      final (c, shuffled) = await shuffledRepeatAll();
      await skip(c, 4);
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode(); // one
      await c.read(queuePlayerProvider.notifier).toggleShuffle(); // off
      expect(await orderOf(c), canonical);
      fakePlayer.emitPosition(const Duration(seconds: 30));
      await pumpEventQueue();
      final plays = fakePlayer.playCalls;
      final seeks = fakePlayer.seekedItems.length;
      final seeds = fakePlayer.seedCalls.length;
      await skip(c, 1);
      expect(current(c), shuffled.last);
      expect(await orderOf(c), canonical);
      expect(fakePlayer.position, Duration.zero,
          reason: 'the current track restarts from its start');
      expect(fakePlayer.playCalls, plays + 1, reason: 'and plays');
      expect((fakePlayer.seekedItems.length, fakePlayer.seedCalls.length),
          (seeks, seeds), reason: 'no other item is loaded or sought');
    });

    test('repeat-one: Previous restarts the current track and changes no '
        'order', () async {
      final (c, shuffled) = await shuffledRepeatAll();
      await skip(c, 2);
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode(); // one
      final order = await orderOf(c);
      fakePlayer.emitPosition(const Duration(seconds: 2)); // within 3 s
      await pumpEventQueue();
      final plays = fakePlayer.playCalls;
      final seeks = fakePlayer.seekedItems.length;
      final seeds = fakePlayer.seedCalls.length;
      await c.read(queuePlayerProvider.notifier).skipPrevious();
      await pumpEventQueue();
      expect(current(c), shuffled[2]);
      expect(await orderOf(c), order);
      expect(fakePlayer.position, Duration.zero,
          reason: 'the current track restarts from its start');
      expect(fakePlayer.playCalls, plays + 1, reason: 'and plays');
      expect((fakePlayer.seekedItems.length, fakePlayer.seedCalls.length),
          (seeks, seeds), reason: 'no other item is loaded or sought');
    });

    /// Quit and relaunch: a new player and engine over the same database.
    Future<ProviderContainer> relaunch(ProviderContainer c) async {
      await c.read(queuePlayerProvider.notifier).pause(); // saves the cursor
      final sessionId = c.read(queuePlayerProvider).queue.sessionId;
      c.dispose();
      fakePlayer = FakePlaybackEngine();
      final next = createContainer(random: Random(5));
      for (var i = 0;
          i < 50 && next.read(queuePlayerProvider).queue.sessionId == null;
          i++) {
        await pumpEventQueue();
      }
      expect(next.read(queuePlayerProvider).queue.sessionId, sessionId,
          reason: 'precondition: the queue was restored');
      return next;
    }

    test('6-R2-01: after a relaunch, a shuffled repeat-all queue still loops '
        'natively (Phase 5)', () async {
      final (c, _) = await shuffledRepeatAll();
      await skip(c, 2);
      final r = await relaunch(c);
      expect(r.read(shuffleProvider), isTrue);
      expect(fakePlayer.lastLoopMode, EngineLoopMode.all);
    });

    test('6-R2-01: after a relaunch, a canonical repeat-all queue still loops '
        'natively (Phase 5)', () async {
      await fixture.insertAlbum(
          artist: 'Artist', album: 'Album', uuids: canonical);
      final first = await fixture.track('a');
      final c = createContainer(random: Random(5));
      await c.read(playbackRequestsProvider).submit(PlayCollection(
          AlbumScope(artistId: first.artistId!, albumId: first.albumId!),
          canonical,
          shuffle: ShuffleStart.canonical));
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode(); // all
      await skip(c, 2);
      final r = await relaunch(c);
      expect(r.read(shuffleProvider), isFalse);
      expect(await orderOf(r), canonical);
      expect(fakePlayer.lastLoopMode, EngineLoopMode.all);
    });

    /// An album-order repeat-all queue at its last track.
    Future<ProviderContainer> canonicalAtLast() async {
      await fixture.insertAlbum(
          artist: 'Artist', album: 'Album', uuids: canonical);
      final first = await fixture.track('a');
      final c = createContainer();
      await c.read(playbackRequestsProvider).submit(PlayCollection(
          AlbumScope(artistId: first.artistId!, albumId: first.albumId!),
          canonical,
          shuffle: ShuffleStart.canonical));
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode(); // all
      await skip(c, 4);
      expect(current(c), 'e');
      return c;
    }

    test('6-R2-03 (review C-2): a completed report repeated after the wrap '
        'has moved the engine to the first track does not advance again',
        () async {
      final c = await canonicalAtLast();
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(current(c), 'a');
      final seeks = fakePlayer.seekedItems.length;
      // The wrap's native seek settles while the plugin still reports the
      // old end.
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.buffering));
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(current(c), 'a');
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 0);
      expect(fakePlayer.seekedItems, hasLength(seeks));
    });

    test('6-R2-03: after the wrap, the next genuine end is still handled',
        () async {
      final c = await canonicalAtLast();
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(current(c), 'a');
      fakePlayer.emitPlayerState(
          EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      await skip(c, 4); // the end of the next cycle
      expect(current(c), 'e');
      final seeks = fakePlayer.seekedItems.length;
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(current(c), 'a');
      expect(fakePlayer.seekedItems.length, seeks + 1);
    });

    // Coordinator Q2 (2026-11-17): a queue stored with shuffle off and an
    // order that is not the original one (reachable when the toggle's order
    // write fails after its shuffle-flag write) is played as stored until
    // the next toggle: no normalising pass, native looping as for any order.
    test('a stored shuffle-off queue whose order is not the original one is '
        'played as stored, wraps natively, and the next toggle off restores '
        'the original order', () async {
      await fixture.insertSingles(canonical);
      final sessionId = await repo.createSessionFromExplicitList(
          sourceType: 'album', trackUuids: canonical, repeatMode: 'all');
      final ids = {
        for (final e in await repo.getSessionTracksInPlayOrder(sessionId))
          e.uuidId: e.itemId,
      };
      const stored = ['d', 'b', 'e', 'a', 'c'];
      await repo.replacePlayOrder(sessionId, [for (final u in stored) ids[u]!]);
      await repo.updatePlaybackCursor(
          sessionId: sessionId, currentItemId: ids['c']!, positionMs: 0);

      final c = createContainer();
      for (var i = 0;
          i < 50 && c.read(queuePlayerProvider).queue.sessionId == null;
          i++) {
        await pumpEventQueue();
      }
      expect(c.read(queuePlayerProvider).queue.sessionId, sessionId);
      expect(c.read(shuffleProvider), isFalse);
      expect(current(c), 'c');
      expect(fakePlayer.lastLoopMode, EngineLoopMode.all,
          reason: 'the stored order is replayed as it is');

      await skip(c, 1); // the wrap
      expect(current(c), 'd');
      expect(await orderOf(c), stored, reason: 'nothing is rewritten');

      await c.read(queuePlayerProvider.notifier).toggleShuffle(); // on
      await c.read(queuePlayerProvider.notifier).toggleShuffle(); // off
      expect(await orderOf(c), canonical);
      expect(current(c), 'd');
    });

    test('6-R2-04: offline, an unavailable advance at the last position '
        'wraps to the first local track', () async {
      await fixture.insertAlbum(
          artist: 'Artist', album: 'Album', uuids: canonical);
      for (final u in canonical) {
        await markDownloaded(u, '/dl/$u');
      }
      final first = await fixture.track('a');
      final c = createContainer(offline: true);
      await c.read(playbackRequestsProvider).submit(PlayCollection(
          AlbumScope(artistId: first.artistId!, albumId: first.albumId!),
          canonical,
          shuffle: ShuffleStart.canonical));
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode(); // all
      await skip(c, 4);
      expect(current(c), 'e');
      await markDeleted('a', '/dl/a'); // the first file is gone too
      await markDeleted('e', '/dl/e'); // the current file is gone
      fakePlayer.emitUnavailableAdvance(UnavailableAdvance(
          itemId: c.read(queuePlayerProvider).queue.currentItemId!,
          playPosition: 4));
      await pumpEventQueue();
      expect(current(c), 'b');
      expect(await orderOf(c), canonical);
    });

    test('6-R2-04: a one-track repeat-all queue wraps onto itself with no '
        'rewrite and keeps native looping', () async {
      await fixture.insertSingles(['x']);
      final c = createContainer();
      await c.read(playbackRequestsProvider)
          .submit(const PlayList(['x'], 0, ListSource('search')));
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode(); // all
      expect(fakePlayer.lastLoopMode, EngineLoopMode.all);
      final rebuilds = fakePlayer.rebuildCalls.length;
      await skip(c, 1);
      expect(current(c), 'x');
      expect(fakePlayer.rebuildCalls, hasLength(rebuilds));
      expect(fakePlayer.lastLoopMode, EngineLoopMode.all);
    });
  });

  // Was "Sign-off OPEN-6-04 (owner, 2026-11-17): a track added after the queue has ended".
  group('a track added after the queue has ended', () {
    String? current(ProviderContainer c) =>
        c.read(currentTrackProvider)?.uuidId;

    Future<int> itemOf(ProviderContainer c, String uuid) async =>
        (await sessionTracksOf(c)).firstWhere((e) => e.uuidId == uuid).itemId;

    /// A list queue a b c that played its last track to the end (repeat
    /// off): the engine reported completed and nothing follows.
    Future<ProviderContainer> ended({bool offline = false}) async {
      await fixture.insertSingles(['a', 'b', 'c', 'y', 'z']);
      if (offline) {
        for (final u in ['a', 'b', 'c', 'y', 'z']) {
          await markDownloaded(u, '/dl/$u');
        }
      }
      final c = createContainer(offline: offline);
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('c'), sourceType: 'search');
      await pumpEventQueue();
      fakePlayer.emitPlayerState(
          EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(current(c), 'c', reason: 'precondition: the queue ended on c');
      expect(c.read(queuePlayerProvider).playback.processing,
          EngineProcessingState.completed);
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isFalse);
      return c;
    }

    /// Well after the end: outside any grace window.
    void later() => testClock.advance(const Duration(seconds: 5));

    Future<void> expectRestingOn(ProviderContainer c, String uuid,
        {required int plays}) async {
      final item = await itemOf(c, uuid);
      expect(current(c), uuid);
      expect(c.read(queuePlayerProvider).queue.currentItemId, item);
      expect(fakePlayer.currentItemId, item,
          reason: 'the engine is on the added track');
      expect(fakePlayer.position, Duration.zero);
      expect(fakePlayer.playCalls, plays, reason: 'nothing starts');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isFalse);
      expect(c.read(audioPositionProvider), Duration.zero);
      final session = await repo.getActiveSession();
      expect(session?.currentItemId, item, reason: 'the cursor is saved');
      expect(session?.currentPositionMs, 0);
    }

    test('Play next after the end: the added track is current at 0:00, '
        'paused', () async {
      final c = await ended();
      later();
      final plays = fakePlayer.playCalls;
      await playNext(c, [await fixture.track('z')]);
      await pumpEventQueue();
      expect((await sessionTracksOf(c)).map((e) => e.uuidId),
          ['a', 'b', 'c', 'z']);
      await expectRestingOn(c, 'z', plays: plays);
    });

    test('Add to queue after the end, several tracks: the first added is '
        'current at 0:00, paused; the rest follow', () async {
      final c = await ended();
      later();
      final plays = fakePlayer.playCalls;
      await addToQueue(c, [await fixture.track('z'), await fixture.track('y')]);
      await pumpEventQueue();
      expect((await sessionTracksOf(c)).map((e) => e.uuidId),
          ['a', 'b', 'c', 'z', 'y']);
      await expectRestingOn(c, 'z', plays: plays);
    });

    test('offline, after the end: the same', () async {
      final c = await ended(offline: true);
      later();
      final plays = fakePlayer.playCalls;
      await playNext(c, [await fixture.track('z')]);
      await pumpEventQueue();
      await expectRestingOn(c, 'z', plays: plays);
    });

    test('the engine insert failing after the end (Phase 7 rebuild) rests '
        'paused on the added track too', () async {
      final c = await ended();
      later();
      final plays = fakePlayer.playCalls;
      await playNext(c, [await fixture.track('z')]);
      fakePlayer.emitCommandFailure(EngineCommandFailure(
        runtimeId: fakePlayer.runtimeId,
        seedRevision: fakePlayer.seedRevision,
        playlistRevision: fakePlayer.playlistRevision,
        command: EngineCommand.insert,
        reason: EngineCommandFailureReason.failed,
        diverged: true,
      ));
      await pumpEventQueue();
      // The rebuilt plugin settles and re-reports where it stands.
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.ready));
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      final z = await itemOf(c, 'z');
      expect(fakePlayer.seedCalls.last.currentItemId, z, reason: 'rebuilt');
      expect(current(c), 'z');
      expect(fakePlayer.playCalls, plays, reason: 'nothing starts');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isFalse);
    });

    test('a track added before the end continues into it (unchanged)',
        () async {
      await fixture.insertSingles(['a', 'b', 'c', 'z']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('c'), sourceType: 'search');
      await pumpEventQueue();
      fakePlayer.emitPlayerState(
          EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      await addToQueue(c, [await fixture.track('z')]);
      await pumpEventQueue();
      expect(current(c), 'c', reason: 'the playing track is not interrupted');
      final plays = fakePlayer.playCalls;
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(current(c), 'z');
      expect(fakePlayer.playCalls, plays + 1);
    });

    test('after the end, seeking back into the last track makes it a paused '
        'queue again: an add only queues', () async {
      final c = await ended();
      later();
      await c.read(queuePlayerProvider.notifier)
          .seek(const Duration(seconds: 10));
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.ready));
      await pumpEventQueue();
      final seeks = fakePlayer.seekedItems.length;
      final plays = fakePlayer.playCalls;
      await playNext(c, [await fixture.track('z')]);
      await pumpEventQueue();
      expect(current(c), 'c');
      expect(fakePlayer.seekedItems, hasLength(seeks));
      expect(fakePlayer.playCalls, plays);
      expect((await sessionTracksOf(c)).map((e) => e.uuidId),
          ['a', 'b', 'c', 'z']);
    });

    test('repeat-all never ends: an add at the last track only queues',
        () async {
      await fixture.insertSingles(['a', 'b', 'c', 'z']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('c'), sourceType: 'search');
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode(); // all
      await pumpEventQueue();
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(current(c), 'a', reason: 'the wrap');
      later();
      final seeks = fakePlayer.seekedItems.length;
      await playNext(c, [await fixture.track('z')]);
      await pumpEventQueue();
      expect(current(c), 'a');
      expect(fakePlayer.seekedItems, hasLength(seeks));
    });

    // The grace window (owner: "If you add a track to your queue within X
    // milliseconds of the queue finishing, then it should start playback.
    // For now, 250ms is a good buffer, but it shouldn't be hardcoded.").

    test('review #1: an old end of the same track never decides a later '
        'add; an add made before the track ends again continues', () async {
      final c = await ended();
      later();
      // The listener scrubs back into c and plays it again.
      await c.read(queuePlayerProvider.notifier)
          .seek(const Duration(seconds: 10));
      fakePlayer.emitPlayerState(
          EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      final plays = fakePlayer.playCalls;
      // Read before the edit is held: the held edit's transaction makes
      // outside reads wait until it commits (section 6 #1).
      final y = await fixture.track('y');
      final z = await fixture.track('z');
      // Near c's end two adds are in the lane; c ends while the first one
      // edits the queue, before the end's own task runs.
      final gate = Completer<void>();
      repo.afterReplacePlayOrder = (_) async {
        repo.afterReplacePlayOrder = null;
        await gate.future;
      };
      final first = addToQueue(c, [y]);
      await pumpEventQueue();
      final second = addToQueue(c, [z]);
      await pumpEventQueue();
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      gate.complete();
      await first;
      await second;
      await pumpEventQueue();
      expect(current(c), 'y');
      expect(fakePlayer.playCalls, plays + 1,
          reason: 'both adds were made before c ended: the queue keeps going');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
    });

    test('review #5: after a paused landing, the old end re-reported (no '
        'ready since) does not advance again', () async {
      final c = await ended();
      later();
      await addToQueue(c, [await fixture.track('z'), await fixture.track('y')]);
      await pumpEventQueue();
      expect(current(c), 'z');
      final seeks = fakePlayer.seekedItems.length;
      final plays = fakePlayer.playCalls;
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.buffering));
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(current(c), 'z');
      expect(fakePlayer.seekedItems, hasLength(seeks));
      expect(fakePlayer.playCalls, plays);
    });

    test('the grace window is one named value, 250 ms by default', () {
      expect(QueuePlayer.queueEndResumeGrace,
          const Duration(milliseconds: 250));
    });

    test('an add at the edge of the grace window after the end plays the '
        'added track from 0:00', () async {
      final c = await ended();
      testClock.advance(QueuePlayer.queueEndResumeGrace);
      final plays = fakePlayer.playCalls;
      await playNext(c, [await fixture.track('z')]);
      await pumpEventQueue();
      expect(current(c), 'z');
      expect(fakePlayer.currentItemId, await itemOf(c, 'z'));
      expect(fakePlayer.position, Duration.zero);
      expect(fakePlayer.playCalls, plays + 1);
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
    });

    test('an add 1 ms past the grace window rests paused at 0:00', () async {
      final c = await ended();
      testClock.advance(
          QueuePlayer.queueEndResumeGrace + const Duration(milliseconds: 1));
      final plays = fakePlayer.playCalls;
      await addToQueue(c, [await fixture.track('z')]);
      await pumpEventQueue();
      await expectRestingOn(c, 'z', plays: plays);
    });

    test('measured from the tap: an add submitted before the end but applied '
        'well after it continues playing', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'z']);
      for (final u in ['a', 'b', 'c', 'z']) {
        await markDownloaded(u, '/dl/$u');
      }
      final c = createContainer(offline: true);
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('c'), sourceType: 'search');
      await pumpEventQueue();
      fakePlayer.emitPlayerState(
          EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      final plays = fakePlayer.playCalls;
      // The offline file check holds the add between its tap and the lane.
      final gate = fileGate = Completer<void>();
      final adding = playNext(c, [await fixture.track('z')]);
      await pumpEventQueue();
      testClock.advance(const Duration(milliseconds: 100));
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(current(c), 'c', reason: 'precondition: the queue ended first');
      testClock.advance(QueuePlayer.queueEndResumeGrace * 2);
      fileGate = null;
      gate.complete();
      await adding;
      await pumpEventQueue();
      expect(current(c), 'z');
      expect(fakePlayer.playCalls, plays + 1,
          reason: 'tapped 100 ms before the end: the queue keeps going');
    });

    test('the engine insert failing inside the grace window: the rebuild '
        'plays the added track', () async {
      final c = await ended();
      testClock.advance(const Duration(milliseconds: 100));
      await playNext(c, [await fixture.track('z')]);
      fakePlayer.emitCommandFailure(EngineCommandFailure(
        runtimeId: fakePlayer.runtimeId,
        seedRevision: fakePlayer.seedRevision,
        playlistRevision: fakePlayer.playlistRevision,
        command: EngineCommand.insert,
        reason: EngineCommandFailureReason.failed,
        diverged: true,
      ));
      await pumpEventQueue();
      final z = await itemOf(c, 'z');
      expect(fakePlayer.seedCalls.last.currentItemId, z, reason: 'rebuilt');
      expect(current(c), 'z');
      expect(c.read(queuePlayerProvider).playback.playWhenReady, isTrue);
    });
  });

  // Was "6-R3-01: an end masked by a pending native insert is a real end".
  group('an end masked by a pending native insert is a real end', () {
    String? current(ProviderContainer c) =>
        c.read(currentTrackProvider)?.uuidId;

    /// A list queue playing its last track.
    Future<ProviderContainer> atLastOf(List<String> uuids) async {
      await fixture.insertSingles([...uuids, 'z']);
      final c = createContainer();
      await playFromTrackList(c, uuids, await fixture.track(uuids.last),
          sourceType: 'test');
      await pumpEventQueue();
      expect(current(c), uuids.last, reason: 'precondition');
      return c;
    }

    /// A 100-track list queue; the seed window holds positions 0..60.
    Future<ProviderContainer> playing100({int start = 0}) async {
      final uuids = List.generate(100, (i) => 't$i');
      await fixture.insertSingles([...uuids, 'z']);
      final c = createContainer();
      await repo.startupRead.future;
      await playFromTrackList(c, uuids, await fixture.track('t$start'),
          sourceType: 'test');
      await pumpEventQueue();
      return c;
    }

    /// The last track ends while the held insert is still pending, then
    /// the insert settles (the engine re-reports completed).
    Future<void> endDuringPendingInsert() async {
      expect(fakePlayer.editPending, isTrue,
          reason: 'precondition: the insert has not applied natively');
      fakePlayer.completeNatively(); // masked as buffering
      await pumpEventQueue();
      fakePlayer.settleEdit(); // completed, the ended item still current
      await pumpEventQueue();
    }

    test('(a) Play next, repeat off: the added track plays', () async {
      final c = await atLastOf(['a', 'b', 'c']);
      fakePlayer.holdNextEdit = true;
      await playNext(c, [await fixture.track('z')]);
      final plays = fakePlayer.playCalls;
      await endDuringPendingInsert();
      expect(current(c), 'z');
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 3);
      expect(fakePlayer.playCalls, plays + 1);
    });

    test('(b) Add to queue, repeat off: the added track plays', () async {
      final c = await atLastOf(['a', 'b', 'c']);
      fakePlayer.holdNextEdit = true;
      await addToQueue(c, [await fixture.track('z')]);
      final plays = fakePlayer.playCalls;
      await endDuringPendingInsert();
      expect(current(c), 'z');
      expect(fakePlayer.playCalls, plays + 1);
    });

    test('(c) repeat-all with a window not covering the queue: the added '
        'track plays once; its own settle re-reporting completed does not '
        'advance again', () async {
      final c = await playing100(start: 99);
      await c.read(queuePlayerProvider.notifier).cycleQueueRepeatMode();
      expect(c.read(repeatModeProvider), QueueRepeatMode.all);
      expect(fakePlayer.lastLoopMode, EngineLoopMode.off,
          reason: 'precondition: the model wraps, not the engine');
      fakePlayer.holdNextEdit = true;
      await playNext(c, [await fixture.track('z')]);
      await endDuringPendingInsert();
      expect(current(c), 'z');
      final seeks = fakePlayer.seekedItems.length;
      // The advance's own native seek settles while the plugin still
      // reports the old end: a repeat of the end just handled.
      fakePlayer.emitPlayerState(
          EngineTransportState(true, EngineProcessingState.buffering));
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(current(c), 'z');
      expect(fakePlayer.seekedItems, hasLength(seeks));
    });

    test('(d) a hydration chunk landing at the end of the window: playback '
        'continues with the next track', () async {
      final c = await playing100();
      final notifier = c.read(queuePlayerProvider.notifier);
      final tracks = await sessionTracksOf(c);
      final gate = repo.hydrationGate = Completer<void>();
      await notifier.skipToTrack(tracks[60].itemId); // the window's last
      await repo.hydrationEntered.future;
      repo.hydrationGate = null;
      fakePlayer.holdNextEdit = true;
      final added = fakePlayer.addedBatches.length;
      gate.complete();
      await pumpEventQueue();
      expect(fakePlayer.addedBatches, hasLength(added + 1),
          reason: 'precondition: the chunk was issued');
      final plays = fakePlayer.playCalls;
      await endDuringPendingInsert();
      expect(current(c), 't61');
      expect(fakePlayer.playCalls, plays + 1);
    });

    test('6-R3-03: a user skip taken before the end report\'s task moves on '
        'once; the stale end does not advance again', () async {
      final c = await playing100();
      final notifier = c.read(queuePlayerProvider.notifier);
      final tracks = await sessionTracksOf(c);
      repo.hydrationGate = Completer<void>(); // hydration lags behind
      await notifier.skipToTrack(tracks[60].itemId); // the window's last
      await pumpEventQueue();
      final skipping = notifier.skipNext(); // in the lane first
      // t60 ends as the skip is taken: the end task queues behind the skip.
      fakePlayer.emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
      await skipping;
      await pumpEventQueue();
      expect(current(c), 't61');
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 61);
      repo.hydrationGate!.complete();
    });
  });

  group('6A.1b (O4/DEV-6-03): a prepared session gone before activation', () {
    const albumIntent = HistoryIntent('album', 'inst-1:1');

    Future<List<HistoryEvent>> clicks() => (db.select(db.historyEvents)
          ..where((e) => e.kind.equals('clicked')))
        .get();

    for (final (name, request) in [
      (
        'PlayList',
        const PlayList(['a', 'b'], 0, ListSource('search'),
            intent: HistoryIntent.track('a')),
      ),
      (
        'PlayQuery',
        const PlayQuery(
            source: BrowseSource('library'),
            currentUuid: 'a',
            intent: HistoryIntent.track('a')),
      ),
      (
        'PlayCollection',
        const PlayCollection(AlbumScope(artistId: 1, albumId: 1), ['a', 'b'],
            shuffle: ShuffleStart.canonical, intent: albumIntent),
      ),
    ]) {
      test('$name ends RejectedEmpty; the active queue is untouched; no click',
          () async {
        await fixture.insertSingles(['x']);
        await fixture.insertAlbum(
            artist: 'Artist', album: 'Album', uuids: ['a', 'b']);
        final c = createContainer();
        await c.read(playbackRequestsProvider)
            .submit(const PlayList(['x'], 0, ListSource('search')));
        final active = (await repo.getActiveSession())!.id;
        final seeds = fakePlayer.seedCalls.length;
        repo.beforeActivation = (sessionId) async {
          if (sessionId == active) return;
          expect(await repo.discardSession(sessionId), isTrue);
        };

        final outcome = await c.read(playbackRequestsProvider).submit(request);

        expect(outcome, isA<RejectedEmpty>());
        expect((await repo.getActiveSession())?.id, active);
        expect(c.read(queuePlayerProvider).queue.sessionId, active);
        expect(c.read(currentTrackProvider)?.uuidId, 'x');
        expect(fakePlayer.seedCalls, hasLength(seeds));
        await pumpEventQueue();
        expect(await clicks(), isEmpty);
      });
    }

    // 6-R2-11b (6-P04 failed queue creation, real path).
    test('a queue creation whose write fails: Failed, the current queue and '
        'engine untouched, no click', () async {
      await fixture.insertSingles(['x']);
      await fixture.insertAlbum(
          artist: 'Artist', album: 'Album', uuids: ['a', 'b']);
      final c = createContainer();
      await c.read(playbackRequestsProvider)
          .submit(const PlayList(['x'], 0, ListSource('search')));
      final active = (await repo.getActiveSession())!.id;
      final sessions = (await db.select(db.queueSessions).get()).length;
      final seeds = fakePlayer.seedCalls.length;
      final plays = fakePlayer.playCalls;
      repo.createSessionError = Exception('disk I/O error');

      final outcome = await c.read(playbackRequestsProvider).submit(
          const PlayCollection(AlbumScope(artistId: 1, albumId: 1), ['a', 'b'],
              shuffle: ShuffleStart.canonical, intent: albumIntent));

      expect(outcome, isA<Failed>());
      expect((await repo.getActiveSession())?.id, active);
      expect(c.read(queuePlayerProvider).queue.sessionId, active);
      expect(c.read(currentTrackProvider)?.uuidId, 'x');
      expect(fakePlayer.seedCalls, hasLength(seeds));
      expect(fakePlayer.playCalls, plays);
      expect(await db.select(db.queueSessions).get(), hasLength(sessions));
      await pumpEventQueue();
      expect(await clicks(), isEmpty);
    });

    test('a newer request still supersedes: Superseded, not RejectedEmpty',
        () async {
      await fixture.insertSingles(['x', 'y']);
      final c = createContainer();
      final requests = c.read(playbackRequestsProvider);
      final older =
          requests.submit(const PlayList(['x'], 0, ListSource('search')));
      final newer =
          requests.submit(const PlayList(['y'], 0, ListSource('search')));
      expect(await older, isA<Superseded>());
      expect(await newer, isA<Accepted>());
    });
  });


  group('6A.1b (spec §5 disappearance, D2): catalog removal between prepare '
      'and activation', () {
    const albumIntent = HistoryIntent('album', 'inst-1:1');

    Future<List<HistoryEvent>> clicks() => (db.select(db.historyEvents)
          ..where((e) => e.kind.equals('clicked')))
        .get();

    /// A playing queue over x; returns its session id.
    Future<(ProviderContainer, int)> playingX() async {
      await fixture.insertSingles(['x']);
      final c = createContainer();
      await c.read(playbackRequestsProvider)
          .submit(const PlayList(['x'], 0, ListSource('search')));
      return (c, (await repo.getActiveSession())!.id);
    }

    Future<AlbumScope> album(List<String> uuids) async {
      await fixture.insertAlbum(artist: 'Artist', album: 'Album', uuids: uuids);
      final first = await fixture.track(uuids.first);
      return AlbumScope(artistId: first.artistId!, albumId: first.albumId!);
    }

    test('review C-1: the old queue ending while a new queue activates does '
        'not advance the new queue', () async {
      final (c, active) = await playingX();
      final scope = await album(['a', 'b', 'c']);
      repo.beforeActivation = (sessionId) async {
        if (sessionId == active) return;
        repo.beforeActivation = null;
        fakePlayer.emitPlayerState(
            EngineTransportState(false, EngineProcessingState.completed));
        await pumpEventQueue();
      };
      final outcome = await c.read(playbackRequestsProvider).submit(
          PlayCollection(scope, const ['a', 'b', 'c'],
              shuffle: ShuffleStart.canonical, intent: albumIntent));
      expect(outcome, isA<Accepted>());
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 0);
    });

    test('a member removed: accepted without it, one click', () async {
      final (c, active) = await playingX();
      final scope = await album(['a', 'b', 'c']);
      repo.beforeActivation = (sessionId) async {
        if (sessionId == active) return;
        repo.beforeActivation = null;
        await repo.removeTrackUuidsFromQueues(const ['c']);
      };
      final outcome = await c.read(playbackRequestsProvider).submit(
          PlayCollection(scope, const ['a', 'b', 'c'],
              shuffle: ShuffleStart.canonical, intent: albumIntent));
      expect(outcome, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      expect((await sessionTracksOf(c)).map((e) => e.uuidId), ['a', 'b']);
      await pumpEventQueue();
      expect(await clicks(), hasLength(1));
    });

    test('the target removed: re-resolved to the next member, one click',
        () async {
      final (c, active) = await playingX();
      final scope = await album(['a', 'b', 'c']);
      repo.beforeActivation = (sessionId) async {
        if (sessionId == active) return;
        repo.beforeActivation = null;
        await repo.removeTrackUuidsFromQueues(const ['a']);
      };
      final outcome = await c.read(playbackRequestsProvider).submit(
          PlayCollection(scope, const ['a', 'b', 'c'],
              shuffle: ShuffleStart.canonical, intent: albumIntent));
      expect(outcome, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect((await sessionTracksOf(c)).map((e) => e.uuidId), ['b', 'c']);
      expect(fakePlayer.seedCalls.last.currentItemId,
          c.read(queuePlayerProvider).queue.currentItemId);
      await pumpEventQueue();
      expect((await clicks()).map((e) => e.entityType), ['album']);
    });

    test('a member before the landing target removed: the target is '
        're-read at its new position', () async {
      await fixture.insertSingles(['x']);
      await markDownloaded('x', '/dl/x');
      final scope = await album(['a', 'b', 'c']);
      await markDownloaded('b', '/dl/b');
      await markDownloaded('c', '/dl/c');
      final c = createContainer(offline: true);
      await c.read(playbackRequestsProvider)
          .submit(const PlayList(['x'], 0, ListSource('search')));
      final active = (await repo.getActiveSession())!.id;
      repo.beforeActivation = (sessionId) async {
        if (sessionId == active) return;
        repo.beforeActivation = null;
        await repo.removeTrackUuidsFromQueues(const ['a']);
      };
      final outcome = await c.read(playbackRequestsProvider).submit(
          PlayCollection(scope, const ['a', 'b', 'c'],
              shuffle: ShuffleStart.canonical, intent: albumIntent));
      expect(outcome, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(c.read(queuePlayerProvider).queue.currentPlayPosition, 0);
      final seed = fakePlayer.seedCalls.last;
      expect(seed.entries.map((e) => (e.uuidId, e.playPosition)),
          contains(('b', 0)));
      expect(seed.entries.map((e) => e.uuidId), isNot(contains('a')));
    });

    test('review r1 #1: a mid-list target removed re-resolves to its '
        'successor, not the top of the list', () async {
      final (c, active) = await playingX();
      await fixture.insertSingles(['a', 'b', 'c', 'd']);
      repo.beforeActivation = (sessionId) async {
        if (sessionId == active) return;
        repo.beforeActivation = null;
        await repo.removeTrackUuidsFromQueues(const ['c']);
      };
      final outcome = await c.read(playbackRequestsProvider).submit(
          const PlayList(['a', 'b', 'c', 'd'], 2, ListSource('search'),
              intent: HistoryIntent.track('c')));
      expect(outcome, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'd');
      expect((await sessionTracksOf(c)).map((e) => e.uuidId), ['a', 'b', 'd']);
    });

    test('review r1: a newer request admitted during a stale retry wins',
        () async {
      final (c, active) = await playingX();
      await fixture.insertSingles(['y']);
      final scope = await album(['a', 'b', 'c']);
      final requests = c.read(playbackRequestsProvider);
      Future<PlaybackOutcome>? newer;
      int? collectionSession;
      repo.beforeActivation = (sessionId) async {
        if (sessionId == active || newer != null) return;
        collectionSession = sessionId;
        await repo.removeTrackUuidsFromQueues(const ['a']);
        newer = requests
            .submit(const PlayList(['y'], 0, ListSource('search')));
      };
      final outcome = await requests.submit(PlayCollection(
          scope, const ['a', 'b', 'c'],
          shuffle: ShuffleStart.canonical, intent: albumIntent));
      expect(outcome, isA<Superseded>());
      expect(await newer!, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'y');
      expect(await repo.getSessionSnapshot(collectionSession!), isNull,
          reason: 'the prepared collection session was discarded');
      await pumpEventQueue();
      expect(await clicks(), isEmpty);
    });

    test('the whole collection removed: RejectedEmpty, queue untouched, no '
        'click, nothing left behind', () async {
      final (c, active) = await playingX();
      final scope = await album(['a', 'b', 'c']);
      final seeds = fakePlayer.seedCalls.length;
      repo.beforeActivation = (sessionId) async {
        if (sessionId == active) return;
        repo.beforeActivation = null;
        await repo.removeTrackUuidsFromQueues(const ['a', 'b', 'c']);
      };
      final outcome = await c.read(playbackRequestsProvider).submit(
          PlayCollection(scope, const ['a', 'b', 'c'],
              shuffle: ShuffleStart.random, intent: albumIntent));
      expect(outcome, isA<RejectedEmpty>());
      expect((await repo.getActiveSession())?.id, active);
      expect(c.read(currentTrackProvider)?.uuidId, 'x');
      expect(fakePlayer.seedCalls, hasLength(seeds));
      expect(await repo.pruneInactiveSessions(), 0,
          reason: 'the prepared session was discarded');
      await pumpEventQueue();
      expect(await clicks(), isEmpty);
    });

    test('the target removed on every attempt: bounded, then RejectedEmpty',
        () async {
      final (c, active) = await playingX();
      final scope = await album(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']);
      final seeds = fakePlayer.seedCalls.length;
      var attempts = 0;
      repo.beforeActivation = (sessionId) async {
        if (sessionId == active) return;
        attempts++;
        final current = (await repo.getSessionSnapshot(sessionId))?.currentItem;
        if (current != null) {
          await repo.removeTrackUuidsFromQueues([current.uuidId]);
        }
      };
      final outcome = await c.read(playbackRequestsProvider).submit(
          PlayCollection(scope, const ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'],
              shuffle: ShuffleStart.canonical, intent: albumIntent));
      expect(outcome, isA<RejectedEmpty>());
      expect(attempts, inInclusiveRange(2, 4), reason: 'a small bound');
      expect((await repo.getActiveSession())?.id, active);
      expect(c.read(currentTrackProvider)?.uuidId, 'x');
      expect(fakePlayer.seedCalls, hasLength(seeds));
      expect(await repo.pruneInactiveSessions(), 0);
      await pumpEventQueue();
      expect(await clicks(), isEmpty);
    });
  });

  group('7B.2a (SC-27 inv. 5): the library relinquishes the output', () {
    late FakeTimers timers;
    late AudioFocus focus;
    late RelinquishingOwner preview;

    setUp(() {
      timers = FakeTimers();
      focus = AudioFocus(sessionPort, timer: timers.create);
      preview = RelinquishingOwner('preview');
    });

    tearDown(() => focus.dispose());

    /// The library plays and holds the output; the fake engine never asks
    /// for focus, so the test takes it as the engine's play() would, then
    /// a preview owner binds and the engine reports playing.
    Future<QueuePlayer> libraryHolds(ProviderContainer c,
        {List<String> uuids = const ['a', 'b'], String? downloadedLast}) async {
      await fixture.insertSingles(uuids);
      if (downloadedLast != null) {
        await markDownloaded(uuids.last, downloadedLast);
      }
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, uuids, await fixture.track('a'),
          sourceType: 'search');
      expect(await focus.beforePlay(AudioOutput.queue), isTrue);
      focus.bind(AudioOutput.preview, preview);
      fakePlayer.emitPlayerState(
          const EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      return notifier;
    }

    Future<bool?> acquirePreview(void Function(bool) onAnswer) async {
      unawaited(focus.acquire(AudioOutput.preview).then(onAnswer));
      await pumpEventQueue();
      return null;
    }

    // Pre-merge A6-07: the real order. `JustAudioEngine.pause` reports "not
    // playing" inside the call, before the hand-over starts waiting for it;
    // the fake now does the same.
    test('a preview acquire pauses the library and is granted on the '
        'engine\'s own pause report, without waiting out the bound',
        () async {
      final c = createContainer(focus: focus);
      await libraryHolds(c);
      bool? granted;
      await acquirePreview((g) => granted = g);
      expect(fakePlayer.pauseCalls, 1);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
      expect(granted, isTrue,
          reason: 'the pause itself reported; nothing later is needed');
      expect(timers.active, isEmpty, reason: 'the 3 s bound never ran out');
      expect(focus.holder, AudioOutput.preview);
    });

    // Was "a preview acquire pauses the library and is granted only once the
    // engine reports it is not playing": that order (a pause whose report
    // comes later) is not one today's engine produces. Kept for the wait
    // itself: an engine that reports late still holds the grant.
    test('an engine whose pause report comes late: the preview is granted '
        'only once it reports it is not playing', () async {
      fakePlayer = _LateReportEngine();
      final c = createContainer(focus: focus);
      await libraryHolds(c);
      bool? granted;
      await acquirePreview((g) => granted = g);
      expect(fakePlayer.pauseCalls, 1);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
      expect(granted, isNull, reason: 'the engine still reports playing');
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.ready));
      await pumpEventQueue();
      expect(granted, isTrue);
      expect(focus.holder, AudioOutput.preview);
    });

    test('a hand-over whose lane step fails (its cursor save) is published '
        'as a task failure, '
        'and the preview still gets the output once the engine stops',
        () async {
      final c = createContainer(focus: focus);
      final issues = <PlaybackIssue>[];
      final sub = c.read(playbackIssueBusProvider).issues.listen(issues.add);
      addTearDown(sub.cancel);
      await libraryHolds(c);
      repo.cursorSaveError = StateError('db gone'); // the pause's cursor save
      bool? granted;
      await acquirePreview((g) => granted = g);
      expect(fakePlayer.pauseCalls, 1);
      final failures = issues.whereType<PlaybackTaskFailed>().toList();
      expect(failures.map((f) => f.task), ['relinquish']);
      expect(failures.single.error, isA<StateError>());
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.ready));
      await pumpEventQueue();
      expect(granted, isTrue);
      expect(focus.holder, AudioOutput.preview);
    });

    test('a paused library acknowledges at once', () async {
      final c = createContainer(focus: focus);
      final notifier = await libraryHolds(c);
      await notifier.pause();
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.ready));
      await pumpEventQueue();
      bool? granted;
      await acquirePreview((g) => granted = g);
      expect(granted, isTrue);
    });

    test('a quiesced library acknowledges at once', () async {
      final c = createContainer(focus: focus);
      final notifier = await libraryHolds(c);
      await notifier.quiesce();
      bool? granted;
      await acquirePreview((g) => granted = g);
      expect(granted, isTrue);
      expect(timers.active, isEmpty);
    });

    test('a late engine end after the library gave up the output advances '
        'without playing (the wrap re-report included)', () async {
      final c = createContainer(focus: focus);
      await libraryHolds(c);
      bool? granted;
      await acquirePreview((g) => granted = g);
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.ready));
      await pumpEventQueue();
      expect(granted, isTrue);
      final plays = fakePlayer.playCalls;
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(fakePlayer.playCalls, plays, reason: 'no automatic resume');
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
      expect(focus.holder, AudioOutput.preview);
    });

    test('a late offline advance after the library gave up the output does '
        'not play', () async {
      final c = createContainer(focus: focus, failingReconcile: true);
      await libraryHolds(c, uuids: const ['a', 'b', 'c'],
          downloadedLast: '/dl/c');
      bool? granted;
      await acquirePreview((g) => granted = g);
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.ready));
      await pumpEventQueue();
      expect(granted, isTrue);
      final b = (await repo.getPlaybackEntries(
              c.read(queuePlayerProvider).queue.sessionId!))
          .firstWhere((e) => e.uuidId == 'b');
      final plays = fakePlayer.playCalls;
      fakePlayer.emitUnavailableAdvance(
          UnavailableAdvance(itemId: b.itemId, playPosition: b.playPosition));
      await pumpEventQueue();
      expect(fakePlayer.stopCalls, 0, reason: 'c is playable: advanced');
      expect(fakePlayer.seekCauses.last,
          PlaybackTransitionCause.naturalAdvance);
      expect(fakePlayer.playCalls, plays);
      expect(focus.holder, AudioOutput.preview);
    });

    // Pre-merge R2-L-02: the output handed back unused (a preview that
    // never sounded was paused or closed).
    group('the output comes back unused', () {
      test('after the hand-over: the library plays again what the hand-over '
          'paused, without a new seed or seek', () async {
        final c = createContainer(focus: focus);
        await libraryHolds(c);
        bool? granted;
        await acquirePreview((g) => granted = g);
        expect(granted, isTrue);
        expect(c.read(audioPlayWhenReadyProvider), isFalse);
        final plays = fakePlayer.playCalls;
        final seeds = fakePlayer.seedCalls.length;
        focus.handBack(AudioOutput.preview);
        await pumpEventQueue();
        expect(fakePlayer.playCalls, plays + 1);
        expect(c.read(audioPlayWhenReadyProvider), isTrue);
        expect(focus.holder, AudioOutput.queue);
        expect(fakePlayer.seedCalls, hasLength(seeds));
        expect(fakePlayer.seekedItems, isEmpty);
      });

      test('while the hand-over waits behind a busy lane: the library is '
          'never paused and nothing is played twice', () async {
        final c = createContainer(focus: focus);
        await libraryHolds(c);
        final gate = Completer<void>();
        fakePlayer.beforeSeed = (_) => gate.future; // the lane is busy
        unawaited(playFromTrackList(c, const ['a', 'b'],
            await fixture.track('a'), sourceType: 'search'));
        await pumpEventQueue();
        bool? granted;
        await acquirePreview((g) => granted = g);
        expect(granted, isNull);
        final plays = fakePlayer.playCalls;
        focus.handBack(AudioOutput.preview);
        await pumpEventQueue();
        expect(granted, isFalse);
        gate.complete();
        fakePlayer.beforeSeed = null;
        await pumpEventQueue();
        expect(fakePlayer.pauseCalls, 0);
        expect(fakePlayer.playCalls, plays + 1,
            reason: 'only the play of the queue that was being started');
        expect(c.read(audioPlayWhenReadyProvider), isTrue);
      });

      test('after the library paused but before it acknowledged: it plays '
          'again', () async {
        fakePlayer = _LateReportEngine();
        final c = createContainer(focus: focus);
        await libraryHolds(c);
        bool? granted;
        await acquirePreview((g) => granted = g);
        expect(fakePlayer.pauseCalls, 1);
        expect(granted, isNull);
        final plays = fakePlayer.playCalls;
        focus.handBack(AudioOutput.preview);
        await pumpEventQueue();
        expect(granted, isFalse);
        expect(fakePlayer.playCalls, plays + 1);
        expect(c.read(audioPlayWhenReadyProvider), isTrue);
      });

      // Re-check finding R1: while the hand-over is still pending the
      // library hears an unplug or an interruption too; whatever the preview
      // does afterwards, the music must not start by itself.
      for (final (what, event) in <(String, AudioSessionEvent)>[
        ('headphones were unplugged', const AudioBecameNoisy()),
        ('an OS interruption began',
            const AudioInterruptionBegan(AudioInterruptionKind.pause)),
      ]) {
        test('$what while the hand-over was pending: the library does not '
            'play again when the output comes back', () async {
          fakePlayer = _LateReportEngine();
          final c = createContainer(focus: focus);
          await libraryHolds(c);
          bool? granted;
          await acquirePreview((g) => granted = g);
          expect(fakePlayer.pauseCalls, 1);
          expect(granted, isNull, reason: 'precondition: still pending');
          sessionPort.emit(event);
          await pumpEventQueue();
          final plays = fakePlayer.playCalls;
          focus.handBack(AudioOutput.preview);
          await pumpEventQueue();
          expect(fakePlayer.playCalls, plays);
          expect(c.read(audioPlayWhenReadyProvider), isFalse);
        });
      }

      // Pre-merge R3-L-01: the leave path must not touch a player that is
      // already gone (a page left while the session scope is torn down).
      test('the output comes back as the player is disposed: nothing is '
          'played and no error is raised', () async {
        // A bus the container does not close, so that a failure reported
        // after the dispose is still seen.
        final bus = PlaybackIssueBus();
        addTearDown(bus.dispose);
        final issues = <PlaybackIssue>[];
        final sub = bus.issues.listen(issues.add);
        addTearDown(sub.cancel);
        final c = createContainer(focus: focus, extraOverrides: [
          playbackIssueBusProvider.overrideWithValue(bus),
        ]);
        await libraryHolds(c);
        bool? granted;
        await acquirePreview((g) => granted = g);
        expect(granted, isTrue);
        final plays = fakePlayer.playCalls;
        final errors = <Object>[];
        await runZonedGuarded(() async {
          focus.handBack(AudioOutput.preview);
          c.dispose();
          container = null;
          await pumpEventQueue();
        }, (error, _) => errors.add(error));
        expect(errors, isEmpty);
        expect(issues.whereType<PlaybackTaskFailed>().map((f) => f.task),
            isEmpty, reason: 'the disposed player was not touched');
        expect(fakePlayer.playCalls, plays);
      });

      test('a library that was paused before the hand-over stays paused',
          () async {
        final c = createContainer(focus: focus);
        final notifier = await libraryHolds(c);
        await notifier.pause();
        await pumpEventQueue();
        bool? granted;
        await acquirePreview((g) => granted = g);
        expect(granted, isTrue);
        final plays = fakePlayer.playCalls;
        focus.handBack(AudioOutput.preview);
        await pumpEventQueue();
        expect(fakePlayer.playCalls, plays);
        expect(c.read(audioPlayWhenReadyProvider), isFalse);
      });

      test('a library the person paused after the hand-over stays paused',
          () async {
        final c = createContainer(focus: focus);
        final notifier = await libraryHolds(c);
        bool? granted;
        await acquirePreview((g) => granted = g);
        expect(granted, isTrue);
        await notifier.pause();
        final plays = fakePlayer.playCalls;
        focus.handBack(AudioOutput.preview);
        await pumpEventQueue();
        expect(fakePlayer.playCalls, plays);
        expect(c.read(audioPlayWhenReadyProvider), isFalse);
      });

      test('a library stopped after the hand-over stays stopped', () async {
        final c = createContainer(focus: focus);
        final notifier = await libraryHolds(c);
        bool? granted;
        await acquirePreview((g) => granted = g);
        expect(granted, isTrue);
        await notifier.stop();
        final plays = fakePlayer.playCalls;
        focus.handBack(AudioOutput.preview);
        await pumpEventQueue();
        expect(fakePlayer.playCalls, plays);
        expect(c.read(queuePlayerProvider).queue.sessionId, isNull);
      });
    });

    test('R1-02: a transfer refused at the bound does not pause the library '
        'later', () async {
      final c = createContainer(focus: focus);
      await libraryHolds(c);
      final gate = Completer<void>();
      fakePlayer.beforeSeed = (_) => gate.future; // the lane is busy
      unawaited(playFromTrackList(c, const ['b'], await fixture.track('b'),
          sourceType: 'search'));
      await pumpEventQueue();
      bool? granted;
      await acquirePreview((g) => granted = g);
      timers.fireAll();
      await pumpEventQueue();
      expect(granted, isFalse);
      gate.complete();
      fakePlayer.beforeSeed = null;
      await pumpEventQueue();
      expect(fakePlayer.pauseCalls, 0,
          reason: 'the library kept the output, so it keeps playing');
      expect(c.read(audioPlayWhenReadyProvider), isTrue);
      expect(focus.holder, AudioOutput.queue);
    });

    test('R1-04: while the library is still stopping, the relinquish waits '
        'for the stop', () async {
      final c = createContainer(focus: focus);
      final notifier = await libraryHolds(c);
      final gate = Completer<void>();
      fakePlayer.beforeSeed = (_) => gate.future; // the lane is busy
      unawaited(playFromTrackList(c, const ['b'], await fixture.track('b'),
          sourceType: 'search'));
      await pumpEventQueue();
      final quiescing = notifier.quiesce();
      bool? granted;
      await acquirePreview((g) => granted = g);
      expect(granted, isNull, reason: 'the library is still audible');
      gate.complete();
      fakePlayer.beforeSeed = null;
      await quiescing;
      await pumpEventQueue();
      expect(granted, isTrue);
    });

    test('no overlap while the library is mid-load: the relinquish cancels '
        'its queued play, so it never starts once preview holds', () async {
      final output = <String>[];
      final plugin = _GatedPlugin(output);
      final engine = JustAudioEngine(plugin,
          beforePlay: () => focus.beforePlay(AudioOutput.queue));
      final c = createContainer(engine: engine, focus: focus);
      await fixture.insertSingles(['a']);
      await playFromTrackList(c, const ['a'], await fixture.track('a'),
          sourceType: 'search');
      expect(c.read(audioPlayWhenReadyProvider), isTrue,
          reason: 'play desired, its load stalled');
      final owner = _OutputPreview(output);
      focus.bind(AudioOutput.preview, owner);
      expect(await focus.acquire(AudioOutput.preview), isTrue);
      output.add('preview on');
      plugin.finishLoad();
      await pumpEventQueue();
      expect(output, isNot(contains('library on')),
          reason: 'the queued library play was cancelled by the relinquish');
      expect(focus.holder, AudioOutput.preview);
      _expectNoOverlap(output);
    });

    // The order 7-R1-23 was first written for: the library's pause ran, and
    // the preview closed before the acknowledgement. With today's engine that
    // window is the pause's cursor save (the pause itself reports at once);
    // an engine that reports late stands in for it here.
    test('7-R1-23: preview closed after the library paused but before it '
        'acknowledged: after the user resumes, the next natural end still '
        'plays on', () async {
      fakePlayer = _LateReportEngine();
      final c = createContainer(focus: focus);
      final notifier = await libraryHolds(c, uuids: const ['a', 'b', 'c']);
      bool? granted;
      await acquirePreview((g) => granted = g);
      expect(fakePlayer.pauseCalls, 1, reason: 'the relinquish paused');
      focus.giveUp(AudioOutput.preview); // preview closed before the ack
      await pumpEventQueue();
      expect(granted, isFalse);
      expect(focus.holder, AudioOutput.queue);
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.ready));
      await pumpEventQueue();

      await notifier.resume();
      fakePlayer.emitPlayerState(
          const EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      final plays = fakePlayer.playCalls;
      fakePlayer.emitPlayerState(
          const EngineTransportState(true, EngineProcessingState.completed));
      await pumpEventQueue();

      expect(fakePlayer.playCalls, greaterThan(plays),
          reason: 'the library holds the output again: its advance plays');
      expect(c.read(audioPlayWhenReadyProvider), isTrue);
      expect(focus.holder, AudioOutput.queue);
    });

    // Changed with the fake's pause report (pre-merge A6-07). It used to
    // pause, leave the engine "still playing", then close the preview: with
    // a pause reported inside the call the hand-over is already granted by
    // then. The preview can still close before the acknowledgement while the
    // library's lane is busy, so the pause has not run yet; that is the
    // order here. The rule it guards is the same: a transfer that was
    // superseded gave nothing away.
    test('7-R1-23: preview closed before the library acknowledged (its lane '
        'was still busy): the library is not paused, and the next natural '
        'end still plays on', () async {
      final c = createContainer(focus: focus);
      await libraryHolds(c, uuids: const ['a', 'b', 'c']);
      final gate = Completer<void>();
      fakePlayer.beforeSeed = (_) => gate.future; // the lane is busy
      unawaited(playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('a'), sourceType: 'search'));
      await pumpEventQueue();
      bool? granted;
      await acquirePreview((g) => granted = g);
      expect(granted, isNull, reason: 'the pause waits behind the lane');
      focus.giveUp(AudioOutput.preview); // preview closed before the ack
      await pumpEventQueue();
      expect(granted, isFalse);
      expect(focus.holder, AudioOutput.queue);
      gate.complete();
      fakePlayer.beforeSeed = null;
      await pumpEventQueue();
      expect(fakePlayer.pauseCalls, 0,
          reason: 'the library gave nothing away: it keeps playing');

      fakePlayer.emitPlayerState(
          const EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      final plays = fakePlayer.playCalls;
      fakePlayer.emitPlayerState(
          const EngineTransportState(true, EngineProcessingState.completed));
      await pumpEventQueue();

      expect(fakePlayer.playCalls, greaterThan(plays),
          reason: 'the library still holds the output: its advance plays');
      expect(c.read(audioPlayWhenReadyProvider), isTrue);
      expect(focus.holder, AudioOutput.queue);
    });
  });

  // Was "7B.2a exit proof: preview and the library never overlap (7-U10, 7-L06)".
  group('preview and the library never overlap', () {
    late AudioFocus focus;
    late List<String> output;
    late _GatedPlugin plugin;
    late List<_LoggingPreviewEngine> previews;
    late _SpyRequests requests;
    late _SpyClicks clickSpy;

    setUp(() {
      focus = AudioFocus(sessionPort, timer: FakeTimers().create);
      output = [];
      plugin = _GatedPlugin(output);
      previews = [];
    });

    tearDown(() => focus.dispose());

    ProviderContainer previewContainer() => createContainer(
          engine: JustAudioEngine(plugin,
              beforePlay: () => focus.beforePlay(AudioOutput.queue)),
          focus: focus,
          extraOverrides: [
            previewSourceUrisProvider.overrideWithValue(PreviewSourceUris(
              baseUrl: 'http://audio.test',
              mediaToken: 'mt',
              mayAttachToken: () async => true,
              isOffline: () => false,
            )),
            previewEngineFactoryProvider.overrideWithValue(() {
              final engine = _LoggingPreviewEngine(output);
              previews.add(engine);
              return engine;
            }),
            playbackRequestsProvider
                .overrideWith((ref) => requests = _SpyRequests(ref)),
            clickRecorderProvider.overrideWith((ref) => clickSpy = _SpyClicks(
                history: ref.read(historyRepositoryProvider),
                binding: ServerBindingRepository(db),
                clock: ref.read(clockProvider))),
          ],
        );

    /// The library plays track a (its load finished, output on).
    Future<ProviderContainer> libraryPlaying() async {
      await fixture.insertSingles(['a']);
      final c = previewContainer();
      c.listen(previewPlayerProvider, (_, _) {});
      await playFromTrackList(c, const ['a'], await fixture.track('a'),
          sourceType: 'search');
      plugin.finishLoad();
      await pumpEventQueue();
      expect(output, ['library on']);
      return c;
    }

    Future<void> previewPlaying(ProviderContainer c) async {
      unawaited(c.read(previewControlsProvider).playStaged('i1'));
      await pumpEventQueue();
      previews.last.finishLoad(null);
      await pumpEventQueue();
      expect(c.read(previewPlayerProvider).status, PreviewStatus.playing);
    }

    test('opening preview pauses the library first; preview sounds only '
        'after that', () async {
      final c = await libraryPlaying();
      unawaited(c.read(previewControlsProvider).playStaged('i1'));
      await pumpEventQueue();
      previews.last.finishLoad(null);
      await pumpEventQueue();
      expect(output, ['library on', 'library off', 'preview on']);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
      _expectNoOverlap(output);
    });

    test('an OS play during preview stops preview first, then the library '
        'plays', () async {
      final c = await libraryPlaying();
      await previewPlaying(c);
      await c.read(playerControlsProvider).click(MediaButton.media);
      await pumpEventQueue();
      expect(output.sublist(output.length - 2), ['preview off', 'library on']);
      expect(c.read(previewPlayerProvider).status, PreviewStatus.idle);
      expect(focus.holder, AudioOutput.queue);
      _expectNoOverlap(output);
    });

    test('an interruption during preview routes to preview and never resumes '
        'the library', () async {
      final c = await libraryPlaying();
      await previewPlaying(c);
      sessionPort.emit(
          const AudioInterruptionBegan(AudioInterruptionKind.pause));
      await pumpEventQueue();
      sessionPort.emit(
          const AudioInterruptionEnded(AudioInterruptionKind.pause));
      await pumpEventQueue();
      expect(previews.last.pauses, 1);
      expect(c.read(previewPlayerProvider).status, PreviewStatus.playing);
      expect(output.where((e) => e == 'library on'), hasLength(1),
          reason: 'the library never resumed');
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
      expect(focus.holder, AudioOutput.preview);
      _expectNoOverlap(output);
    });

    // Pre-merge R2-L-02 (live case R5: Play preview, Pause 20 ms later).
    group('a preview that never sounded gives the music back', () {
      List<String> library() =>
          [for (final e in output) if (e.startsWith('library')) e];

      /// Music plays; a preview is started and still loads (the library has
      /// already handed the output over).
      Future<ProviderContainer> previewLoading() async {
        final c = await libraryPlaying();
        unawaited(c.read(previewControlsProvider).playStaged('i1'));
        await pumpEventQueue();
        expect(library(), ['library on', 'library off']);
        expect(c.read(previewPlayerProvider).status, PreviewStatus.loading);
        return c;
      }

      void expectMusicPlaysOn(ProviderContainer c) {
        expect(library(), ['library on', 'library off', 'library on']);
        expect(output, isNot(contains('preview on')));
        expect(c.read(audioPlayWhenReadyProvider), isTrue);
        expect(focus.holder, AudioOutput.queue);
        expect(c.read(currentTrackProvider)?.uuidId, 'a');
        expect(plugin.loadCalls, 1, reason: 'the same track, never reloaded');
        verifyNever(() => plugin.seek(any(), index: any(named: 'index')));
        _expectNoOverlap(output);
      }

      test('paused while it still loads: the music plays on, same track and '
          'position; Resume then pauses the music and plays the preview',
          () async {
        final c = await previewLoading();
        await c.read(previewControlsProvider).pause();
        await pumpEventQueue();
        expectMusicPlaysOn(c);
        expect(c.read(previewPlayerProvider).status, PreviewStatus.paused);
        previews.last.finishLoad(null); // the late load never sounds
        await pumpEventQueue();
        expectMusicPlaysOn(c);

        unawaited(c.read(previewControlsProvider).resume());
        await pumpEventQueue();
        previews.last.finishLoad(null);
        await pumpEventQueue();
        expect(library().last, 'library off');
        expect(output.last, 'preview on');
        expect(c.read(previewPlayerProvider).status, PreviewStatus.playing);
        _expectNoOverlap(output);
      });

      test('closed while it still loads: the music plays on', () async {
        final c = await previewLoading();
        await c.read(previewControlsProvider).close();
        await pumpEventQueue();
        expectMusicPlaysOn(c);
        expect(c.read(previewPlayerProvider).status, PreviewStatus.idle);
      });

      // Review finding 1: an unplug or an OS interruption reaches only the
      // preview while it holds the output; a later close must not start the
      // music (from the speaker, or during a call).
      for (final (what, event) in <(String, AudioSessionEvent)>[
        ('headphones were unplugged', const AudioBecameNoisy()),
        ('an OS interruption began',
            const AudioInterruptionBegan(AudioInterruptionKind.pause)),
      ]) {
        test('$what while it loaded: closing it afterwards does not start '
            'the music', () async {
          final c = await previewLoading();
          sessionPort.emit(event);
          await pumpEventQueue();
          expect(c.read(previewPlayerProvider).status, PreviewStatus.paused);
          await c.read(previewControlsProvider).close();
          await pumpEventQueue();
          expect(library(), ['library on', 'library off']);
          expect(c.read(audioPlayWhenReadyProvider), isFalse);
        });
      }

      test('music that was paused before the preview stays paused',
          () async {
        final c = await libraryPlaying();
        await c.read(queuePlayerProvider.notifier).pause();
        await pumpEventQueue();
        unawaited(c.read(previewControlsProvider).playStaged('i1'));
        await pumpEventQueue();
        await c.read(previewControlsProvider).pause();
        await pumpEventQueue();
        expect(library().where((e) => e == 'library on'), hasLength(1));
        expect(c.read(audioPlayWhenReadyProvider), isFalse);
      });

      test('music the person paused while the preview loaded stays paused',
          () async {
        final c = await previewLoading();
        await c.read(queuePlayerProvider.notifier).pause();
        await pumpEventQueue();
        await c.read(previewControlsProvider).pause();
        await pumpEventQueue();
        expect(library().where((e) => e == 'library on'), hasLength(1));
        expect(c.read(audioPlayWhenReadyProvider), isFalse);
      });
    });

    test('closing preview leaves the library paused', () async {
      final c = await libraryPlaying();
      await previewPlaying(c);
      await c.read(previewControlsProvider).close();
      await pumpEventQueue();
      expect(output.last, 'preview off');
      expect(output.where((e) => e == 'library on'), hasLength(1));
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
    });

    test('preview never submits a playback request, records a click or '
        'writes history, and never touches the queue', () async {
      final c = await libraryPlaying();
      c.read(clickRecorderProvider); // builds the spy
      final submits = requests.submits;
      final clicks = clickSpy.records;
      final events = (await db.select(db.historyEvents).get()).length;
      final session = c.read(queuePlayerProvider).queue.sessionId;
      final seeds = plugin.loadCalls;
      await previewPlaying(c);
      await c.read(previewControlsProvider).pause();
      await c.read(previewControlsProvider).resume();
      unawaited(c.read(previewControlsProvider).playLibraryTrack('a'));
      await pumpEventQueue();
      previews.last.finishLoad(null);
      await pumpEventQueue();
      await c.read(previewControlsProvider).close();
      await pumpEventQueue();
      expect(requests.submits, submits);
      expect(clickSpy.records, clicks);
      expect((await db.select(db.historyEvents).get()).length, events);
      expect(c.read(queuePlayerProvider).queue.sessionId, session);
      expect(plugin.loadCalls, seeds, reason: 'no queue rows or reloads');
      expect(previews.expand((e) => e.loads).map((u) => u.path), [
        '/tracks/uploads/items/i1/preview',
        '/tracks/a/stream',
      ]);
    });
  });

  // 7P.1 (SC-27 §6 row 1): a typed engine command failure is published and,
  // when the engine diverged, answered by a rebuild from queue data: a new
  // seed around the item the core asked for, never a natural advance.
  // 7P.2 (5B.0d m6): a failed load is classified by the source the engine
  // built (the load event names it), never by the catalog's recorded path.
  group('7P.2 m6: a load failure is classified by the source the engine '
      'built', () {
    test('a streamed seed of a recorded download that fails to load is a '
        'stream failure, not a damaged file', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a'); // recorded and on disk
      final c = createContainer();
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      final queue = c.read(queuePlayerProvider).queue;
      fakePlayer.emitLoadEvent(EngineLoadEvent(
        playlistRevision: fakePlayer.seedRevision,
        outcome: EngineLoadOutcome.failed,
        // The engine streamed it (no local path).
        source: EngineSourceIdentity(
            sourceId: 41,
            sessionId: queue.sessionId,
            itemId: queue.currentItemId!,
            trackUuid: 'a'),
      ));
      await pumpEventQueue();

      final kinds = [
        for (final i in issues.whereType<PlaybackSourceFailed>()) i.kind
      ];
      expect(kinds, hasLength(1));
      expect(kinds.single,
          isNot(anyOf(SourceFailureKind.damagedLocalFile,
              SourceFailureKind.missingLocalFile)),
          reason: 'the failing source was a stream');
      expect(c.read(localSourcePolicyProvider).isSuspect('a', '/dl/a'),
          isFalse, reason: 'no suspicion against a file that never played');
      expect(fakePlayer.refreshedSources, isEmpty,
          reason: 'no file-to-stream fallback for a stream');
    });
  });

  // 7P.2 exit proof (SC-27 §6 "one local-vs-remote decision point"): the
  // resolver's verdict reaches the engine, which never second-guesses it
  // from the recorded download.
  group('7P.2 exit proof: the target source kind reaches the engine', () {
    Future<String?> recordedPath(String uuid) async =>
        (await (db.select(db.tracks)..where((t) => t.uuidId.equals(uuid)))
                .getSingle())
            .filePath;

    test('a remote target for a track with a recorded file_path streams '
        '(real engine)', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      existingFiles.remove('/dl/a'); // recorded, but gone from disk
      final plugin = _ScriptedPlugin();
      final engine = JustAudioEngine(plugin);
      addTearDown(engine.dispose);
      // The catalog can't be corrected, so the path stays recorded.
      final c = createContainer(engine: engine, failingReconcile: true);
      final issues = <PlaybackIssue>[];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'search');
      await pumpEventQueue();

      expect(await recordedPath('a'), '/dl/a', reason: 'precondition');
      expect(issues, contains(const LocalFileMissing('a', '/dl/a')),
          reason: 'the resolver decided remote');
      final load = plugin.loads.single;
      final current = load.uris[load.initialIndex];
      expect(current.scheme, isNot('file'),
          reason: 'the engine streams what the resolver said is remote');
      expect(current.path, endsWith('tracks/a/stream'));
      final item = c.read(queuePlayerProvider).queue.currentItemId!;
      expect(engine.sourceKindOf(item), PlaybackSourceKind.remote);
    });

    test('the start applies the resolved kind: local for a download on '
        'disk, remote for a stream', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'search');
      expect(fakePlayer.seedCalls.last.currentSourceKind,
          PlaybackSourceKind.local);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('b'),
          sourceType: 'search');
      expect(fakePlayer.seedCalls.last.currentSourceKind,
          PlaybackSourceKind.remote);
    });

    test('an online restore resolves its landing: a recorded download gone '
        'from disk is restored as the stream', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      existingFiles.remove('/dl/a');
      final sessionId = await repo.createSessionFromExplicitList(
        sourceType: 'search',
        trackUuids: const ['a', 'b'],
        currentIndex: 0,
      );
      final snapshot = await repo.getSessionSnapshot(sessionId);
      await repo.updatePlaybackCursor(
        sessionId: sessionId,
        currentItemId: snapshot!.currentItem!.itemId,
        positionMs: 42000,
      );

      final c = createContainer(failingReconcile: true);
      c.read(queuePlayerProvider);
      await pumpEventQueue();

      expect(fakePlayer.seedCalls, hasLength(1));
      expect(fakePlayer.seedCalls.single.currentSourceKind,
          PlaybackSourceKind.remote);
      expect(fakePlayer.seedCalls.single.initialPosition,
          const Duration(seconds: 42), reason: 'the same item, kept');
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
    });
  });

  // 7P.2: every landing the core resolves applies the resolver's kind; a
  // reseed without a new decision keeps the kind the engine applied.
  group('7P.2 every landing applies its kind', () {
    /// a (stream), b (recorded, gone from disk; the catalog can't be
    /// corrected), c (stream); playing a.
    Future<(ProviderContainer, QueuePlayer, List<int>)> playingA() async {
      await fixture.insertSingles(['a', 'b', 'c']);
      await markDownloaded('b', '/dl/b');
      existingFiles.remove('/dl/b');
      final c = createContainer(failingReconcile: true);
      await playFromTrackList(c, const ['a', 'b', 'c'],
          await fixture.track('a'), sourceType: 'search');
      await pumpEventQueue();
      final items = [for (final t in await sessionTracksOf(c)) t.itemId];
      expect(fakePlayer.sourceKindOf(items[1]), PlaybackSourceKind.local,
          reason: 'precondition: b is loaded by the rule as its file');
      return (c, c.read(queuePlayerProvider.notifier), items);
    }

    test('a skip onto a loaded source of the other kind reseeds it as the '
        'target says', () async {
      final (_, notifier, items) = await playingA();
      await notifier.skipNext();
      await pumpEventQueue();
      final seed = fakePlayer.seedCalls.last;
      expect((seed.currentItemId, seed.currentSourceKind),
          (items[1], PlaybackSourceKind.remote));
      expect(fakePlayer.sourceKindOf(items[1]), PlaybackSourceKind.remote);
    });

    test('an online tap resolves its landing and applies the kind', () async {
      final (_, notifier, items) = await playingA();
      await notifier.skipToTrack(items[1]);
      await pumpEventQueue();
      final seed = fakePlayer.seedCalls.last;
      expect((seed.currentItemId, seed.currentSourceKind),
          (items[1], PlaybackSourceKind.remote));
    });

    test('a landing on a loaded source of the same kind is a plain seek, '
        'not a reseed', () async {
      final (c, notifier, items) = await playingA();
      final seeds = fakePlayer.seedCalls.length;
      await notifier.skipToTrack(items[2]); // c: a stream, loaded as one
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds), reason: 'no reseed');
      expect(fakePlayer.seekedItems.last, items[2]);
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
    });

    Future<(ProviderContainer, QueuePlayer)> playingRemoteA() async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      existingFiles.remove('/dl/a');
      final c = createContainer(failingReconcile: true);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'search');
      await pumpEventQueue();
      expect(fakePlayer.seedCalls.last.currentSourceKind,
          PlaybackSourceKind.remote, reason: 'precondition');
      return (c, c.read(queuePlayerProvider.notifier));
    }

    test('a rebuild after an engine command failure keeps the applied kind',
        () async {
      final (_, _) = await playingRemoteA();
      final seeds = fakePlayer.seedCalls.length;
      fakePlayer.emitCommandFailure(EngineCommandFailure(
        runtimeId: fakePlayer.runtimeId,
        seedRevision: fakePlayer.seedRevision,
        playlistRevision: fakePlayer.playlistRevision,
        command: EngineCommand.insert,
        reason: EngineCommandFailureReason.failed,
        diverged: true,
      ));
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1), reason: 'rebuilt');
      expect(fakePlayer.seedCalls.last.currentSourceKind,
          PlaybackSourceKind.remote,
          reason: 'the rebuild does not re-decide behind the resolver');
    });

    test('a sync reconcile that keeps the current item keeps its kind',
        () async {
      final (c, notifier) = await playingRemoteA();
      final seeds = fakePlayer.seedCalls.length;
      await notifier.reconcileAfterSyncQueueMutation(
          {c.read(queuePlayerProvider).queue.sessionId!});
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.seedCalls.last.currentSourceKind,
          PlaybackSourceKind.remote);
    });
  });

  group('7P.1 rebuild from queue data', () {
    late List<PlaybackIssue> issues;

    Future<QueuePlayer> started(ProviderContainer c,
        {List<String> uuids = const ['a', 'b', 'c'], bool playing = true}) async {
      issues = [];
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      await fixture.insertSingles(uuids);
      await playFromTrackList(c, uuids, await fixture.track(uuids.first),
          sourceType: 'search');
      final notifier = c.read(queuePlayerProvider.notifier);
      if (!playing) await notifier.pause();
      fakePlayer.emitPlayerState(
          EngineTransportState(playing, EngineProcessingState.ready));
      await pumpEventQueue();
      return notifier;
    }

    int itemOf(ProviderContainer c) =>
        c.read(queuePlayerProvider).queue.currentItemId!;

    EngineCommandFailure failure({
      required EngineCommand? command,
      EngineCommandFailureReason reason = EngineCommandFailureReason.failed,
      bool diverged = true,
      int? itemId,
      Duration? position,
      PlaybackTransitionCause? cause,
      int? seedRevision,
    }) =>
        EngineCommandFailure(
          runtimeId: fakePlayer.runtimeId,
          seedRevision: seedRevision ?? fakePlayer.seedRevision,
          playlistRevision: fakePlayer.playlistRevision,
          command: command,
          reason: reason,
          diverged: diverged,
          target: itemId == null
              ? null
              : EngineCommandTarget(
                  itemId: itemId,
                  trackUuid: 'x',
                  sourceKind: PlaybackSourceKind.remote),
          position: position,
          cause: cause,
        );

    test('a failed insert while playing reseeds the current item at its '
        'position from queue data and plays on', () async {
      final c = createContainer();
      await started(c);
      final current = itemOf(c);
      fakePlayer.emitPosition(const Duration(seconds: 42));
      final seeds = fakePlayer.seedCalls.length;
      final plays = fakePlayer.playCalls;
      final reported = failure(
          command: EngineCommand.insert,
          itemId: current + 2,
          cause: PlaybackTransitionCause.queueEdit);
      fakePlayer.emitCommandFailure(reported);
      await pumpEventQueue();

      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      final seed = fakePlayer.seedCalls.last;
      expect(seed.currentItemId, current);
      expect(seed.initialPosition, const Duration(seconds: 42));
      expect(seed.cause, PlaybackTransitionCause.reconcileContinuation,
          reason: 'a same-item rebuild continues the listen');
      expect(seed.entries.map((e) => e.itemId), contains(current + 2),
          reason: 'entries come from the queue, not the engine');
      expect(fakePlayer.playCalls, greaterThan(plays));
      expect(c.read(queuePlayerProvider).queue.currentItemId, current);
      expect(issues.whereType<PlaybackEngineCommandFailed>().single.failure,
          same(reported));
    });

    test('a paused queue is rebuilt paused (a restore never starts audio)',
        () async {
      final c = createContainer();
      await started(c, playing: false);
      final plays = fakePlayer.playCalls;
      final seeds = fakePlayer.seedCalls.length;
      fakePlayer.emitCommandFailure(
          failure(command: EngineCommand.remove, itemId: itemOf(c) + 1));
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.seedCalls.last.autoPlay, isFalse);
      expect(fakePlayer.playCalls, plays);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
    });

    test('a dropped skip lands on the item the user asked for, as a skip',
        () async {
      final c = createContainer();
      final notifier = await started(c);
      await notifier.skipNext();
      await pumpEventQueue();
      final target = itemOf(c);
      final seeds = fakePlayer.seedCalls.length;
      fakePlayer.emitCommandFailure(failure(
          command: EngineCommand.seek,
          reason: EngineCommandFailureReason.dropped,
          itemId: target,
          position: Duration.zero,
          cause: PlaybackTransitionCause.userSkip));
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      final seed = fakePlayer.seedCalls.last;
      expect(seed.currentItemId, target);
      expect(seed.initialPosition, Duration.zero);
      expect(seed.cause, PlaybackTransitionCause.userSkip);
    });

    test('a dropped seek is rebuilt at the asked position', () async {
      final c = createContainer();
      final notifier = await started(c);
      await notifier.seek(const Duration(seconds: 30));
      fakePlayer.emitPosition(const Duration(seconds: 1));
      fakePlayer.emitCommandFailure(failure(
          command: EngineCommand.seek,
          reason: EngineCommandFailureReason.dropped,
          itemId: itemOf(c),
          position: const Duration(seconds: 30),
          cause: PlaybackTransitionCause.userSeek));
      await pumpEventQueue();
      final seed = fakePlayer.seedCalls.last;
      expect(seed.currentItemId, itemOf(c));
      expect(seed.initialPosition, const Duration(seconds: 30));
      expect(seed.cause, PlaybackTransitionCause.reconcileContinuation);
    });

    test('repeat-one: a dropped restart seek rebuilds the same item at its '
        'start and keeps the native loop', () async {
      final c = createContainer();
      final notifier = await started(c);
      await notifier.cycleQueueRepeatMode(); // all
      await notifier.cycleQueueRepeatMode(); // one
      await notifier.skipNext(); // a restart under repeat-one
      final current = itemOf(c);
      fakePlayer.emitCommandFailure(failure(
          command: EngineCommand.seek,
          reason: EngineCommandFailureReason.dropped,
          itemId: current,
          position: Duration.zero,
          cause: PlaybackTransitionCause.userSeek));
      await pumpEventQueue();
      final seed = fakePlayer.seedCalls.last;
      expect(seed.currentItemId, current);
      expect(seed.initialPosition, Duration.zero);
      expect(seed.cause, PlaybackTransitionCause.reconcileContinuation);
      expect(fakePlayer.lastLoopMode, EngineLoopMode.one);
    });

    test('a failed pause is rebuilt paused', () async {
      final c = createContainer();
      final notifier = await started(c);
      await notifier.pause();
      final plays = fakePlayer.playCalls;
      final seeds = fakePlayer.seedCalls.length;
      fakePlayer.emitCommandFailure(
          failure(command: EngineCommand.pause, itemId: itemOf(c)));
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.playCalls, plays);
    });

    test('a failure that leaves the playlist intact is only published',
        () async {
      final c = createContainer();
      await started(c);
      final seeds = fakePlayer.seedCalls.length;
      for (final command in [
        EngineCommand.play,
        EngineCommand.stop,
        EngineCommand.setLoopMode,
        EngineCommand.setVolume,
      ]) {
        fakePlayer.emitCommandFailure(
            failure(command: command, diverged: false));
      }
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds));
      expect(issues.whereType<PlaybackEngineCommandFailed>(), hasLength(4));
    });

    test('a failure of a playlist a newer seed replaced is dropped, and a '
        'duplicate rebuilds once', () async {
      final c = createContainer();
      await started(c);
      final old = failure(command: EngineCommand.insert, itemId: 1);
      // A new session replaces the playlist the failure was about.
      await playFromTrackList(c, ['c', 'b'], await fixture.track('c'),
          sourceType: 'search');
      await pumpEventQueue();
      final seeds = fakePlayer.seedCalls.length;
      fakePlayer.emitCommandFailure(old);
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds), reason: 'stale');

      final current = failure(command: EngineCommand.insert, itemId: 1);
      fakePlayer.emitCommandFailure(current);
      fakePlayer.emitCommandFailure(current);
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1), reason: 'once');
    });

    for (final quiesce in [false, true]) {
      test('after ${quiesce ? 'quiesce' : 'stop'} a late failure rebuilds '
          'nothing', () async {
        final c = createContainer();
        final notifier = await started(c);
        final late = failure(command: EngineCommand.insert, itemId: 1);
        if (quiesce) {
          await notifier.quiesce();
        } else {
          await notifier.stop();
        }
        final seeds = fakePlayer.seedCalls.length;
        final plays = fakePlayer.playCalls;
        fakePlayer.emitCommandFailure(late);
        await pumpEventQueue();
        expect(fakePlayer.seedCalls, hasLength(seeds));
        expect(fakePlayer.playCalls, plays);
      });
    }

    test('while the library has yielded the output a rebuild never plays',
        () async {
      final timers = FakeTimers();
      final focus = AudioFocus(sessionPort, timer: timers.create);
      addTearDown(focus.dispose);
      final preview = RelinquishingOwner('preview');
      final c = createContainer(focus: focus);
      await started(c);
      expect(await focus.beforePlay(AudioOutput.queue), isTrue);
      focus.bind(AudioOutput.preview, preview);
      unawaited(focus.acquire(AudioOutput.preview));
      await pumpEventQueue();
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.ready));
      await pumpEventQueue();
      expect(focus.holder, AudioOutput.preview);
      final plays = fakePlayer.playCalls;
      final seeds = fakePlayer.seedCalls.length;
      fakePlayer.emitCommandFailure(
          failure(command: EngineCommand.insert, itemId: itemOf(c) + 1));
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.playCalls, plays);
      expect(focus.holder, AudioOutput.preview);
    });

    test('a transfer to preview that starts while a rebuild is under way '
        'keeps the rebuild from playing', () async {
      final timers = FakeTimers();
      final focus = AudioFocus(sessionPort, timer: timers.create);
      addTearDown(focus.dispose);
      final preview = RelinquishingOwner('preview');
      final c = createContainer(focus: focus);
      await started(c);
      expect(await focus.beforePlay(AudioOutput.queue), isTrue);
      focus.bind(AudioOutput.preview, preview);
      expect(c.read(audioPlayWhenReadyProvider), isTrue);
      // The rebuild has decided to play on; the transfer starts as it seeds.
      fakePlayer.beforeSeed = (_) async {
        unawaited(focus.acquire(AudioOutput.preview));
        await pumpEventQueue();
      };
      final plays = fakePlayer.playCalls;
      final seeds = fakePlayer.seedCalls.length;
      fakePlayer.emitCommandFailure(
          failure(command: EngineCommand.insert, itemId: itemOf(c) + 1));
      await pumpEventQueue(times: 200);
      fakePlayer.beforeSeed = null;
      expect(fakePlayer.seedCalls, hasLength(seeds + 1), reason: 'rebuilt');
      expect(focus.yieldedBy(AudioOutput.queue), isTrue);
      expect(fakePlayer.playCalls, plays, reason: 'never takes the output back');
    });
  });

  // 7P.1 (SC-27 invariant 13): rebuilds are bounded. A run of failures that
  // keeps diverging the engine stops honestly; the user's next command
  // starts a new run and reseeds the engine it can no longer trust.
  group('7P.1 bounded rebuild', () {
    Future<QueuePlayer> started(ProviderContainer c) async {
      await fixture.insertSingles(['a', 'b', 'c']);
      await playFromTrackList(c, ['a', 'b', 'c'], await fixture.track('a'),
          sourceType: 'search');
      fakePlayer.emitPlayerState(
          const EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      return c.read(queuePlayerProvider.notifier);
    }

    Future<void> failOnce() async {
      fakePlayer.emitCommandFailure(EngineCommandFailure(
        runtimeId: fakePlayer.runtimeId,
        seedRevision: fakePlayer.seedRevision,
        playlistRevision: fakePlayer.playlistRevision,
        command: EngineCommand.insert,
        reason: EngineCommandFailureReason.failed,
        diverged: true,
        cause: PlaybackTransitionCause.queueEdit,
      ));
      await pumpEventQueue();
    }

    test('the fourth rebuild in a run stops instead of looping', () async {
      final c = createContainer();
      await started(c);
      final seeds = fakePlayer.seedCalls.length;
      for (var i = 0; i < 3; i++) {
        await failOnce();
      }
      expect(fakePlayer.seedCalls, hasLength(seeds + 3));
      final stops = fakePlayer.stopCalls;
      await failOnce();
      expect(fakePlayer.seedCalls, hasLength(seeds + 3), reason: 'no 4th');
      expect(fakePlayer.stopCalls, stops + 1);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
      expect(c.read(queuePlayerProvider).queue.sessionId, isNotNull,
          reason: 'the queue is kept');
    });

    test('after it stopped, a resume reseeds the untrusted engine and plays',
        () async {
      final c = createContainer();
      final notifier = await started(c);
      for (var i = 0; i < 4; i++) {
        await failOnce();
      }
      final seeds = fakePlayer.seedCalls.length;
      final plays = fakePlayer.playCalls;
      await notifier.resume();
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.seedCalls.last.currentItemId,
          c.read(queuePlayerProvider).queue.currentItemId);
      expect(fakePlayer.playCalls, greaterThan(plays));
    });

    test('after it stopped, a skip reseeds instead of seeking the untrusted '
        'engine', () async {
      final c = createContainer();
      final notifier = await started(c);
      for (var i = 0; i < 4; i++) {
        await failOnce();
      }
      final seeds = fakePlayer.seedCalls.length;
      final seeks = fakePlayer.seekedItems.length;
      await notifier.skipNext();
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.seekedItems, hasLength(seeks),
          reason: 'no seek on a diverged playlist');
    });

    test('user input starts a new run', () async {
      final c = createContainer();
      final notifier = await started(c);
      final seeds = fakePlayer.seedCalls.length;
      for (var i = 0; i < 3; i++) {
        await failOnce();
      }
      await notifier.skipNext();
      await pumpEventQueue();
      final afterSkip = fakePlayer.seedCalls.length;
      for (var i = 0; i < 3; i++) {
        await failOnce();
      }
      expect(fakePlayer.seedCalls, hasLength(afterSkip + 3));
      expect(afterSkip, greaterThanOrEqualTo(seeds + 3));
    });
    test('after it stopped, a seek reseeds at the asked position', () async {
      final c = createContainer();
      final notifier = await started(c);
      for (var i = 0; i < 4; i++) {
        await failOnce();
      }
      final seeds = fakePlayer.seedCalls.length;
      await notifier.seek(const Duration(seconds: 12));
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.seedCalls.last.initialPosition,
          const Duration(seconds: 12));
    });
  });

  // 7-R1-24: a user resume while preview holds the output must play (spec §5:
  // "any library resume/play ... first stops preview"); the engine's play()
  // takes the output back through beforePlay. The yield guard on reseeds is
  // for automatic plays only.
  // Was "7-R1-24: a user resume of an untrusted engine while preview holds".
  group('a user resume of an untrusted engine while preview holds', () {
    late FakeTimers timers;
    late AudioFocus focus;
    late RelinquishingOwner preview;

    setUp(() {
      timers = FakeTimers();
      focus = AudioFocus(sessionPort, timer: timers.create);
      preview = RelinquishingOwner('preview');
    });

    tearDown(() => focus.dispose());

    /// The library played, its engine diverged until the rebuild bound
    /// stopped it, then preview took the output.
    Future<QueuePlayer> divergedThenPreview(ProviderContainer c) async {
      await fixture.insertSingles(['a', 'b', 'c']);
      await playFromTrackList(c, ['a', 'b', 'c'], await fixture.track('a'),
          sourceType: 'search');
      expect(await focus.beforePlay(AudioOutput.queue), isTrue);
      focus.bind(AudioOutput.preview, preview);
      fakePlayer.emitPlayerState(
          const EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      for (var i = 0; i < 4; i++) {
        fakePlayer.emitCommandFailure(EngineCommandFailure(
          runtimeId: fakePlayer.runtimeId,
          seedRevision: fakePlayer.seedRevision,
          playlistRevision: fakePlayer.playlistRevision,
          command: EngineCommand.insert,
          reason: EngineCommandFailureReason.failed,
          diverged: true,
          cause: PlaybackTransitionCause.queueEdit,
        ));
        await pumpEventQueue();
      }
      expect(c.read(audioPlayWhenReadyProvider), isFalse,
          reason: 'the bound stopped the rebuilds');
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.ready));
      await pumpEventQueue();
      expect(await focus.acquire(AudioOutput.preview), isTrue);
      expect(focus.yieldedBy(AudioOutput.queue), isTrue);
      return c.read(queuePlayerProvider.notifier);
    }

    test('resume reseeds and plays (the engine play takes the output back)',
        () async {
      final c = createContainer(focus: focus);
      final notifier = await divergedThenPreview(c);
      final seeds = fakePlayer.seedCalls.length;
      final plays = fakePlayer.playCalls;
      await notifier.resume();
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1), reason: 'reseeded');
      expect(fakePlayer.playCalls, greaterThan(plays));
      expect(c.read(audioPlayWhenReadyProvider), isTrue);
    });

    test('the play/pause toggle reseeds and plays', () async {
      final c = createContainer(focus: focus);
      final notifier = await divergedThenPreview(c);
      final seeds = fakePlayer.seedCalls.length;
      final plays = fakePlayer.playCalls;
      await notifier.togglePlayPause();
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.playCalls, greaterThan(plays));
    });

    // The yield guard of automatic reseeds is pinned by 7P.1's "while the
    // library has yielded the output a rebuild never plays".
    test('a seek while paused and yielded does not play', () async {
      final c = createContainer(focus: focus);
      await divergedThenPreview(c);
      final plays = fakePlayer.playCalls;
      await c.read(queuePlayerProvider.notifier).seek(Duration.zero);
      await pumpEventQueue();
      expect(fakePlayer.playCalls, plays,
          reason: 'a seek while paused and yielded does not play');
      expect(focus.holder, AudioOutput.preview);
    });
  });

  // 7P.1 (5B.0d m5): a hydration chunk extends the window's coverage only
  // once the engine applied it natively, so native loop-all (which needs the
  // whole queue loaded) is never set over a window that failed to grow.
  group('7P.1 coverage acknowledged at native application (m5)', () {
    Future<(ProviderContainer, QueuePlayer, List<QueueTrackEntry>)>
        repeatAll70() async {
      final uuids = List.generate(70, (i) => 't$i');
      await fixture.insertSingles(uuids);
      final c = createContainer();
      await repo.startupRead.future;
      await playFromTrackList(c, uuids, await fixture.track('t0'),
          sourceType: 'test');
      await pumpEventQueue();
      final notifier = c.read(queuePlayerProvider.notifier);
      await notifier.cycleQueueRepeatMode(); // all
      await pumpEventQueue();
      return (c, notifier, await sessionTracksOf(c));
    }

    test('coverage and native loop-all wait for the engine to apply the '
        'chunk', () async {
      final (c, notifier, tracks) = await repeatAll70();
      final window = c.read(queueWindowProvider);
      expect(fakePlayer.lastLoopMode, EngineLoopMode.off,
          reason: 'the seed holds positions 0..48 of 70');
      final applied = fakePlayer.appliedGate = Completer<bool>();
      await notifier.skipToTrack(tracks[40].itemId); // within 24 of the end
      await pumpEventQueue();
      expect(fakePlayer.addedBatches, isNotEmpty, reason: 'chunk issued');
      expect(window.coversQueue(70), isFalse, reason: 'not yet applied');
      expect(fakePlayer.lastLoopMode, EngineLoopMode.off);

      applied.complete(true);
      await pumpEventQueue();
      expect(window.coversQueue(70), isTrue);
      expect(fakePlayer.lastLoopMode, EngineLoopMode.all);
    });

    test('a chunk the engine failed to apply is never acknowledged', () async {
      final (c, notifier, tracks) = await repeatAll70();
      final window = c.read(queueWindowProvider);
      final end = window.nextForwardHydrationPlayPosition;
      final applied = fakePlayer.appliedGate = Completer<bool>();
      await notifier.skipToTrack(tracks[40].itemId);
      await pumpEventQueue();
      fakePlayer.appliedGate = null;
      applied.complete(false);
      await pumpEventQueue();
      expect(window.nextForwardHydrationPlayPosition, end);
      expect(fakePlayer.lastLoopMode, EngineLoopMode.off);
    });

    test('waiting for the application never holds the lane', () async {
      final (c, notifier, tracks) = await repeatAll70();
      fakePlayer.appliedGate = Completer<bool>(); // never completes
      await notifier.skipToTrack(tracks[40].itemId);
      await pumpEventQueue();
      final pauses = fakePlayer.pauseCalls;
      await notifier.pause().timeout(const Duration(seconds: 1));
      expect(fakePlayer.pauseCalls, pauses + 1);
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
    });
  });

  // 7P.1 exit proof (SC-27 §6 row 1, 5-U13 regression): on the real
  // JustAudioEngine over a scripted plugin, a dropped seek, a failed insert
  // and a late index event each produce a typed failure and a rebuild from
  // queue data, and nothing is labelled naturalAdvance.
  group('7P.1 exit proof (real engine, scripted plugin)', () {
    late _ScriptedPlugin plugin;
    late JustAudioEngine engine;
    late List<PlaybackObservation> seen;
    late List<PlaybackIssue> issues;

    Future<ProviderContainer> playing(List<String> uuids) async {
      plugin = _ScriptedPlugin();
      engine = JustAudioEngine(plugin);
      addTearDown(engine.dispose);
      seen = [];
      issues = [];
      engine.observations.listen(seen.add);
      final c = createContainer(engine: engine);
      c.read(playbackIssueBusProvider).issues.listen(issues.add);
      await fixture.insertSingles(uuids);
      await playFromTrackList(c, uuids, await fixture.track(uuids.first),
          sourceType: 'search');
      await pumpEventQueue();
      plugin.state(ja.ProcessingState.ready, playing: true);
      await pumpEventQueue();
      seen.clear();
      return c;
    }

    void expectNoNaturalAdvance() => expect(
        seen.where(
            (o) => o.transitionCause == PlaybackTransitionCause.naturalAdvance),
        isEmpty);

    List<EngineCommandFailure> failures() => [
          for (final issue in issues.whereType<PlaybackEngineCommandFailed>())
            issue.failure
        ];

    test('a seek dropped while loading is rebuilt at the asked position',
        () async {
      final c = await playing(['a', 'b', 'c']);
      final loads = plugin.loads.length;
      plugin.processing = ja.ProcessingState.loading;
      await c.read(queuePlayerProvider.notifier)
          .seek(const Duration(seconds: 30));
      await pumpEventQueue();

      expect(failures().single.reason, EngineCommandFailureReason.dropped);
      expect(plugin.loads, hasLength(loads + 1), reason: 'a new seed');
      expect(plugin.loads.last.initialPosition, const Duration(seconds: 30));
      expect(plugin.loads.last.initialIndex, 0, reason: 'still track a');
      expect(c.read(queuePlayerProvider).playback.currentTrack?.uuidId, 'a');
      expectNoNaturalAdvance();
    });

    test('a failed insert is rebuilt from queue data, the added track '
        'included', () async {
      final c = await playing(['a', 'b']);
      await fixture.insertSingles(['d']);
      final loads = plugin.loads.length;
      plugin.failInserts = true;
      await addToQueue(c, [await fixture.track('d')]);
      await pumpEventQueue();

      expect(failures().first.command, EngineCommand.insert);
      expect(plugin.loads, hasLength(loads + 1));
      expect(plugin.loads.last.count, 3, reason: 'a, b and d from the queue');
      expect(plugin.loads.last.initialIndex, 0);
      expect(c.read(queuePlayerProvider).playback.currentTrack?.uuidId, 'a');
      expectNoNaturalAdvance();
    });

    test('a late index event is never committed; the item the core asked '
        'for is rebuilt', () async {
      final c = await playing(['a', 'b', 'c']);
      await c.read(queuePlayerProvider.notifier).skipNext();
      await pumpEventQueue();
      expect(c.read(queuePlayerProvider).playback.currentTrack?.uuidId, 'b');
      seen.clear();
      final loads = plugin.loads.length;
      plugin.reportIndex(0); // late: the index before the skip
      await pumpEventQueue();

      expect(failures(), isNotEmpty);
      expect(failures().first.reason,
          EngineCommandFailureReason.unexplainedIndex);
      expect(plugin.loads, hasLength(loads + 1));
      expect(plugin.loads.last.initialIndex, 1, reason: 'b, from the queue');
      expect(c.read(queuePlayerProvider).playback.currentTrack?.uuidId, 'b');
      expectNoNaturalAdvance();
    });

    // 7-R1-05 (7P.1 R1-06): the scripted plugin, like just_audio on Android,
    // keeps its old index after a remove returns until it reports the new
    // one. Removing an already-played track must not move playback.
    test('7-R1-05: removing an earlier track with the index reported late '
        'keeps the playing track: no advance, no rebuild, no failure',
        () async {
      final c = await playing(['a', 'b', 'c', 'd']);
      await c.read(queuePlayerProvider.notifier).skipNext();
      await pumpEventQueue();
      expect(c.read(queuePlayerProvider).playback.currentTrack?.uuidId, 'b');
      final sessionId = c.read(queuePlayerProvider).queue.sessionId!;
      final a = (await repo.getPlaybackEntries(sessionId))
          .firstWhere((e) => e.uuidId == 'a');
      seen.clear();
      final loads = plugin.loads.length;

      await c.read(queuePlayerProvider.notifier).removeFromQueue(a.itemId);
      await pumpEventQueue();
      expect(c.read(queuePlayerProvider).playback.currentTrack?.uuidId, 'b',
          reason: 'the stale index (1, now c) is not an advance');
      plugin.reportIndex(0); // the plugin's own report: b moved to 0
      await pumpEventQueue();

      expect(c.read(queuePlayerProvider).playback.currentTrack?.uuidId, 'b');
      expect(failures(), isEmpty);
      expect(plugin.loads, hasLength(loads), reason: 'no rebuild');
      expectNoNaturalAdvance();
      expect(seen.last.uncertain, isFalse);
      expect(seen.last.source?.trackUuid, 'b');
    });
  });

  // 7P.1 in-piece review round 1 (`7P.1-review.md`).
  // Was "7P.1 review r1".
  group(
      'an untrusted engine: rebuilds onto settled items, failed pauses and reseeds',
      () {
    Future<QueuePlayer> started(ProviderContainer c) async {
      await fixture.insertSingles(['a', 'b', 'c']);
      await playFromTrackList(c, ['a', 'b', 'c'], await fixture.track('a'),
          sourceType: 'search');
      fakePlayer.emitPlayerState(
          const EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      return c.read(queuePlayerProvider.notifier);
    }

    int itemOf(ProviderContainer c) =>
        c.read(queuePlayerProvider).queue.currentItemId!;

    void fail(EngineCommand command,
        {EngineCommandFailureReason reason = EngineCommandFailureReason.failed,
        int? itemId,
        Duration? position,
        PlaybackTransitionCause? cause}) {
      fakePlayer.emitCommandFailure(EngineCommandFailure(
        runtimeId: fakePlayer.runtimeId,
        seedRevision: fakePlayer.seedRevision,
        playlistRevision: fakePlayer.playlistRevision,
        command: command,
        reason: reason,
        diverged: true,
        target: itemId == null
            ? null
            : EngineCommandTarget(
                itemId: itemId,
                trackUuid: 'x',
                sourceKind: PlaybackSourceKind.remote),
        position: position,
        cause: cause,
      ));
    }

    test('R1-01: a rebuild onto an item the engine never settled on starts '
        'it from zero, not at the old track\'s position', () async {
      final c = createContainer();
      await started(c);
      final first = itemOf(c);
      fakePlayer.emitObservation(playing: true); // settled on a
      fakePlayer.emitPosition(const Duration(seconds: 170));
      await pumpEventQueue();
      // The core moved the engine to c (a wrap target); natively it never got
      // there before the reseat's insert failed.
      fakePlayer.commitSilently(first + 2);
      fail(EngineCommand.insert, itemId: first + 1,
          cause: PlaybackTransitionCause.queueEdit);
      await pumpEventQueue();
      final seed = fakePlayer.seedCalls.last;
      expect(seed.currentItemId, first + 2);
      expect(seed.initialPosition, Duration.zero);
    });

    test('R1-01: a dropped seek on one item, then a skip, starts the next '
        'item from zero', () async {
      final c = createContainer();
      final notifier = await started(c);
      final a = itemOf(c);
      fakePlayer.emitObservation(playing: true);
      await pumpEventQueue();
      await notifier.skipNext(); // b
      fail(EngineCommand.seek,
          reason: EngineCommandFailureReason.dropped,
          itemId: a,
          position: const Duration(seconds: 30),
          cause: PlaybackTransitionCause.userSeek);
      await pumpEventQueue();
      final seed = fakePlayer.seedCalls.last;
      expect(seed.currentItemId, a + 1);
      expect(seed.initialPosition, Duration.zero);
    });

    test('R1-01: the same settled item keeps its engine position', () async {
      final c = createContainer();
      await started(c);
      fakePlayer.emitObservation(playing: true);
      fakePlayer.emitPosition(const Duration(seconds: 42));
      await pumpEventQueue();
      fail(EngineCommand.insert, itemId: itemOf(c) + 1,
          cause: PlaybackTransitionCause.queueEdit);
      await pumpEventQueue();
      expect(fakePlayer.seedCalls.last.initialPosition,
          const Duration(seconds: 42));
    });

    test('R1-02/R2-01: a failed pause is rebuilt paused without a full stop '
        '(the engine resets its plugin at that seed; the listen is not split)',
        () async {
      final c = createContainer();
      final notifier = await started(c);
      await notifier.pause();
      final stops = fakePlayer.stopCalls;
      final seeds = fakePlayer.seedCalls.length;
      fail(EngineCommand.pause, itemId: itemOf(c));
      await pumpEventQueue();
      expect(fakePlayer.stopCalls, stops, reason: 'no stop observation');
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.seedCalls.last.cause,
          PlaybackTransitionCause.reconcileContinuation);
    });

    test('R2-n2: a resume that reseeds an untrusted engine starts an item the '
        'engine never settled on from zero', () async {
      final c = createContainer();
      final notifier = await started(c);
      final first = itemOf(c);
      fakePlayer.emitObservation(playing: true);
      fakePlayer.emitPosition(const Duration(seconds: 100));
      await pumpEventQueue();
      for (var i = 0; i < 4; i++) {
        fail(EngineCommand.insert, cause: PlaybackTransitionCause.queueEdit);
        await pumpEventQueue();
      }
      fakePlayer.commitSilently(first + 2);
      await notifier.resume();
      await pumpEventQueue();
      expect(fakePlayer.seedCalls.last.currentItemId, first + 2);
      expect(fakePlayer.seedCalls.last.initialPosition, Duration.zero);
    });

    test('R1-04: a rebuild that could not finish leaves the engine untrusted: '
        'the next resume reseeds', () async {
      final c = createContainer();
      final notifier = await started(c);
      await notifier.pause();
      fakePlayer.beforeSeed = (_) async => throw StateError('db gone');
      fail(EngineCommand.insert, itemId: itemOf(c) + 1);
      await pumpEventQueue();
      fakePlayer.beforeSeed = null;
      final seeds = fakePlayer.seedCalls.length;
      await notifier.resume();
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
    });

    test('R1-08: a seek after the engine diverged reseeds at the asked '
        'position', () async {
      final c = createContainer();
      final notifier = await started(c);
      fakePlayer.beforeSeed = (_) async => throw StateError('db gone');
      fail(EngineCommand.insert, itemId: itemOf(c) + 1);
      await pumpEventQueue();
      fakePlayer.beforeSeed = null;
      await notifier.seek(const Duration(seconds: 120));
      await pumpEventQueue();
      expect(fakePlayer.seedCalls.last.initialPosition,
          const Duration(seconds: 120));
    });

    Future<void> exhaust() async {
      for (var i = 0; i < 4; i++) {
        fail(EngineCommand.insert, cause: PlaybackTransitionCause.queueEdit);
        await pumpEventQueue();
      }
    }

    test('R1-05: after the bound, repeat-one Next reseeds instead of seeking '
        'the untrusted engine', () async {
      final c = createContainer();
      final notifier = await started(c);
      await notifier.cycleQueueRepeatMode(); // all
      await notifier.cycleQueueRepeatMode(); // one
      await exhaust();
      final seeds = fakePlayer.seedCalls.length;
      await notifier.skipNext();
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.seedCalls.last.initialPosition, Duration.zero);
    });

    test('R1-05: after the bound, Previous late in a track reseeds at its '
        'start', () async {
      final c = createContainer();
      final notifier = await started(c);
      await exhaust();
      fakePlayer.emitPosition(const Duration(seconds: 50));
      await pumpEventQueue();
      final seeds = fakePlayer.seedCalls.length;
      await notifier.skipPrevious();
      await pumpEventQueue();
      expect(fakePlayer.seedCalls, hasLength(seeds + 1));
      expect(fakePlayer.seedCalls.last.initialPosition, Duration.zero);
    });

    test('R1-09: an automatic resume (a natural end) does not start a new '
        'rebuild run', () async {
      final c = createContainer();
      await started(c);
      for (var i = 0; i < 3; i++) {
        fail(EngineCommand.insert, cause: PlaybackTransitionCause.queueEdit);
        await pumpEventQueue();
      }
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.completed));
      await pumpEventQueue();
      final stops = fakePlayer.stopCalls;
      fail(EngineCommand.insert, cause: PlaybackTransitionCause.queueEdit);
      await pumpEventQueue();
      expect(fakePlayer.stopCalls, stops + 1, reason: 'the 4th in the run');
      expect(c.read(audioPlayWhenReadyProvider), isFalse);
    });
  });

  // Sign-off OPEN-M-11 step D, review r1 F3/F5: while the server check failed
  // a stream behaves like a non-downloaded item offline, and the gate's
  // verdicts reach the engine through the queue player's lane.
  // Was "OPEN-M-11 step D: media token".
  group('media tokens: unavailable streams and gate verdicts in the lane', () {
    test('streams unavailable (the check failed): a request for a track '
        'that is not downloaded is refused like offline', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      final c = createContainer(extraOverrides: [
        streamsUnavailableProvider.overrideWithValue(() => true),
      ]);
      final outcome = await c
          .read(playbackRequestsProvider)
          .submit(const PlayList(['b'], 0, ListSource('search')));
      expect(outcome, isA<RejectedUnplayableOffline>());
      expect(fakePlayer.seedCalls, isEmpty);
      final ok = await c
          .read(playbackRequestsProvider)
          .submit(const PlayList(['a'], 0, ListSource('search')));
      expect(ok, isA<Accepted>());
      expect(fakePlayer.seedCalls.last.currentSourceKind,
          PlaybackSourceKind.local);
    });

    test('the gate verdicts run in the lane: Verified refreshes, a failed '
        'check releases what is ahead, a different server stops a streamed '
        'current item and releases everything', () async {
      await fixture.insertSingles(['a', 'b']);
      final engine = TokenAwareFakeEngine();
      fakePlayer = engine;
      final gate = _StatesGate();
      addTearDown(gate.close);
      final c = createContainer(engine: engine, extraOverrides: [
        serverBindingGateProvider.overrideWithValue(gate),
      ]);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'search');
      expect(fakePlayer.seedCalls.last.currentSourceKind,
          PlaybackSourceKind.remote, reason: 'precondition: a streams');
      c.read(queuePlayerProvider);

      gate.publish(const BindingVerified(token: 't', instanceId: 'i'));
      await pumpEventQueue();
      expect(engine.tokenCalls, ['refresh']);

      gate.publish(BindingUnverified(StateError('x')));
      await pumpEventQueue();
      expect(engine.tokenCalls, ['refresh', 'release ahead']);

      final stops = engine.stopCalls;
      gate.publish(const BindingDifferentServer(
          boundInstanceId: 'a', serverInstanceId: 'b'));
      await pumpEventQueue();
      expect(engine.stopCalls, stops + 1, reason: 'a stream was current');
      expect(engine.tokenCalls,
          ['refresh', 'release ahead', 'release everything']);

      gate.publish(const BindingVerifying());
      await pumpEventQueue();
      expect(engine.tokenCalls, hasLength(3), reason: 'nothing for a pending '
          'verdict');
    });
  });

  // Was "U17-FE-PB-CORE-B-01: a queue edit does not overwrite engine reports that arrive while it reads".
  group(
      'a queue edit does not overwrite engine reports that arrive while it reads',
      () {
    test('an engine report during the edit\'s queue read is kept: playing, '
        'not loading', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b', 'c', 'd'],
          await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      fakePlayer.emitPlayerState(
          const EngineTransportState(true, EngineProcessingState.buffering));
      await pumpEventQueue();
      expect(c.read(queuePlayerProvider).playback.status, PlayerStatus.loading,
          reason: 'precondition: buffering shows loading');
      final tracks = await sessionTracksOf(c);

      final gate = Completer<void>();
      repo.sessionSnapshotGate = gate;
      final removal = c
          .read(queuePlayerProvider.notifier)
          .removeFromQueue(tracks[2].itemId);
      await repo.sessionSnapshotEntered.future;
      // The engine finishes buffering while the edit waits on its read.
      fakePlayer.emitPlayerState(
          const EngineTransportState(true, EngineProcessingState.ready));
      fakePlayer.emitPosition(const Duration(seconds: 3));
      await pumpEventQueue();
      expect(c.read(queuePlayerProvider).playback.status, PlayerStatus.playing);
      gate.complete();
      await removal;
      await pumpEventQueue();

      final playback = c.read(queuePlayerProvider).playback;
      expect(playback.status, PlayerStatus.playing,
          reason: 'the report that arrived during the read is not undone');
      expect(playback.processing, EngineProcessingState.ready);
      expect(playback.position, const Duration(seconds: 3));
      expect(c.read(queuePlayerProvider).queue.totalCount, 3);
    });

    test('removing another entry while paused keeps the shown position',
        () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b', 'c', 'd'],
          await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      fakePlayer.emitPosition(const Duration(seconds: 42));
      fakePlayer.emitPlayerState(
          const EngineTransportState(false, EngineProcessingState.ready));
      await pumpEventQueue();
      final tracks = await sessionTracksOf(c);

      await c
          .read(queuePlayerProvider.notifier)
          .removeFromQueue(tracks[2].itemId);
      await pumpEventQueue();

      final state = c.read(queuePlayerProvider);
      expect(state.queue.currentItemId, tracks[0].itemId);
      expect(state.playback.position, const Duration(seconds: 42),
          reason: 'the current track was not removed: no jump to 0:00');
    });

    test('review r1 #3: when the engine already moved to the next track, the '
        'removal does not show the old track\'s position on it', () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b', 'c', 'd'],
          await fixture.track('a'), sourceType: 'test');
      await pumpEventQueue();
      fakePlayer.emitPosition(const Duration(seconds: 42));
      await pumpEventQueue();
      final tracks = await sessionTracksOf(c);
      // a ended: the engine is on b, its item-change event not processed.
      fakePlayer.commitSilently(tracks[1].itemId);

      await c
          .read(queuePlayerProvider.notifier)
          .removeFromQueue(tracks[3].itemId);
      await pumpEventQueue();

      final state = c.read(queuePlayerProvider);
      expect(state.queue.currentItemId, tracks[1].itemId);
      expect(state.playback.position, Duration.zero);
    });
  });

  // Was "U17-FE-PB-CORE-B-02: Stop keeps the volume".
  group('Stop keeps the volume', () {
    test('after Stop the shown volume is the one the engine still uses',
        () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await notifier.setVolume(0.3);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      await pumpEventQueue();

      await notifier.stop();
      await pumpEventQueue();

      final state = c.read(queuePlayerProvider);
      expect(state.queue.sessionId, isNull, reason: 'precondition: stopped');
      expect(state.playback.currentTrack, isNull);
      expect(state.playback.volume, 0.3);
      expect(c.read(audioVolumeProvider), 0.3);
      expect(fakePlayer.lastVolume, 0.3);
    });
  });

  // Was "U17-FE-PB-CORE-B-04: a failure classified after the listener moved on writes nothing".
  group('a failure classified after the listener moved on writes nothing', () {
    Future<String?> damagedPathOf(String uuid) async =>
        (await (db.select(db.tracks)..where((t) => t.uuidId.equals(uuid)))
                .getSingle())
            .damagedFilePath;

    Future<ProviderContainer> playingDownloadedA() async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('a', '/dl/a');
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      await pumpEventQueue();
      return c;
    }

    test('the user skips while the failed download is being checked: no '
        'suspicion, no stream stand-in, and returning to it later marks '
        'nothing', () async {
      final c = await playingDownloadedA();
      final gate = classifyGate = Completer<void>();
      fakePlayer.emitSourceFailure(); // a's download fails
      await pumpEventQueue();
      await c.read(queuePlayerProvider.notifier).skipNext(); // the user moves
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      gate.complete(); // the check answers "present but failed"
      await pumpEventQueue();

      expect(c.read(localSourcePolicyProvider).isSuspect('a', '/dl/a'),
          isFalse, reason: 'a check that finished after the move is stale');
      expect(fakePlayer.refreshedSources, isEmpty);

      await c.read(queuePlayerProvider.notifier).skipPrevious();
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
      fakePlayer.emitObservation(playing: true); // a plays again
      await pumpEventQueue();
      expect(await damagedPathOf('a'), isNull,
          reason: 'a healthy download is never marked from a stale check');
    });

    test('the failed track plays while it is being checked (the run is over): '
        'no suspicion and no stream stand-in', () async {
      final c = await playingDownloadedA();
      final gate = classifyGate = Completer<void>();
      fakePlayer.emitSourceFailure();
      await pumpEventQueue();
      fakePlayer.emitObservation(playing: true); // it plays after all
      await pumpEventQueue();
      gate.complete();
      await pumpEventQueue();

      expect(c.read(localSourcePolicyProvider).isSuspect('a', '/dl/a'),
          isFalse);
      expect(fakePlayer.refreshedSources, isEmpty);
      expect(await damagedPathOf('a'), isNull);
      expect(c.read(currentTrackProvider)?.uuidId, 'a');
    });

    test('a natural advance onto the failed (preloaded) download while it is '
        'checked is not a move: it is still suspected and streamed', () async {
      await fixture.insertSingles(['a', 'b']);
      await markDownloaded('b', '/dl/b');
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      await pumpEventQueue();
      final b = (await sessionTracksOf(c))[1].itemId;
      final gate = classifyGate = Completer<void>();
      fakePlayer.emitSourceFailure(itemId: b); // the preloaded file fails
      await pumpEventQueue();
      // a ends and the engine moves on to b by itself.
      await fakePlayer.seekToItem(b,
          cause: PlaybackTransitionCause.naturalAdvance);
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      gate.complete();
      await pumpEventQueue();

      expect(c.read(localSourcePolicyProvider).isSuspect('b', '/dl/b'),
          isTrue, reason: 'handled exactly as before: a real failure');
      expect(fakePlayer.refreshedSources.single.newHasFile, isFalse);
    });

    test('review r1 #1: a resume while a streamed track\'s server check '
        'waits is not a move: a track gone from the server is still skipped',
        () async {
      await fixture.insertSingles(['a', 'b']);
      trackStatuses['a'] = 404; // deleted on the server
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      await pumpEventQueue();
      final gate = probeGate = Completer<void>();
      fakePlayer.emitSourceFailure(); // a's stream fails
      await pumpEventQueue();
      await c.read(queuePlayerProvider.notifier).resume(); // lock-screen Play
      await pumpEventQueue();
      gate.complete(); // the check answers: gone
      await pumpEventQueue();

      expect(c.read(currentTrackProvider)?.uuidId, 'b',
          reason: 'handled as before: a gone track is skipped');
    });

    test('nothing moved meanwhile: the held check is handled as before '
        '(suspected, streamed, marked once the stream plays)', () async {
      final c = await playingDownloadedA();
      final gate = classifyGate = Completer<void>();
      fakePlayer.emitSourceFailure();
      await pumpEventQueue();
      gate.complete();
      await pumpEventQueue();

      expect(c.read(localSourcePolicyProvider).isSuspect('a', '/dl/a'),
          isTrue);
      expect(fakePlayer.refreshedSources.single.newHasFile, isFalse);
      fakePlayer.emitObservation(playing: true); // the stream plays
      await pumpEventQueue();
      expect(await damagedPathOf('a'), '/dl/a');
    });
  });

  // Was "section 6 #1 (U20-FE-QUEUE-A-01): Play next and Add to queue write the new order in one transaction".
  group(
      'Play next and Add to queue write the new order in one transaction',
      () {
    Future<(ProviderContainer, int)> playingABC() async {
      await fixture.insertSingles(['a', 'b', 'c', 'x', 'y']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b', 'c'], await fixture.track('a'),
          sourceType: 'test');
      await pumpEventQueue();
      return (c, c.read(queuePlayerProvider).queue.sessionId!);
    }

    Future<List<String>> order(int sessionId) async =>
        [for (final r in await _orderRows(db, sessionId)) r.$3];

    for (final (position, expected) in [
      (EnqueuePosition.next, ['a', 'x', 'y', 'b', 'c']),
      (EnqueuePosition.end, ['a', 'x', 'y', 'b', 'c']),
    ]) {
      test('${position.name}: a failed order rewrite leaves the queue as it '
          'was (no tracks stranded at the end)', () async {
        final (c, sessionId) = await playingABC();
        repo.replacePlayOrderError = StateError('disk full');
        final outcome = await c
            .read(playbackRequestsProvider)
            .submit(Enqueue(const ['x', 'y'], position));
        expect(outcome, isA<Failed>());
        expect(await order(sessionId), ['a', 'b', 'c']);
        expect((await db.select(db.queueSessionItems).get())
            .where((i) => i.sessionId == sessionId)
            .map((i) => i.uuidId), unorderedEquals(['a', 'b', 'c']),
            reason: 'the added items are rolled back with the order');
        // The queue still works as before.
        expect(await c.read(playbackRequestsProvider)
            .submit(Enqueue(const ['x', 'y'], position)), isA<Accepted>());
        expect(await order(sessionId), expected);
      });

      test('${position.name}: a reader outside the edit never sees the added '
          'tracks appended but not yet ordered', () async {
        final (c, sessionId) = await playingABC();
        final held = Completer<void>();
        final entered = Completer<void>();
        repo.beforeReplacePlayOrder = (_) async {
          repo.beforeReplacePlayOrder = null;
          entered.complete();
          await held.future;
        };
        final outcome = c
            .read(playbackRequestsProvider)
            .submit(Enqueue(const ['x', 'y'], position));
        await entered.future; // the items are written; the order is not yet
        final outside = order(sessionId);
        await pumpEventQueue();
        held.complete();
        expect(await outcome, isA<Accepted>());
        expect(await outside, expected,
            reason: 'the outside read sees the queue before or after the '
                'edit, never in between');
        expect(await order(sessionId), expected);
      });
    }
  });

  // Pre-merge A6-06: like Play next and Add to queue above (decision 1 of
  // 2026-11-17), the shuffle toggle writes its flag and its order together.
  group('Shuffle on/off writes the flag and the play order in one transaction',
      () {
    const album = ['a', 'b', 'c', 'd', 'e', 'f', 'g'];

    Future<(ProviderContainer, int)> playingAlbumAtD() async {
      await fixture.insertAlbum(artist: 'Artist', album: 'Album', uuids: album);
      final c = createContainer(random: Random(1));
      await playFromQueue(c, track: await fixture.track('d'),
          sourceType: 'album',
          artistId: 1,
          albumId: 1,
          orderParams: [OrderParameter(column: 'track_number')]);
      await pumpEventQueue();
      return (c, c.read(queuePlayerProvider).queue.sessionId!);
    }

    Future<List<String>> order(int sessionId) async =>
        [for (final r in await _orderRows(db, sessionId)) r.$3];

    Future<bool> storedFlag(int sessionId) async =>
        (await repo.getSessionSnapshot(sessionId))!.session.shuffleEnabled;

    test('on: a failed order rewrite leaves the stored flag off, with the '
        'unshuffled order', () async {
      final (c, sessionId) = await playingAlbumAtD();
      repo.replacePlayOrderError = StateError('disk full');
      await expectLater(
          c.read(queuePlayerProvider.notifier).toggleShuffle(),
          throwsStateError);
      expect(await order(sessionId), album);
      expect(await storedFlag(sessionId), isFalse,
          reason: 'the flag is rolled back with the order');
      expect(c.read(queuePlayerProvider).shuffle.shuffleOn, isFalse);
      // The toggle still works afterwards.
      await c.read(queuePlayerProvider.notifier).toggleShuffle();
      expect(await storedFlag(sessionId), isTrue);
      expect(c.read(queuePlayerProvider).shuffle.shuffleOn, isTrue);
    });

    test('off: a failed order rewrite leaves the stored flag on, with the '
        'shuffled order', () async {
      final (c, sessionId) = await playingAlbumAtD();
      final notifier = c.read(queuePlayerProvider.notifier);
      await notifier.toggleShuffle(); // on
      final shuffled = await order(sessionId);
      expect(shuffled, isNot(album), reason: 'seeded: really shuffled');
      repo.replacePlayOrderError = StateError('disk full');
      await expectLater(notifier.toggleShuffle(), throwsStateError);
      expect(await order(sessionId), shuffled);
      expect(await storedFlag(sessionId), isTrue,
          reason: 'the flag is rolled back with the order');
      expect(c.read(queuePlayerProvider).shuffle.shuffleOn, isTrue);
      await notifier.toggleShuffle(); // off works afterwards
      expect(await storedFlag(sessionId), isFalse);
      expect(await order(sessionId), album);
    });
  });

  // Was "U17-FE-PB-CORE-B-01: a position report during a stop is ignored".
  group('a position report during a stop is ignored', () {
    test('while Stop is still finishing, a position report does not move '
        'the stopping track', () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      fakePlayer.emitPosition(const Duration(seconds: 10));
      await pumpEventQueue();
      final gate = repo.deactivateGate = Completer<void>();
      final stopping = notifier.stop();
      await repo.deactivateEntered.future; // the engine is stopped
      fakePlayer.emitPosition(const Duration(seconds: 42));
      await pumpEventQueue();
      expect(c.read(currentTrackProvider)?.uuidId, 'a',
          reason: 'precondition: the track is still shown');
      expect(c.read(queuePlayerProvider).playback.position,
          const Duration(seconds: 10));
      repo.deactivateGate = null;
      gate.complete();
      await stopping;
      expect(c.read(queuePlayerProvider).playback.position, Duration.zero);
    });

    test('after a quiesce a position report changes nothing', () async {
      await fixture.insertSingles(['a', 'b']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      await notifier.quiesce();
      final before = c.read(queuePlayerProvider);
      fakePlayer.emitPosition(const Duration(seconds: 42));
      await pumpEventQueue();
      expect(identical(c.read(queuePlayerProvider), before), isTrue,
          reason: 'no state is published after the quiesce');
    });
  });

  // Was "U17-FE-PB-CORE-B-04: a volume set while the player closes writes nothing afterwards".
  group('a volume set while the player closes writes nothing afterwards', () {
    Future<double?> savedVolume() async =>
        (await SharedPreferences.getInstance()).getDouble('audioVolume');

    test('closed by a reset while the engine applied it: no state, no saved '
        'preference after the close', () async {
      await fixture.insertSingles(['a']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await pumpEventQueue();
      final gate = fakePlayer.setVolumeGate = Completer<void>();
      final setting = notifier.setVolume(0.3);
      await notifier.quiesce(); // the reset closes the player ...
      (await SharedPreferences.getInstance()).clear(); // ... and wipes prefs
      gate.complete();
      await setting;
      expect(await savedVolume(), isNull,
          reason: 'the next user does not inherit this volume');
      expect(c.read(queuePlayerProvider).playback.volume, isNot(0.3));
    });

    test('its scope disposed while the engine applied it: completes without '
        'an error and saves nothing', () async {
      await fixture.insertSingles(['a']);
      final c = createContainer();
      final notifier = c.read(queuePlayerProvider.notifier);
      await pumpEventQueue();
      final gate = fakePlayer.setVolumeGate = Completer<void>();
      final setting = notifier.setVolume(0.3);
      c.dispose();
      container = null;
      gate.complete();
      await expectLater(setting, completes);
      expect(await savedVolume(), isNull);
    });

    test('an open player still applies and saves it (control)', () async {
      final c = createContainer();
      await pumpEventQueue();
      await c.read(queuePlayerProvider.notifier).setVolume(0.3);
      expect(c.read(queuePlayerProvider).playback.volume, 0.3);
      expect(await savedVolume(), 0.3);
    });
  });

  // Was "section 6 #6 (U17-FE-PB-CORE-B-06): an internal error while preparing playback is a failure".
  group('an internal error while preparing playback is a failure', () {
    Future<(ProviderContainer, AudioState)> playingAB() async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final c = createContainer();
      await playFromTrackList(c, const ['a', 'b'], await fixture.track('a'),
          sourceType: 'test');
      await pumpEventQueue();
      return (c, c.read(queuePlayerProvider));
    }

    Future<void> expectUntouched(ProviderContainer c, AudioState before) async {
      final after = c.read(queuePlayerProvider);
      expect(after.queue.sessionId, before.queue.sessionId);
      expect(after.playback.currentTrack?.uuidId, 'a');
      expect((await repo.getActiveSession())?.id, before.queue.sessionId);
      expect((await db.select(db.queueSessions).get()).map((s) => s.id),
          [before.queue.sessionId], reason: 'no prepared session is left');
    }

    test('an internal error creating the session is Failed, not "nothing to '
        'play"', () async {
      final (c, before) = await playingAB();
      repo.createSessionError = StateError('db gone');
      final outcome = await c.read(playbackRequestsProvider)
          .submit(const PlayList(['c'], 0, ListSource('s')));
      expect(outcome, isA<Failed>());
      await expectUntouched(c, before);
    });

    test('an internal error recording the prepared target is Failed, not '
        're-resolved into "nothing to play"', () async {
      final (c, before) = await playingAB();
      repo.setPreparedCurrentItemError = StateError('db gone');
      final outcome = await c.read(playbackRequestsProvider)
          .submit(const PlayList(['c'], 0, ListSource('s')));
      expect(outcome, isA<Failed>());
      await expectUntouched(c, before);
    });

    test('an internal error activating the prepared session is Failed, not '
        'stale', () async {
      final (c, before) = await playingAB();
      repo.beforeActivation = (id) async {
        repo.beforeActivation = null;
        repo.failActivationOf = id; // the prepared one: StateError('db gone')
      };
      final seeds = fakePlayer.seedCalls.length;
      final outcome = await c.read(playbackRequestsProvider)
          .submit(const PlayList(['c'], 0, ListSource('s')));
      expect(outcome, isA<Failed>());
      expect(fakePlayer.seedCalls, hasLength(seeds));
      await expectUntouched(c, before);
    });

    test('a target removed by a sync between resolving and recording it is '
        're-resolved to its successor, not a failure', () async {
      final (c, _) = await playingAB();
      await fixture.insertSingles(['d']);
      repo.beforeSetPreparedCurrentItem = (sessionId) async {
        repo.beforeSetPreparedCurrentItem = null;
        await repo.removeTrackUuidsFromQueues(const ['c']); // a catalog sync
      };
      final outcome = await c.read(playbackRequestsProvider)
          .submit(const PlayList(['c', 'd'], 0, ListSource('s')));
      expect(outcome, isA<Accepted>());
      expect(c.read(currentTrackProvider)?.uuidId, 'd');
    });

    test('a real "nothing to queue" is still RejectedEmpty: no track left, or '
        'the tapped track not among them', () async {
      final (c, before) = await playingAB();
      final requests = c.read(playbackRequestsProvider);
      expect(
          await requests.submit(const PlayQuery(
              source: BrowseSource('library'),
              currentUuid: 'c',
              downloadedOnly: true)),
          isA<RejectedEmpty>(),
          reason: 'nothing downloaded');
      await markDownloaded('b', '/dl/b');
      expect(
          await requests.submit(const PlayQuery(
              source: BrowseSource('library'),
              currentUuid: 'c',
              downloadedOnly: true)),
          isA<RejectedEmpty>(),
          reason: 'the tapped track is not downloaded');
      await expectUntouched(c, before);
    });

    // The nine pages that show a failed row tap's message
    // (showPlaybackOutcome: Tracks twice, Search, Home recents and
    // suggestions, See all, statistics, ranking, Downloaded) all start it
    // through LibraryActions.playFromList or playQuery and show
    // playbackOutcomeMessage of the outcome unchanged.
    group('the row-tap pages\' message', () {
      for (final (name, error) in [
        ('creating', 'create'),
        ('recording the target', 'target'),
      ]) {
        test('an internal error while $name: "Couldn\'t start playback." for '
            'a list tap and a browse tap', () async {
          final (c, _) = await playingAB();
          final actions = c.read(libraryActionsProvider);
          final track = await fixture.track('c');
          void arm() => error == 'create'
              ? repo.createSessionError = StateError('db gone')
              : repo.setPreparedCurrentItemError = StateError('db gone');
          arm();
          expect(
              playbackOutcomeMessage(
                  await actions.playFromList([track], 0, source: 'search')),
              "Couldn't start playback.");
          if (error == 'target') {
            arm();
            expect(
                playbackOutcomeMessage(
                    await actions.playQuery(track, downloadedOnly: false)),
                "Couldn't start playback.");
          }
        });
      }

      test('nothing to play keeps its text for a browse tap', () async {
        final (c, _) = await playingAB();
        final outcome = await c
            .read(libraryActionsProvider)
            .playQuery(await fixture.track('c'), downloadedOnly: true);
        expect(playbackOutcomeMessage(outcome),
            'Nothing to play here right now.');
      });
    });
  });
}

/// An engine whose pause is not reported inside the call (today's
/// `JustAudioEngine` reports it there): the report comes when the test
/// emits it.
class _LateReportEngine extends FakePlaybackEngine {
  @override
  Future<void> pause() async {
    pauseCalls++;
    wantsPlaying = false;
  }
}

class _LoggingPreviewEngine extends FakePreviewEngine {
  _LoggingPreviewEngine(this.output);
  final List<String> output;

  @override
  Future<void> play() async {
    await super.play();
    output.add('preview on');
  }

  @override
  Future<void> pause() async {
    await super.pause();
    output.add('preview off');
  }

  @override
  Future<void> stop() async {
    await super.stop();
    if (output.isNotEmpty && output.last != 'preview off') {
      output.add('preview off');
    }
  }
}

class _SpyRequests extends PlaybackRequests {
  _SpyRequests(super.ref);
  int submits = 0;

  @override
  Future<PlaybackOutcome> submit(PlaybackRequest request) {
    submits++;
    return super.submit(request);
  }
}

class _SpyClicks extends ClickRecorder {
  _SpyClicks({required super.history, required super.binding,
      required super.clock});
  int records = 0;

  @override
  Future<void> record(HistoryIntent intent) {
    records++;
    return super.record(intent);
  }
}

/// Fails if the library and preview outputs were ever on at once.
void _expectNoOverlap(List<String> output) {
  var library = false;
  var preview = false;
  for (final event in output) {
    switch (event) {
      case 'library on':
        library = true;
      case 'library off':
        library = false;
      case 'preview on':
        preview = true;
      case 'preview off':
        preview = false;
    }
    expect(library && preview, isFalse, reason: 'overlap in $output');
  }
}

/// A preview owner whose output the test switches on; relinquishing turns
/// it off and acknowledges at once.
class _OutputPreview implements AudioFocusOwner, FocusRelinquisher {
  _OutputPreview(this.output);
  final List<String> output;

  @override
  Future<void> relinquishFocus() async => output.add('preview off');

  @override
  void onInterruptionBegan() {}

  @override
  void onInterruptionEnded({required bool shouldResume}) {}

  @override
  void onBecameNoisy() {}
}

/// A just_audio plugin whose load completes when the test says so, and
/// which records when the library output starts and stops.
class _GatedPlugin extends Mock implements ja.AudioPlayer {
  _GatedPlugin(this.output) {
    registerFallbackValue(_FakeAudioSource());
    registerFallbackValue(Duration.zero);
    registerFallbackValue(ja.LoopMode.off);
    when(() => setAudioSources(any(),
            initialIndex: any(named: 'initialIndex'),
            initialPosition: any(named: 'initialPosition')))
        .thenAnswer((_) {
      loadCalls++;
      return _load.future;
    });
    when(() => this.play()).thenAnswer((_) {
      output.add('library on');
      return Completer<void>().future;
    });
    when(() => pause()).thenAnswer((_) async => output.add('library off'));
    when(() => stop()).thenAnswer((_) async => output.add('library off'));
    when(() => setLoopMode(any())).thenAnswer((_) async {});
    when(() => setVolume(any())).thenAnswer((_) async {});
    when(() => setShuffleModeEnabled(any())).thenAnswer((_) async {});
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
  final List<String> output;
  final _load = Completer<Duration?>();
  int loadCalls = 0;

  void finishLoad() => _load.complete(null);
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

  /// When set, the next explicit-list session creation fails with it (a
  /// repository write that fails).
  Object? createSessionError;

  @override
  Future<int> createSessionFromExplicitList({
    required String sourceType,
    int? sourceArtistId,
    int? sourceAlbumId,
    required List<String> trackUuids,
    int currentIndex = 0,
    String repeatMode = 'off',
    bool shuffleEnabled = false,
    bool activate = true,
    List<int>? playOrder,
  }) {
    final error = createSessionError;
    if (error != null) {
      createSessionError = null;
      return Future.error(error);
    }
    return super.createSessionFromExplicitList(
      sourceType: sourceType,
      sourceArtistId: sourceArtistId,
      sourceAlbumId: sourceAlbumId,
      trackUuids: trackUuids,
      currentIndex: currentIndex,
      repeatMode: repeatMode,
      shuffleEnabled: shuffleEnabled,
      activate: activate,
      playOrder: playOrder,
    );
  }

  /// Runs after every play-order rewrite (e.g. a sync removal landing right
  /// after the wrap's order write).
  Future<void> Function(int sessionId)? afterReplacePlayOrder;

  /// Runs before every play-order rewrite (it may hold it).
  Future<void> Function(int sessionId)? beforeReplacePlayOrder;

  /// When set, the next play-order rewrite fails with it (one shot).
  Object? replacePlayOrderError;

  @override
  Future<void> replacePlayOrder(int sessionId, List<int> itemIds) async {
    await beforeReplacePlayOrder?.call(sessionId);
    final error = replacePlayOrderError;
    if (error != null) {
      replacePlayOrderError = null;
      throw error;
    }
    await super.replacePlayOrder(sessionId, itemIds);
    await afterReplacePlayOrder?.call(sessionId);
  }

  /// Runs before every activation (the window between a request's prepare
  /// and its activation, where catalog sync can still change the session).
  Future<void> Function(int sessionId)? beforeActivation;

  @override
  Future<void> activateSession(int sessionId) async {
    await beforeActivation?.call(sessionId);
    if (sessionId == failActivationOf) {
      failActivationOf = null;
      throw StateError('db gone');
    }
    return super.activateSession(sessionId);
  }

  /// When set, the next recording of a prepared target fails with it.
  Object? setPreparedCurrentItemError;

  /// Runs before every recording of a prepared target (one shot by the
  /// test that sets it).
  Future<void> Function(int sessionId)? beforeSetPreparedCurrentItem;

  @override
  Future<void> setPreparedCurrentItem(
      int sessionId, int itemId, int expectedPlayPosition) async {
    await beforeSetPreparedCurrentItem?.call(sessionId);
    final error = setPreparedCurrentItemError;
    if (error != null) {
      setPreparedCurrentItemError = null;
      return Future.error(error);
    }
    return super.setPreparedCurrentItem(sessionId, itemId, expectedPlayPosition);
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
  /// When set, the next session snapshot read waits on it (one shot).
  Completer<void>? sessionSnapshotGate;
  final sessionSnapshotEntered = Completer<void>();

  @override
  Future<QueueSessionSnapshot?> getSessionSnapshot(int sessionId) async {
    final gate = sessionSnapshotGate;
    if (gate != null) {
      sessionSnapshotGate = null;
      if (!sessionSnapshotEntered.isCompleted) {
        sessionSnapshotEntered.complete();
      }
      await gate.future;
    }
    return super.getSessionSnapshot(sessionId);
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
    if (gate != null && limit == QueueWindow.hydrationChunk) {
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

  /// When set, the next cursor save fails with it (a database write that
  /// fails).
  Object? cursorSaveError;

  @override
  Future<void> updatePlaybackCursor({
    required int sessionId,
    required int currentItemId,
    required int positionMs,
  }) {
    final error = cursorSaveError;
    if (error != null) {
      cursorSaveError = null;
      return Future.error(error);
    }
    cursorSaves.add(positionMs);
    return super.updatePlaybackCursor(
      sessionId: sessionId,
      currentItemId: currentItemId,
      positionMs: positionMs,
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
  _GatedCoverArt({this.local}) : super.noop();
  final Uri? local;
  final entered = Completer<void>();
  final release = Completer<Uri?>();
  int resolveCalls = 0;
  @override
  Uri? localArtUri(int coverArtId) => local;
  @override
  Future<Uri?> resolveArtUri({required bool hasAlbumArt, required int? coverArtId}) {
    if (!hasAlbumArt || coverArtId == null) return Future.value(null);
    resolveCalls++;
    if (!entered.isCompleted) entered.complete();
    // Only the first lookup is gated; later items resolve to no art.
    return resolveCalls == 1 ? release.future : Future.value(null);
  }
}

/// Every play-order row of a session: (play position, canonical position,
/// uuid), straight from the tables.
Future<List<(int, int, String)>> _orderRows(AppDatabase db, int sessionId) async {
  final rows = await db.customSelect(
    'SELECT po.play_position, qsi.position, qsi.uuid_id '
    'FROM queue_session_play_order AS po '
    'JOIN queue_session_items AS qsi ON qsi.item_id = po.item_id '
    'WHERE po.session_id = ? ORDER BY po.play_position',
    variables: [Variable.withInt(sessionId)],
  ).get();
  return [
    for (final r in rows)
      (r.read<int>('play_position'), r.read<int>('position'),
          r.read<String>('uuid_id')),
  ];
}

/// A generator whose first `nextInt` answer is scripted (the first pick of a
/// collection shuffle); every later draw comes from [_rest].
class _FirstPickRandom implements Random {
  _FirstPickRandom(this._first, this._rest);
  final int Function(int max) _first;
  final Random _rest;
  int? firstMax;

  @override
  int nextInt(int max) {
    if (firstMax == null) {
      firstMax = max;
      return _first(max);
    }
    return _rest.nextInt(max);
  }

  @override
  double nextDouble() => _rest.nextDouble();

  @override
  bool nextBool() => _rest.nextBool();
}

/// Counts the draws a shuffle makes from the injected generator.
class _RecordingRandom implements Random {
  _RecordingRandom(this._inner);
  final Random _inner;
  int draws = 0;

  @override
  int nextInt(int max) {
    draws++;
    return _inner.nextInt(max);
  }

  @override
  double nextDouble() {
    draws++;
    return _inner.nextDouble();
  }

  @override
  bool nextBool() {
    draws++;
    return _inner.nextBool();
  }
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
  _RecordingWarm(QueueRepository repo)
      : super(queueRepo: repo, apiClient: noServerApi());
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
      : super(db: db, statusReader: DownloadStatusReader());
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

/// 7P.1: a scripted just_audio player: loads complete at once and are
/// recorded; the test sets the processing state, fails inserts and reports
/// indices, deterministically.
class _ScriptedPlugin extends Mock implements ja.AudioPlayer {
  _ScriptedPlugin() {
    registerFallbackValue(_FakeAudioSource());
    registerFallbackValue(Duration.zero);
    registerFallbackValue(ja.LoopMode.off);
    when(() => setAudioSources(any(),
            initialIndex: any(named: 'initialIndex'),
            initialPosition: any(named: 'initialPosition')))
        .thenAnswer((invocation) async {
      final sources = invocation.positionalArguments[0] as List;
      final index = invocation.namedArguments[#initialIndex] as int? ?? 0;
      loads.add((
        count: sources.length,
        uris: [for (final s in sources) (s as ja.UriAudioSource).uri],
        initialIndex: index,
        initialPosition:
            invocation.namedArguments[#initialPosition] as Duration? ??
                Duration.zero,
      ));
      _index = index;
      return const Duration(minutes: 3);
    });
    when(() => seek(any(), index: any(named: 'index')))
        .thenAnswer((invocation) async {
      final index = invocation.namedArguments[#index] as int?;
      if (index != null) _index = index;
    });
    when(() => insertAudioSource(any(), any())).thenAnswer((_) async {
      if (failInserts) throw ja.PlayerException(1, 'insert refused', 0);
    });
    when(() => removeAudioSourceAt(any())).thenAnswer((_) async {});
    when(() => this.play()).thenAnswer((_) => Completer<void>().future);
    when(() => pause()).thenAnswer((_) async {});
    when(() => stop()).thenAnswer((_) async {});
    when(() => setLoopMode(any())).thenAnswer((_) async {});
    when(() => setVolume(any())).thenAnswer((_) async {});
    when(() => dispose()).thenAnswer((_) async {});
    when(() => playing).thenAnswer((_) => _playing);
    when(() => processingState).thenAnswer((_) => processing);
    when(() => duration).thenReturn(const Duration(minutes: 3));
    when(() => position).thenReturn(Duration.zero);
    when(() => speed).thenReturn(1.0);
    when(() => currentIndex).thenAnswer((_) => _index);
    when(() => currentIndexStream).thenAnswer((_) => _indices.stream);
    when(() => playerStateStream).thenAnswer((_) => _states.stream);
    when(() => positionStream).thenAnswer((_) => const Stream.empty());
    when(() => durationStream).thenAnswer((_) => const Stream.empty());
    when(() => positionDiscontinuityStream)
        .thenAnswer((_) => const Stream.empty());
    when(() => errorStream).thenAnswer((_) => const Stream.empty());
  }

  final loads = <({
    int count,
    List<Uri> uris,
    int initialIndex,
    Duration initialPosition
  })>[];
  final _indices = StreamController<int?>.broadcast();
  final _states = StreamController<ja.PlayerState>.broadcast();
  int _index = 0;
  bool _playing = false;
  bool failInserts = false;
  ja.ProcessingState processing = ja.ProcessingState.ready;

  void state(ja.ProcessingState next, {required bool playing}) {
    processing = next;
    _playing = playing;
    _states.add(ja.PlayerState(playing, next));
  }

  void reportIndex(int index) {
    _index = index;
    _indices.add(index);
  }
}

/// A gate whose states the test publishes.
class _StatesGate extends Fake implements ServerBindingGate {
  final _states = StreamController<BindingGateState>.broadcast();
  BindingGateState _state = const BindingIdle();
  void publish(BindingGateState s) {
    _state = s;
    _states.add(s);
  }

  Future<void> close() => _states.close();
  @override
  BindingGateState get state => _state;
  @override
  Stream<BindingGateState> get states => _states.stream;
}
