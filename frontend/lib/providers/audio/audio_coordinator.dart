import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_player_controller.dart';
import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/audio/queue_resolver.dart';
import 'package:frontend/providers/audio/track_cache_manager.dart';
import 'package:frontend/providers/providers.dart';

class AudioCoordinator extends Notifier<AudioState> {
  late final AudioPlayerController _player;
  late final TrackCacheManager _cache;
  late final AudioQueueLookup _queue;
  late final AudioServiceBridge _bridge;
  int _upcomingRefreshGeneration = 0;
  bool _stopInProgress = false;

  @override
  AudioState build() {
    _player = ref.read(audioPlayerProvider);
    _cache = ref.read(trackCacheProvider);
    _queue = ref.read(audioQueueLookupProvider);
    _bridge = ref.read(audioServiceProvider);

    _bridge.onPlay = resume;
    _bridge.onPause = pause;
    _bridge.onSkipToNext = skipNext;
    _bridge.onSkipToPrevious = skipPrevious;
    _bridge.onSeek = seek;
    _bridge.onStop = stop;

    _player.onStatusChanged = (status) {
      // Suppress idle during natural completion — _handleNaturalCompletion
      // (fired via onTrackCompleted) manages the transition without
      // broadcasting idle, which would tear down the audio session.
      final isNaturalCompletion =
          status == PlayerStatus.idle &&
          !_stopInProgress &&
          state.playback.status == PlayerStatus.playing &&
          state.playback.currentTrack != null;
      if (isNaturalCompletion) {
        return;
      }

      state = state.copyWith(playback: state.playback.copyWith(status: status));
      _updateBridgePlaybackState();
    };

    _player.onPositionChanged = (position) {
      state = state.copyWith(playback: state.playback.copyWith(position: position));
      _updateBridgePlaybackState();
    };

    _player.onDurationChanged = (duration) {
      state = state.copyWith(playback: state.playback.copyWith(duration: duration));
    };

    _player.onTrackCompleted = _handleNaturalCompletion;

    ref.onDispose(() {
      _player.dispose();
      unawaited(_cache.cancelPrefetch());
    });

    return const AudioState();
  }

  Future<void> play(TrackUI track) async {
    state = state.copyWith(
      queue: const QueueSlice(),
      shuffle: const ShuffleSlice(),
    );
    await _playTrack(
      track,
      shouldPlay: true,
      initialPosition: Duration.zero,
    );
  }

  Future<void> playFromQueue(QueueContext context, TrackUI track) async {
    var nextContext = context;
    if (state.shuffle.shuffleOn) {
      nextContext = context.withNewSeed();
      final uuids = await ref
          .read(databaseProvider)
          .getTrackUuids(
            orderBy: nextContext.orderParams,
            artist: nextContext.artist,
            album: nextContext.album,
          );
      final shuffled = shuffleWithCurrentFirst(
        uuids,
        track.uuidId,
        nextContext.shuffleSeed,
      );
      state = state.copyWith(
        queue: state.queue.copyWith(queueContext: nextContext),
        shuffle: state.shuffle.copyWith(
          shuffledUuids: shuffled,
          shuffleIndex: 0,
        ),
      );
    } else {
      state = state.copyWith(
        queue: state.queue.copyWith(queueContext: nextContext),
        shuffle: const ShuffleSlice(),
      );
    }

    await _playTrack(
      track,
      shouldPlay: true,
      initialPosition: Duration.zero,
    );
  }

  Future<void> skipNext() async {
    final track = state.playback.currentTrack;
    if (track == null || state.queue.queueContext == null) {
      await _player.stop();
      state = state.copyWith(
        playback: state.playback.copyWith(status: PlayerStatus.idle),
      );
      _updateBridgePlaybackState();
      return;
    }

    if (state.queue.repeatMode == QueueRepeatMode.one) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }

    final nextTrack = state.queue.upcomingTracks.isNotEmpty
        ? state.queue.upcomingTracks.first
        : await _resolveEdgeNeighbor(track, forward: true);
    if (nextTrack != null) {
      await _playTrack(
        nextTrack,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );
      return;
    }

    await _cache.cancelPrefetch();
    await _player.stop();
    state = state.copyWith(
      playback: state.playback.copyWith(status: PlayerStatus.idle),
      queue: state.queue.copyWith(upcomingTracks: const []),
    );
    _updateBridgePlaybackState();
  }

  Future<void> skipPrevious() async {
    final track = state.playback.currentTrack;

    if (state.playback.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      return;
    }

    if (track == null || state.queue.queueContext == null) {
      await _player.seek(Duration.zero);
      return;
    }

    if (state.queue.repeatMode == QueueRepeatMode.one) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }

    final previousTrack = await _resolveEdgeNeighbor(track, forward: false);
    if (previousTrack != null) {
      await _playTrack(
        previousTrack,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );
      return;
    }

    await _player.seek(Duration.zero);
  }

  Future<void> toggleShuffle() async {
    final context = state.queue.queueContext;
    if (context == null) {
      return;
    }

    if (!state.shuffle.shuffleOn) {
      final newContext = context.withNewSeed();
      final uuids = await ref
          .read(databaseProvider)
          .getTrackUuids(
            orderBy: newContext.orderParams,
            artist: newContext.artist,
            album: newContext.album,
          );
      final currentUuid = state.playback.currentTrack?.uuidId;
      final shuffled = shuffleWithCurrentFirst(
        uuids,
        currentUuid,
        newContext.shuffleSeed,
      );
      state = state.copyWith(
        queue: state.queue.copyWith(queueContext: newContext),
        shuffle: state.shuffle.copyWith(
          shuffleOn: true,
          shuffledUuids: shuffled,
          shuffleIndex: 0,
        ),
      );
    } else {
      state = state.copyWith(shuffle: const ShuffleSlice());
    }

    await _cache.cancelPrefetch();
    await _refreshUpcoming();
    await _prefetchNextTrack();
  }

  Future<void> cycleQueueRepeatMode() async {
    final nextMode = switch (state.queue.repeatMode) {
      QueueRepeatMode.off => QueueRepeatMode.all,
      QueueRepeatMode.all => QueueRepeatMode.one,
      QueueRepeatMode.one => QueueRepeatMode.off,
    };
    state = state.copyWith(queue: state.queue.copyWith(repeatMode: nextMode));

    await _cache.cancelPrefetch();
    await _refreshUpcoming();
    await _prefetchNextTrack();
  }

  Future<void> skipToTrack(TrackUI track) async {
    if (state.shuffle.shuffleOn && state.shuffle.shuffledUuids.isNotEmpty) {
      final index = state.shuffle.shuffledUuids.indexOf(track.uuidId);
      if (index >= 0) {
        state = state.copyWith(
          shuffle: state.shuffle.copyWith(shuffleIndex: index),
        );
      }
    }

    await _playTrack(
      track,
      shouldPlay: true,
      initialPosition: Duration.zero,
    );
  }

  Future<void> resume() async {
    if (state.playback.status == PlayerStatus.paused) {
      await _player.play();
    }
  }

  Future<void> pause() => _player.pause();

  Future<void> stop() async {
    _stopInProgress = true;
    try {
      _player.incrementGeneration();
      await _cache.clear();
      await _player.stop();
      _bridge.clearNowPlaying();
      await Future<void>.delayed(Duration.zero);
      state = const AudioState();
      _updateBridgePlaybackState();
    } finally {
      _stopInProgress = false;
    }
  }

  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> setVolume(double volume) async {
    await _player.setVolume(volume);
    state = state.copyWith(playback: state.playback.copyWith(volume: volume));
  }

  Future<void> _playTrack(
    TrackUI track, {
    required bool shouldPlay,
    required Duration initialPosition,
  }) async {
    final generation = _player.incrementGeneration();
    final previousPlayback = state.playback;
    final previousUpcoming = state.queue.upcomingTracks;
    final previousTrack = state.playback.currentTrack;
    final nextDuration = state.playback.currentTrack?.uuidId == track.uuidId
        ? state.playback.duration
        : Duration(milliseconds: (track.duration * 1000).round());

    state = state.copyWith(
      playback: state.playback.copyWith(
        currentTrack: track,
        status: PlayerStatus.loading,
        position: initialPosition,
        duration: nextDuration,
      ),
      shuffle: _copyShuffleForTrack(track),
    );
    _updateBridgeNowPlaying(track);
    _updateBridgePlaybackState();

    void restorePreviousState() {
      state = state.copyWith(
        playback: previousPlayback,
        queue: state.queue.copyWith(upcomingTracks: previousUpcoming),
      );
      if (previousTrack != null) {
        _updateBridgeNowPlaying(previousTrack);
      } else {
        _bridge.clearNowPlaying();
      }
      _updateBridgePlaybackState();
    }

    await _cache.cancelPrefetch();
    final played = await _player.playTrack(
      track,
      shouldPlay: shouldPlay,
      initialPosition: initialPosition,
      cache: _cache,
      generation: generation,
    );

    if (!played) {
      if (generation == _player.generation) {
        restorePreviousState();
      }
      return;
    }

    if (generation != _player.generation ||
        state.playback.currentTrack?.uuidId != track.uuidId) {
      return;
    }

    if (previousTrack != null && previousTrack.uuidId != track.uuidId) {
      await _cache.evict(previousTrack.uuidId);
    }

    await _refreshUpcoming();
    if (generation != _player.generation ||
        state.playback.currentTrack?.uuidId != track.uuidId) {
      return;
    }
    await _prefetchNextTrack();
  }

  Future<void> _prefetchNextTrack() async {
    if (state.queue.repeatMode == QueueRepeatMode.one) {
      return;
    }

    final currentTrack = state.playback.currentTrack;
    if (currentTrack == null) {
      return;
    }

    final nextTrack = state.queue.upcomingTracks.isNotEmpty
        ? state.queue.upcomingTracks.first
        : await _resolveEdgeNeighbor(currentTrack, forward: true);
    if (nextTrack != null) {
      unawaited(_cache.prefetch(nextTrack));
    }
  }

  Future<void> _handleNaturalCompletion() async {
    if (_stopInProgress) {
      return;
    }

    final currentTrack = state.playback.currentTrack;

    if (state.queue.repeatMode == QueueRepeatMode.one &&
        currentTrack != null) {
      state = state.copyWith(
        playback: state.playback.copyWith(
          status: PlayerStatus.playing,
          position: Duration.zero,
        ),
      );
      _updateBridgePlaybackState();
      unawaited(() async {
        await _player.seek(Duration.zero);
        await _player.play();
      }());
      return;
    }
    if (currentTrack == null) {
      state = state.copyWith(
        playback: state.playback.copyWith(status: PlayerStatus.idle),
      );
      _updateBridgePlaybackState();
      return;
    }

    final nextTrack = state.queue.upcomingTracks.isNotEmpty
        ? state.queue.upcomingTracks.first
        : await _resolveEdgeNeighbor(currentTrack, forward: true);
    if (nextTrack != null) {
      await _playTrack(
        nextTrack,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );
      return;
    }

    await _cache.cancelPrefetch();
    state = state.copyWith(
      playback: state.playback.copyWith(status: PlayerStatus.idle),
      queue: state.queue.copyWith(upcomingTracks: const []),
    );
    _updateBridgePlaybackState();
  }

  ShuffleSlice? _copyShuffleForTrack(TrackUI track) {
    final shuffleIndex = _resolvedShuffleIndex(track);
    if (shuffleIndex < 0) {
      return null;
    }
    return state.shuffle.copyWith(shuffleIndex: shuffleIndex);
  }

  int _resolvedShuffleIndex(TrackUI track) {
    if (!state.shuffle.shuffleOn || state.shuffle.shuffledUuids.isEmpty) {
      return -1;
    }
    final uuids = state.shuffle.shuffledUuids;
    final currentIndex = state.shuffle.shuffleIndex;
    if (currentIndex >= 0 &&
        currentIndex < uuids.length &&
        uuids[currentIndex] == track.uuidId) {
      return currentIndex;
    }
    return uuids.indexOf(track.uuidId);
  }

  Future<void> _refreshUpcoming() async {
    final refreshGeneration = ++_upcomingRefreshGeneration;
    final track = state.playback.currentTrack;
    final context = state.queue.queueContext;
    final trackUuid = track?.uuidId;
    if (track == null || context == null) {
      if (refreshGeneration == _upcomingRefreshGeneration) {
        state = state.copyWith(
          queue: state.queue.copyWith(upcomingTracks: const []),
        );
      }
      return;
    }

    final upcoming = await _queue.resolveUpcoming(
      track: track,
      context: context,
      shuffle: state.shuffle,
      repeatMode: state.queue.repeatMode,
    );

    if (refreshGeneration != _upcomingRefreshGeneration ||
        state.playback.currentTrack?.uuidId != trackUuid) {
      return;
    }
    state = state.copyWith(
      queue: state.queue.copyWith(upcomingTracks: upcoming),
    );
  }

  @visibleForTesting
  void debugSetState(AudioState nextState) {
    state = nextState;
  }

  @visibleForTesting
  Future<void> debugRefreshUpcoming() => _refreshUpcoming();

  Future<TrackUI?> _resolveEdgeNeighbor(
    TrackUI track, {
    required bool forward,
  }) async {
    final context = state.queue.queueContext;
    if (context == null) {
      return null;
    }
    final candidates = await _queue.resolveCandidates(
      current: track,
      context: context,
      shuffle: state.shuffle,
      repeatMode: state.queue.repeatMode,
      limit: 1,
    );
    final tracks = forward ? candidates.next : candidates.previous;
    return tracks.isNotEmpty ? tracks.first : null;
  }

  void _updateBridgeNowPlaying(TrackUI track) {
    _bridge.updateNowPlaying(track);
  }

  void _updateBridgePlaybackState() {
    final status = state.playback.status;
    _bridge.updatePlaybackState(
      playing: status == PlayerStatus.playing,
      processingState: AudioServiceBridge.processingStateFrom(status),
      position: state.playback.position,
    );
  }
}
