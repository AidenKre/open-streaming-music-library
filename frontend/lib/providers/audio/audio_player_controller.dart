import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/audio/track_cache_manager.dart';

typedef TrackCompletedCallback = FutureOr<void> Function();
typedef StatusChangedCallback = void Function(PlayerStatus status);
typedef PositionChangedCallback = void Function(Duration position);
typedef DurationChangedCallback = void Function(Duration duration);

abstract class AudioPlayerController {
  set onTrackCompleted(TrackCompletedCallback? callback);
  set onStatusChanged(StatusChangedCallback? callback);
  set onPositionChanged(PositionChangedCallback? callback);
  set onDurationChanged(DurationChangedCallback? callback);

  int get generation;
  int incrementGeneration();

  Future<bool> playTrack(
    TrackUI track, {
    required bool shouldPlay,
    required Duration initialPosition,
    required TrackCacheManager cache,
    required int generation,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> stop();
  void dispose();
}

class SingleAudioPlayerController implements AudioPlayerController {
  final ja.AudioPlayer _player;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  bool _wasPlaying = false;
  bool _isDisposed = false;
  int _generation = 0;

  @override
  TrackCompletedCallback? onTrackCompleted;

  @override
  StatusChangedCallback? onStatusChanged;

  @override
  PositionChangedCallback? onPositionChanged;

  @override
  DurationChangedCallback? onDurationChanged;

  SingleAudioPlayerController(this._player) {
    _subscriptions.add(
      _player.playerStateStream.listen((playerState) {
        if (playerState.processingState == ja.ProcessingState.completed) {
          // Don't emit idle status on completion — that would tear down the
          // audio session before the next track can start. The completion
          // callback handles the transition instead.
          if (_wasPlaying) {
            _wasPlaying = false;
            final callback = onTrackCompleted;
            if (callback != null) {
              unawaited(Future<void>.value(callback()));
            }
          }
          return;
        }

        onStatusChanged?.call(_mapStatus(playerState));
        _wasPlaying = playerState.playing;
      }),
    );

    _subscriptions.add(
      _player.positionStream.listen((position) {
        onPositionChanged?.call(position);
      }),
    );

    _subscriptions.add(
      _player.durationStream.listen((duration) {
        onDurationChanged?.call(duration ?? Duration.zero);
      }),
    );
  }

  factory SingleAudioPlayerController.create() {
    return SingleAudioPlayerController(ja.AudioPlayer());
  }

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
    if (_isDisposed || generation != _generation) {
      return false;
    }

    final cachedFile = cache.getCachedFile(track.uuidId);
    if (cachedFile != null) {
      try {
        debugPrint('[audio] playing from cache: ${track.uuidId}');
        final loaded = await _setSource(
          ja.AudioSource.file(cachedFile.path),
          initialPosition: initialPosition,
          generation: generation,
        );
        if (loaded) {
          _startPlaybackIfNeeded(shouldPlay);
        }
        return loaded;
      } on Exception catch (e) {
        debugPrint('[audio] cache load failed, falling back to network: ${track.uuidId} — $e');
        await cache.evict(track.uuidId);
      }
    }

    try {
      debugPrint('[audio] playing from network: ${track.uuidId}');
      final loaded = await _setSource(
        ja.AudioSource.uri(buildTrackStreamUri(track.uuidId)),
        initialPosition: initialPosition,
        generation: generation,
      );
      if (loaded) {
        _startPlaybackIfNeeded(shouldPlay);
      }
      return loaded;
    } on Exception {
      return false;
    }
  }

  @override
  Future<void> play() async {
    _wasPlaying = true;
    unawaited(_player.play());
  }

  @override
  Future<void> pause() async {
    _wasPlaying = false;
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> stop() async {
    _generation++;
    _wasPlaying = false;
    await _player.stop();
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }

    _isDisposed = true;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    unawaited(_player.dispose());
  }

  Future<bool> _setSource(
    ja.AudioSource source, {
    required Duration initialPosition,
    required int generation,
  }) async {
    await _player.setAudioSource(source, initialPosition: initialPosition);
    return !_isDisposed && generation == _generation;
  }

  void _startPlaybackIfNeeded(bool shouldPlay) {
    if (shouldPlay) {
      _wasPlaying = true;
      unawaited(_player.play());
    } else {
      _wasPlaying = false;
    }
  }

  PlayerStatus _mapStatus(ja.PlayerState playerState) {
    final processingState = playerState.processingState;
    if (processingState == ja.ProcessingState.loading ||
        processingState == ja.ProcessingState.buffering) {
      return PlayerStatus.loading;
    }
    if (processingState == ja.ProcessingState.completed ||
        processingState == ja.ProcessingState.idle) {
      return PlayerStatus.idle;
    }
    return playerState.playing ? PlayerStatus.playing : PlayerStatus.paused;
  }
}
