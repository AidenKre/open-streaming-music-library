import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/audio/concatenating_player_controller.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/download_providers.dart';

void main() {
  late AppDatabase db;
  late QueueRepository repo;
  late _LibraryFixture fixture;
  ProviderContainer? container;
  late FakeConcatenatingPlayerController fakePlayer;
  late RecordingAudioServiceBridge bridge;

  final Set<String> existingFiles = <String>{};
  late StreamController<int> downloadStatusController;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.init('http://localhost:8080');
    initCoverArtCache(CoverArtCacheManager.noop());
    db = AppDatabase(NativeDatabase.memory());
    existingFiles.clear();
    repo = QueueRepository(db, localFileExists: existingFiles.contains);
    fixture = _LibraryFixture(db);
    fakePlayer = FakeConcatenatingPlayerController();
    bridge = RecordingAudioServiceBridge();
    downloadStatusController = StreamController<int>.broadcast();
  });

  tearDown(() async {
    await bridge.disposeBridge();
    container?.dispose();
    await downloadStatusController.close();
    await db.close();
  });

  ProviderContainer createContainer({bool offline = false}) {
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        concatenatingPlayerProvider.overrideWithValue(fakePlayer),
        audioServiceProvider.overrideWithValue(bridge),
        queueRepositoryProvider.overrideWithValue(repo),
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
    container!.listen(audioProvider, (_, _) {});
    return container!;
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

  test('playFromQueue seeds only a bounded initial player queue', () async {
    await fixture.insertAlbum(
      artist: 'Artist',
      album: 'Album',
      uuids: List.generate(120, (i) => 'track-${i + 1}'),
    );
    final startTrack = await fixture.track('track-60');

    final c = createContainer();
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromQueue(
      track: startTrack,
      sourceType: 'album',
      artistId: 1,
      albumId: 1,
      orderParams: [OrderParameter(column: 'track_number')],
    );
    await Future<void>.delayed(Duration.zero);

    final snapshot = await repo.getSessionSnapshot(
      c.read(audioProvider).queue.sessionId!,
    );
    final queueTracks = await c.read(queueTracksProvider.future);

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
      final notifier = c.read(audioProvider.notifier);
      await notifier.playFromQueue(
        track: startTrack,
        sourceType: 'album',
        artistId: 1,
        albumId: 1,
        orderParams: [OrderParameter(column: 'track_number')],
      );
      await Future<void>.delayed(Duration.zero);

      final currentItemId = c.read(audioProvider).queue.currentItemId;
      await notifier.toggleShuffle();
      await Future<void>.delayed(Duration.zero);

      final queueTracks = await c.read(queueTracksProvider.future);
      expect(fakePlayer.seedCalls, hasLength(1));
      expect(fakePlayer.rebuildCalls, hasLength(1));
      expect(c.read(audioProvider).queue.currentItemId, currentItemId);
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
      final notifier = c.read(audioProvider.notifier);
      await notifier.playFromQueue(
        track: startTrack,
        sourceType: 'album',
        artistId: 1,
        albumId: 1,
        orderParams: [OrderParameter(column: 'track_number')],
      );
      await Future<void>.delayed(Duration.zero);

      final canonicalOrder = (await c.read(
        queueTracksProvider.future,
      )).map((entry) => entry.uuidId).toList(growable: false);
      final currentItemId = c.read(audioProvider).queue.currentItemId;

      await notifier.toggleShuffle();
      await Future<void>.delayed(Duration.zero);
      await notifier.toggleShuffle();
      await Future<void>.delayed(Duration.zero);

      final restoredOrder = (await c.read(
        queueTracksProvider.future,
      )).map((entry) => entry.uuidId).toList(growable: false);

      expect(fakePlayer.seedCalls, hasLength(1));
      expect(fakePlayer.rebuildCalls, hasLength(2));
      expect(c.read(audioProvider).queue.currentItemId, currentItemId);
      expect(restoredOrder, canonicalOrder);
      expect(
        await _playOrderCount(db, c.read(audioProvider).queue.sessionId!),
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
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromQueue(
      track: startTrack,
      sourceType: 'album',
      artistId: 1,
      albumId: 1,
      orderParams: [OrderParameter(column: 'track_number')],
    );
    await Future<void>.delayed(Duration.zero);

    final queueTracks = await c.read(queueTracksProvider.future);
    final target = queueTracks.last;
    expect(fakePlayer.hasItem(target.itemId), isFalse);

    await notifier.skipToTrack(target.itemId);
    await Future<void>.delayed(Duration.zero);

    expect(fakePlayer.addedBatches, isNotEmpty);
    expect(fakePlayer.seekedItems.last, target.itemId);
    expect(c.read(audioProvider).queue.currentItemId, target.itemId);
  });

  test('playNext inserts tracks immediately after the current item', () async {
    await fixture.insertSingles(['a', 'b', 'c', 'd', 'e', 'x', 'y']);
    final queueTracks = ['a', 'b', 'c', 'd', 'e'];
    final startTrack = await fixture.track('b');
    final x = await fixture.track('x');
    final y = await fixture.track('y');

    final c = createContainer();
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromTrackList(
      queueTracks,
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.playNext([x, y]);
    await Future<void>.delayed(Duration.zero);

    final entries = await c.read(queueTracksProvider.future);
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
      final notifier = c.read(audioProvider.notifier);
      await notifier.playNext([x, y]);
      await Future<void>.delayed(Duration.zero);

      final sessionId = c.read(audioProvider).queue.sessionId!;
      final entries = await c.read(queueTracksProvider.future);

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
      final notifier = c.read(audioProvider.notifier);
      await notifier.addToQueue([x, y]);
      await Future<void>.delayed(Duration.zero);

      final sessionId = c.read(audioProvider).queue.sessionId!;
      final entries = await c.read(queueTracksProvider.future);

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
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromTrackList(
      const ['a', 'b', 'c', 'd'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.playNext([queued]);
    await Future<void>.delayed(Duration.zero);
    expect(
      (await c.read(queueTracksProvider.future)).map((entry) => entry.uuidId),
      ['a', 'b', 'x', 'c', 'd'],
    );

    await notifier.toggleShuffle();
    await Future<void>.delayed(Duration.zero);
    expect(
      (await c.read(queueTracksProvider.future)).skip(2).first.uuidId,
      'x',
    );

    await notifier.toggleShuffle();
    await Future<void>.delayed(Duration.zero);
    expect(
      (await c.read(queueTracksProvider.future)).map((entry) => entry.uuidId),
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
      c.read(audioProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      await c.read(audioProvider.notifier).playNext([queued]);
      await Future<void>.delayed(Duration.zero);

      final entries = await c.read(queueTracksProvider.future);
      expect(entries.map((entry) => entry.uuidId), [
        'a',
        'd',
        'c',
        'e',
        'x',
        'b',
      ]);
      expect(c.read(currentTrackProvider)?.uuidId, 'e');

      await c.read(audioProvider.notifier).skipNext();
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
      c.read(audioProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(currentTrackProvider)?.uuidId, 'c');
      expect(c.read(audioProvider).queue.currentPlayPosition, 1);

      await c.read(audioProvider.notifier).toggleShuffle();
      await Future<void>.delayed(Duration.zero);

      final entries = await c.read(queueTracksProvider.future);
      expect(entries.map((entry) => entry.uuidId), ['a', 'b', 'c', 'd', 'e']);
      expect(c.read(currentTrackProvider)?.uuidId, 'c');
      expect(c.read(audioProvider).queue.currentPlayPosition, 2);
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
      final notifier = c.read(audioProvider.notifier);
      await notifier.playFromTrackList(
        const ['a', 'b', 'c', 'd'],
        startTrack,
        sourceType: 'search',
      );
      await Future<void>.delayed(Duration.zero);

      await notifier.playNext([x, y]);
      await Future<void>.delayed(Duration.zero);

      final afterInsert = await c.read(queueTracksProvider.future);
      await notifier.skipToTrack(afterInsert[2].itemId);
      await Future<void>.delayed(Duration.zero);

      final snapshotBeforeShuffle = await repo.getSessionSnapshot(
        c.read(audioProvider).queue.sessionId!,
      );
      expect(
        snapshotBeforeShuffle?.session.resumeMainItemId,
        afterInsert[1].itemId,
      );

      await notifier.toggleShuffle();
      await Future<void>.delayed(Duration.zero);
      await notifier.toggleShuffle();
      await Future<void>.delayed(Duration.zero);

      final restored = await c.read(queueTracksProvider.future);
      expect(restored.map((entry) => entry.uuidId), [
        'a',
        'b',
        'x',
        'y',
        'c',
        'd',
      ]);
      expect(c.read(currentTrackProvider)?.uuidId, 'x');
      expect(c.read(audioProvider).queue.currentPlayPosition, 2);
    },
  );

  test(
    'removeFromQueue before the current item updates current play position',
    () async {
      await fixture.insertSingles(['a', 'b', 'c', 'd']);
      final startTrack = await fixture.track('a');

      final c = createContainer();
      final notifier = c.read(audioProvider.notifier);
      await notifier.playFromTrackList(
        const ['a', 'b', 'c', 'd'],
        startTrack,
        sourceType: 'search',
      );
      await Future<void>.delayed(Duration.zero);

      var entries = await c.read(queueTracksProvider.future);
      await notifier.skipToTrack(entries[3].itemId);
      await Future<void>.delayed(Duration.zero);

      await notifier.removeFromQueue(entries[1].itemId);
      await Future<void>.delayed(Duration.zero);

      entries = await c.read(queueTracksProvider.future);
      expect(entries.map((entry) => entry.uuidId), ['a', 'c', 'd']);
      expect(c.read(audioProvider).queue.currentPlayPosition, 2);
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
    c.read(audioProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(fakePlayer.seedCalls, hasLength(1));
    expect(fakePlayer.seedCalls.single.autoPlay, isFalse);
    expect(c.read(currentTrackProvider)?.uuidId, 'c');
    expect(c.read(audioPositionProvider), const Duration(seconds: 42));
  });

  test('restores persisted volume on startup', () async {
    SharedPreferences.setMockInitialValues({'audioVolume': 0.35});

    final c = createContainer();
    c.read(audioProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(c.read(audioVolumeProvider), 0.35);
    expect(fakePlayer.lastVolume, 0.35);
  });

  test('setVolume persists volume preference', () async {
    final c = createContainer();
    c.read(audioProvider);
    await Future<void>.delayed(Duration.zero);

    await c.read(audioProvider.notifier).setVolume(0.42);

    final prefs = await SharedPreferences.getInstance();
    expect(c.read(audioVolumeProvider), 0.42);
    expect(fakePlayer.lastVolume, 0.42);
    expect(prefs.getDouble('audioVolume'), 0.42);
  });

  test('skipNext advances to next track', () async {
    await fixture.insertSingles(['a', 'b', 'c']);
    final startTrack = await fixture.track('a');

    final c = createContainer();
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromTrackList(
      const ['a', 'b', 'c'],
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
      c.read(audioProvider).queue.currentItemId,
    );
  });

  test('skipNext at end with repeat off is a no-op', () async {
    await fixture.insertSingles(['a', 'b']);
    final startTrack = await fixture.track('b');

    final c = createContainer();
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromTrackList(
      const ['a', 'b'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    expect(c.read(currentTrackProvider)?.uuidId, 'b');
    expect(c.read(audioProvider).queue.currentPlayPosition, 1);

    await notifier.skipNext();
    await Future<void>.delayed(Duration.zero);

    expect(c.read(currentTrackProvider)?.uuidId, 'b');
    expect(c.read(audioProvider).queue.currentPlayPosition, 1);
  });

  test('skipNext with repeat-all wraps to first track', () async {
    await fixture.insertSingles(['a', 'b', 'c']);
    final startTrack = await fixture.track('c');

    final c = createContainer();
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromTrackList(
      const ['a', 'b', 'c'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.cycleQueueRepeatMode();
    await Future<void>.delayed(Duration.zero);
    expect(c.read(audioProvider).queue.repeatMode, QueueRepeatMode.all);

    await notifier.skipNext();
    await Future<void>.delayed(Duration.zero);

    expect(c.read(currentTrackProvider)?.uuidId, 'a');
    expect(c.read(audioProvider).queue.currentPlayPosition, 0);
  });

  test('skipPrevious restarts when position > 3s', () async {
    await fixture.insertSingles(['a', 'b', 'c']);
    final startTrack = await fixture.track('b');

    final c = createContainer();
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromTrackList(
      const ['a', 'b', 'c'],
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
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromTrackList(
      const ['a', 'b', 'c'],
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
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromTrackList(
      const ['a', 'b', 'c'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.cycleQueueRepeatMode();
    await Future<void>.delayed(Duration.zero);

    await notifier.skipPrevious();
    await Future<void>.delayed(Duration.zero);

    expect(c.read(currentTrackProvider)?.uuidId, 'c');
    expect(c.read(audioProvider).queue.currentPlayPosition, 2);
  });

  test('cycleQueueRepeatMode cycles off → all → one → off', () async {
    await fixture.insertSingles(['a']);
    final startTrack = await fixture.track('a');

    final c = createContainer();
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromTrackList(
      const ['a'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    expect(c.read(audioProvider).queue.repeatMode, QueueRepeatMode.off);

    await notifier.cycleQueueRepeatMode();
    expect(c.read(audioProvider).queue.repeatMode, QueueRepeatMode.all);
    expect(fakePlayer.lastLoopMode, ja.LoopMode.all);

    await notifier.cycleQueueRepeatMode();
    expect(c.read(audioProvider).queue.repeatMode, QueueRepeatMode.one);
    expect(fakePlayer.lastLoopMode, ja.LoopMode.one);

    await notifier.cycleQueueRepeatMode();
    expect(c.read(audioProvider).queue.repeatMode, QueueRepeatMode.off);
    expect(fakePlayer.lastLoopMode, ja.LoopMode.off);
  });

  test('stop resets state and deactivates session', () async {
    await fixture.insertSingles(['a', 'b']);
    final startTrack = await fixture.track('a');

    final c = createContainer();
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromTrackList(
      const ['a', 'b'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.stop();

    expect(c.read(audioProvider).queue.sessionId, isNull);
    expect(c.read(audioProvider).playback.status, PlayerStatus.idle);
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
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromTrackList(
      const ['a', 'b', 'c'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.addToQueue([x, y]);
    await Future<void>.delayed(Duration.zero);

    final entries = await c.read(queueTracksProvider.future);
    expect(entries.map((entry) => entry.uuidId), ['a', 'x', 'y', 'b', 'c']);
    expect(c.read(currentTrackProvider)?.uuidId, 'a');
  });

  test(
    'bridge media callbacks no-op after the coordinator is disposed',
    () async {
      // Wire up a coordinator, then tear down its scope. An OS notification
      // tap firing afterwards must NOT reach the disposed coordinator/player.
      await fixture.insertSingles(['a']);
      final c = createContainer();
      c.read(audioProvider.notifier); // build the coordinator
      // Let the build's Future.microtask(_restoreStartupState) complete
      // before tearing the scope down; otherwise the in-flight restore
      // throws ref-after-dispose noise unrelated to the assertion below.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(bridge.onPlay, isNotNull);

      container?.dispose();
      container = null;

      expect(bridge.onPlay, isNull);
      expect(bridge.onPause, isNull);
      expect(bridge.onSkipToNext, isNull);
      expect(bridge.onSkipToPrevious, isNull);
      expect(bridge.onSeek, isNull);
      expect(bridge.onStop, isNull);

      // audio_service still routes media button events through the bridge.
      // After clearCallbacks they must be no-ops, not throws — this would
      // previously have called into a torn-down player.
      await bridge.play();
      await bridge.pause();
      await bridge.skipToNext();
      await bridge.skipToPrevious();
      await bridge.seek(const Duration(seconds: 5));
      await bridge.stop();
    },
  );

  test(
    'a newer coordinator rebinding the bridge survives the old one disposing',
    () async {
      // Two coordinators in sequence: scope A binds, scope B binds, then
      // scope A disposes. Owner-aware clearCallbacks must leave B's
      // callbacks intact.
      await fixture.insertSingles(['a']);

      final cA = createContainer();
      cA.read(audioProvider.notifier);
      // Wait for the first coordinator's startup-restore microtask.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final firstOnPlay = bridge.onPlay;
      expect(firstOnPlay, isNotNull);

      // Build a second container against the same bridge — its coordinator
      // rebinds the callbacks.
      final cB = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          concatenatingPlayerProvider.overrideWithValue(
            FakeConcatenatingPlayerController(),
          ),
          audioServiceProvider.overrideWithValue(bridge),
        ],
      );
      addTearDown(cB.dispose);
      cB.read(audioProvider.notifier);
      // Wait for the second coordinator's startup-restore microtask.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        identical(bridge.onPlay, firstOnPlay),
        isFalse,
        reason: 'second coordinator should have rebound onPlay',
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
        final notifier = c.read(audioProvider.notifier);
        final startTrack = await fixture.track('a');
        await notifier.playFromTrackList(
          const ['a', 'b', 'c', 'd', 'e'],
          startTrack,
          sourceType: 'search',
        );
        await Future<void>.delayed(Duration.zero);

        await notifier.skipNext();
        await Future<void>.delayed(Duration.zero);

        expect(c.read(currentTrackProvider)?.uuidId, 'd');
        expect(c.read(audioProvider).queue.currentPlayPosition, 3);
      },
    );

    test(
      'offline skipPrevious searches backward for a downloaded entry',
      () async {
        await fixture.insertSingles(['a', 'b', 'c', 'd', 'e']);
        await markDownloaded('a', '/dl/a');
        await markDownloaded('e', '/dl/e');

        final c = createContainer(offline: true);
        final notifier = c.read(audioProvider.notifier);
        final startTrack = await fixture.track('e');
        await notifier.playFromTrackList(
          const ['a', 'b', 'c', 'd', 'e'],
          startTrack,
          sourceType: 'search',
        );
        await Future<void>.delayed(Duration.zero);

        await notifier.skipPrevious();
        await Future<void>.delayed(Duration.zero);

        expect(c.read(currentTrackProvider)?.uuidId, 'a');
        expect(c.read(audioProvider).queue.currentPlayPosition, 0);
      },
    );

    test(
      'offline repeat-all wraps to a downloaded entry on skipNext',
      () async {
        await fixture.insertSingles(['a', 'b', 'c']);
        await markDownloaded('a', '/dl/a');

        final c = createContainer(offline: true);
        final notifier = c.read(audioProvider.notifier);
        final startTrack = await fixture.track('a');
        await notifier.playFromTrackList(
          const ['a', 'b', 'c'],
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
        final notifier = c.read(audioProvider.notifier);
        final startTrack = await fixture.track('track-1');
        await notifier.playFromQueue(
          track: startTrack,
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
        final notifier = c.read(audioProvider.notifier);
        final startTrack = await fixture.track('a');
        await notifier.playFromTrackList(
          const ['a', 'b', 'c', 'd'],
          startTrack,
          sourceType: 'search',
        );
        await Future<void>.delayed(Duration.zero);

        // Simulate just_audio naturally advancing into the streaming-only
        // entry "b" — the controller surfaces the bad index to the coordinator
        // which must hop the queue forward to "d".
        final entries = await repo.getPlaybackEntries(
          c.read(audioProvider).queue.sessionId!,
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
        c.read(audioProvider);
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
      c.read(audioProvider);
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
        final notifier = c.read(audioProvider.notifier);
        final startTrack = await fixture.track('a');
        await notifier.playFromTrackList(
          const ['a', 'b', 'c'],
          startTrack,
          sourceType: 'search',
        );
        await Future<void>.delayed(Duration.zero);

        // 'b' is currently a streaming-only entry hydrated into the player.
        final bEntryBefore = fakePlayer.loadedItemIds.contains(
          (await repo.getPlaybackEntries(
            c.read(audioProvider).queue.sessionId!,
          )).firstWhere((e) => e.uuidId == 'b').itemId,
        );
        expect(bEntryBefore, isTrue);

        // Seed the version stream with a baseline so the next emission is a
        // genuine prev→next transition (the coordinator suppresses the
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
        final notifier = c.read(audioProvider.notifier);
        final startTrack = await fixture.track('a');
        await notifier.playFromTrackList(
          const ['a', 'b', 'c'],
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
        final notifier = c.read(audioProvider.notifier);
        final startTrack = await fixture.track('a');
        await notifier.playFromTrackList(
          const ['a', 'b', 'c', 'd'],
          startTrack,
          sourceType: 'search',
        );
        await Future<void>.delayed(Duration.zero);

        final entries = await c.read(queueTracksProvider.future);
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
    final notifier = c.read(audioProvider.notifier);
    await notifier.playFromTrackList(
      const ['a', 'b'],
      startTrack,
      sourceType: 'search',
    );
    await Future<void>.delayed(Duration.zero);

    await notifier.seek(const Duration(seconds: 75));

    final snapshot = await repo.getSessionSnapshot(
      c.read(audioProvider).queue.sessionId!,
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
      final notifier = c.read(audioProvider.notifier);
      await notifier.playFromTrackList(
        const ['a', 'b', 'c'],
        startTrack,
        sourceType: 'search',
      );
      await notifier.seek(const Duration(seconds: 45));

      final sessionId = c.read(audioProvider).queue.sessionId!;
      final firstCurrentItemId = c.read(audioProvider).queue.currentItemId;
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
      expect(c.read(audioProvider).queue.currentPlayPosition, 0);
      expect(c.read(audioProvider).queue.totalCount, 2);
      expect(
        c.read(audioProvider).queue.currentItemId,
        isNot(firstCurrentItemId),
      );
      expect(fakePlayer.seedCalls, hasLength(2));
      expect(fakePlayer.seedCalls.last.initialPosition, Duration.zero);
      expect(fakePlayer.seedCalls.last.autoPlay, isTrue);
      expect(
        sessionRow.currentItemId,
        c.read(audioProvider).queue.currentItemId,
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
      final notifier = c.read(audioProvider.notifier);
      await notifier.playFromTrackList(
        const ['a'],
        startTrack,
        sourceType: 'search',
      );
      await Future<void>.delayed(Duration.zero);

      final sessionId = c.read(audioProvider).queue.sessionId!;
      expect(c.read(currentTrackProvider)?.uuidId, 'a');

      await repo.removeTrackUuidsFromQueues(const ['a']);
      await notifier.reconcileAfterSyncQueueMutation({sessionId});

      expect(c.read(audioProvider).queue.sessionId, isNull);
      expect(c.read(audioProvider).queue.currentItemId, isNull);
      expect(c.read(currentTrackProvider), isNull);
      expect(await repo.getActiveSession(), isNull);

      await notifier.addToQueue([nextTrack]);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(c.read(audioProvider).queue.sessionId, isNot(sessionId));
      expect(c.read(audioProvider).queue.currentItemId, isNotNull);
    },
  );

  test(
    'sync queue mutation preserves surviving current item position',
    () async {
      await fixture.insertSingles(['a', 'b', 'c']);
      final startTrack = await fixture.track('b');

      final c = createContainer();
      final notifier = c.read(audioProvider.notifier);
      await notifier.playFromTrackList(
        const ['a', 'b', 'c'],
        startTrack,
        sourceType: 'search',
      );
      await notifier.seek(const Duration(seconds: 45));

      final sessionId = c.read(audioProvider).queue.sessionId!;
      final currentItemId = c.read(audioProvider).queue.currentItemId;
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(c.read(audioProvider).queue.currentPlayPosition, 1);

      await repo.removeTrackUuidsFromQueues(const ['a']);
      await notifier.reconcileAfterSyncQueueMutation({sessionId});

      final sessionRow = await (db.select(
        db.queueSessions,
      )..where((s) => s.id.equals(sessionId))).getSingle();
      expect(await _playOrderCount(db, sessionId), 2);
      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(c.read(audioPositionProvider), const Duration(seconds: 45));
      expect(c.read(audioProvider).queue.currentItemId, currentItemId);
      expect(c.read(audioProvider).queue.currentPlayPosition, 0);
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
      final notifier = c.read(audioProvider.notifier);
      await notifier.playFromTrackList(
        const ['a', 'b', 'c'],
        startTrack,
        sourceType: 'search',
      );
      await notifier.seek(const Duration(seconds: 12));

      fakePlayer.emitPlayerState(
        ja.PlayerState(true, ja.ProcessingState.buffering),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.read(audioProvider).playback.status, PlayerStatus.loading);

      final sessionId = c.read(audioProvider).queue.sessionId!;
      final currentItemId = c.read(audioProvider).queue.currentItemId;

      await repo.removeTrackUuidsFromQueues(const ['c']);
      await notifier.reconcileAfterSyncQueueMutation({sessionId});

      expect(c.read(currentTrackProvider)?.uuidId, 'b');
      expect(c.read(audioPositionProvider), const Duration(seconds: 12));
      expect(c.read(audioProvider).queue.currentItemId, currentItemId);
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

class FakeConcatenatingPlayerController
    implements ConcatenatingPlayerController {
  final _playerStateController = StreamController<ja.PlayerState>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _currentItemIdController = StreamController<int?>.broadcast();
  final _unavailableAdvanceController =
      StreamController<UnavailableAdvance>.broadcast();

  List<QueuePlaybackEntry> _loadedEntries = const [];
  int? _currentLocalIndex;
  int? _committedCurrentItemId;
  Duration _position = Duration.zero;
  bool _disposed = false;

  final List<SeedCall> seedCalls = [];
  final List<List<QueuePlaybackEntry>> addedBatches = [];
  final List<List<QueuePlaybackEntry>> replacedFutureBatches = [];
  final List<List<QueuePlaybackEntry>> rebuildCalls = [];
  final List<int> removedItems = [];
  final List<int> seekedItems = [];
  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  ja.LoopMode? lastLoopMode;
  double? lastVolume;
  String? lastStreamQuality;

  @override
  void setStreamQuality(String quality) {
    lastStreamQuality = quality;
  }

  @override
  Future<void> rebuildCurrentSource(String quality, Duration seekTo) async {}

  @override
  Future<void> rebuildAllSources(String quality, Duration seekTo) async {}

  @override
  Future<void> setSeed(
    List<QueuePlaybackEntry> entries, {
    required int currentItemId,
    Duration initialPosition = Duration.zero,
    bool autoPlay = false,
    bool shuffleEnabled = false,
  }) async {
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
        initialPosition: initialPosition,
        autoPlay: autoPlay,
        shuffleEnabled: shuffleEnabled,
      ),
    );
    _currentItemIdController.add(_committedCurrentItemId);
    if (autoPlay) {
      playCalls++;
    }
  }

  @override
  Future<void> addEntries(List<QueuePlaybackEntry> entries) async {
    final additions = entries
        .where((entry) => !hasItem(entry.itemId))
        .toList(growable: false);
    if (additions.isEmpty) return;

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
    final currentIndex = _loadedEntries.indexWhere(
      (entry) => entry.itemId == currentItemId,
    );
    if (currentIndex < 0) {
      throw StateError('Current item $currentItemId is not loaded');
    }

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

    rebuildCalls.add(List<QueuePlaybackEntry>.from(sorted));
    _loadedEntries = sorted;
    _currentLocalIndex = nextIndex;
    _committedCurrentItemId = currentItemId;
  }

  @override
  Future<void> removeItem(int itemId) async {
    final index = _loadedEntries.indexWhere((entry) => entry.itemId == itemId);
    if (index < 0) return;
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
  }) async {
    final index = _loadedEntries.indexWhere((entry) => entry.itemId == itemId);
    if (index < 0) {
      throw StateError('Item $itemId is not loaded');
    }
    seekedItems.add(itemId);
    _currentLocalIndex = index;
    _committedCurrentItemId = itemId;
    _position = position;
    _currentItemIdController.add(itemId);
  }

  @override
  int? get currentIndex => _currentLocalIndex;

  @override
  int? get currentItemId => _committedCurrentItemId;

  @override
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

  @override
  Future<void> setLoopMode(ja.LoopMode mode) async {
    lastLoopMode = mode;
  }

  @override
  Stream<ja.PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<int?> get currentItemIdStream => _currentItemIdController.stream;

  @override
  Stream<UnavailableAdvance> get unavailableAdvanceStream =>
      _unavailableAdvanceController.stream;

  void emitPlayerState(ja.PlayerState state) {
    _playerStateController.add(state);
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
    _durationController.close();
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
  final Duration initialPosition;
  final bool autoPlay;
  final bool shuffleEnabled;

  const SeedCall({
    required this.entries,
    required this.currentItemId,
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
