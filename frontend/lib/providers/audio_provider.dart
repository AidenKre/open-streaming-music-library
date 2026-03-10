import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:just_audio_background/just_audio_background.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/playback_window.dart';
import 'package:frontend/providers/providers.dart';

enum PlayerStatus { idle, loading, playing, paused }

enum QueueRepeatMode { off, all, one }

class QueueContext {
  final String? artist;
  final String? album;
  final List<OrderParameter> orderParams;
  final int shuffleSeed;

  const QueueContext({
    this.artist,
    this.album,
    this.orderParams = const [],
    int? shuffleSeed,
  }) : shuffleSeed = shuffleSeed ?? 0;

  QueueContext withNewSeed() => QueueContext(
    artist: artist,
    album: album,
    orderParams: orderParams,
    shuffleSeed: Random().nextInt(1 << 32),
  );
}

class AudioState {
  final TrackUI? currentTrack;
  final PlayerStatus status;
  final Duration position;
  final Duration duration;
  final double volume;
  final QueueContext? queueContext;
  final bool shuffleOn;
  final QueueRepeatMode repeatMode;
  final List<String> shuffledUuids;
  final int shuffleIndex;
  final List<TrackUI> upcomingTracks;

  const AudioState({
    this.currentTrack,
    this.status = PlayerStatus.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 1.0,
    this.queueContext,
    this.shuffleOn = false,
    this.repeatMode = QueueRepeatMode.off,
    this.shuffledUuids = const [],
    this.shuffleIndex = 0,
    this.upcomingTracks = const [],
  });

  AudioState copyWith({
    TrackUI? currentTrack,
    bool clearTrack = false,
    PlayerStatus? status,
    Duration? position,
    Duration? duration,
    double? volume,
    QueueContext? queueContext,
    bool clearQueueContext = false,
    bool? shuffleOn,
    QueueRepeatMode? repeatMode,
    List<String>? shuffledUuids,
    int? shuffleIndex,
    List<TrackUI>? upcomingTracks,
  }) {
    return AudioState(
      currentTrack: clearTrack ? null : (currentTrack ?? this.currentTrack),
      status: status ?? this.status,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      queueContext: clearQueueContext
          ? null
          : (queueContext ?? this.queueContext),
      shuffleOn: shuffleOn ?? this.shuffleOn,
      repeatMode: repeatMode ?? this.repeatMode,
      shuffledUuids: shuffledUuids ?? this.shuffledUuids,
      shuffleIndex: shuffleIndex ?? this.shuffleIndex,
      upcomingTracks: upcomingTracks ?? this.upcomingTracks,
    );
  }
}

List<OrderParameter> reversedOrder(List<OrderParameter> params) => params
    .map((o) => OrderParameter(column: o.column, isAscending: !o.isAscending))
    .toList();

List<RowFilterParameter> _cursorFromTrack(
  TrackUI track,
  List<OrderParameter> orderParams,
) {
  return orderParams.map((o) {
    final value = switch (o.column) {
      'artist' => track.artist,
      'album' => track.album,
      'disc_number' => track.discNumber,
      'track_number' => track.trackNumber,
      'uuid_id' => track.uuidId,
      'title' => track.title,
      'album_artist' => track.albumArtist,
      'year' => track.year,
      'date' => track.date,
      'genre' => track.genre,
      'codec' => track.codec,
      'duration' => track.duration,
      'bitrate_kbps' => track.bitrateKbps,
      'sample_rate_hz' => track.sampleRateHz,
      'channels' => track.channels,
      'created_at' => track.createdAt,
      'last_updated' => track.lastUpdated,
      _ => null,
    };
    return RowFilterParameter(column: o.column, value: value);
  }).toList();
}

const int _playbackWindowSize = 5;
const int _preferredNeighborsPerSide = 2;

class AudioNotifier extends Notifier<AudioState> {
  late final ja.AudioPlayer _player;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Future<void> _mutationQueue = Future<void>.value();
  int _windowGeneration = 0;
  int _currentIndexMuteDepth = 0;
  int _upcomingRefreshGeneration = 0;
  bool _isDisposed = false;
  List<TrackUI> _windowTracks = const [];
  int? _windowCurrentIndex;

  AppDatabase get _db => ref.read(databaseProvider);

  @override
  AudioState build() {
    _player = ja.AudioPlayer();

    _subscriptions.add(
      _player.playerStateStream.listen((playerState) {
        final status = _mapStatus(playerState);
        state = state.copyWith(status: status);
        if (playerState.processingState == ja.ProcessingState.completed) {
          final completedTrackUuid = state.currentTrack?.uuidId;
          unawaited(
            _enqueueMutation(() async {
              if (_currentIndexMuteDepth > 0) return;
              if (_hasNextTrackInWindow()) return;
              if (completedTrackUuid == null) return;
              if (state.currentTrack?.uuidId != completedTrackUuid) return;
              if (_player.processingState != ja.ProcessingState.completed) {
                return;
              }
              await _handlePlaybackCompleted();
            }),
          );
        }
      }),
    );

    _subscriptions.add(
      _player.positionStream.listen((pos) {
        state = state.copyWith(position: pos);
      }),
    );

    _subscriptions.add(
      _player.durationStream.listen((dur) {
        state = state.copyWith(duration: dur ?? Duration.zero);
      }),
    );

    _subscriptions.add(
      _player.currentIndexStream.listen((index) {
        if (index == null) return;
        final ignoreEvent = _currentIndexMuteDepth > 0;
        unawaited(
          _enqueueMutation(() async {
            if (ignoreEvent) return;
            await _handleCurrentIndexChanged(index);
          }),
        );
      }),
    );

    ref.onDispose(() {
      _isDisposed = true;
      for (final sub in _subscriptions) {
        sub.cancel();
      }
      _player.dispose();
    });

    return const AudioState();
  }

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

  void _playWithoutAwait() => unawaited(_player.play());

  Future<void> _enqueueMutation(Future<void> Function() action) {
    final completer = Completer<void>();
    _mutationQueue = _mutationQueue
        .catchError((Object error, StackTrace stackTrace) {})
        .then((_) async {
          if (_isDisposed) {
            if (!completer.isCompleted) {
              completer.complete();
            }
            return;
          }
          try {
            await action();
            if (!completer.isCompleted) {
              completer.complete();
            }
          } catch (error, stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          }
        });
    return completer.future;
  }

  Future<T> _withMutedCurrentIndexEvents<T>(Future<T> Function() action) async {
    _currentIndexMuteDepth++;
    try {
      return await action();
    } finally {
      _currentIndexMuteDepth--;
    }
  }

  bool _hasNextTrackInWindow() {
    final currentIndex = _player.currentIndex ?? _windowCurrentIndex;
    if (currentIndex == null) return false;
    return currentIndex >= 0 && currentIndex < _windowTracks.length - 1;
  }

  String _streamUrl(TrackUI track) {
    final base = ApiClient.instance.baseUrl;
    return '$base/tracks/${track.uuidId}/stream';
  }

  ja.AudioSource _audioSourceForTrack(TrackUI track) {
    return ja.AudioSource.uri(
      Uri.parse(_streamUrl(track)),
      tag: MediaItem(
        id: track.uuidId,
        title: track.title ?? 'Unknown',
        artist: track.artist ?? '',
        album: track.album ?? '',
      ),
    );
  }

  bool _sameTrackSequence(List<TrackUI> a, List<TrackUI> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].uuidId != b[i].uuidId) return false;
    }
    return true;
  }

  int _resolvedShuffleIndex(TrackUI track) {
    if (!state.shuffleOn || state.shuffledUuids.isEmpty) return -1;
    if (state.shuffleIndex >= 0 &&
        state.shuffleIndex < state.shuffledUuids.length &&
        state.shuffledUuids[state.shuffleIndex] == track.uuidId) {
      return state.shuffleIndex;
    }
    return state.shuffledUuids.indexOf(track.uuidId);
  }

  void _setCurrentTrackState(
    TrackUI track, {
    required Duration position,
    Duration? duration,
    required bool resetDuration,
    PlayerStatus? status,
  }) {
    final shuffleIndex = _resolvedShuffleIndex(track);
    state = state.copyWith(
      currentTrack: track,
      status: status,
      position: position,
      duration: duration ?? (resetDuration ? Duration.zero : state.duration),
      shuffleIndex: shuffleIndex >= 0 ? shuffleIndex : state.shuffleIndex,
    );
  }

  Duration _fallbackDurationForTrack(TrackUI track) {
    final playerDuration = _player.duration;
    if (playerDuration != null && playerDuration > Duration.zero) {
      return playerDuration;
    }
    if (track.duration > 0) {
      return Duration(milliseconds: (track.duration * 1000).round());
    }
    return Duration.zero;
  }

  List<String> _uniqueUuids(Iterable<String> uuids, {String? excludeUuid}) {
    final seen = <String>{};
    if (excludeUuid != null) {
      seen.add(excludeUuid);
    }

    final unique = <String>[];
    for (final uuid in uuids) {
      if (seen.add(uuid)) {
        unique.add(uuid);
      }
    }
    return unique;
  }

  Future<List<TrackUI>> _tracksForUuidsInOrder(List<String> uuids) async {
    if (uuids.isEmpty) return const [];

    final rows = await _db.getTracksByUuids(
      uuids.toSet().toList(growable: false),
    );
    final byUuid = <String, TrackUI>{};
    for (final row in rows) {
      final track = TrackUI.fromQueryRow(row);
      byUuid[track.uuidId] = track;
    }

    return uuids
        .where(byUuid.containsKey)
        .map((uuid) => byUuid[uuid]!)
        .toList();
  }

  Future<List<TrackUI>> _loadShuffleCandidates(
    TrackUI current, {
    required bool forward,
    required int limit,
  }) async {
    if (limit <= 0 || state.shuffledUuids.isEmpty) return const [];

    final currentIndex = _resolvedShuffleIndex(current);
    if (currentIndex < 0) return const [];

    final total = state.shuffledUuids.length;
    final uuids = <String>[];
    for (var step = 1; step <= limit; step++) {
      var index = forward ? currentIndex + step : currentIndex - step;
      if (index < 0 || index >= total) {
        if (state.repeatMode != QueueRepeatMode.all) break;
        index = ((index % total) + total) % total;
      }
      uuids.add(state.shuffledUuids[index]);
    }

    return _tracksForUuidsInOrder(
      _uniqueUuids(uuids, excludeUuid: current.uuidId),
    );
  }

  Future<List<TrackUI>> _loadNextCursorCandidates(
    TrackUI current,
    QueueContext context, {
    required int limit,
  }) async {
    if (limit <= 0) return const [];

    final cursor = _cursorFromTrack(current, context.orderParams);
    final rows = await _db.getTracks(
      orderBy: context.orderParams,
      cursorFilters: cursor,
      artist: context.artist,
      album: context.album,
      limit: limit,
    );
    final tracks = rows.map(TrackUI.fromQueryRow).toList();
    if (tracks.length < limit && state.repeatMode == QueueRepeatMode.all) {
      final wrapRows = await _db.getTracks(
        orderBy: context.orderParams,
        artist: context.artist,
        album: context.album,
        limit: limit - tracks.length,
      );
      tracks.addAll(wrapRows.map(TrackUI.fromQueryRow));
    }
    return _tracksForUuidsInOrder(
      _uniqueUuids(
        tracks.map((track) => track.uuidId),
        excludeUuid: current.uuidId,
      ),
    );
  }

  Future<List<TrackUI>> _loadPreviousCursorCandidates(
    TrackUI current,
    QueueContext context, {
    required int limit,
  }) async {
    if (limit <= 0) return const [];

    final reversed = reversedOrder(context.orderParams);
    final cursor = _cursorFromTrack(current, reversed);
    final rows = await _db.getTracks(
      orderBy: reversed,
      cursorFilters: cursor,
      artist: context.artist,
      album: context.album,
      limit: limit,
    );
    final tracks = rows.map(TrackUI.fromQueryRow).toList();
    if (tracks.length < limit && state.repeatMode == QueueRepeatMode.all) {
      final wrapRows = await _db.getTracks(
        orderBy: reversed,
        artist: context.artist,
        album: context.album,
        limit: limit - tracks.length,
      );
      tracks.addAll(wrapRows.map(TrackUI.fromQueryRow));
    }
    return _tracksForUuidsInOrder(
      _uniqueUuids(
        tracks.map((track) => track.uuidId),
        excludeUuid: current.uuidId,
      ),
    );
  }

  Future<PlaybackWindowPlan> _buildWindowPlan(TrackUI current) async {
    final context = state.queueContext;
    if (context == null || state.repeatMode == QueueRepeatMode.one) {
      return _singleTrackPlan(current);
    }

    final previousCandidates = state.shuffleOn && state.shuffledUuids.isNotEmpty
        ? await _loadShuffleCandidates(
            current,
            forward: false,
            limit: _playbackWindowSize - 1,
          )
        : await _loadPreviousCursorCandidates(
            current,
            context,
            limit: _playbackWindowSize - 1,
          );
    final nextCandidates = state.shuffleOn && state.shuffledUuids.isNotEmpty
        ? await _loadShuffleCandidates(
            current,
            forward: true,
            limit: _playbackWindowSize - 1,
          )
        : await _loadNextCursorCandidates(
            current,
            context,
            limit: _playbackWindowSize - 1,
          );

    return buildPlaybackWindowPlan(
      current: current,
      previousCandidates: previousCandidates,
      nextCandidates: nextCandidates,
      windowSize: _playbackWindowSize,
      preferredNeighborsPerSide: _preferredNeighborsPerSide,
    );
  }

  PlaybackWindowPlan _singleTrackPlan(TrackUI track) =>
      PlaybackWindowPlan(tracks: [track], currentIndex: 0);

  Future<bool> _applyWindowPlan(
    PlaybackWindowPlan plan, {
    required int generation,
    required bool shouldPlay,
    required Duration initialPosition,
  }) async {
    try {
      await _withMutedCurrentIndexEvents(() async {
        if (plan.tracks.length == 1 && plan.currentIndex == 0) {
          await _player.setAudioSource(_audioSourceForTrack(plan.tracks.first));
        } else {
          await _player.setAudioSources(
            plan.tracks.map(_audioSourceForTrack).toList(growable: false),
            initialIndex: plan.currentIndex,
          );
        }
        if (generation != _windowGeneration) return;
        if (initialPosition > Duration.zero) {
          await _player.seek(initialPosition, index: plan.currentIndex);
          if (generation != _windowGeneration) return;
        }
        _windowTracks = List<TrackUI>.unmodifiable(plan.tracks);
        _windowCurrentIndex = plan.currentIndex;
        if (shouldPlay) {
          _playWithoutAwait();
        }
      });
    } on Exception {
      return false;
    }

    if (generation != _windowGeneration) return false;
    await _refreshUpcoming(windowGenerationSnapshot: generation);
    return true;
  }

  Future<void> _expandPlaybackWindow(
    TrackUI track, {
    required int generation,
  }) async {
    if (generation != _windowGeneration) return;
    if (state.queueContext == null || state.repeatMode == QueueRepeatMode.one) {
      return;
    }

    PlaybackWindowPlan desired;
    try {
      desired = await _buildWindowPlan(track);
    } on Exception {
      return;
    }
    if (generation != _windowGeneration) return;
    if (_sameTrackSequence(_windowTracks, desired.tracks) &&
        _windowCurrentIndex == desired.currentIndex) {
      return;
    }

    await _applyWindowPlan(
      desired,
      generation: generation,
      shouldPlay: _player.playing,
      initialPosition: _player.position,
    );
  }

  Future<void> _replaceWindowAroundTrack(
    TrackUI track, {
    required bool shouldPlay,
    required Duration initialPosition,
    bool eagerStart = false,
  }) async {
    final generation = ++_windowGeneration;
    final resetDuration = state.currentTrack?.uuidId != track.uuidId;
    _setCurrentTrackState(
      track,
      position: initialPosition,
      resetDuration: resetDuration,
      status: PlayerStatus.loading,
    );

    if (eagerStart) {
      final started = await _applyWindowPlan(
        _singleTrackPlan(track),
        generation: generation,
        shouldPlay: shouldPlay,
        initialPosition: initialPosition,
      );
      if (!started) {
        if (generation == _windowGeneration) {
          state = state.copyWith(status: PlayerStatus.idle);
        }
        return;
      }
      unawaited(
        _enqueueMutation(() async {
          await _expandPlaybackWindow(track, generation: generation);
        }),
      );
      return;
    }

    try {
      final plan = await _buildWindowPlan(track);
      if (generation != _windowGeneration) return;
      final applied = await _applyWindowPlan(
        plan,
        generation: generation,
        shouldPlay: shouldPlay,
        initialPosition: initialPosition,
      );
      if (!applied && generation == _windowGeneration) {
        state = state.copyWith(status: PlayerStatus.idle);
      }
    } on Exception {
      if (generation == _windowGeneration) {
        state = state.copyWith(status: PlayerStatus.idle);
      }
    }
  }

  Future<void> _syncPlayerWindowToPlan(
    PlaybackWindowPlan desired, {
    required int generation,
  }) async {
    if (generation != _windowGeneration) return;
    if (_sameTrackSequence(_windowTracks, desired.tracks) &&
        _windowCurrentIndex == desired.currentIndex) {
      return;
    }
    if (_windowCurrentIndex == null) {
      await _applyWindowPlan(
        desired,
        generation: generation,
        shouldPlay: _player.playing,
        initialPosition: _player.position,
      );
      return;
    }
    final windowCurrentIndex = _windowCurrentIndex!;
    if (windowCurrentIndex < 0 || windowCurrentIndex >= _windowTracks.length) {
      await _applyWindowPlan(
        desired,
        generation: generation,
        shouldPlay: _player.playing,
        initialPosition: _player.position,
      );
      return;
    }
    if (desired.currentIndex < 0 ||
        desired.currentIndex >= desired.tracks.length) {
      return;
    }

    final currentTrack = _windowTracks[windowCurrentIndex];
    if (desired.tracks[desired.currentIndex].uuidId != currentTrack.uuidId) {
      await _replaceWindowAroundTrack(
        desired.tracks[desired.currentIndex],
        shouldPlay: _player.playing,
        initialPosition: _player.position,
      );
      return;
    }

    final working = List<TrackUI>.from(_windowTracks);
    var currentIndex = windowCurrentIndex;
    var committedWindowState = false;

    await _withMutedCurrentIndexEvents(() async {
      while (currentIndex > 0) {
        if (generation != _windowGeneration || working.isEmpty) return;
        await _player.removeAudioSourceAt(0);
        working.removeAt(0);
        currentIndex--;
      }

      while (working.length > currentIndex + 1) {
        if (generation != _windowGeneration || working.isEmpty) return;
        await _player.removeAudioSourceAt(working.length - 1);
        working.removeLast();
      }

      for (var i = desired.currentIndex - 1; i >= 0; i--) {
        if (generation != _windowGeneration) return;
        final track = desired.tracks[i];
        await _player.insertAudioSource(0, _audioSourceForTrack(track));
        working.insert(0, track);
        currentIndex++;
      }

      for (var i = desired.currentIndex + 1; i < desired.tracks.length; i++) {
        if (generation != _windowGeneration) return;
        final track = desired.tracks[i];
        await _player.addAudioSource(_audioSourceForTrack(track));
        working.add(track);
      }
      _windowTracks = List<TrackUI>.unmodifiable(working);
      _windowCurrentIndex = currentIndex;
      committedWindowState = true;
    });

    if (generation != _windowGeneration) return;
    if (!committedWindowState) return;
    if (!_sameTrackSequence(working, desired.tracks) ||
        currentIndex != desired.currentIndex) {
      await _replaceWindowAroundTrack(
        desired.tracks[desired.currentIndex],
        shouldPlay: _player.playing,
        initialPosition: _player.position,
      );
      return;
    }
  }

  Future<TrackUI?> _resolveNextTrack(TrackUI current) async {
    final context = state.queueContext;
    if (state.repeatMode == QueueRepeatMode.one) return current;
    if (context == null) return null;

    final tracks = state.shuffleOn && state.shuffledUuids.isNotEmpty
        ? await _loadShuffleCandidates(current, forward: true, limit: 1)
        : await _loadNextCursorCandidates(current, context, limit: 1);
    return tracks.isEmpty ? null : tracks.first;
  }

  Future<TrackUI?> _resolvePreviousTrack(TrackUI current) async {
    final context = state.queueContext;
    if (state.repeatMode == QueueRepeatMode.one) return current;
    if (context == null) return null;

    final tracks = state.shuffleOn && state.shuffledUuids.isNotEmpty
        ? await _loadShuffleCandidates(current, forward: false, limit: 1)
        : await _loadPreviousCursorCandidates(current, context, limit: 1);
    return tracks.isEmpty ? null : tracks.first;
  }

  Future<void> _handleCurrentIndexChanged(int index) async {
    if (index < 0 || index >= _windowTracks.length) return;

    final generation = _windowGeneration;
    _windowCurrentIndex = index;
    final track = _windowTracks[index];
    final trackChanged = state.currentTrack?.uuidId != track.uuidId;
    if (trackChanged) {
      _setCurrentTrackState(
        track,
        position: Duration.zero,
        duration: _fallbackDurationForTrack(track),
        resetDuration: true,
      );
    }
    await _refreshUpcoming(windowGenerationSnapshot: generation);

    final desired = await _buildWindowPlan(track);
    if (generation != _windowGeneration) return;
    await _syncPlayerWindowToPlan(desired, generation: generation);
  }

  Future<void> _handlePlaybackCompleted() async {
    if (_hasNextTrackInWindow()) return;

    final track = state.currentTrack;
    if (track == null) return;

    if (state.repeatMode == QueueRepeatMode.one) {
      await _player.seek(Duration.zero);
      _playWithoutAwait();
      return;
    }

    final nextTrack = await _resolveNextTrack(track);
    if (nextTrack == null) {
      _windowGeneration++;
      await _withMutedCurrentIndexEvents(() async {
        await _player.stop();
        await _player.clearAudioSources();
      });
      _windowTracks = const [];
      _windowCurrentIndex = null;
      state = state.copyWith(
        status: PlayerStatus.idle,
        position: Duration.zero,
      );
      return;
    }

    await _replaceWindowAroundTrack(
      nextTrack,
      shouldPlay: true,
      initialPosition: Duration.zero,
    );
  }

  Future<void> _reconfigureWindowAroundCurrentTrack(TrackUI track) async {
    final generation = ++_windowGeneration;
    final desired = await _buildWindowPlan(track);
    if (generation != _windowGeneration) return;
    await _syncPlayerWindowToPlan(desired, generation: generation);
    if (generation != _windowGeneration) return;
    await _refreshUpcoming(windowGenerationSnapshot: generation);
  }

  /// Play a single track with no queue context.
  Future<void> play(TrackUI track) {
    return _enqueueMutation(() async {
      state = state.copyWith(
        clearQueueContext: true,
        shuffleOn: false,
        shuffledUuids: const [],
        shuffleIndex: 0,
        upcomingTracks: const [],
      );
      await _replaceWindowAroundTrack(
        track,
        shouldPlay: true,
        initialPosition: Duration.zero,
        eagerStart: true,
      );
    });
  }

  /// Play a track within a queue context (artist/album/sort order).
  Future<void> playFromQueue(QueueContext context, TrackUI track) {
    return _enqueueMutation(() async {
      var ctx = context;
      if (state.shuffleOn) {
        ctx = ctx.withNewSeed();
        final uuids = await _db.getTrackUuids(
          orderBy: ctx.orderParams,
          artist: ctx.artist,
          album: ctx.album,
        );
        final shuffled = _shuffleWithCurrentFirst(
          uuids,
          track.uuidId,
          ctx.shuffleSeed,
        );
        state = state.copyWith(
          queueContext: ctx,
          shuffledUuids: shuffled,
          shuffleIndex: 0,
        );
      } else {
        state = state.copyWith(
          queueContext: ctx,
          shuffledUuids: const [],
          shuffleIndex: 0,
        );
      }
      await _replaceWindowAroundTrack(
        track,
        shouldPlay: true,
        initialPosition: Duration.zero,
        eagerStart: true,
      );
    });
  }

  Future<void> skipNext() {
    return _enqueueMutation(() async {
      final track = state.currentTrack;
      if (track == null || state.queueContext == null) {
        await _player.stop();
        state = state.copyWith(status: PlayerStatus.idle);
        return;
      }

      if (state.repeatMode == QueueRepeatMode.one) {
        await _player.seek(Duration.zero);
        _playWithoutAwait();
        return;
      }

      final nextIndex = (_windowCurrentIndex ?? 0) + 1;
      if (nextIndex < _windowTracks.length) {
        await _player.seek(Duration.zero, index: nextIndex);
        _playWithoutAwait();
        return;
      }

      final nextTrack = await _resolveNextTrack(track);
      if (nextTrack != null) {
        await _replaceWindowAroundTrack(
          nextTrack,
          shouldPlay: true,
          initialPosition: Duration.zero,
        );
        return;
      }

      await _player.stop();
      state = state.copyWith(status: PlayerStatus.idle);
    });
  }

  Future<void> skipPrevious() {
    return _enqueueMutation(() async {
      final track = state.currentTrack;

      if (state.position.inSeconds > 3) {
        await _player.seek(Duration.zero);
        return;
      }

      if (track == null || state.queueContext == null) {
        await _player.seek(Duration.zero);
        return;
      }

      if (state.repeatMode == QueueRepeatMode.one) {
        await _player.seek(Duration.zero);
        _playWithoutAwait();
        return;
      }

      final previousIndex = (_windowCurrentIndex ?? 0) - 1;
      if (previousIndex >= 0) {
        await _player.seek(Duration.zero, index: previousIndex);
        _playWithoutAwait();
        return;
      }

      final previousTrack = await _resolvePreviousTrack(track);
      if (previousTrack != null) {
        await _replaceWindowAroundTrack(
          previousTrack,
          shouldPlay: true,
          initialPosition: Duration.zero,
        );
        return;
      }

      await _player.seek(Duration.zero);
    });
  }

  Future<void> toggleShuffle() {
    return _enqueueMutation(() async {
      final ctx = state.queueContext;
      if (ctx == null) return;

      if (!state.shuffleOn) {
        final newCtx = ctx.withNewSeed();
        final uuids = await _db.getTrackUuids(
          orderBy: newCtx.orderParams,
          artist: newCtx.artist,
          album: newCtx.album,
        );
        final currentUuid = state.currentTrack?.uuidId;
        final shuffled = _shuffleWithCurrentFirst(
          uuids,
          currentUuid,
          newCtx.shuffleSeed,
        );
        state = state.copyWith(
          shuffleOn: true,
          queueContext: newCtx,
          shuffledUuids: shuffled,
          shuffleIndex: 0,
        );
      } else {
        state = state.copyWith(
          shuffleOn: false,
          shuffledUuids: const [],
          shuffleIndex: 0,
        );
      }

      final track = state.currentTrack;
      if (track == null) {
        await _refreshUpcoming(windowGenerationSnapshot: _windowGeneration);
        return;
      }

      await _reconfigureWindowAroundCurrentTrack(track);
    });
  }

  Future<void> cycleQueueRepeatMode() {
    return _enqueueMutation(() async {
      final next = switch (state.repeatMode) {
        QueueRepeatMode.off => QueueRepeatMode.all,
        QueueRepeatMode.all => QueueRepeatMode.one,
        QueueRepeatMode.one => QueueRepeatMode.off,
      };
      state = state.copyWith(repeatMode: next);

      final track = state.currentTrack;
      if (track == null) {
        await _refreshUpcoming(windowGenerationSnapshot: _windowGeneration);
        return;
      }

      await _reconfigureWindowAroundCurrentTrack(track);
    });
  }

  Future<void> skipToTrack(TrackUI track) {
    return _enqueueMutation(() async {
      if (state.shuffleOn && state.shuffledUuids.isNotEmpty) {
        final idx = state.shuffledUuids.indexOf(track.uuidId);
        if (idx >= 0) {
          state = state.copyWith(shuffleIndex: idx);
        }
      }
      await _replaceWindowAroundTrack(
        track,
        shouldPlay: true,
        initialPosition: Duration.zero,
        eagerStart: true,
      );
    });
  }

  Future<void> _refreshUpcoming({required int windowGenerationSnapshot}) async {
    final refreshGeneration = ++_upcomingRefreshGeneration;
    final track = state.currentTrack;
    final ctx = state.queueContext;
    final trackUuid = track?.uuidId;
    if (track == null || ctx == null) {
      if (refreshGeneration == _upcomingRefreshGeneration &&
          windowGenerationSnapshot == _windowGeneration) {
        state = state.copyWith(upcomingTracks: const []);
      }
      return;
    }

    List<TrackUI> upcoming;
    if (state.shuffleOn && state.shuffledUuids.isNotEmpty) {
      final start = state.shuffleIndex + 1;
      final end = (start + 20).clamp(0, state.shuffledUuids.length);
      if (start >= state.shuffledUuids.length) {
        upcoming = const [];
      } else {
        final uuids = state.shuffledUuids.sublist(start, end);
        final rows = await _db.getTracksByUuids(uuids);
        final map = <String, TrackUI>{};
        for (final row in rows) {
          final t = TrackUI.fromQueryRow(row);
          map[t.uuidId] = t;
        }
        upcoming = uuids
            .where((u) => map.containsKey(u))
            .map((u) => map[u]!)
            .toList();
      }
    } else {
      final cursor = _cursorFromTrack(track, ctx.orderParams);
      final rows = await _db.getTracks(
        orderBy: ctx.orderParams,
        cursorFilters: cursor,
        artist: ctx.artist,
        album: ctx.album,
        limit: 20,
      );
      upcoming = rows.map(TrackUI.fromQueryRow).toList();
    }

    if (refreshGeneration != _upcomingRefreshGeneration ||
        windowGenerationSnapshot != _windowGeneration ||
        state.currentTrack?.uuidId != trackUuid) {
      return;
    }
    state = state.copyWith(upcomingTracks: upcoming);
  }

  Future<void> resume() {
    return _enqueueMutation(() async {
      if (state.status == PlayerStatus.paused) {
        _playWithoutAwait();
      }
    });
  }

  Future<void> pause() {
    return _enqueueMutation(() async {
      await _player.pause();
    });
  }

  Future<void> stop() {
    return _enqueueMutation(() async {
      _windowGeneration++;
      await _withMutedCurrentIndexEvents(() async {
        await _player.stop();
        await _player.clearAudioSources();
      });
      _windowTracks = const [];
      _windowCurrentIndex = null;
      state = state.copyWith(
        clearTrack: true,
        clearQueueContext: true,
        status: PlayerStatus.idle,
        position: Duration.zero,
        duration: Duration.zero,
        shuffleOn: false,
        shuffledUuids: const [],
        shuffleIndex: 0,
        upcomingTracks: const [],
      );
    });
  }

  Future<void> seek(Duration pos) {
    return _enqueueMutation(() async {
      await _player.seek(pos);
    });
  }

  Future<void> setVolume(double v) async {
    await _player.setVolume(v);
    state = state.copyWith(volume: v);
  }

  List<String> _shuffleWithCurrentFirst(
    List<String> uuids,
    String? currentUuid,
    int seed,
  ) {
    final shuffled = List<String>.from(uuids);
    shuffled.shuffle(Random(seed));
    if (currentUuid != null) {
      shuffled.remove(currentUuid);
      shuffled.insert(0, currentUuid);
    }
    return shuffled;
  }
}

final audioProvider = NotifierProvider<AudioNotifier, AudioState>(
  AudioNotifier.new,
);

final currentTrackProvider = Provider<TrackUI?>(
  (ref) => ref.watch(audioProvider.select((s) => s.currentTrack)),
);

final audioPositionProvider = Provider<Duration>(
  (ref) => ref.watch(audioProvider.select((s) => s.position)),
);

final audioDurationProvider = Provider<Duration>(
  (ref) => ref.watch(audioProvider.select((s) => s.duration)),
);

final audioStatusProvider = Provider<PlayerStatus>(
  (ref) => ref.watch(audioProvider.select((s) => s.status)),
);

final audioVolumeProvider = Provider<double>(
  (ref) => ref.watch(audioProvider.select((s) => s.volume)),
);

final shuffleProvider = Provider<bool>(
  (ref) => ref.watch(audioProvider.select((s) => s.shuffleOn)),
);

final repeatModeProvider = Provider<QueueRepeatMode>(
  (ref) => ref.watch(audioProvider.select((s) => s.repeatMode)),
);

final upcomingTracksProvider = Provider<List<TrackUI>>(
  (ref) => ref.watch(audioProvider.select((s) => s.upcomingTracks)),
);
