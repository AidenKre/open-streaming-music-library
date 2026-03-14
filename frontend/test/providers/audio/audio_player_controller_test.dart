import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_player_controller.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/audio/track_cache_manager.dart';

class MockAudioPlayer extends Mock implements ja.AudioPlayer {}

class MockTrackCacheManager extends Mock implements TrackCacheManager {}

class FakeAudioSource extends Fake implements ja.AudioSource {}

void main() {
  late MockAudioPlayer player;
  late MockTrackCacheManager cache;
  late SingleAudioPlayerController controller;
  late StreamController<ja.PlayerState> playerStateController;
  late StreamController<Duration> positionController;
  late StreamController<Duration?> durationController;

  setUpAll(() {
    registerFallbackValue(FakeAudioSource());
    registerFallbackValue(Duration.zero);
    ApiClient.init('http://test:8080');
  });

  setUp(() {
    player = MockAudioPlayer();
    cache = MockTrackCacheManager();
    playerStateController = StreamController<ja.PlayerState>.broadcast();
    positionController = StreamController<Duration>.broadcast();
    durationController = StreamController<Duration?>.broadcast();

    when(() => player.playerStateStream).thenAnswer((_) => playerStateController.stream);
    when(() => player.positionStream).thenAnswer((_) => positionController.stream);
    when(() => player.durationStream).thenAnswer((_) => durationController.stream);
    when(
      () => player.setAudioSource(
        any(),
        initialPosition: any(named: 'initialPosition'),
      ),
    ).thenAnswer((_) async => const Duration(minutes: 3));
    when(() => player.play()).thenAnswer((_) async {});
    when(() => player.pause()).thenAnswer((_) async {});
    when(() => player.seek(any())).thenAnswer((_) async {});
    when(() => player.setVolume(any())).thenAnswer((_) async {});
    when(() => player.stop()).thenAnswer((_) async {});
    when(() => player.dispose()).thenAnswer((_) async {});
    when(() => cache.evict(any())).thenAnswer((_) async {});

    controller = SingleAudioPlayerController(player);
  });

  tearDown(() async {
    controller.dispose();
    await playerStateController.close();
    await positionController.close();
    await durationController.close();
  });

  test('playTrack loads cached file when present', () async {
    final temp = await Directory.systemTemp.createTemp('player-cache-hit');
    final cachedFile = File('${temp.path}/a.audio');
    await cachedFile.writeAsBytes([1, 2, 3]);
    when(() => cache.getCachedFile('a')).thenReturn(cachedFile);

    final generation = controller.incrementGeneration();
    final played = await controller.playTrack(
      _track('a'),
      shouldPlay: true,
      initialPosition: const Duration(seconds: 12),
      cache: cache,
      generation: generation,
    );

    expect(played, isTrue);
    final captured = verify(
      () => player.setAudioSource(
        captureAny(),
        initialPosition: const Duration(seconds: 12),
      ),
    ).captured.single as ja.UriAudioSource;
    expect(captured.uri, Uri.file(cachedFile.path));
    verify(() => player.play()).called(1);

    await temp.delete(recursive: true);
  });

  test('playTrack loads network URL when cache misses', () async {
    when(() => cache.getCachedFile('a')).thenReturn(null);

    final generation = controller.incrementGeneration();
    final played = await controller.playTrack(
      _track('a'),
      shouldPlay: false,
      initialPosition: Duration.zero,
      cache: cache,
      generation: generation,
    );

    expect(played, isTrue);
    final captured = verify(
      () => player.setAudioSource(
        captureAny(),
        initialPosition: Duration.zero,
      ),
    ).captured.single as ja.UriAudioSource;
    expect(captured.uri, Uri.parse('http://test:8080/tracks/a/stream'));
    verifyNever(() => player.play());
  });

  test('playTrack falls back to network when cached file load throws', () async {
    final temp = await Directory.systemTemp.createTemp('player-cache-fallback');
    final cachedFile = File('${temp.path}/a.audio');
    await cachedFile.writeAsBytes([1, 2, 3]);
    when(() => cache.getCachedFile('a')).thenReturn(cachedFile);
    when(
      () => player.setAudioSource(
        any(),
        initialPosition: any(named: 'initialPosition'),
      ),
    ).thenAnswer((invocation) async {
      final source = invocation.positionalArguments[0] as ja.UriAudioSource;
      if (source.uri.scheme == 'file') {
        throw Exception('bad cache');
      }
      return const Duration(minutes: 3);
    });

    final generation = controller.incrementGeneration();
    final played = await controller.playTrack(
      _track('a'),
      shouldPlay: true,
      initialPosition: Duration.zero,
      cache: cache,
      generation: generation,
    );

    expect(played, isTrue);
    final capturedSources = verify(
      () => player.setAudioSource(
        captureAny(),
        initialPosition: Duration.zero,
      ),
    ).captured.cast<ja.UriAudioSource>();
    expect(capturedSources, hasLength(2));
    expect(capturedSources.first.uri, Uri.file(cachedFile.path));
    expect(capturedSources.last.uri, Uri.parse('http://test:8080/tracks/a/stream'));
    verify(() => cache.evict('a')).called(1);
    verify(() => player.play()).called(1);

    await temp.delete(recursive: true);
  });

  test('playTrack returns false on stale generation', () async {
    when(() => cache.getCachedFile('a')).thenReturn(null);
    final generation = controller.incrementGeneration();
    controller.incrementGeneration();

    final played = await controller.playTrack(
      _track('a'),
      shouldPlay: true,
      initialPosition: Duration.zero,
      cache: cache,
      generation: generation,
    );

    expect(played, isFalse);
    verifyNever(
      () => player.setAudioSource(
        any(),
        initialPosition: any(named: 'initialPosition'),
      ),
    );
  });

  test('playTrack returns false when setAudioSource throws', () async {
    when(() => cache.getCachedFile('a')).thenReturn(null);
    when(
      () => player.setAudioSource(
        any(),
        initialPosition: any(named: 'initialPosition'),
      ),
    ).thenThrow(Exception('boom'));

    final generation = controller.incrementGeneration();
    final played = await controller.playTrack(
      _track('a'),
      shouldPlay: true,
      initialPosition: Duration.zero,
      cache: cache,
      generation: generation,
    );

    expect(played, isFalse);
  });

  test('onTrackCompleted fires on completed when track had been playing', () async {
    var completedCalls = 0;
    controller.onTrackCompleted = () async {
      completedCalls++;
    };

    playerStateController.add(
      ja.PlayerState(true, ja.ProcessingState.ready),
    );
    await Future<void>.delayed(Duration.zero);

    playerStateController.add(
      ja.PlayerState(false, ja.ProcessingState.completed),
    );
    await Future<void>.delayed(Duration.zero);

    expect(completedCalls, 1);
  });

  test('onTrackCompleted does not fire after stop', () async {
    var completedCalls = 0;
    controller.onTrackCompleted = () async {
      completedCalls++;
    };

    playerStateController.add(
      ja.PlayerState(true, ja.ProcessingState.ready),
    );
    await Future<void>.delayed(Duration.zero);

    await controller.stop();
    playerStateController.add(
      ja.PlayerState(false, ja.ProcessingState.completed),
    );
    await Future<void>.delayed(Duration.zero);

    expect(completedCalls, 0);
  });

  test('onStatusChanged should not fire idle on natural track completion',
      () async {
    final statuses = <PlayerStatus>[];
    controller.onStatusChanged = statuses.add;
    controller.onTrackCompleted = () async {};

    // Track starts playing
    playerStateController
        .add(ja.PlayerState(true, ja.ProcessingState.ready));
    await Future<void>.delayed(Duration.zero);
    statuses.clear();

    // Track completes naturally
    playerStateController
        .add(ja.PlayerState(false, ja.ProcessingState.completed));
    await Future<void>.delayed(Duration.zero);

    // Status should NOT contain idle — completion is handled by onTrackCompleted
    expect(
      statuses,
      isNot(contains(PlayerStatus.idle)),
      reason:
          'Idle status was emitted on completion, which tears down the audio session',
    );
  });

  test('forwards status, position, and duration streams', () async {
    final statuses = <PlayerStatus>[];
    final positions = <Duration>[];
    final durations = <Duration>[];

    controller.onStatusChanged = statuses.add;
    controller.onPositionChanged = positions.add;
    controller.onDurationChanged = durations.add;

    playerStateController.add(ja.PlayerState(false, ja.ProcessingState.loading));
    playerStateController.add(ja.PlayerState(true, ja.ProcessingState.ready));
    playerStateController.add(ja.PlayerState(false, ja.ProcessingState.ready));
    positionController.add(const Duration(seconds: 45));
    durationController.add(const Duration(minutes: 4));
    durationController.add(null);
    await Future<void>.delayed(Duration.zero);

    expect(statuses, [
      PlayerStatus.loading,
      PlayerStatus.playing,
      PlayerStatus.paused,
    ]);
    expect(positions, [const Duration(seconds: 45)]);
    expect(durations, [const Duration(minutes: 4), Duration.zero]);
  });
}

TrackUI _track(String uuidId) {
  return TrackUI(
    uuidId: uuidId,
    createdAt: 0,
    lastUpdated: 0,
    duration: 180,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: false,
  );
}
