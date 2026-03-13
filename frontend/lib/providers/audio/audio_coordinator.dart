import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/audio/queue_resolver.dart';
import 'package:frontend/providers/audio/window_manager.dart';
import 'package:frontend/providers/providers.dart';

class AudioCoordinator extends Notifier<AudioState> {
  late final AudioWindowController _window;
  late final AudioQueueLookup _queue;
  late final AudioServiceBridge _bridge;
  int _upcomingRefreshGeneration = 0;
  bool _stopInProgress = false;

  @override
  AudioState build() {
    _window = ref.read(audioWindowProvider);
    _queue = ref.read(audioQueueLookupProvider);
    _bridge = ref.read(audioServiceProvider);

    // Bind media button callbacks to our methods.
    _bridge.onPlay = resume;
    _bridge.onPause = pause;
    _bridge.onSkipToNext = skipNext;
    _bridge.onSkipToPrevious = skipPrevious;
    _bridge.onSeek = seek;
    _bridge.onStop = stop;

    // Wire window manager callbacks to state updates.
    _window.onStatusChanged = (status) {
      final shouldRestartRepeatOne =
          status == PlayerStatus.idle &&
          !_stopInProgress &&
          state.playback.status == PlayerStatus.playing &&
          state.queue.repeatMode == QueueRepeatMode.one &&
          state.playback.currentTrack != null;
      if (shouldRestartRepeatOne) {
        state = state.copyWith(
          playback: state.playback.copyWith(
            status: PlayerStatus.playing,
            position: Duration.zero,
          ),
        );
        _updateBridgePlaybackState();
        unawaited(
          _window.enqueueMutation(() async {
            await _window.seek(Duration.zero);
            _window.playWithoutAwait();
          }),
        );
        return;
      }

      state = state.copyWith(playback: state.playback.copyWith(status: status));
      _updateBridgePlaybackState();
    };

    _window.onPositionChanged = (pos) {
      state = state.copyWith(playback: state.playback.copyWith(position: pos));
    };

    _window.onDurationChanged = (dur) {
      state = state.copyWith(playback: state.playback.copyWith(duration: dur));
    };

    _window.onTrackChanged = (change) => _handleTrackChanged(change);

    ref.onDispose(() {
      _window.dispose();
    });

    return const AudioState();
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Play a single track with no queue context.
  Future<void> play(TrackUI track) {
    return _window.enqueueMutation(() async {
      state = state.copyWith(
        queue: const QueueSlice(),
        shuffle: const ShuffleSlice(),
      );
      await _replaceWindowAroundTrack(
        track,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );
    });
  }

  /// Play a track within a queue context (artist/album/sort order).
  Future<void> playFromQueue(QueueContext context, TrackUI track) {
    return _window.enqueueMutation(() async {
      var ctx = context;
      if (state.shuffle.shuffleOn) {
        ctx = ctx.withNewSeed();
        final uuids = await ref
            .read(databaseProvider)
            .getTrackUuids(
              orderBy: ctx.orderParams,
              artist: ctx.artist,
              album: ctx.album,
            );
        final shuffled = shuffleWithCurrentFirst(
          uuids,
          track.uuidId,
          ctx.shuffleSeed,
        );
        state = state.copyWith(
          queue: state.queue.copyWith(queueContext: ctx),
          shuffle: state.shuffle.copyWith(
            shuffledUuids: shuffled,
            shuffleIndex: 0,
          ),
        );
      } else {
        state = state.copyWith(
          queue: state.queue.copyWith(queueContext: ctx),
          shuffle: const ShuffleSlice(),
        );
      }
      await _replaceWindowAroundTrack(
        track,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );
    });
  }

  Future<void> skipNext() {
    return _window.enqueueMutation(() async {
      final track = state.playback.currentTrack;
      if (track == null || state.queue.queueContext == null) {
        await _window.stopPlayback();
        state = state.copyWith(
          playback: state.playback.copyWith(status: PlayerStatus.idle),
        );
        return;
      }

      if (state.queue.repeatMode == QueueRepeatMode.one) {
        await _window.seek(Duration.zero);
        _window.playWithoutAwait();
        return;
      }

      final currentIndex =
          _window.playerCurrentIndex ?? _window.windowCurrentIndex;
      if (currentIndex == null) return;
      final nextIndex = currentIndex + 1;
      if (nextIndex < _window.windowTracks.length) {
        await _window.seekToIndex(nextIndex);
        _window.playWithoutAwait();
        return;
      }

      final edgeNext = state.queue.upcomingTracks.isNotEmpty
          ? state.queue.upcomingTracks.first
          : await _resolveEdgeNeighbor(track, forward: true);
      if (edgeNext != null) {
        await _replaceWindowAroundTrack(
          edgeNext,
          shouldPlay: true,
          initialPosition: Duration.zero,
        );
        return;
      }

      await _window.stopPlayback();
      state = state.copyWith(
        playback: state.playback.copyWith(status: PlayerStatus.idle),
      );
    });
  }

  Future<void> skipPrevious() {
    return _window.enqueueMutation(() async {
      final track = state.playback.currentTrack;

      if (state.playback.position.inSeconds > 3) {
        await _window.seek(Duration.zero);
        return;
      }

      if (track == null || state.queue.queueContext == null) {
        await _window.seek(Duration.zero);
        return;
      }

      if (state.queue.repeatMode == QueueRepeatMode.one) {
        await _window.seek(Duration.zero);
        _window.playWithoutAwait();
        return;
      }

      final currentIndex =
          _window.playerCurrentIndex ?? _window.windowCurrentIndex;
      if (currentIndex == null) {
        await _window.seek(Duration.zero);
        return;
      }
      final previousIndex = currentIndex - 1;
      if (previousIndex >= 0) {
        await _window.seekToIndex(previousIndex);
        _window.playWithoutAwait();
        return;
      }

      final edgePrevious = await _resolveEdgeNeighbor(track, forward: false);
      if (edgePrevious != null) {
        await _replaceWindowAroundTrack(
          edgePrevious,
          shouldPlay: true,
          initialPosition: Duration.zero,
        );
        return;
      }

      await _window.seek(Duration.zero);
    });
  }

  Future<void> toggleShuffle() {
    return _window.enqueueMutation(() async {
      final ctx = state.queue.queueContext;
      if (ctx == null) return;

      if (!state.shuffle.shuffleOn) {
        final newCtx = ctx.withNewSeed();
        final uuids = await ref
            .read(databaseProvider)
            .getTrackUuids(
              orderBy: newCtx.orderParams,
              artist: newCtx.artist,
              album: newCtx.album,
            );
        final currentUuid = state.playback.currentTrack?.uuidId;
        final shuffled = shuffleWithCurrentFirst(
          uuids,
          currentUuid,
          newCtx.shuffleSeed,
        );
        state = state.copyWith(
          queue: state.queue.copyWith(queueContext: newCtx),
          shuffle: state.shuffle.copyWith(
            shuffleOn: true,
            shuffledUuids: shuffled,
            shuffleIndex: 0,
          ),
        );
      } else {
        state = state.copyWith(shuffle: const ShuffleSlice());
      }

      final track = state.playback.currentTrack;
      if (track == null) {
        await _refreshUpcoming();
        return;
      }

      await _reconfigureAroundCurrentTrack(track);
    });
  }

  Future<void> cycleQueueRepeatMode() {
    return _window.enqueueMutation(() async {
      final next = switch (state.queue.repeatMode) {
        QueueRepeatMode.off => QueueRepeatMode.all,
        QueueRepeatMode.all => QueueRepeatMode.one,
        QueueRepeatMode.one => QueueRepeatMode.off,
      };
      state = state.copyWith(queue: state.queue.copyWith(repeatMode: next));

      final track = state.playback.currentTrack;
      if (track == null) {
        await _refreshUpcoming();
        return;
      }

      await _reconfigureAroundCurrentTrack(track);
    });
  }

  Future<void> skipToTrack(TrackUI track) {
    return _window.enqueueMutation(() async {
      if (state.shuffle.shuffleOn && state.shuffle.shuffledUuids.isNotEmpty) {
        final idx = state.shuffle.shuffledUuids.indexOf(track.uuidId);
        if (idx >= 0) {
          state = state.copyWith(
            shuffle: state.shuffle.copyWith(shuffleIndex: idx),
          );
        }
      }
      await _replaceWindowAroundTrack(
        track,
        shouldPlay: true,
        initialPosition: Duration.zero,
      );
    });
  }

  Future<void> resume() {
    return _window.enqueueMutation(() async {
      if (state.playback.status == PlayerStatus.paused) {
        _window.playWithoutAwait();
      }
    });
  }

  Future<void> pause() {
    return _window.enqueueMutation(() async {
      await _window.pause();
    });
  }

  Future<void> stop() {
    return _window.enqueueMutation(() async {
      _stopInProgress = true;
      try {
        await _window.stopPlayer();
        _window.acknowledgeCurrentTrack(null);
        _bridge.clearNowPlaying();
        await Future<void>.delayed(Duration.zero);
        state = const AudioState();
      } finally {
        _stopInProgress = false;
      }
    });
  }

  Future<void> seek(Duration pos) {
    return _window.enqueueMutation(() async {
      await _window.seek(pos);
    });
  }

  Future<void> setVolume(double v) async {
    await _window.setVolume(v);
    state = state.copyWith(playback: state.playback.copyWith(volume: v));
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<void> _handleTrackChanged(WindowTrackChange change) async {
    final index = change.index;
    final generation = _window.generation;
    final track = change.track;
    if (state.playback.currentTrack?.uuidId == track.uuidId) {
      return;
    }

    _setCurrentTrackState(
      track,
      position: Duration.zero,
      duration: Duration(milliseconds: (track.duration * 1000).round()),
      resetDuration: true,
    );
    _updateBridgeNowPlaying(track);

    await _refreshUpcoming();

    // After a natural advance, reconfigure the window around the new track.
    final ctx = state.queue.queueContext;
    if (ctx == null || generation != _window.generation) return;

    final candidates = await _queue.resolveCandidates(
      current: track,
      context: ctx,
      shuffle: state.shuffle,
      repeatMode: state.queue.repeatMode,
      limit: playbackWindowSize - 1,
    );
    if (generation != _window.generation) return;

    final newPrev = candidates.previous.isNotEmpty
        ? candidates.previous.first
        : null;
    final newNext = candidates.next.isNotEmpty ? candidates.next.first : null;

    // Determine if we can slide forward (the common case).
    if (_canSlideForward(index, newNext)) {
      if (newNext != null) {
        await _window.slideForward(newNext, generation: generation);
      }
    } else {
      await _window.reconfigureNeighbors(
        newPrev,
        newNext,
        generation: generation,
      );
    }
  }

  /// Check if the index change is a simple forward advance and we can slide.
  bool _canSlideForward(int newIndex, TrackUI? newNext) {
    final tracks = _window.windowTracks;
    // Natural advance: player moved from index N to N+1 in the window.
    // After slide: remove index 0, append newNext.
    // This works when newIndex is the last valid index (or near end).
    return newIndex > 0 && newNext != null && newIndex == tracks.length - 1;
  }

  void _setCurrentTrackState(
    TrackUI track, {
    required Duration position,
    Duration? duration,
    required bool resetDuration,
    PlayerStatus? status,
  }) {
    final shuffleIndex = _resolvedShuffleIndex(track);
    _window.acknowledgeCurrentTrack(track);
    state = state.copyWith(
      playback: state.playback.copyWith(
        currentTrack: track,
        status: status,
        position: position,
        duration:
            duration ??
            (resetDuration ? Duration.zero : state.playback.duration),
      ),
      shuffle: shuffleIndex >= 0
          ? state.shuffle.copyWith(shuffleIndex: shuffleIndex)
          : null,
    );
  }

  int _resolvedShuffleIndex(TrackUI track) {
    if (!state.shuffle.shuffleOn || state.shuffle.shuffledUuids.isEmpty) {
      return -1;
    }
    final uuids = state.shuffle.shuffledUuids;
    final idx = state.shuffle.shuffleIndex;
    if (idx >= 0 && idx < uuids.length && uuids[idx] == track.uuidId) {
      return idx;
    }
    return uuids.indexOf(track.uuidId);
  }

  Future<PlaybackWindowPlan> _buildWindowPlan(TrackUI current) async {
    final context = state.queue.queueContext;
    if (context == null) {
      return PlaybackWindowPlan(tracks: [current], currentIndex: 0);
    }

    if (state.queue.repeatMode == QueueRepeatMode.one) {
      return PlaybackWindowPlan(
        tracks: List<TrackUI>.generate(playbackWindowSize, (_) => current),
        currentIndex: preferredNeighborsPerSide,
      );
    }

    final candidates = await _queue.resolveCandidates(
      current: current,
      context: context,
      shuffle: state.shuffle,
      repeatMode: state.queue.repeatMode,
      limit: playbackWindowSize - 1,
    );

    if (state.queue.repeatMode == QueueRepeatMode.all &&
        candidates.previous.isEmpty &&
        candidates.next.isEmpty) {
      return PlaybackWindowPlan(
        tracks: List<TrackUI>.generate(playbackWindowSize, (_) => current),
        currentIndex: preferredNeighborsPerSide,
      );
    }

    return buildPlaybackWindowPlan(
      current: current,
      previousCandidates: candidates.previous,
      nextCandidates: candidates.next,
    );
  }

  Future<void> _replaceWindowAroundTrack(
    TrackUI track, {
    required bool shouldPlay,
    required Duration initialPosition,
  }) async {
    final generation = _window.incrementGeneration();
    final resetDuration = state.playback.currentTrack?.uuidId != track.uuidId;
    _setCurrentTrackState(
      track,
      position: initialPosition,
      resetDuration: resetDuration,
      status: PlayerStatus.loading,
    );
    _updateBridgeNowPlaying(track);

    try {
      final plan = await _buildWindowPlan(track);
      if (generation != _window.generation) return;
      final applied = await _window.fullReplace(
        plan.tracks,
        plan.currentIndex,
        generation: generation,
        shouldPlay: shouldPlay,
        initialPosition: initialPosition,
      );
      if (!applied && generation == _window.generation) {
        state = state.copyWith(
          playback: state.playback.copyWith(status: PlayerStatus.idle),
        );
      }
    } on Exception {
      if (generation == _window.generation) {
        state = state.copyWith(
          playback: state.playback.copyWith(status: PlayerStatus.idle),
        );
      }
    }

    if (generation == _window.generation) {
      await _refreshUpcoming();
    }
  }

  Future<void> _reconfigureAroundCurrentTrack(TrackUI track) async {
    final generation = _window.incrementGeneration();
    final ctx = state.queue.queueContext;
    if (ctx == null) return;

    final candidates = await _queue.resolveCandidates(
      current: track,
      context: ctx,
      shuffle: state.shuffle,
      repeatMode: state.queue.repeatMode,
      limit: playbackWindowSize - 1,
    );
    if (generation != _window.generation) return;

    final newPrev = candidates.previous.isNotEmpty
        ? candidates.previous.first
        : null;
    final newNext = candidates.next.isNotEmpty ? candidates.next.first : null;

    await _window.reconfigureNeighbors(
      newPrev,
      newNext,
      generation: generation,
    );
    if (generation != _window.generation) return;
    await _refreshUpcoming();
  }

  Future<void> _refreshUpcoming() async {
    final refreshGeneration = ++_upcomingRefreshGeneration;
    final track = state.playback.currentTrack;
    final ctx = state.queue.queueContext;
    final trackUuid = track?.uuidId;
    if (track == null || ctx == null) {
      if (refreshGeneration == _upcomingRefreshGeneration) {
        state = state.copyWith(
          queue: state.queue.copyWith(upcomingTracks: const []),
        );
      }
      return;
    }

    final upcoming = await _queue.resolveUpcoming(
      track: track,
      context: ctx,
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
  Future<void> debugHandleTrackChanged(WindowTrackChange change) =>
      _handleTrackChanged(change);

  @visibleForTesting
  Future<void> debugRefreshUpcoming() => _refreshUpcoming();

  Future<TrackUI?> _resolveEdgeNeighbor(
    TrackUI track, {
    required bool forward,
  }) async {
    final ctx = state.queue.queueContext;
    if (ctx == null) return null;
    final candidates = await _queue.resolveCandidates(
      current: track,
      context: ctx,
      shuffle: state.shuffle,
      repeatMode: state.queue.repeatMode,
      limit: 1,
    );
    final list = forward ? candidates.next : candidates.previous;
    return list.isNotEmpty ? list.first : null;
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
