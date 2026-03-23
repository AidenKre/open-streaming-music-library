import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/audio/concatenating_player_controller.dart';
import 'package:frontend/providers/audio/queue_hydration_controller.dart';
import 'package:frontend/providers/audio/queue_order_manager.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';

class AudioCoordinator extends Notifier<AudioState> {
  static const _volumePreferenceKey = 'audioVolume';

  late ConcatenatingPlayerController _player;
  late QueueRepository _queueRepo;
  late AudioServiceBridge _bridge;
  late QueueOrderManager _orderManager;
  late QueueHydrationController _hydrationController;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  Future<void> _mutationTail = Future<void>.value();
  bool _disposed = false;
  bool _stopInProgress = false;
  DateTime? _lastPositionSave;

  @override
  AudioState build() {
    _player = ref.read(concatenatingPlayerProvider);
    _queueRepo = ref.read(queueRepositoryProvider);
    _bridge = ref.read(audioServiceProvider);
    _orderManager = QueueOrderManager(_queueRepo);
    _hydrationController = QueueHydrationController(_queueRepo, _player);

    _bridge.onPlay = resume;
    _bridge.onPause = pause;
    _bridge.onSkipToNext = skipNext;
    _bridge.onSkipToPrevious = skipPrevious;
    _bridge.onSeek = seek;
    _bridge.onStop = stop;

    _subscriptions.add(_player.playerStateStream.listen(_onPlayerStateChanged));
    _subscriptions.add(_player.positionStream.listen(_onPositionChanged));
    _subscriptions.add(
      _player.durationStream.listen((duration) {
        state = state.copyWith(
          playback: state.playback.copyWith(
            duration: duration ?? Duration.zero,
          ),
        );
      }),
    );
    _subscriptions.add(
      _player.currentItemIdStream.listen((currentItemId) {
        unawaited(_serialize(() => _onCurrentItemChanged(currentItemId)));
      }),
    );

    ref.onDispose(() {
      _disposed = true;
      _hydrationController.dispose();
      for (final sub in _subscriptions) {
        sub.cancel();
      }
      _player.dispose();
    });

    Future.microtask(_restoreStartupState);
    return const AudioState();
  }

  Future<void> play(TrackUI track) {
    return _serialize(() async {
      final sessionId = await _queueRepo.createSessionFromExplicitList(
        sourceType: 'single',
        trackUuids: [track.uuidId],
        currentIndex: 0,
        repeatMode: state.queue.repeatMode.name,
        shuffleEnabled: false,
      );
      await _startSession(sessionId, autoPlay: true);
    });
  }

  Future<void> playFromQueue({
    required TrackUI track,
    required String sourceType,
    int? artistId,
    int? albumId,
    List<OrderParameter> orderParams = const [],
  }) {
    return _serialize(() async {
      _setPlaybackStatus(PlayerStatus.loading);
      final sessionId = await _queueRepo.createSessionFromQuery(
        sourceType: sourceType,
        sourceArtistId: artistId,
        sourceAlbumId: albumId,
        currentUuid: track.uuidId,
        orderBy: orderParams,
        repeatMode: state.queue.repeatMode.name,
        shuffleEnabled: false,
      );
      await _startSession(sessionId, autoPlay: true);
      if (state.shuffle.shuffleOn) {
        await _toggleShuffleInternal(forceEnable: true);
      }
    });
  }

  Future<void> playFromTrackList(
    List<String> uuids,
    TrackUI startTrack, {
    required String sourceType,
  }) {
    return _serialize(() async {
      _setPlaybackStatus(PlayerStatus.loading);
      final startIndex = uuids.indexOf(startTrack.uuidId);
      final sessionId = await _queueRepo.createSessionFromExplicitList(
        sourceType: sourceType,
        trackUuids: uuids,
        currentIndex: startIndex >= 0 ? startIndex : 0,
        repeatMode: state.queue.repeatMode.name,
        shuffleEnabled: false,
      );
      await _startSession(sessionId, autoPlay: true);
      if (state.shuffle.shuffleOn) {
        await _toggleShuffleInternal(forceEnable: true);
      }
    });
  }

  Future<void> skipNext() {
    return _serialize(() async {
      final sessionId = state.queue.sessionId;
      final currentItemId = state.queue.currentItemId;
      if (sessionId == null || currentItemId == null) return;

      if (state.queue.repeatMode == QueueRepeatMode.one) {
        await _player.seek(Duration.zero);
        await _player.play();
        return;
      }

      var targetPlayPosition = state.queue.currentPlayPosition + 1;
      if (targetPlayPosition >= state.queue.totalCount) {
        if (state.queue.repeatMode != QueueRepeatMode.all ||
            state.queue.totalCount == 0) {
          return;
        }
        targetPlayPosition = 0;
      }

      final targetEntries = await _queueRepo.getPlaybackEntries(
        sessionId,
        startPlayPosition: targetPlayPosition,
        limit: 1,
      );
      if (targetEntries.isEmpty) return;

      final target = targetEntries.first;
      await _hydrationController.ensureItemLoaded(sessionId, target);
      await _player.seekToItem(target.itemId);
      await _player.play();
    });
  }

  Future<void> skipPrevious() {
    return _serialize(() async {
      if (state.playback.position.inSeconds > 3) {
        await _player.seek(Duration.zero);
        return;
      }

      final sessionId = state.queue.sessionId;
      final currentItemId = state.queue.currentItemId;
      if (sessionId == null || currentItemId == null) {
        await _player.seek(Duration.zero);
        return;
      }

      if (state.queue.repeatMode == QueueRepeatMode.one) {
        await _player.seek(Duration.zero);
        await _player.play();
        return;
      }

      var targetPlayPosition = state.queue.currentPlayPosition - 1;
      if (targetPlayPosition < 0) {
        if (state.queue.repeatMode != QueueRepeatMode.all ||
            state.queue.totalCount == 0) {
          await _player.seek(Duration.zero);
          return;
        }
        targetPlayPosition = state.queue.totalCount - 1;
      }

      final targetEntries = await _queueRepo.getPlaybackEntries(
        sessionId,
        startPlayPosition: targetPlayPosition,
        limit: 1,
      );
      if (targetEntries.isEmpty) return;

      final target = targetEntries.first;
      await _hydrationController.ensureItemLoaded(sessionId, target);
      await _player.seekToItem(target.itemId);
      await _player.play();
    });
  }

  Future<void> skipToTrack(int itemId) {
    return _serialize(() async {
      final sessionId = state.queue.sessionId;
      if (sessionId == null) return;

      final entry = await _queueRepo.getPlaybackEntryForItem(sessionId, itemId);
      if (entry == null) return;

      await _hydrationController.ensureItemLoaded(sessionId, entry);
      await _player.seekToItem(itemId);
      await _player.play();
    });
  }

  Future<void> toggleShuffle() => _serialize(_toggleShuffleInternal);

  Future<void> cycleQueueRepeatMode() {
    return _serialize(() async {
      final nextMode = switch (state.queue.repeatMode) {
        QueueRepeatMode.off => QueueRepeatMode.all,
        QueueRepeatMode.all => QueueRepeatMode.one,
        QueueRepeatMode.one => QueueRepeatMode.off,
      };

      await _player.setLoopMode(_loopModeFrom(nextMode));

      final sessionId = state.queue.sessionId;
      if (sessionId != null) {
        await _queueRepo.updateRepeatMode(sessionId, nextMode.name);
      }

      state = state.copyWith(queue: state.queue.copyWith(repeatMode: nextMode));
    });
  }

  Future<void> playNext(List<TrackUI> tracks) {
    return _serialize(() async {
      if (tracks.isEmpty) return;

      final sessionId = state.queue.sessionId;
      final currentItemId = state.queue.currentItemId;
      if (sessionId == null || currentItemId == null) {
        final sessionId = await _queueRepo.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: tracks
              .map((track) => track.uuidId)
              .toList(growable: false),
          currentIndex: 0,
          repeatMode: state.queue.repeatMode.name,
          shuffleEnabled: false,
        );
        await _startSession(sessionId, autoPlay: true);
        return;
      }

      await _queueRepo.prependManualItems(
        sessionId,
        tracks.map((track) => track.uuidId).toList(growable: false),
      );
      await _orderManager.rebuildEffectiveOrder(
        sessionId,
        currentItemId: currentItemId,
        preserveShuffledMainFuture: state.shuffle.shuffleOn,
        isShuffleOn: state.shuffle.shuffleOn,
      );
      await _refreshLoadedEntriesMetadata(sessionId);
      await _replaceLoadedFutureSuffixForCurrent(
        sessionId,
        currentItemId: currentItemId,
      );
      await _refreshCurrentQueueState(
        sessionId,
        preservePlaybackPosition: true,
      );
      _invalidateQueueTracks();
      _scheduleForwardHydration();
    });
  }

  Future<void> addToQueue(List<TrackUI> tracks) {
    return _serialize(() async {
      if (tracks.isEmpty) return;

      final sessionId = state.queue.sessionId;
      if (sessionId == null) {
        final sessionId = await _queueRepo.createSessionFromExplicitList(
          sourceType: 'custom',
          trackUuids: tracks
              .map((track) => track.uuidId)
              .toList(growable: false),
          currentIndex: 0,
          repeatMode: state.queue.repeatMode.name,
          shuffleEnabled: false,
        );
        await _startSession(sessionId, autoPlay: true);
        return;
      }

      final currentItemId = state.queue.currentItemId;
      if (currentItemId == null) return;

      final snapshot = await _queueRepo.getSessionSnapshot(sessionId);
      if (snapshot == null || snapshot.totalCount == 0) return;

      await _queueRepo.appendManualItems(
        sessionId,
        tracks.map((track) => track.uuidId).toList(growable: false),
      );
      await _orderManager.rebuildEffectiveOrder(
        sessionId,
        currentItemId: currentItemId,
        preserveShuffledMainFuture: state.shuffle.shuffleOn,
        isShuffleOn: state.shuffle.shuffleOn,
      );
      await _refreshLoadedEntriesMetadata(sessionId);
      await _replaceLoadedFutureSuffixForCurrent(
        sessionId,
        currentItemId: currentItemId,
      );
      await _refreshCurrentQueueState(
        sessionId,
        preservePlaybackPosition: true,
      );
      _invalidateQueueTracks();
      _scheduleForwardHydration();
    });
  }

  Future<void> removeFromQueue(int itemId) {
    return _serialize(() async {
      final sessionId = state.queue.sessionId;
      final currentItemId = state.queue.currentItemId;
      if (sessionId == null ||
          currentItemId == null ||
          currentItemId == itemId) {
        return;
      }

      final removedEntry = await _queueRepo.getPlaybackEntryForItem(
        sessionId,
        itemId,
      );
      if (removedEntry == null) return;

      await _queueRepo.removeItem(sessionId, itemId);
      await _player.removeItem(itemId);
      await _refreshLoadedEntriesMetadata(sessionId);

      if (removedEntry.playPosition <
          _hydrationController.nextForwardHydrationPlayPosition) {
        _hydrationController.nextForwardHydrationPlayPosition--;
      }

      await _refreshCurrentQueueState(sessionId);
      _invalidateQueueTracks();
      _scheduleForwardHydration();
    });
  }

  Future<void> resume() {
    return _serialize(() async {
      if (state.queue.sessionId == null) return;
      await _player.play();
    });
  }

  Future<void> pause() {
    return _serialize(() async {
      await _player.pause();
      await _persistPlaybackCursor();
    });
  }

  Future<void> stop() {
    return _serialize(() async {
      _stopInProgress = true;
      try {
        await _player.stop();
        _bridge.clearNowPlaying();

        final sessionId = state.queue.sessionId;
        if (sessionId != null) {
          await _queueRepo.deactivateAll();
        }

        _hydrationController.reset();
        state = const AudioState();
        _updateBridgePlaybackState();
      } finally {
        _stopInProgress = false;
      }
    });
  }

  Future<void> seek(Duration position) {
    return _serialize(() async {
      await _player.seek(position);
      state = state.copyWith(
        playback: state.playback.copyWith(position: position),
      );
      _updateBridgePlaybackState();
      _lastPositionSave = DateTime.now();
      await _persistPlaybackCursor();
    });
  }

  Future<void> setVolume(double volume) async {
    await _player.setVolume(volume);
    state = state.copyWith(playback: state.playback.copyWith(volume: volume));
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setDouble(_volumePreferenceKey, volume);
  }

  Future<void> _restoreStartupState() async {
    await _restorePersistedVolume();
    await _restoreSession();
  }

  Future<void> _restorePersistedVolume() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final savedVolume = prefs.getDouble(_volumePreferenceKey);
    if (savedVolume == null) {
      return;
    }

    await _player.setVolume(savedVolume);
    state = state.copyWith(
      playback: state.playback.copyWith(volume: savedVolume),
    );
  }

  Future<void> _restoreSession() async {
    if (_hasHydratedSessionState) {
      return;
    }

    try {
      ApiClient.instance.baseUrl;
    } catch (_) {
      return;
    }

    final snapshot = await _queueRepo.getActiveSessionSnapshot();
    if (snapshot == null ||
        snapshot.currentItem == null ||
        snapshot.totalCount == 0) {
      return;
    }

    await _serialize(() async {
      if (_hasHydratedSessionState) {
        return;
      }

      await _startSession(
        snapshot.session.id,
        autoPlay: false,
        initialPosition: Duration(
          milliseconds: snapshot.session.currentPositionMs,
        ),
      );
    });
  }

  Future<void> _startSession(
    int sessionId, {
    required bool autoPlay,
    Duration initialPosition = Duration.zero,
  }) async {
    final snapshot = await _queueRepo.getSessionSnapshot(sessionId);
    final currentItem = snapshot?.currentItem;
    if (snapshot == null || currentItem == null || snapshot.totalCount == 0) {
      throw StateError('Cannot start an empty queue session');
    }

    final seedEntries = await _hydrationController.seedEntriesForPlayPosition(
      sessionId,
      currentItem.playPosition,
    );
    if (seedEntries.isEmpty) {
      throw StateError('Failed to seed the player queue');
    }

    await _player.setSeed(
      seedEntries,
      currentItemId: currentItem.itemId,
      initialPosition: initialPosition,
      autoPlay: autoPlay,
      shuffleEnabled: snapshot.session.shuffleEnabled,
    );

    await _player.setLoopMode(
      _loopModeFrom(_repeatModeFrom(snapshot.session.repeatMode)),
    );

    _hydrationController.nextForwardHydrationPlayPosition =
        seedEntries.map((entry) => entry.playPosition).reduce(max) + 1;

    final currentTrack = await _queueRepo.getTrackForItem(
      sessionId,
      currentItem.itemId,
    );
    if (currentTrack == null) {
      throw StateError('Current queue item could not be loaded');
    }

    state = state.copyWith(
      playback: state.playback.copyWith(
        currentTrack: currentTrack.track,
        status: autoPlay ? PlayerStatus.playing : PlayerStatus.paused,
        position: initialPosition,
        duration: Duration(
          milliseconds: (currentTrack.track.duration * 1000).round(),
        ),
      ),
      queue: state.queue.copyWith(
        sessionId: sessionId,
        currentItemId: currentItem.itemId,
        currentPlayPosition: currentItem.playPosition,
        totalCount: snapshot.totalCount,
        repeatMode: _repeatModeFrom(snapshot.session.repeatMode),
        queueVersion: state.queue.queueVersion + 1,
      ),
      shuffle: ShuffleSlice(shuffleOn: snapshot.session.shuffleEnabled),
    );

    _bridge.updateNowPlaying(currentTrack.track);
    _updateBridgePlaybackState();
    _scheduleForwardHydration();
  }

  bool get _hasHydratedSessionState =>
      state.queue.sessionId != null ||
      _player.queueLength > 0 ||
      state.playback.status != PlayerStatus.idle;

  Future<void> _toggleShuffleInternal({bool? forceEnable}) async {
    final sessionId = state.queue.sessionId;
    final currentItemId = state.queue.currentItemId;
    if (sessionId == null || currentItemId == null) {
      final nextValue = forceEnable ?? !state.shuffle.shuffleOn;
      state = state.copyWith(shuffle: ShuffleSlice(shuffleOn: nextValue));
      return;
    }

    final enable = forceEnable ?? !state.shuffle.shuffleOn;
    if (enable == state.shuffle.shuffleOn) {
      return;
    }

    await _queueRepo.updateShuffleEnabled(sessionId, enable);
    await _orderManager.rebuildEffectiveOrder(
      sessionId,
      currentItemId: currentItemId,
      preserveShuffledMainFuture: false,
      shuffleMainFuture: enable,
      isShuffleOn: state.shuffle.shuffleOn,
    );
    final rebuiltCurrentEntry = await _queueRepo.getPlaybackEntryForItem(
      sessionId,
      currentItemId,
    );
    if (rebuiltCurrentEntry == null) return;

    final windowEntries = await _hydrationController.seedEntriesForPlayPosition(
      sessionId,
      rebuiltCurrentEntry.playPosition,
    );
    await _player.rebuildAroundCurrent(
      currentItemId: currentItemId,
      entries: windowEntries,
    );
    _hydrationController.nextForwardHydrationPlayPosition =
        windowEntries.isEmpty
            ? rebuiltCurrentEntry.playPosition + 1
            : windowEntries.last.playPosition + 1;
    await _refreshCurrentQueueState(sessionId, preservePlaybackPosition: true);
    state = state.copyWith(shuffle: ShuffleSlice(shuffleOn: enable));

    _invalidateQueueTracks();
    _scheduleForwardHydration();
  }

  Future<void> _refreshCurrentQueueState(
    int sessionId, {
    bool preservePlaybackPosition = false,
  }) async {
    final currentItemId = _player.currentItemId ?? state.queue.currentItemId;
    if (currentItemId == null) return;

    final currentTrack = await _queueRepo.getTrackForItem(
      sessionId,
      currentItemId,
    );
    if (currentTrack == null) return;

    state = state.copyWith(
      playback: state.playback.copyWith(
        currentTrack: currentTrack.track,
        position: preservePlaybackPosition
            ? state.playback.position
            : Duration.zero,
        duration: Duration(
          milliseconds: (currentTrack.track.duration * 1000).round(),
        ),
      ),
      queue: state.queue.copyWith(
        currentItemId: currentTrack.itemId,
        currentPlayPosition: currentTrack.playPosition,
        totalCount:
            (await _queueRepo.getSessionSnapshot(sessionId))?.totalCount ??
            state.queue.totalCount,
      ),
    );
  }

  Future<void> _refreshLoadedEntriesMetadata(int sessionId) async {
    final itemIds = _player.loadedItemIds;
    if (itemIds.isEmpty) return;

    final entries = await _queueRepo.getPlaybackEntriesForItemIds(
      sessionId,
      itemIds,
    );
    _player.replaceLoadedEntriesMetadata(entries);
  }

  Future<void> _replaceLoadedFutureSuffixForCurrent(
    int sessionId, {
    required int currentItemId,
  }) async {
    final currentEntry = await _queueRepo.getPlaybackEntryForItem(
      sessionId,
      currentItemId,
    );
    if (currentEntry == null) return;

    final futureEntries = await _queueRepo.getPlaybackEntries(
      sessionId,
      startPlayPosition: currentEntry.playPosition + 1,
      limit: QueueHydrationController.seedNextCount,
    );
    await _player.replaceFutureEntries(
      currentItemId: currentItemId,
      entries: futureEntries,
    );
    _hydrationController.nextForwardHydrationPlayPosition =
        futureEntries.isEmpty
            ? currentEntry.playPosition + 1
            : futureEntries.last.playPosition + 1;
  }

  void _scheduleForwardHydration() {
    final sessionId = state.queue.sessionId;
    if (sessionId == null) return;
    _hydrationController.scheduleForwardHydration(
      sessionId: sessionId,
      totalCount: state.queue.totalCount,
      currentPlayPosition: state.queue.currentPlayPosition,
    );
  }

  Future<void> _onCurrentItemChanged(int? currentItemId) async {
    if (_stopInProgress) return;

    final sessionId = state.queue.sessionId;
    if (sessionId == null || currentItemId == null) return;

    final currentTrack = await _queueRepo.getTrackForItem(
      sessionId,
      currentItemId,
    );
    if (currentTrack == null) return;

    if (state.queue.currentItemId == currentTrack.itemId &&
        state.queue.currentPlayPosition == currentTrack.playPosition &&
        state.playback.currentTrack?.uuidId == currentTrack.track.uuidId) {
      return;
    }

    state = state.copyWith(
      playback: state.playback.copyWith(
        currentTrack: currentTrack.track,
        position: Duration.zero,
        duration: Duration(
          milliseconds: (currentTrack.track.duration * 1000).round(),
        ),
      ),
      queue: state.queue.copyWith(
        currentItemId: currentTrack.itemId,
        currentPlayPosition: currentTrack.playPosition,
      ),
    );

    _bridge.updateNowPlaying(currentTrack.track);
    _updateBridgePlaybackState();
    await _persistPlaybackCursor(
      resetPosition: true,
      resumeMainItemId: currentTrack.queueType == QueueItemTypes.main
          ? currentTrack.itemId
          : null,
      updateResumeMainItemId: currentTrack.queueType == QueueItemTypes.main,
    );
    _scheduleForwardHydration();
  }

  void _onPlayerStateChanged(ja.PlayerState playerState) {
    if (_stopInProgress) return;

    if (playerState.processingState == ja.ProcessingState.completed) {
      state = state.copyWith(
        playback: state.playback.copyWith(status: PlayerStatus.idle),
      );
      _updateBridgePlaybackState();
      return;
    }

    final nextStatus = _mapStatus(playerState);
    if (nextStatus != state.playback.status) {
      state = state.copyWith(
        playback: state.playback.copyWith(status: nextStatus),
      );
      _updateBridgePlaybackState();
    }
  }

  void _onPositionChanged(Duration position) {
    state = state.copyWith(
      playback: state.playback.copyWith(position: position),
    );
    _updateBridgePlaybackState();

    final now = DateTime.now();
    if (_lastPositionSave == null ||
        now.difference(_lastPositionSave!) > const Duration(seconds: 5)) {
      _lastPositionSave = now;
      unawaited(_persistPlaybackCursor());
    }
  }

  Future<void> _persistPlaybackCursor({
    bool resetPosition = false,
    int? resumeMainItemId,
    bool updateResumeMainItemId = false,
  }) async {
    final sessionId = state.queue.sessionId;
    final currentItemId = state.queue.currentItemId;
    if (sessionId == null || currentItemId == null) return;

    await _queueRepo.updatePlaybackCursor(
      sessionId: sessionId,
      currentItemId: currentItemId,
      positionMs: resetPosition ? 0 : state.playback.position.inMilliseconds,
      resumeMainItemId: resumeMainItemId,
      updateResumeMainItemId: updateResumeMainItemId,
    );
  }

  Future<void> _serialize(Future<void> Function() action) {
    final future = _mutationTail.then((_) => action());
    _mutationTail = future.catchError((_) {});
    return future;
  }

  void _invalidateQueueTracks() {
    state = state.copyWith(
      queue: state.queue.copyWith(queueVersion: state.queue.queueVersion + 1),
    );
  }

  void _setPlaybackStatus(PlayerStatus status) {
    state = state.copyWith(playback: state.playback.copyWith(status: status));
  }

  void _updateBridgePlaybackState() {
    final status = state.playback.status;
    _bridge.updatePlaybackState(
      playing: status == PlayerStatus.playing,
      processingState: AudioServiceBridge.processingStateFrom(status),
      position: state.playback.position,
    );
  }

  static QueueRepeatMode _repeatModeFrom(String value) {
    return switch (value) {
      'all' => QueueRepeatMode.all,
      'one' => QueueRepeatMode.one,
      _ => QueueRepeatMode.off,
    };
  }

  static ja.LoopMode _loopModeFrom(QueueRepeatMode mode) {
    return switch (mode) {
      QueueRepeatMode.off => ja.LoopMode.off,
      QueueRepeatMode.all => ja.LoopMode.all,
      QueueRepeatMode.one => ja.LoopMode.one,
    };
  }

  static PlayerStatus _mapStatus(ja.PlayerState playerState) {
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
