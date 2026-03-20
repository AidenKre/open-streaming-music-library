import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_player_controller.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/audio/queue_resolver.dart';
import 'package:frontend/providers/audio/track_cache_manager.dart';
import 'package:frontend/providers/providers.dart';

class PlayTrackCall {
  final TrackUI track;
  final bool shouldPlay;
  final Duration initialPosition;
  final TrackCacheManager cache;
  final int generation;

  const PlayTrackCall({
    required this.track,
    required this.shouldPlay,
    required this.initialPosition,
    required this.cache,
    required this.generation,
  });
}

class FakePlayerController implements AudioPlayerController {
  @override
  TrackCompletedCallback? onTrackCompleted;

  @override
  StatusChangedCallback? onStatusChanged;

  @override
  PositionChangedCallback? onPositionChanged;

  @override
  DurationChangedCallback? onDurationChanged;

  int _generation = 0;
  final List<PlayTrackCall> playTrackCalls = [];
  int playCalls = 0;
  int pauseCalls = 0;
  int seekCalls = 0;
  int stopCalls = 0;
  int setVolumeCalls = 0;
  Duration? lastSeekPosition;
  double? lastVolume;
  bool playTrackShouldSucceed = true;

  @override
  int get generation => _generation;

  @override
  int incrementGeneration() => ++_generation;

  @override
  Future<bool> playTrack(
    TrackUI track, {
    required bool shouldPlay,
    required Duration initialPosition,
    required TrackCacheManager cache,
    required int generation,
  }) async {
    playTrackCalls.add(PlayTrackCall(
      track: track,
      shouldPlay: shouldPlay,
      initialPosition: initialPosition,
      cache: cache,
      generation: generation,
    ));
    return playTrackShouldSucceed;
  }

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
    seekCalls++;
    lastSeekPosition = position;
  }

  @override
  Future<void> setVolume(double volume) async {
    setVolumeCalls++;
    lastVolume = volume;
  }

  @override
  Future<void> stop() async {
    _generation++;
    stopCalls++;
  }

  @override
  void dispose() {}

  void emitStatus(PlayerStatus status) {
    onStatusChanged?.call(status);
  }

  void emitPosition(Duration position) {
    onPositionChanged?.call(position);
  }

  void emitDuration(Duration duration) {
    onDurationChanged?.call(duration);
  }

  Future<void> emitTrackCompleted() async {
    await onTrackCompleted?.call();
  }

  void resetCounters() {
    playTrackCalls.clear();
    playCalls = 0;
    pauseCalls = 0;
    seekCalls = 0;
    stopCalls = 0;
    setVolumeCalls = 0;
    lastSeekPosition = null;
    lastVolume = null;
    playTrackShouldSucceed = true;
  }
}

class FakeTrackCacheManager implements TrackCacheManager {
  final Map<String, File> cachedFiles = {};
  final List<String> prefetchedUuids = [];
  final List<String> evictedUuids = [];
  int cancelPrefetchCalls = 0;
  int clearCalls = 0;

  @override
  File? getCachedFile(String uuidId) => cachedFiles[uuidId];

  @override
  Future<void> prefetch(TrackUI track) async {
    prefetchedUuids.add(track.uuidId);
  }

  @override
  Future<void> cancelPrefetch() async {
    cancelPrefetchCalls++;
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    cachedFiles.clear();
  }

  @override
  Future<void> evict(String uuidId) async {
    evictedUuids.add(uuidId);
    cachedFiles.remove(uuidId);
  }

  void resetCounters() {
    prefetchedUuids.clear();
    evictedUuids.clear();
    cancelPrefetchCalls = 0;
    clearCalls = 0;
  }
}

class FakeQueueLookup implements AudioQueueLookup {
  final Map<String, ({List<TrackUI> previous, List<TrackUI> next})> candidates;
  final Map<String, List<TrackUI>> upcoming;

  int resolveCandidatesCalls = 0;
  int resolveUpcomingCalls = 0;

  FakeQueueLookup({this.candidates = const {}, this.upcoming = const {}});

  @override
  Future<({List<TrackUI> previous, List<TrackUI> next})> resolveCandidates({
    required TrackUI current,
    required QueueContext context,
    required ShuffleSlice shuffle,
    required QueueRepeatMode repeatMode,
    required int limit,
  }) async {
    resolveCandidatesCalls++;
    return candidates[current.uuidId] ??
        (previous: const <TrackUI>[], next: const <TrackUI>[]);
  }

  @override
  Future<List<TrackUI>> resolveUpcoming({
    required TrackUI track,
    required QueueContext context,
    required ShuffleSlice shuffle,
    required QueueRepeatMode repeatMode,
  }) async {
    resolveUpcomingCalls++;
    return upcoming[track.uuidId] ?? const [];
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

void main() {
  late AppDatabase db;
  ProviderContainer? container;
  late FakePlayerController fakePlayer;
  late FakeTrackCacheManager fakeCache;
  late RecordingAudioServiceBridge bridge;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    fakePlayer = FakePlayerController();
    fakeCache = FakeTrackCacheManager();
    bridge = RecordingAudioServiceBridge();
    _nextArtistId = 1;
    _nextAlbumId = 1;
    _artistIds.clear();
    _albumIds.clear();
  });

  tearDown(() async {
    await bridge.disposeBridge();
    container?.dispose();
    await db.close();
  });

  ProviderContainer createContainer({AudioQueueLookup? queueLookup}) {
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        audioPlayerProvider.overrideWithValue(fakePlayer),
        trackCacheProvider.overrideWithValue(fakeCache),
        audioQueueLookupProvider.overrideWithValue(
          queueLookup ?? FakeQueueLookup(),
        ),
        audioServiceProvider.overrideWithValue(bridge),
      ],
    );
    return container!;
  }

  group('AudioCoordinator bug regressions', () {
    test(
      'failed playTrack should keep current track and background state unchanged',
      () async {
        final a = _track(
          'a',
          title: 'A',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 1,
        );
        final b = _track(
          'b',
          title: 'B',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 2,
        );
        final cTrack = _track(
          'c',
          title: 'C',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 3,
        );
        final d = _track(
          'd',
          title: 'D',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 4,
        );
        final queue = FakeQueueLookup(
          candidates: {
            'a': (previous: [d], next: [b]),
            'b': (previous: [a], next: [cTrack]),
          },
          upcoming: {
            'a': [b, cTrack],
            'b': [cTrack, d],
          },
        );

        final c = createContainer(queueLookup: queue);
        final notifier = c.read(audioProvider.notifier);
        final context = QueueContext(
          artistId: 1,
          albumId: 1,
          orderParams: [OrderParameter(column: 'track_number')],
        );

        await notifier.playFromQueue(context, a);
        fakePlayer.emitStatus(PlayerStatus.playing);
        await Future<void>.delayed(Duration.zero);

        expect(c.read(audioProvider).playback.currentTrack?.uuidId, 'a');
        expect(c.read(audioProvider).playback.status, PlayerStatus.playing);
        expect(bridge.mediaItemEvents.whereType<MediaItem>().last.id, 'a');
        expect(
          c.read(audioProvider).queue.upcomingTracks.map((track) => track.uuidId),
          ['b', 'c'],
        );

        fakePlayer.playTrackShouldSucceed = false;
        await notifier.skipToTrack(b);
        await Future<void>.delayed(Duration.zero);

        expect(c.read(audioProvider).playback.currentTrack?.uuidId, 'a');
        expect(c.read(audioProvider).playback.status, PlayerStatus.playing);
        expect(
          c.read(audioProvider).queue.upcomingTracks.map((track) => track.uuidId),
          ['b', 'c'],
        );
        expect(bridge.mediaItemEvents.whereType<MediaItem>().last.id, 'a');
      },
    );

    test(
      'repeat-all upcoming queue should wrap at the end of the queue without replaying the current track',
      () async {
        await _insertTrack(
          db,
          uuid: 'a',
          title: 'A',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 1,
        );
        await _insertTrack(
          db,
          uuid: 'b',
          title: 'B',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 2,
        );
        final current = await _insertTrack(
          db,
          uuid: 'c',
          title: 'C',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 3,
        );

        final c = createContainer(queueLookup: QueueResolver(db));
        final notifier = c.read(audioProvider.notifier);
        final context = QueueContext(
          artistId: 1,
          albumId: 1,
          orderParams: [
            OrderParameter(column: 'track_number'),
            OrderParameter(column: 'uuid_id'),
          ],
        );

        await notifier.playFromQueue(context, current);
        fakePlayer.resetCounters();
        fakeCache.resetCounters();

        await notifier.cycleQueueRepeatMode();

        expect(
          c.read(audioProvider).queue.upcomingTracks.map((track) => track.uuidId),
          ['a', 'b'],
        );
        expect(fakePlayer.playTrackCalls, isEmpty);
      },
    );

    test('playFromQueue prefetches the next track in non-shuffle playback', () async {
      final a = await _insertTrack(
        db,
        uuid: 'a',
        title: 'A',
        artist: 'Artist',
        album: 'Album',
        trackNumber: 1,
      );
      await _insertTrack(
        db,
        uuid: 'b',
        title: 'B',
        artist: 'Artist',
        album: 'Album',
        trackNumber: 2,
      );
      await _insertTrack(
        db,
        uuid: 'c',
        title: 'C',
        artist: 'Artist',
        album: 'Album',
        trackNumber: 3,
      );

      final c = createContainer(queueLookup: QueueResolver(db));
      final notifier = c.read(audioProvider.notifier);
      final context = QueueContext(
        artistId: 1,
        albumId: 1,
        orderParams: [
          OrderParameter(column: 'track_number'),
          OrderParameter(column: 'uuid_id'),
        ],
      );

      await notifier.playFromQueue(context, a);

      expect(c.read(audioProvider).queue.upcomingTracks.map((track) => track.uuidId), [
        'b',
        'c',
      ]);
      expect(fakeCache.prefetchedUuids, contains('b'));
    });

    test(
      'toggleShuffle keeps the current track first in the shuffled order and leaves the player untouched',
      () async {
        final a = await _insertTrack(
          db,
          uuid: 'a',
          title: 'A',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 1,
        );
        await _insertTrack(
          db,
          uuid: 'b',
          title: 'B',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 2,
        );
        await _insertTrack(
          db,
          uuid: 'c',
          title: 'C',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 3,
        );

        final c = createContainer(queueLookup: QueueResolver(db));
        final notifier = c.read(audioProvider.notifier);
        final context = QueueContext(
          artistId: 1,
          albumId: 1,
          orderParams: [
            OrderParameter(column: 'track_number'),
            OrderParameter(column: 'uuid_id'),
          ],
        );

        await notifier.playFromQueue(context, a);
        fakePlayer.resetCounters();
        fakeCache.resetCounters();

        await notifier.toggleShuffle();

        final state = c.read(audioProvider);
        expect(state.shuffle.shuffleOn, isTrue);
        expect(state.shuffle.shuffledUuids.first, 'a');
        expect(fakePlayer.playTrackCalls, isEmpty);
        expect(fakeCache.cancelPrefetchCalls, 1);
      },
    );

    test('skipNext should not stop when upcoming queue entries still exist', () async {
      final cTrack = _track('c');
      final d = _track('d');

      final c = createContainer();
      final notifier = c.read(audioProvider.notifier);
      notifier.debugSetState(
        AudioState(
          playback: PlaybackSlice(
            currentTrack: cTrack,
            status: PlayerStatus.playing,
          ),
          queue: QueueSlice(
            queueContext: QueueContext(
              orderParams: [OrderParameter(column: 'track_number')],
            ),
            upcomingTracks: [d],
          ),
        ),
      );
      fakePlayer.resetCounters();

      await notifier.skipNext();

      expect(fakePlayer.stopCalls, 0);
      expect(fakePlayer.playTrackCalls.single.track.uuidId, 'd');
      expect(c.read(audioProvider).playback.currentTrack?.uuidId, 'd');
    });

    test(
      'skipPrevious should not restart current song when a logical previous track exists',
      () async {
        final a = _track('a');
        final b = _track('b');
        final cTrack = _track('c');
        final queue = FakeQueueLookup(
          candidates: {
            'b': (previous: [a], next: [cTrack]),
          },
        );

        final c = createContainer(queueLookup: queue);
        final notifier = c.read(audioProvider.notifier);
        notifier.debugSetState(
          AudioState(
            playback: PlaybackSlice(
              currentTrack: b,
              status: PlayerStatus.playing,
              position: Duration.zero,
            ),
            queue: QueueSlice(
              queueContext: QueueContext(
                orderParams: [OrderParameter(column: 'track_number')],
              ),
            ),
          ),
        );
        fakePlayer.resetCounters();

        await notifier.skipPrevious();

        expect(fakePlayer.seekCalls, 0);
        expect(fakePlayer.playTrackCalls.single.track.uuidId, 'a');
        expect(c.read(audioProvider).playback.currentTrack?.uuidId, 'a');
      },
    );

    test(
      'skipPrevious on first track with repeat-off should restart instead of wrapping to last track',
      () async {
        final a = await _insertTrack(
          db,
          uuid: 'a',
          title: 'A',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 1,
        );
        await _insertTrack(
          db,
          uuid: 'b',
          title: 'B',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 2,
        );
        await _insertTrack(
          db,
          uuid: 'c',
          title: 'C',
          artist: 'Artist',
          album: 'Album',
          trackNumber: 3,
        );

        final c = createContainer(queueLookup: QueueResolver(db));
        final notifier = c.read(audioProvider.notifier);
        final context = QueueContext(
          artistId: 1,
          albumId: 1,
          orderParams: [
            OrderParameter(column: 'track_number'),
            OrderParameter(column: 'uuid_id'),
          ],
        );

        await notifier.playFromQueue(context, a);
        fakePlayer.resetCounters();

        await notifier.skipPrevious();

        expect(c.read(audioProvider).playback.currentTrack?.uuidId, 'a');
        expect(fakePlayer.seekCalls, 1);
        expect(fakePlayer.playTrackCalls, isEmpty);
      },
    );

    test(
      'repeat-one natural sequence end should restart the current track instead of idling',
      () async {
        final current = _track('b');

        final c = createContainer();
        final notifier = c.read(audioProvider.notifier);
        notifier.debugSetState(
          AudioState(
            playback: PlaybackSlice(
              currentTrack: current,
              status: PlayerStatus.playing,
            ),
            queue: QueueSlice(
              queueContext: QueueContext(
                orderParams: [OrderParameter(column: 'track_number')],
              ),
              repeatMode: QueueRepeatMode.one,
            ),
          ),
        );
        fakePlayer.resetCounters();

        fakePlayer.emitStatus(PlayerStatus.idle);
        await fakePlayer.emitTrackCompleted();
        await Future<void>.delayed(Duration.zero);

        expect(fakePlayer.seekCalls, 1);
        expect(fakePlayer.playCalls, 1);
        expect(c.read(audioProvider).playback.status, isNot(PlayerStatus.idle));
      },
    );

    test(
      'natural completion should not broadcast idle to bridge when a next track exists',
      () async {
        final a = _track('a');
        final b = _track('b');
        final queue = FakeQueueLookup(
          upcoming: {'a': [b]},
        );

        final c = createContainer(queueLookup: queue);
        final notifier = c.read(audioProvider.notifier);
        notifier.debugSetState(
          AudioState(
            playback: PlaybackSlice(
              currentTrack: a,
              status: PlayerStatus.playing,
            ),
            queue: QueueSlice(
              queueContext: QueueContext(
                orderParams: [OrderParameter(column: 'track_number')],
              ),
              upcomingTracks: [b],
            ),
          ),
        );
        bridge.playbackStateEvents.clear();

        // Simulate what the real player controller does on track completion:
        // 1. onStatusChanged fires with idle
        // 2. onTrackCompleted fires
        fakePlayer.emitStatus(PlayerStatus.idle);
        await fakePlayer.emitTrackCompleted();
        await Future<void>.delayed(Duration.zero);

        // The bridge should never have received AudioProcessingState.idle
        // between tracks — this would tear down the background audio session
        final idleEvents = bridge.playbackStateEvents.where(
          (e) => e.processingState == AudioProcessingState.idle,
        );
        expect(
          idleEvents,
          isEmpty,
          reason:
              'Bridge received idle between tracks, tearing down the audio session',
        );
      },
    );

    test('natural completion should play the next track', () async {
      final a = _track('a', duration: 180);
      final b = _track('b', duration: 245);
      final queue = FakeQueueLookup(
        upcoming: {
          'a': [b],
        },
      );

      final c = createContainer(queueLookup: queue);
      final notifier = c.read(audioProvider.notifier);
      notifier.debugSetState(
        AudioState(
          playback: PlaybackSlice(
            currentTrack: a,
            status: PlayerStatus.playing,
            position: const Duration(minutes: 2),
            duration: const Duration(seconds: 180),
          ),
          queue: QueueSlice(
            queueContext: QueueContext(
              orderParams: [OrderParameter(column: 'track_number')],
            ),
            upcomingTracks: [b],
          ),
        ),
      );
      fakePlayer.resetCounters();

      await fakePlayer.emitTrackCompleted();
      await Future<void>.delayed(Duration.zero);

      expect(fakePlayer.playTrackCalls.single.track.uuidId, 'b');
      expect(c.read(audioProvider).playback.currentTrack?.uuidId, 'b');
      expect(
        c.read(audioProvider).playback.duration,
        const Duration(seconds: 245),
      );
      expect(bridge.playbackStateEvents.last.updatePosition, Duration.zero);
    });

    test(
      'position updates while playing should be forwarded to audio_service playbackState',
      () async {
        final current = _track('b', duration: 240);

        final c = createContainer(queueLookup: FakeQueueLookup());
        final notifier = c.read(audioProvider.notifier);
        notifier.debugSetState(
          AudioState(
            playback: PlaybackSlice(
              currentTrack: current,
              status: PlayerStatus.playing,
              position: Duration.zero,
              duration: const Duration(minutes: 4),
            ),
            queue: QueueSlice(
              queueContext: QueueContext(
                orderParams: [OrderParameter(column: 'track_number')],
              ),
            ),
          ),
        );

        fakePlayer.emitStatus(PlayerStatus.playing);
        await Future<void>.delayed(Duration.zero);
        expect(bridge.playbackStateEvents.last.updatePosition, Duration.zero);

        fakePlayer.emitPosition(const Duration(seconds: 90));
        await Future<void>.delayed(Duration.zero);

        expect(
          bridge.playbackStateEvents.last.updatePosition,
          const Duration(seconds: 90),
        );
      },
    );

    test('stop should clear the now playing item in audio_service and cache', () async {
      final current = _track('b', title: 'B');
      final queue = FakeQueueLookup(
        upcoming: {
          'b': [_track('c')],
        },
      );

      final c = createContainer(queueLookup: queue);
      final notifier = c.read(audioProvider.notifier);
      final context = QueueContext(
        orderParams: [OrderParameter(column: 'track_number')],
      );

      await notifier.playFromQueue(context, current);
      await notifier.stop();

      expect(bridge.mediaItemEvents.where((item) => item != null), hasLength(1));
      expect(bridge.mediaItemEvents.whereType<MediaItem>().single.id, 'b');
      expect(bridge.mediaItemEvents.last, isNull);
      expect(fakeCache.clearCalls, 1);
      expect(fakePlayer.stopCalls, 1);
    });
  });
}

TrackUI _track(
  String uuid, {
  String? title,
  String? artist,
  String? album,
  int? artistId,
  int? albumId,
  int? trackNumber,
  double duration = 180,
}) {
  return TrackUI(
    uuidId: uuid,
    title: title,
    artist: artist,
    album: album,
    artistId: artistId,
    albumId: albumId,
    trackNumber: trackNumber,
    createdAt: 0,
    lastUpdated: 0,
    duration: duration,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: false,
  );
}

int _nextArtistId = 1;
int _nextAlbumId = 1;
final _artistIds = <String, int>{};
final _albumIds = <String, int>{};

int _ensureArtist(String name) =>
    _artistIds.putIfAbsent(name.toLowerCase(), () => _nextArtistId++);
int _ensureAlbum(String name, int artistId) =>
    _albumIds.putIfAbsent('${artistId}_${name.toLowerCase()}', () => _nextAlbumId++);

Future<TrackUI> _insertTrack(
  AppDatabase db, {
  required String uuid,
  required String title,
  required String artist,
  required String album,
  required int trackNumber,
}) async {
  final artistId = _ensureArtist(artist);
  final albumId = _ensureAlbum(album, artistId);

  // Upsert artist and album rows
  await db.into(db.artists).insertOnConflictUpdate(
    ArtistsCompanion(id: Value(artistId), name: Value(artist)),
  );
  await db.into(db.albums).insertOnConflictUpdate(
    AlbumsCompanion(
      id: Value(albumId),
      name: Value(album),
      artistId: Value(artistId),
      isSingleGrouping: const Value(false),
    ),
  );

  final dto = ClientTrackDto.fromJson({
    'uuid_id': uuid,
    'created_at': 1000,
    'last_updated': 2000,
    'metadata': {
      'title': title,
      'artist': artist,
      'album': album,
      'artist_id': artistId,
      'album_id': albumId,
      'track_number': trackNumber,
      'duration': 180.0,
      'bitrate_kbps': 320.0,
      'sample_rate_hz': 44100,
      'channels': 2,
      'has_album_art': false,
    },
  });
  await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
  await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
  return _track(
    uuid,
    title: title,
    artist: artist,
    album: album,
    artistId: artistId,
    albumId: albumId,
    trackNumber: trackNumber,
  );
}
