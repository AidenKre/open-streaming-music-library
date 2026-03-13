import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/audio/queue_resolver.dart';
import 'package:frontend/providers/audio/window_manager.dart';
import 'package:frontend/providers/providers.dart';

class FakeWindowController implements AudioWindowController {
  @override
  TrackChangeCallback? onTrackChanged;

  @override
  StatusChangedCallback? onStatusChanged;

  @override
  PositionChangedCallback? onPositionChanged;

  @override
  DurationChangedCallback? onDurationChanged;

  List<TrackUI> _windowTracks = const [];
  int? _windowCurrentIndex;
  int _generation = 0;

  int fullReplaceCalls = 0;
  int slideForwardCalls = 0;
  int reconfigureCalls = 0;
  int stopPlaybackCalls = 0;
  int stopPlayerCalls = 0;
  int seekToIndexCalls = 0;
  int seekCalls = 0;
  int playCalls = 0;
  String? acknowledgedTrackUuid;

  @override
  List<TrackUI> get windowTracks => _windowTracks;

  @override
  int? get windowCurrentIndex => _windowCurrentIndex;

  @override
  int get generation => _generation;

  @override
  int incrementGeneration() => ++_generation;

  @override
  Future<void> enqueueMutation(Future<void> Function() action) async {
    await action();
  }

  @override
  Future<void> slideForward(TrackUI newNext, {required int generation}) async {
    slideForwardCalls++;
    if (_windowTracks.isEmpty || _windowCurrentIndex == null) return;
    _windowTracks = List<TrackUI>.unmodifiable([
      ..._windowTracks.sublist(1),
      newNext,
    ]);
    _windowCurrentIndex = (_windowCurrentIndex! - 1).clamp(
      0,
      _windowTracks.length - 1,
    );
  }

  @override
  Future<void> reconfigureNeighbors(
    TrackUI? newPrev,
    TrackUI? newNext, {
    required int generation,
  }) async {
    reconfigureCalls++;
    if (_windowTracks.isEmpty || _windowCurrentIndex == null) return;
    final current = _windowTracks[_windowCurrentIndex!];
    final nextTracks = <TrackUI>[
      if (newPrev != null) newPrev,
      current,
      if (newNext != null) newNext,
    ];
    _windowTracks = List<TrackUI>.unmodifiable(nextTracks);
    _windowCurrentIndex = newPrev == null ? 0 : 1;
  }

  @override
  Future<bool> fullReplace(
    List<TrackUI> tracks,
    int currentIndex, {
    required int generation,
    required bool shouldPlay,
    required Duration initialPosition,
  }) async {
    fullReplaceCalls++;
    _windowTracks = List<TrackUI>.unmodifiable(tracks);
    _windowCurrentIndex = currentIndex;
    if (shouldPlay) {
      playWithoutAwait();
    }
    return true;
  }

  @override
  Future<void> seekToIndex(
    int index, {
    Duration position = Duration.zero,
  }) async {
    seekToIndexCalls++;
    _windowCurrentIndex = index;
  }

  @override
  void playWithoutAwait() {
    playCalls++;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
  }

  @override
  Future<void> setVolume(double v) async {}

  @override
  Future<void> stopPlayback() async {
    stopPlaybackCalls++;
  }

  @override
  Future<void> stopPlayer() async {
    stopPlayerCalls++;
    _windowTracks = const [];
    _windowCurrentIndex = null;
  }

  @override
  int? get playerCurrentIndex => _windowCurrentIndex;

  @override
  TrackUI? get currentTrack {
    final idx = _windowCurrentIndex;
    if (idx == null || idx < 0 || idx >= _windowTracks.length) return null;
    return _windowTracks[idx];
  }

  @override
  void acknowledgeCurrentTrack(TrackUI? track) {
    acknowledgedTrackUuid = track?.uuidId;
  }

  @override
  void dispose() {}

  Future<void> emitTrackChanged(WindowTrackChange change) async {
    _windowCurrentIndex = change.index;
    await onTrackChanged?.call(change);
  }

  void emitStatus(PlayerStatus status) {
    onStatusChanged?.call(status);
  }

  Future<void> emitIndexAsTrackChange(int index) async {
    _windowCurrentIndex = index;
    final track = _windowTracks[index];
    await onTrackChanged?.call(
      WindowTrackChange(
        track: track,
        index: index,
        origin: WindowTrackChangeOrigin.directPlayerIndex,
      ),
    );
  }

  void setWindow(List<TrackUI> tracks, int currentIndex) {
    _windowTracks = List<TrackUI>.unmodifiable(tracks);
    _windowCurrentIndex = currentIndex;
  }

  void resetCounters() {
    fullReplaceCalls = 0;
    slideForwardCalls = 0;
    reconfigureCalls = 0;
    stopPlaybackCalls = 0;
    stopPlayerCalls = 0;
    seekToIndexCalls = 0;
    seekCalls = 0;
    playCalls = 0;
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
  late final StreamSubscription<MediaItem?> _mediaSub;

  RecordingAudioServiceBridge() {
    _mediaSub = mediaItem.listen(mediaItemEvents.add);
  }

  Future<void> disposeBridge() async {
    await _mediaSub.cancel();
  }
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late FakeWindowController fakeWindow;
  late RecordingAudioServiceBridge bridge;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    fakeWindow = FakeWindowController();
    bridge = RecordingAudioServiceBridge();
  });

  tearDown(() async {
    await bridge.disposeBridge();
    container.dispose();
    await db.close();
  });

  ProviderContainer createContainer({AudioQueueLookup? queueLookup}) {
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        audioWindowProvider.overrideWithValue(fakeWindow),
        audioQueueLookupProvider.overrideWithValue(
          queueLookup ?? FakeQueueLookup(),
        ),
        audioServiceProvider.overrideWithValue(bridge),
      ],
    );
    return container;
  }

  group('AudioCoordinator bug regressions', () {
    test(
      'repeat-all upcoming queue should wrap at the end of the queue',
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
          artist: 'Artist',
          album: 'Album',
          orderParams: [
            OrderParameter(column: 'track_number'),
            OrderParameter(column: 'uuid_id'),
          ],
        );

        await notifier.playFromQueue(context, current);
        await notifier.cycleQueueRepeatMode(); // off -> all

        final upcoming = c.read(audioProvider).queue.upcomingTracks;
        expect(upcoming.map((t) => t.uuidId).toList(), ['a', 'b']);
      },
    );

    test(
      'duplicate track-change callbacks should not reshape the playlist again',
      () async {
        final a = _track('a');
        final b = _track('b');
        final cTrack = _track('c');
        final d = _track('d');
        final queue = FakeQueueLookup(
          candidates: {
            'b': (previous: [a], next: [cTrack]),
          },
          upcoming: {
            'b': [cTrack, d],
          },
        );

        final c = createContainer(queueLookup: queue);
        final notifier = c.read(audioProvider.notifier);
        final context = QueueContext(
          orderParams: [OrderParameter(column: 'track_number')],
        );

        await notifier.playFromQueue(context, b);
        fakeWindow.resetCounters();
        notifier.debugSetState(
          c
              .read(audioProvider)
              .copyWith(
                playback: c
                    .read(audioProvider)
                    .playback
                    .copyWith(currentTrack: b),
              ),
        );

        await notifier.debugHandleTrackChanged(
          WindowTrackChange(
            track: b,
            index: fakeWindow.windowCurrentIndex!,
            origin: WindowTrackChangeOrigin.directPlayerIndex,
          ),
        );

        expect(fakeWindow.slideForwardCalls, 0);
        expect(fakeWindow.reconfigureCalls, 0);
      },
    );

    test(
      'skipNext should not stop when upcoming queue entries still exist',
      () async {
        final a = _track('a');
        final b = _track('b');
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
        fakeWindow.setWindow([a, b, cTrack], 2);

        await notifier.skipNext();

        expect(fakeWindow.stopPlaybackCalls, 0);
      },
    );

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
        fakeWindow.setWindow([b, cTrack], 0);

        await notifier.skipPrevious();

        expect(fakeWindow.seekCalls, 0);
        expect(fakeWindow.playCalls, greaterThan(0));
        expect(c.read(audioProvider).playback.currentTrack?.uuidId, 'a');
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
        fakeWindow.setWindow([current, current, current], 1);
        fakeWindow.resetCounters();

        fakeWindow.emitStatus(PlayerStatus.idle);
        await Future<void>.delayed(Duration.zero);

        expect(fakeWindow.seekCalls, 1);
        expect(fakeWindow.playCalls, 1);
        expect(c.read(audioProvider).playback.status, isNot(PlayerStatus.idle));
      },
    );

    test(
      'natural track change should seed playback duration from track metadata before a duration event arrives',
      () async {
        final a = _track('a', duration: 180);
        final b = _track('b', duration: 245);

        final c = createContainer(queueLookup: FakeQueueLookup());
        final notifier = c.read(audioProvider.notifier);
        notifier.debugSetState(
          AudioState(
            playback: PlaybackSlice(
              currentTrack: a,
              status: PlayerStatus.playing,
              duration: const Duration(seconds: 180),
            ),
            queue: QueueSlice(
              queueContext: QueueContext(
                orderParams: [OrderParameter(column: 'track_number')],
              ),
            ),
          ),
        );
        fakeWindow.setWindow([a, b], 1);

        await notifier.debugHandleTrackChanged(
          WindowTrackChange(
            track: b,
            index: 1,
            origin: WindowTrackChangeOrigin.directPlayerIndex,
          ),
        );

        expect(
          c.read(audioProvider).playback.duration,
          const Duration(seconds: 245),
        );
      },
    );

    test('stop should clear the now playing item in audio_service', () async {
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

      expect(
        bridge.mediaItemEvents.where((item) => item != null),
        hasLength(1),
      );
      expect(bridge.mediaItemEvents.whereType<MediaItem>().single.id, 'b');
      expect(bridge.mediaItemEvents.last, isNull);
    });
  });
}

TrackUI _track(
  String uuid, {
  String? title,
  String? artist,
  String? album,
  int? trackNumber,
  double duration = 180,
}) {
  return TrackUI(
    uuidId: uuid,
    title: title,
    artist: artist,
    album: album,
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

Future<TrackUI> _insertTrack(
  AppDatabase db, {
  required String uuid,
  required String title,
  required String artist,
  required String album,
  required int trackNumber,
}) async {
  final dto = ClientTrackDto.fromJson({
    'uuid_id': uuid,
    'created_at': 1000,
    'last_updated': 2000,
    'metadata': {
      'title': title,
      'artist': artist,
      'album': album,
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
    trackNumber: trackNumber,
  );
}
