import 'dart:async';
import 'dart:math';

import 'package:just_audio/just_audio.dart' as ja;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_state.dart';

const int playbackWindowSize = 3;
const int preferredNeighborsPerSide = 1;

class PlaybackWindowPlan {
  final List<TrackUI> tracks;
  final int currentIndex;

  const PlaybackWindowPlan({required this.tracks, required this.currentIndex});
}

PlaybackWindowPlan buildPlaybackWindowPlan({
  required TrackUI current,
  required List<TrackUI> previousCandidates,
  required List<TrackUI> nextCandidates,
  int windowSize = playbackWindowSize,
  int preferredNeighbors = preferredNeighborsPerSide,
}) {
  if (windowSize < 1) {
    throw ArgumentError.value(windowSize, 'windowSize', 'Must be positive.');
  }
  if (preferredNeighbors < 0) {
    throw ArgumentError.value(
      preferredNeighbors,
      'preferredNeighbors',
      'Cannot be negative.',
    );
  }

  var previousCount = min(preferredNeighbors, previousCandidates.length);
  var nextCount = min(preferredNeighbors, nextCandidates.length);
  var remainingSlots = windowSize - 1 - previousCount - nextCount;

  if (remainingSlots > 0) {
    final extraNext = min(remainingSlots, nextCandidates.length - nextCount);
    nextCount += extraNext;
    remainingSlots -= extraNext;
  }

  if (remainingSlots > 0) {
    final extraPrevious = min(
      remainingSlots,
      previousCandidates.length - previousCount,
    );
    previousCount += extraPrevious;
  }

  final previousTracks = previousCandidates
      .take(previousCount)
      .toList()
      .reversed
      .toList(growable: false);
  final nextTracks = nextCandidates.take(nextCount).toList(growable: false);

  return PlaybackWindowPlan(
    tracks: [...previousTracks, current, ...nextTracks],
    currentIndex: previousTracks.length,
  );
}

enum WindowTrackChangeOrigin { directPlayerIndex, reconciledAfterMutation }

class WindowTrackChange {
  final TrackUI track;
  final int index;
  final WindowTrackChangeOrigin origin;

  const WindowTrackChange({
    required this.track,
    required this.index,
    required this.origin,
  });
}

/// Callback signatures for window events.
typedef StatusChangedCallback = void Function(PlayerStatus status);
typedef PositionChangedCallback = void Function(Duration position);
typedef DurationChangedCallback = void Function(Duration duration);
typedef TrackChangeCallback = Future<void> Function(WindowTrackChange change);

abstract class AudioWindowController {
  set onTrackChanged(TrackChangeCallback? callback);
  set onStatusChanged(StatusChangedCallback? callback);
  set onPositionChanged(PositionChangedCallback? callback);
  set onDurationChanged(DurationChangedCallback? callback);

  List<TrackUI> get windowTracks;
  int? get windowCurrentIndex;
  int get generation;
  int incrementGeneration();

  Future<void> enqueueMutation(Future<void> Function() action);
  Future<void> slideForward(TrackUI newNext, {required int generation});
  Future<void> reconfigureNeighbors(
    TrackUI? newPrev,
    TrackUI? newNext, {
    required int generation,
  });
  Future<bool> fullReplace(
    List<TrackUI> tracks,
    int currentIndex, {
    required int generation,
    required bool shouldPlay,
    required Duration initialPosition,
  });
  Future<void> seekToIndex(int index, {Duration position = Duration.zero});
  void playWithoutAwait();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double v);
  Future<void> stopPlayback();
  Future<void> stopPlayer();
  int? get playerCurrentIndex;
  TrackUI? get currentTrack;
  void acknowledgeCurrentTrack(TrackUI? track);
  void dispose();
}

/// Manages the just_audio player's playlist window.
/// Provides 3 operations: slideForward, reconfigureNeighbors, fullReplace.
class WindowManager implements AudioWindowController {
  final ja.AudioPlayer _player;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  bool _isDisposed = false;

  List<TrackUI> _windowTracks = const [];
  int? _windowCurrentIndex;
  int _windowGeneration = 0;
  int _currentIndexMuteDepth = 0;
  Future<void> _mutationQueue = Future<void>.value();

  /// Callback invoked when the current playing track actually changes.
  TrackChangeCallback? onTrackChanged;
  StatusChangedCallback? onStatusChanged;
  PositionChangedCallback? onPositionChanged;
  DurationChangedCallback? onDurationChanged;
  String? _acknowledgedTrackUuid;

  WindowManager(this._player) {
    _subscriptions.add(
      _player.playerStateStream.listen((playerState) {
        final status = _mapStatus(playerState);
        onStatusChanged?.call(status);
      }),
    );

    _subscriptions.add(
      _player.positionStream.listen((pos) {
        onPositionChanged?.call(pos);
      }),
    );

    _subscriptions.add(
      _player.durationStream.listen((dur) {
        onDurationChanged?.call(dur ?? Duration.zero);
      }),
    );

    _subscriptions.add(
      _player.currentIndexStream.listen((index) {
        if (index == null) return;
        final ignoreEvent = _currentIndexMuteDepth > 0;
        unawaited(
          enqueueMutation(() async {
            if (ignoreEvent) return;
            await _emitTrackChangeIfNeeded(
              index,
              WindowTrackChangeOrigin.directPlayerIndex,
            );
          }),
        );
      }),
    );
  }

  factory WindowManager.create() => WindowManager(ja.AudioPlayer());

  ja.AudioPlayer get player => _player;
  @override
  List<TrackUI> get windowTracks => _windowTracks;

  @override
  int? get windowCurrentIndex => _windowCurrentIndex;

  @override
  int get generation => _windowGeneration;

  @override
  int incrementGeneration() => ++_windowGeneration;

  PlayerStatus _mapStatus(ja.PlayerState playerState) {
    final processing = playerState.processingState;
    if (processing == ja.ProcessingState.loading ||
        processing == ja.ProcessingState.buffering) {
      return PlayerStatus.loading;
    }
    if (processing == ja.ProcessingState.completed ||
        processing == ja.ProcessingState.idle) {
      return PlayerStatus.idle;
    }
    return playerState.playing ? PlayerStatus.playing : PlayerStatus.paused;
  }

  Future<void> _emitTrackChangeIfNeeded(
    int index,
    WindowTrackChangeOrigin origin,
  ) async {
    if (index < 0 || index >= _windowTracks.length) return;
    _windowCurrentIndex = index;
    final track = _windowTracks[index];
    if (_acknowledgedTrackUuid == track.uuidId) {
      return;
    }
    await onTrackChanged?.call(
      WindowTrackChange(track: track, index: index, origin: origin),
    );
    _acknowledgedTrackUuid = track.uuidId;
  }

  @override
  Future<void> enqueueMutation(Future<void> Function() action) {
    final completer = Completer<void>();
    _mutationQueue = _mutationQueue
        .catchError((Object error, StackTrace stackTrace) {})
        .then((_) async {
          if (_isDisposed) {
            if (!completer.isCompleted) completer.complete();
            return;
          }
          try {
            await action();
            if (!completer.isCompleted) completer.complete();
          } catch (error, stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          }
        });
    return completer.future;
  }

  Future<T> _withMutedEvents<T>(Future<T> Function() action) async {
    _currentIndexMuteDepth++;
    try {
      return await action();
    } finally {
      _currentIndexMuteDepth--;
    }
  }

  Future<void> _reconcileTrackAfterMutation({
    required String? expectedTrackUuid,
  }) async {
    if (_windowTracks.isEmpty) return;
    final actualIndex = _player.currentIndex ?? _windowCurrentIndex;
    if (actualIndex == null) return;
    if (actualIndex < 0 || actualIndex >= _windowTracks.length) return;
    final actualTrack = _windowTracks[actualIndex];
    _windowCurrentIndex = actualIndex;
    if (actualTrack.uuidId == expectedTrackUuid) {
      return;
    }
    await _emitTrackChangeIfNeeded(
      actualIndex,
      WindowTrackChangeOrigin.reconciledAfterMutation,
    );
  }

  static String streamUrl(TrackUI track) {
    final base = ApiClient.instance.baseUrl;
    return '$base/tracks/${track.uuidId}/stream';
  }

  ja.AudioSource _audioSourceForTrack(TrackUI track) {
    return ja.AudioSource.uri(Uri.parse(streamUrl(track)));
  }

  /// Operation 1: Slide the window forward by one position.
  /// Removes the first item and appends a new next track.
  /// Preserves the buffer of the current (now-playing) track.
  @override
  Future<void> slideForward(TrackUI newNext, {required int generation}) async {
    if (generation != _windowGeneration) return;
    if (_windowTracks.length < 2 || _windowCurrentIndex == null) return;
    final expectedTrackUuid = currentTrack?.uuidId;

    await _withMutedEvents(() async {
      await _player.removeAudioSourceAt(0);
      await _player.addAudioSource(_audioSourceForTrack(newNext));
    });

    if (generation != _windowGeneration) return;
    final newTracks = [..._windowTracks.sublist(1), newNext];
    _windowTracks = List<TrackUI>.unmodifiable(newTracks);
    _windowCurrentIndex = _windowCurrentIndex! - 1;
    await _reconcileTrackAfterMutation(expectedTrackUuid: expectedTrackUuid);
  }

  /// Operation 2: Reconfigure neighbors around the current track.
  /// Keeps the current track in place (buffer preserved), swaps out everything else.
  @override
  Future<void> reconfigureNeighbors(
    TrackUI? newPrev,
    TrackUI? newNext, {
    required int generation,
  }) async {
    if (generation != _windowGeneration) return;
    if (_windowCurrentIndex == null || _windowTracks.isEmpty) return;
    final expectedTrackUuid = currentTrack?.uuidId;

    var currentIndex = _windowCurrentIndex!;

    var sourceCount = _windowTracks.length;

    await _withMutedEvents(() async {
      // Remove everything after current
      while (sourceCount > currentIndex + 1) {
        if (generation != _windowGeneration) return;
        await _player.removeAudioSourceAt(sourceCount - 1);
        sourceCount--;
      }

      // Remove everything before current
      while (currentIndex > 0) {
        if (generation != _windowGeneration) return;
        await _player.removeAudioSourceAt(0);
        currentIndex--;
        sourceCount--;
      }

      // Insert new prev at index 0
      if (newPrev != null) {
        if (generation != _windowGeneration) return;
        await _player.insertAudioSource(0, _audioSourceForTrack(newPrev));
        currentIndex++;
      }

      // Append new next
      if (newNext != null) {
        if (generation != _windowGeneration) return;
        await _player.addAudioSource(_audioSourceForTrack(newNext));
      }
    });

    if (generation != _windowGeneration) return;

    final current = _windowTracks[_windowCurrentIndex!];
    final newTracks = <TrackUI>[
      if (newPrev != null) newPrev,
      current,
      if (newNext != null) newNext,
    ];
    _windowTracks = List<TrackUI>.unmodifiable(newTracks);
    _windowCurrentIndex = currentIndex;
    await _reconcileTrackAfterMutation(expectedTrackUuid: expectedTrackUuid);
  }

  /// Operation 3: Full replace of the playlist.
  /// Used when the current track itself changes (new queue, skip to track).
  @override
  Future<bool> fullReplace(
    List<TrackUI> tracks,
    int currentIndex, {
    required int generation,
    required bool shouldPlay,
    required Duration initialPosition,
  }) async {
    if (generation != _windowGeneration) return false;
    final expectedTrackUuid = tracks[currentIndex].uuidId;

    try {
      await _withMutedEvents(() async {
        if (tracks.length == 1 && currentIndex == 0) {
          await _player.setAudioSource(_audioSourceForTrack(tracks.first));
        } else {
          await _player.setAudioSources(
            tracks.map(_audioSourceForTrack).toList(growable: false),
            initialIndex: currentIndex,
          );
        }
        if (generation != _windowGeneration) return;
        if (initialPosition > Duration.zero) {
          await _player.seek(initialPosition, index: currentIndex);
          if (generation != _windowGeneration) return;
        }
        _windowTracks = List<TrackUI>.unmodifiable(tracks);
        _windowCurrentIndex = currentIndex;
        if (shouldPlay) {
          unawaited(_player.play());
        }
      });
    } on Exception {
      return false;
    }

    if (generation == _windowGeneration) {
      await _reconcileTrackAfterMutation(expectedTrackUuid: expectedTrackUuid);
    }

    return generation == _windowGeneration;
  }

  /// Seek within the current playlist (for skip next/prev).
  @override
  Future<void> seekToIndex(
    int index, {
    Duration position = Duration.zero,
  }) async {
    await _player.seek(position, index: index);
  }

  @override
  void playWithoutAwait() => unawaited(_player.play());

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double v) => _player.setVolume(v);

  @override
  Future<void> stopPlayback() => _player.stop();

  @override
  Future<void> stopPlayer() async {
    _windowGeneration++;
    await _withMutedEvents(() async {
      await _player.stop();
      await _player.clearAudioSources();
    });
    _windowTracks = const [];
    _windowCurrentIndex = null;
  }

  Duration get currentDuration => _player.duration ?? Duration.zero;
  Duration get currentPosition => _player.position;
  bool get isPlaying => _player.playing;
  @override
  int? get playerCurrentIndex => _player.currentIndex;

  @override
  TrackUI? get currentTrack {
    final idx = _windowCurrentIndex;
    if (idx == null || idx < 0 || idx >= _windowTracks.length) return null;
    return _windowTracks[idx];
  }

  @override
  void acknowledgeCurrentTrack(TrackUI? track) {
    _acknowledgedTrackUuid = track?.uuidId;
  }

  @override
  void dispose() {
    _isDisposed = true;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _player.dispose();
  }
}
