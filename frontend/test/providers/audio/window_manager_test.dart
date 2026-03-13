import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/window_manager.dart';

// Mock AudioPlayer
class MockAudioPlayer extends Mock implements ja.AudioPlayer {}

class FakeAudioSource extends Fake implements ja.AudioSource {}

void main() {
  late MockAudioPlayer mockPlayer;
  late WindowManager manager;
  late StreamController<int?> currentIndexController;

  setUpAll(() {
    registerFallbackValue(FakeAudioSource());
    registerFallbackValue(Duration.zero);
    ApiClient.init('http://test:8080');
  });

  setUp(() {
    mockPlayer = MockAudioPlayer();
    currentIndexController = StreamController<int?>.broadcast();

    // Default stream stubs
    when(
      () => mockPlayer.playerStateStream,
    ).thenAnswer((_) => Stream<ja.PlayerState>.empty());
    when(
      () => mockPlayer.positionStream,
    ).thenAnswer((_) => Stream<Duration>.empty());
    when(
      () => mockPlayer.durationStream,
    ).thenAnswer((_) => Stream<Duration?>.empty());
    when(
      () => mockPlayer.currentIndexStream,
    ).thenAnswer((_) => currentIndexController.stream);

    // Default method stubs
    when(
      () => mockPlayer.setAudioSource(any()),
    ).thenAnswer((_) async => Duration.zero);
    when(
      () => mockPlayer.setAudioSources(
        any(),
        initialIndex: any(named: 'initialIndex'),
        initialPosition: any(named: 'initialPosition'),
      ),
    ).thenAnswer((_) async => Duration.zero);
    when(() => mockPlayer.removeAudioSourceAt(any())).thenAnswer((_) async {});
    when(() => mockPlayer.addAudioSource(any())).thenAnswer((_) async {});
    when(
      () => mockPlayer.insertAudioSource(any(), any()),
    ).thenAnswer((_) async {});
    when(
      () => mockPlayer.seek(any(), index: any(named: 'index')),
    ).thenAnswer((_) async {});
    when(() => mockPlayer.seek(any())).thenAnswer((_) async {});
    when(() => mockPlayer.play()).thenAnswer((_) async {});
    when(() => mockPlayer.pause()).thenAnswer((_) async {});
    when(() => mockPlayer.stop()).thenAnswer((_) async {});
    when(() => mockPlayer.clearAudioSources()).thenAnswer((_) async {});
    when(() => mockPlayer.dispose()).thenAnswer((_) async {});
    when(() => mockPlayer.playing).thenReturn(true);
    when(() => mockPlayer.position).thenReturn(Duration.zero);
    when(() => mockPlayer.duration).thenReturn(null);
    when(() => mockPlayer.currentIndex).thenReturn(null);

    manager = WindowManager(mockPlayer);
  });

  tearDown(() {
    manager.dispose();
    currentIndexController.close();
  });

  group('fullReplace', () {
    test('sets audio sources and updates window state', () async {
      final tracks = [_track('a'), _track('b'), _track('c')];
      final gen = manager.incrementGeneration();

      final result = await manager.fullReplace(
        tracks,
        1,
        generation: gen,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );

      expect(result, true);
      expect(manager.windowTracks.length, 3);
      expect(manager.windowCurrentIndex, 1);
      expect(manager.windowTracks[1].uuidId, 'b');
      verify(() => mockPlayer.play()).called(1);
    });

    test('uses setAudioSource for single track', () async {
      final tracks = [_track('a')];
      final gen = manager.incrementGeneration();

      await manager.fullReplace(
        tracks,
        0,
        generation: gen,
        shouldPlay: false,
        initialPosition: Duration.zero,
      );

      verify(() => mockPlayer.setAudioSource(any())).called(1);
      verifyNever(
        () => mockPlayer.setAudioSources(
          any(),
          initialIndex: any(named: 'initialIndex'),
          initialPosition: any(named: 'initialPosition'),
        ),
      );
    });

    test('does not play when shouldPlay is false', () async {
      final gen = manager.incrementGeneration();

      await manager.fullReplace(
        [_track('a')],
        0,
        generation: gen,
        shouldPlay: false,
        initialPosition: Duration.zero,
      );

      verifyNever(() => mockPlayer.play());
    });

    test('aborts on stale generation', () async {
      final gen = manager.incrementGeneration();
      manager.incrementGeneration(); // Stale the generation

      final result = await manager.fullReplace(
        [_track('a')],
        0,
        generation: gen,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );

      expect(result, false);
      verifyNever(() => mockPlayer.setAudioSource(any()));
    });

    test('seeks to initial position when non-zero', () async {
      final gen = manager.incrementGeneration();
      final pos = const Duration(seconds: 30);

      await manager.fullReplace(
        [_track('a'), _track('b')],
        0,
        generation: gen,
        shouldPlay: true,
        initialPosition: pos,
      );

      verify(() => mockPlayer.seek(pos, index: 0)).called(1);
    });

    test(
      'ignores currentIndex events emitted during full replace mutation',
      () async {
        final seenTrackUuids = <String>[];
        manager.onTrackChanged = (change) async {
          seenTrackUuids.add(change.track.uuidId);
        };

        when(
          () => mockPlayer.setAudioSources(
            any(),
            initialIndex: any(named: 'initialIndex'),
            initialPosition: any(named: 'initialPosition'),
          ),
        ).thenAnswer((_) async {
          currentIndexController.add(1);
          await Future<void>.delayed(Duration.zero);
          return Duration.zero;
        });

        final gen = manager.incrementGeneration();
        await manager.enqueueMutation(() async {
          await manager.fullReplace(
            [_track('a'), _track('b'), _track('c')],
            1,
            generation: gen,
            shouldPlay: false,
            initialPosition: Duration.zero,
          );
        });
        await Future<void>.delayed(Duration.zero);

        expect(seenTrackUuids, isEmpty);
      },
    );

    test(
      'forwards track changes emitted after full replace completes',
      () async {
        final seenTrackUuids = <String>[];
        final seenOrigins = <WindowTrackChangeOrigin>[];
        manager.onTrackChanged = (change) async {
          seenTrackUuids.add(change.track.uuidId);
          seenOrigins.add(change.origin);
        };

        final gen = manager.incrementGeneration();
        await manager.fullReplace(
          [_track('a'), _track('b'), _track('c')],
          1,
          generation: gen,
          shouldPlay: false,
          initialPosition: Duration.zero,
        );

        currentIndexController.add(2);
        await Future<void>.delayed(Duration.zero);

        expect(seenTrackUuids, ['c']);
        expect(seenOrigins, [WindowTrackChangeOrigin.directPlayerIndex]);
      },
    );

    test(
      'reconciles to a real track change that happened during full replace mutation',
      () async {
        final seenTrackUuids = <String>[];
        final seenOrigins = <WindowTrackChangeOrigin>[];
        manager.onTrackChanged = (change) async {
          seenTrackUuids.add(change.track.uuidId);
          seenOrigins.add(change.origin);
        };

        when(
          () => mockPlayer.setAudioSources(
            any(),
            initialIndex: any(named: 'initialIndex'),
            initialPosition: any(named: 'initialPosition'),
          ),
        ).thenAnswer((_) async {
          currentIndexController.add(2);
          when(() => mockPlayer.currentIndex).thenReturn(2);
          await Future<void>.delayed(Duration.zero);
          return Duration.zero;
        });

        final gen = manager.incrementGeneration();
        await manager.enqueueMutation(() async {
          await manager.fullReplace(
            [_track('a'), _track('b'), _track('c')],
            1,
            generation: gen,
            shouldPlay: false,
            initialPosition: Duration.zero,
          );
        });
        await Future<void>.delayed(Duration.zero);

        expect(seenTrackUuids, ['c']);
        expect(seenOrigins, [WindowTrackChangeOrigin.reconciledAfterMutation]);
      },
    );
  });

  group('slideForward', () {
    test('removes first track and appends new next', () async {
      // Set up initial window: [a, b, c]
      final gen = manager.incrementGeneration();
      await manager.fullReplace(
        [_track('a'), _track('b'), _track('c')],
        1,
        generation: gen,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );

      reset(mockPlayer);
      _stubPlayerMethods(mockPlayer);

      final newNext = _track('d');
      await manager.slideForward(newNext, generation: gen);

      verify(() => mockPlayer.removeAudioSourceAt(0)).called(1);
      verify(() => mockPlayer.addAudioSource(any())).called(1);
      expect(manager.windowTracks.map((t) => t.uuidId).toList(), [
        'b',
        'c',
        'd',
      ]);
      expect(manager.windowCurrentIndex, 0); // Was 1, minus 1 after remove
    });

    test('aborts on stale generation', () async {
      final gen = manager.incrementGeneration();
      await manager.fullReplace(
        [_track('a'), _track('b'), _track('c')],
        1,
        generation: gen,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );

      reset(mockPlayer);
      _stubPlayerMethods(mockPlayer);

      manager.incrementGeneration(); // Stale

      await manager.slideForward(_track('d'), generation: gen);
      verifyNever(() => mockPlayer.removeAudioSourceAt(any()));
    });
  });

  group('reconfigureNeighbors', () {
    test('swaps neighbors while keeping current track', () async {
      final gen = manager.incrementGeneration();
      await manager.fullReplace(
        [_track('a'), _track('b'), _track('c')],
        1,
        generation: gen,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );

      reset(mockPlayer);
      _stubPlayerMethods(mockPlayer);

      await manager.reconfigureNeighbors(
        _track('x'),
        _track('y'),
        generation: gen,
      );

      // Should have removed the old neighbors and added new ones
      expect(manager.windowTracks.map((t) => t.uuidId).toList(), [
        'x',
        'b',
        'y',
      ]);
      expect(manager.windowCurrentIndex, 1);
    });

    test('works with null prev', () async {
      final gen = manager.incrementGeneration();
      await manager.fullReplace(
        [_track('a'), _track('b'), _track('c')],
        1,
        generation: gen,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );

      reset(mockPlayer);
      _stubPlayerMethods(mockPlayer);

      await manager.reconfigureNeighbors(null, _track('y'), generation: gen);

      expect(manager.windowTracks.map((t) => t.uuidId).toList(), ['b', 'y']);
      expect(manager.windowCurrentIndex, 0);
    });

    test('works with null next', () async {
      final gen = manager.incrementGeneration();
      await manager.fullReplace(
        [_track('a'), _track('b'), _track('c')],
        1,
        generation: gen,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );

      reset(mockPlayer);
      _stubPlayerMethods(mockPlayer);

      await manager.reconfigureNeighbors(_track('x'), null, generation: gen);

      expect(manager.windowTracks.map((t) => t.uuidId).toList(), ['x', 'b']);
      expect(manager.windowCurrentIndex, 1);
    });

    test('works with both null (current only)', () async {
      final gen = manager.incrementGeneration();
      await manager.fullReplace(
        [_track('a'), _track('b'), _track('c')],
        1,
        generation: gen,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );

      reset(mockPlayer);
      _stubPlayerMethods(mockPlayer);

      await manager.reconfigureNeighbors(null, null, generation: gen);

      expect(manager.windowTracks.map((t) => t.uuidId).toList(), ['b']);
      expect(manager.windowCurrentIndex, 0);
    });

    test('aborts on stale generation', () async {
      final gen = manager.incrementGeneration();
      await manager.fullReplace(
        [_track('a'), _track('b'), _track('c')],
        1,
        generation: gen,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );

      reset(mockPlayer);
      _stubPlayerMethods(mockPlayer);

      manager.incrementGeneration(); // Stale

      await manager.reconfigureNeighbors(
        _track('x'),
        _track('y'),
        generation: gen,
      );

      // Window should not have changed
      expect(manager.windowTracks.map((t) => t.uuidId).toList(), [
        'a',
        'b',
        'c',
      ]);
    });

    test(
      'ignores currentIndex events emitted during neighbor reconfiguration',
      () async {
        final seenTrackUuids = <String>[];
        manager.onTrackChanged = (change) async {
          seenTrackUuids.add(change.track.uuidId);
        };

        final gen = manager.incrementGeneration();
        await manager.fullReplace(
          [_track('a'), _track('b'), _track('c')],
          1,
          generation: gen,
          shouldPlay: false,
          initialPosition: Duration.zero,
        );

        reset(mockPlayer);
        _stubPlayerMethods(mockPlayer);
        when(
          () => mockPlayer.currentIndexStream,
        ).thenAnswer((_) => currentIndexController.stream);
        when(() => mockPlayer.removeAudioSourceAt(any())).thenAnswer((_) async {
          currentIndexController.add(0);
          await Future<void>.delayed(Duration.zero);
        });

        await manager.enqueueMutation(() async {
          await manager.reconfigureNeighbors(
            _track('x'),
            _track('y'),
            generation: gen,
          );
        });
        await Future<void>.delayed(Duration.zero);

        expect(seenTrackUuids, isEmpty);
      },
    );
  });

  group('stopPlayer', () {
    test('clears window state', () async {
      final gen = manager.incrementGeneration();
      await manager.fullReplace(
        [_track('a'), _track('b')],
        0,
        generation: gen,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );

      await manager.stopPlayer();

      expect(manager.windowTracks, isEmpty);
      expect(manager.windowCurrentIndex, isNull);
      verify(() => mockPlayer.stop()).called(1);
      verify(() => mockPlayer.clearAudioSources()).called(1);
    });
  });

  group('buildPlaybackWindowPlan', () {
    test('default window size 3 with balanced neighbors', () {
      final plan = buildPlaybackWindowPlan(
        current: _track('c'),
        previousCandidates: [_track('p1'), _track('p2')],
        nextCandidates: [_track('n1'), _track('n2')],
      );

      expect(plan.tracks.map((t) => t.uuidId).toList(), ['p1', 'c', 'n1']);
      expect(plan.currentIndex, 1);
    });

    test('single track when no candidates', () {
      final plan = buildPlaybackWindowPlan(
        current: _track('c'),
        previousCandidates: const [],
        nextCandidates: const [],
      );

      expect(plan.tracks.length, 1);
      expect(plan.tracks[0].uuidId, 'c');
      expect(plan.currentIndex, 0);
    });
  });
}

TrackUI _track(String uuid) {
  return TrackUI(
    uuidId: uuid,
    createdAt: 0,
    lastUpdated: 0,
    duration: 180,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: false,
  );
}

void _stubPlayerMethods(MockAudioPlayer player) {
  when(
    () => player.playerStateStream,
  ).thenAnswer((_) => Stream<ja.PlayerState>.empty());
  when(() => player.positionStream).thenAnswer((_) => Stream<Duration>.empty());
  when(
    () => player.durationStream,
  ).thenAnswer((_) => Stream<Duration?>.empty());
  when(() => player.currentIndexStream).thenAnswer((_) => Stream<int?>.empty());
  when(() => player.removeAudioSourceAt(any())).thenAnswer((_) async {});
  when(() => player.addAudioSource(any())).thenAnswer((_) async {});
  when(() => player.insertAudioSource(any(), any())).thenAnswer((_) async {});
  when(() => player.play()).thenAnswer((_) async {});
  when(() => player.stop()).thenAnswer((_) async {});
  when(() => player.clearAudioSources()).thenAnswer((_) async {});
  when(() => player.dispose()).thenAnswer((_) async {});
  when(() => player.playing).thenReturn(true);
  when(() => player.position).thenReturn(Duration.zero);
  when(() => player.duration).thenReturn(null);
  when(() => player.currentIndex).thenReturn(null);
}
