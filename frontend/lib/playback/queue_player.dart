import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_focus.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/playback/queue_window.dart';
import 'package:frontend/playback/source_failure_classifier.dart';
import 'package:frontend/playback/queue_order_manager.dart';
import 'package:frontend/playback/playback_issue_bus.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/session_readiness.dart';
import 'package:frontend/services/settings_service.dart';

/// The playback core (SC-27 `QueuePlayer`). Invariants:
///  1. It alone writes playback state; each publication is coherent
///     (identity, position and duration belong to the same item).
///  2. Lifecycle ([lifecycle]), desired transport and processing are
///     independent axes (see [PlaybackSlice]).
///  3. The lane serializes command issuance only: engine commands return
///     once issued and loads complete as engine events, so pause, stop and
///     focus loss never wait behind a load.
///  4. Lane code never awaits a public, lane-enqueuing method.
///  5. Audio focus events arrive as commands through the lane
///     ([AudioFocusOwner]); the engine gates audible output on focus.
///  7. The engine window is one contiguous interval ([QueueWindow]); a
///     distant jump rebases; hydration is applied in the lane only while
///     its session, queue, window and source configuration are current.
///  8. Resolvers and the failure classifier decide; this core publishes
///     their issues ([PlaybackIssueBus]), on success and on rejection.
///  9. Clicks are emitted only by [PlaybackRequests.submit], never here.
///  10. Observers ([NowPlayingPublisher], queue warm, the listen tracker
///     and recorder) never mutate it; listen accounting reads engine
///     observations only.
///  11. User input reaches it through interface-backed controllers.
///  12. Quiesce closes admission synchronously; quiesced is terminal.
///  13. Every listener task has an error sink; recovery is bounded.
///  14. Its dependencies are scope-bound providers; a reset rebuilds them.
///  15. Unknown duration is null, never zero.
class QueuePlayer extends Notifier<AudioState>
    implements AudioFocusOwner {
  static const _volumePreferenceKey = 'audioVolume';

  late PlaybackEngine _player;
  late QueueRepository _queueRepo;
  late PlaybackTargetResolver _targetResolver;
  late QueueOrderManager _orderManager;
  late QueueWindow _window;
  late AudioFocus _focus;

  /// Bumped when stream quality or download states change, so a hydration
  /// proposal built under the old configuration is not applied.
  int _sourceConfigVersion = 0;

  /// Set when an OS interruption paused playing audio; any later transport
  /// command by the user clears it, so their choice is never undone.
  bool _resumeAfterInterruption = false;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  Future<void> _mutationTail = Future<void>.value();
  bool _stopInProgress = false;

  /// Newest admitted replacement request (SC-27 principle 5).
  int _requestRevision = 0;
  PlaybackLifecycle _lifecycle = PlaybackLifecycle.none;
  Future<void>? _quiescing;
  late Clock _clock;
  late PlaybackIssueBus _issues;
  late SourceFailureClassifier _classifier;

  /// Monotonic time since the last throttled cursor save (SC-20).
  MonotonicStopwatch? _sinceCursorSave;

  @override
  AudioState build() {
    _player = ref.read(playbackEngineProvider);
    _queueRepo = ref.read(queueRepositoryProvider);
    _targetResolver = ref.read(playbackTargetResolverProvider);
    _orderManager = QueueOrderManager(_queueRepo);
    _window = ref.read(queueWindowProvider);
    _focus = ref.read(audioFocusProvider);
    _clock = ref.read(clockProvider);
    _issues = ref.read(playbackIssueBusProvider);
    _classifier = ref.read(sourceFailureClassifierProvider);
    _focus.bind(AudioOutput.queue, this);

    // Push stream quality changes into the player so newly-built sources use
    // the user's current preset. The very first fire happens during build() —
    // before `state` is initialised — so we only push the quality through and
    // skip the prefetch on that initial call.
    ref.listen<String>(streamQualityProvider, (previous, next) {
      _player.setStreamQuality(next);
      if (previous != null) {
        _sourceConfigVersion++;
        // Rebuild playlist sources so in-flight buffered tracks switch to the
        // new quality. Full change rebuilds all; temp change rebuilds only the
        // current source (cheaper — avoids rebuffering the whole ahead window).
        final kind = ref.read(streamQualityChangeKindProvider);
        // Through the lane: never interleaved with a structural operation,
        // and at the position (and item) current when it runs.
        if (kind == QualityChangeKind.full) {
          _runTask('quality rebuild', () async {
            if (state.queue.sessionId == null) return;
            await _player.rebuildAllSources(next, _player.position);
          });
        } else if (kind == QualityChangeKind.temporary) {
          _runTask('quality rebuild', () async {
            if (state.queue.sessionId == null) return;
            await _player.rebuildCurrentSource(next, _player.position);
          });
        }
      }
    }, fireImmediately: true);

    // When a track is downloaded or deleted while it's already in the loaded
    // player window, its in-flight just_audio source still points at the old
    // stream/file URI. Refresh metadata and rebuild any source whose local
    // file vs streaming availability changed. Skip the synthetic
    // AsyncLoading → AsyncData(initial) transition that fires once on build —
    // there's no real download-state change to reconcile yet.
    ref.listen<AsyncValue<int>>(downloadStatusVersionProvider, (
      previous,
      next,
    ) {
      final previousValue = previous?.value;
      final nextValue = next.value;
      if (previousValue == null || nextValue == null) return;
      if (previousValue == nextValue) return;
      _sourceConfigVersion++;
      _runTask('download refresh', _refreshLoadedSourcesForDownloadChange);
    });

    ref.listen<AsyncValue<TrackSyncState>>(trackSyncProvider, (previous, next) {
      final previousValue = previous?.value;
      final nextValue = next.value;
      if (nextValue == null) return;
      final previousVersion = previousValue?.queueMutationVersion ?? 0;
      if (nextValue.queueMutationVersion <= previousVersion) return;
      if (nextValue.affectedQueueSessionIds.isEmpty) return;
      _runTask('sync reconcile',
          () => _reconcileInLane(nextValue.affectedQueueSessionIds));
    });

    _subscriptions.add(_player.transportStateStream.listen(_onPlayerStateChanged));
    _subscriptions.add(_player.positionStream.listen(_onPositionChanged));
    // The measured duration comes only from settled observations of the
    // current item: identity and duration always belong together
    // (invariant 1), and an unknown one is null (invariant 15).
    _subscriptions.add(_player.observations.listen(_onObservation));
    _subscriptions.add(_player.loadEvents.listen(_onLoadEvent));
    _subscriptions.add(_player.sourceFailures.listen((failure) => _offLaneTask(
        'source failure',
        () => _onSourceFailure(
              itemId: failure.source?.itemId,
              trackUuid: failure.source?.trackUuid,
              sourceKey: failure.source?.sourceId,
              uncertain: failure.uncertain,
              errorCode: failure.errorCode,
              errorMessage: failure.errorMessage,
            ))));
    _subscriptions.add(
      _player.currentItemIdStream.listen((currentItemId) {
        _runTask('item change', () => _onCurrentItemChanged(currentItemId));
      }),
    );
    _subscriptions.add(
      _player.unavailableAdvanceStream.listen((event) {
        _runTask('unavailable advance', () => _onUnavailableAdvance(event));
      }),
    );

    ref.onDispose(() {
      // The engine and window belong to their providers' scope, which
      // disposes them; a rebuilt player reuses the live ones.
      _focus.release(AudioOutput.queue, this);
      for (final sub in _subscriptions) {
        sub.cancel();
      }
    });

    // Lifecycle none -> active with the session-ready signal, independent of
    // the volume restore (restore order itself is unchanged).
    unawaited(
      ref.read(sessionReadinessProvider).ready.then((_) {
        if (!ref.mounted) return;
        if (_lifecycle == PlaybackLifecycle.none) {
          _lifecycle = PlaybackLifecycle.active;
        }
      }),
    );

    Future.microtask(() => _offLaneTask('startup restore', _restoreStartupState));
    return const AudioState();
  }

  // ---- SC-27 request entry points (used by PlaybackRequests) -------------

  /// Admits a replacement request (SC-27 principle 5): its revision is the
  /// newest; any older pending replacement is superseded. Stop and quiesce
  /// also advance it.
  int admitReplacement() => ++_requestRevision;

  /// The newest admitted replacement revision (an Enqueue compares it to
  /// know whether a newer replacement was admitted while it waited).
  int get requestRevision => _requestRevision;

  /// Whether a request admitted at [revision] may still activate.
  bool isCurrentRequest(int revision) =>
      revision == _requestRevision && !_admissionClosed;

  /// Activates a prepared session on the lane: only for the newest
  /// admitted request; the conditional repository activation fails
  /// (stale) for a session that is gone. State is committed last; if the
  /// start fails after activation, the previous session is reactivated.
  Future<ActivationResult> activatePreparedSession(
    int sessionId,
    QueuePlaybackEntry target, {
    required bool autoPlay,
    required int requestRevision,
  }) async {
    var result = ActivationResult.superseded;
    await _serialize(() async {
      if (requestRevision != _requestRevision) return;
      final previous = state.queue.sessionId;
      try {
        await _queueRepo.activateSession(sessionId);
      } on StateError {
        result = ActivationResult.stale;
        return;
      }
      final engineRevision = _player.playlistRevision;
      final before = state;
      try {
        await _startSession(sessionId,
            autoPlay: autoPlay, overrideCurrentItem: target);
      } catch (_) {
        // The start failed: the prepared session (discarded by the caller)
        // must not stay active, and the current queue, status and audio
        // stay as they were.
        try {
          if (previous != null) {
            await _queueRepo.activateSession(previous);
          } else {
            await _queueRepo.deactivateAll();
          }
        } catch (_) {
          // At least the prepared session must not stay active (its discard
          // skips an active session); then the current one is retried.
          try {
            await _queueRepo.deactivateAll();
            if (previous != null) await _queueRepo.activateSession(previous);
          } catch (_) {/* the error below is what the caller sees */}
        }
        if (_player.playlistRevision != engineRevision) {
          try {
            await _restoreAfterFailedStart(before);
          } catch (_) {/* as above */}
        }
        rethrow;
      }
      result = ActivationResult.accepted;
    });
    return result;
  }

  /// A failed start had already seeded the engine with the prepared
  /// session: give the engine the queue [before] described again, at its
  /// item and position; if that fails too, stop honestly (empty state).
  Future<void> _restoreAfterFailedStart(AudioState before) async {
    final sessionId = before.queue.sessionId;
    final itemId = before.queue.currentItemId;
    if (sessionId != null && itemId != null) {
      try {
        await _queueRepo.activateSession(sessionId); // if the first try failed
        final entry = await _queueRepo.getPlaybackEntryForItem(sessionId, itemId);
        if (entry == null) throw StateError('The current item is gone');
        await _startSession(sessionId,
            autoPlay: before.playback.playWhenReady,
            initialPosition: before.playback.position,
            overrideCurrentItem: entry,
            cause: PlaybackTransitionCause.reconcileContinuation);
        return;
      } catch (_) {
        // fall through to a stop
      }
    }
    _stopInProgress = true;
    try {
      _window.reset();
      state =
          AudioState(playback: PlaybackSlice(volume: state.playback.volume));
      await _player.stop();
      await _queueRepo.deactivateAll();
    } finally {
      _stopInProgress = false;
    }
  }

  Future<void> skipNext() {
    return _serialize(() async {
      _resetFailureRun(); // a user move starts a new failure run
      final sessionId = state.queue.sessionId;
      final currentItemId = state.queue.currentItemId;
      if (sessionId == null || currentItemId == null) return;

      if (state.queue.repeatMode == QueueRepeatMode.one) {
        await _player.seek(Duration.zero);
        await _player.play();
        return;
      }

      final target = await _resolveAdvanceTarget(
        sessionId: sessionId,
        direction: PlayOrderDirection.forward,
      );
      if (target == null) return;

      await _ensureItemLoaded(sessionId, target);
      await _player.seekToItem(target.itemId);
      await _player.play();
    });
  }

  Future<void> skipPrevious() {
    return _serialize(() async {
      _resetFailureRun(); // a user move starts a new failure run
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

      final target = await _resolveAdvanceTarget(
        sessionId: sessionId,
        direction: PlayOrderDirection.backward,
      );
      if (target == null) {
        await _player.seek(Duration.zero);
        return;
      }

      await _ensureItemLoaded(sessionId, target);
      await _player.seekToItem(target.itemId);
      await _player.play();
    });
  }

  Future<void> skipToTrack(int itemId) {
    return _serialize(() async {
      _resetFailureRun(); // a user move starts a new failure run
      final sessionId = state.queue.sessionId;
      if (sessionId == null) return;

      var entry = await _queueRepo.getPlaybackEntryForItem(sessionId, itemId);
      if (entry == null) return;

      // Offline: if the user tapped a row whose file is no longer on disk,
      // walk forward (then backward) to the nearest locally playable entry.
      if (_isOffline) {
        final resolution = await _publishIssuesOf(await _targetResolver.resolveStart(
          sessionId: sessionId,
          preferredItemId: entry.itemId,
          totalCount: state.queue.totalCount,
          offline: true,
        ));
        final playable = resolution.target?.entry;
        if (playable == null) return;
        entry = playable;
      }

      await _ensureItemLoaded(sessionId, entry);
      await _player.seekToItem(entry.itemId);
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

      await _syncLoopMode(nextMode, state.queue.totalCount);

      final sessionId = state.queue.sessionId;
      if (sessionId != null) {
        await _queueRepo.updateRepeatMode(sessionId, nextMode.name);
      }

      state = state.copyWith(queue: state.queue.copyWith(repeatMode: nextMode));
    });
  }

  /// SC-27 conditional enqueue: applies only to [expectedSessionId] (an
  /// enqueue for a session replaced meanwhile is superseded).
  Future<EnqueueResult> enqueue(List<String> uuids, EnqueuePosition position,
      {required int expectedSessionId}) async {
    var result = EnqueueResult.superseded;
    await _serialize(() async {
      final sessionId = state.queue.sessionId;
      final currentItemId = state.queue.currentItemId;
      if (uuids.isEmpty ||
          sessionId == null ||
          sessionId != expectedSessionId ||
          currentItemId == null) {
        return;
      }
      if (position == EnqueuePosition.end) {
        final snapshot = await _queueRepo.getSessionSnapshot(sessionId);
        if (snapshot == null || snapshot.totalCount == 0) return;
      }
      await _applyQueueEdit(sessionId, currentItemId, () => switch (position) {
            EnqueuePosition.next =>
              _queueRepo.prependManualItems(sessionId, uuids),
            EnqueuePosition.end =>
              _queueRepo.appendManualItems(sessionId, uuids),
          });
      result = EnqueueResult.applied;
    });
    return result;
  }

  /// The shared successful manual-queue edit sequence. Keep command and
  /// persistence ordering unchanged during the 5B.0b extraction.
  Future<void> _applyQueueEdit(int sessionId, int currentItemId,
      Future<void> Function() mutate) async {
    await mutate();
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
    // After the total is current: the edit may grow the queue past the window.
    await _syncLoopMode(state.queue.repeatMode, state.queue.totalCount);
    _invalidateQueueTracks();
    _scheduleForwardHydration();
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
      // Later play positions shift down by one; the window follows at once
      // (before any read that could fail and leave it one too long).
      final start = _window.windowStartPlayPosition;
      final end = _window.nextForwardHydrationPlayPosition;
      if (start != null && removedEntry.playPosition < end) {
        _window.replaceWindow(
          start: removedEntry.playPosition < start ? start - 1 : start,
          end: end - 1,
        );
      }
      await _refreshLoadedEntriesMetadata(sessionId);

      await _refreshCurrentQueueState(sessionId);
      await _syncLoopMode(state.queue.repeatMode, state.queue.totalCount);
      _invalidateQueueTracks();
      _scheduleForwardHydration();
    });
  }

  /// Play/pause toggle, decided here when the command executes (inside the
  /// serial lane), never by a view or the OS: two quick taps alternate, and
  /// the OS media button and in-app buttons can't disagree (SC-27). It acts
  /// on the desired-transport axis -- what the play/pause control and the
  /// OS state show -- so a tap while loading with play desired pauses.
  Future<void> togglePlayPause() {
    return _serialize(() async {
      if (state.queue.sessionId == null) return;
      if (state.playback.playWhenReady) {
        await _pauseInLane();
      } else {
        await _resumeInLane();
      }
    });
  }

  Future<void> resume() {
    return _serialize(() async {
      if (state.queue.sessionId == null) return;
      await _resumeInLane();
    });
  }

  Future<void> pause() => _serialize(_pauseInLane);

  /// OS interruption began (SC-27 invariant 5): pause playing audio and
  /// remember to resume it when the interruption ends.
  @override
  void onInterruptionBegan() {
    _runTask('interruption', () async {
      if (!state.playback.playWhenReady) return;
      await _pauseInLane();
      _resumeAfterInterruption = true;
    });
  }

  @override
  void onInterruptionEnded({required bool shouldResume}) {
    _runTask('interruption end', () async {
      final resume = _resumeAfterInterruption && shouldResume;
      _resumeAfterInterruption = false;
      if (resume && state.queue.sessionId != null) await _resumeInLane();
    });
  }

  /// Headphones unplugged: pause, like a user pause.
  @override
  void onBecameNoisy() {
    _runTask('noisy output', () async {
      if (state.playback.playWhenReady) await _pauseInLane();
      _resumeAfterInterruption = false;
    });
  }

  // Lane bodies (invariant: lane code never awaits a public lane method).
  Future<void> _resumeInLane() async {
    _resumeAfterInterruption = false;
    _resetFailureRun(); // a user resume starts a new failure run
    _setPlayWhenReady(true);
    await _player.play();
    // Mirror of _pauseInLane: publish the command's result so a toggle
    // queued behind it alternates. A buffering engine corrects it to
    // `loading` with its own state event.
    if (state.playback.status == PlayerStatus.paused) {
      _setPlaybackStatus(PlayerStatus.playing);
    }
  }

  Future<void> _pauseInLane() async {
    _resumeAfterInterruption = false;
    _setPlayWhenReady(false);
    await _player.pause();
    // The paused state is the result of this command: publish it now so a
    // toggle queued behind it decides from it (the engine's own state event
    // confirms it later).
    if (state.playback.status == PlayerStatus.playing) {
      _setPlaybackStatus(PlayerStatus.paused);
    }
    await _persistPlaybackCursor();
  }

  /// Whether the playback runtime accepts work (SC-27 lifecycle axis).
  PlaybackLifecycle get lifecycle => _lifecycle;

  bool get _admissionClosed =>
      _lifecycle == PlaybackLifecycle.stopping ||
      _lifecycle == PlaybackLifecycle.quiesced;

  /// SC-15 reset participant: closes admission synchronously (`stopping`),
  /// lets lane work admitted before that settle, stops audio and the OS
  /// media session, then reaches the terminal `quiesced`. No DB writes: the
  /// reset's fence already made durable writes no-ops and the wipe follows.
  /// Idempotent.
  Future<void> quiesce() {
    if (_lifecycle == PlaybackLifecycle.quiesced) return Future.value();
    final inFlight = _quiescing;
    if (inFlight != null) return inFlight;
    _lifecycle = PlaybackLifecycle.stopping;
    _requestRevision++;
    // Chained on the lane directly: _serialize no longer admits anything.
    final future = _mutationTail.then((_) async {
      // Never cleared: quiesced is terminal, so late player events stay
      // ignored.
      _stopInProgress = true;
      try {
        await _player.stop();
        // Nothing plays any more: a coherent empty state (observers, such
        // as the OS now-playing, clear); only the volume is kept.
        state = AudioState(
          playback: PlaybackSlice(volume: state.playback.volume),
        );
      } finally {
        _lifecycle = PlaybackLifecycle.quiesced;
      }
    });
    _mutationTail = future.catchError((_) {});
    return _quiescing = future;
  }

  Future<void> stop() {
    _requestRevision++; // supersedes pending replacement requests
    return _serialize(() async {
      _stopInProgress = true;
      try {
        await _player.stop();

        final sessionId = state.queue.sessionId;
        if (sessionId != null) {
          await _queueRepo.deactivateAll();
        }

        _window.reset();
        state = const AudioState();
      } finally {
        _stopInProgress = false;
      }
    });
  }

  Future<void> reconcileAfterSyncQueueMutation(Set<int> affectedSessionIds) =>
      _serialize(() => _reconcileInLane(affectedSessionIds));

  Future<void> _reconcileInLane(Set<int> affectedSessionIds) async {
    {
      final sessionId = state.queue.sessionId;
      if (sessionId == null || !affectedSessionIds.contains(sessionId)) {
        return;
      }

      final previousCurrentItemId = state.queue.currentItemId;
      final previousPosition = state.playback.position;
      final wasPlaying = state.playback.playWhenReady;
      final snapshot = await _queueRepo.getSessionSnapshot(sessionId);

      if (snapshot == null ||
          snapshot.currentItem == null ||
          snapshot.totalCount == 0) {
        await _player.stop();
        await _queueRepo.deactivateAll();
        _window.reset();
        state = state.copyWith(
          playback: state.playback.copyWith(
            clearTrack: true,
            status: PlayerStatus.idle,
            playWhenReady: false,
            processing: EngineProcessingState.idle,
            position: Duration.zero,
            catalogDuration: null,
            measuredDuration: null,
          ),
          queue: state.queue.copyWith(
            clearSession: true,
            clearCurrentItem: true,
            currentPlayPosition: 0,
            totalCount: 0,
            queueVersion: state.queue.queueVersion + 1,
          ),
        );
        return;
      }

      final nextCurrentItem = snapshot.currentItem!;
      final preservePosition = previousCurrentItemId == nextCurrentItem.itemId;
      await _startSession(
        sessionId,
        autoPlay: wasPlaying,
        initialPosition: preservePosition ? previousPosition : Duration.zero,
        overrideCurrentItem: nextCurrentItem,
        // Only a reconcile that keeps the current item continues it.
        cause: preservePosition
            ? PlaybackTransitionCause.reconcileContinuation
            : PlaybackTransitionCause.queueReplacement,
      );
      await _persistPlaybackCursor(
        resetPosition: !preservePosition,
        resumeMainItemId: nextCurrentItem.queueType == QueueItemTypes.main
            ? nextCurrentItem.itemId
            : null,
        updateResumeMainItemId:
            nextCurrentItem.queueType == QueueItemTypes.main,
      );
    }
  }

  /// Seek, clamped here (not in the view): negative targets go to 0, and a
  /// known duration bounds the end. An unknown duration is no upper bound.
  Future<void> seek(Duration requested) {
    return _serialize(() async {
      final duration = state.playback.duration;
      var position = requested.isNegative ? Duration.zero : requested;
      if (duration != null && duration > Duration.zero && position > duration) {
        position = duration;
      }
      await _player.seek(position);
      state = state.copyWith(
        playback: state.playback.copyWith(position: position),
      );
      _sinceCursorSave = _clock.stopwatch();
      await _persistPlaybackCursor();
    });
  }

  Future<void> setVolume(double volume) async {
    if (_admissionClosed) return;
    await _player.setVolume(volume);
    state = state.copyWith(playback: state.playback.copyWith(volume: volume));
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setDouble(_volumePreferenceKey, volume);
  }

  Future<void> _restoreStartupState() async {
    if (!ref.mounted) return;
    await _restorePersistedVolume();
    if (!ref.mounted) return;
    // Restore (and its queue warm and remote source loads) waits for the
    // session with its offline state known (SC-27 session-ready signal).
    await ref.read(sessionReadinessProvider).ready;
    if (!ref.mounted) return;
    await _restoreSession();
  }

  Future<void> _restorePersistedVolume() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    if (!ref.mounted) return;
    final savedVolume = prefs.getDouble(_volumePreferenceKey);
    if (savedVolume == null) {
      return;
    }

    await _player.setVolume(savedVolume);
    if (!ref.mounted) return;
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

    // Prepared sessions of a previous run (a request that never activated)
    // and replaced queues are dropped before restoring (SC-27).
    try {
      await _queueRepo.pruneInactiveSessionsOnce();
    } on BindingFencedException {
      return; // no session store
    }
    if (!ref.mounted) return;
    final snapshot = await _queueRepo.getActiveSessionSnapshot();
    if (!ref.mounted) return;
    if (snapshot == null ||
        snapshot.currentItem == null ||
        snapshot.totalCount == 0) {
      return;
    }

    await _serialize(() async {
      if (!ref.mounted || _hasHydratedSessionState) {
        return;
      }

      // Offline restore must not seed the player on a streaming-only entry.
      // Pick the nearest locally playable item before handing to _startSession.
      final initialPosition = Duration(
        milliseconds: snapshot.session.currentPositionMs,
      );
      if (_isOffline) {
        final resolution = await _publishIssuesOf(await _targetResolver.resolveStart(
          sessionId: snapshot.session.id,
          preferredItemId: snapshot.currentItem!.itemId,
          totalCount: snapshot.totalCount,
          offline: true,
        ));
        final fallback = resolution.target?.entry;
        if (fallback == null) return;
        final usePreferred = fallback.itemId == snapshot.currentItem!.itemId;
        await _startSession(
          snapshot.session.id,
          autoPlay: false,
          initialPosition: usePreferred ? initialPosition : Duration.zero,
          overrideCurrentItem: usePreferred ? null : fallback,
        );
        return;
      }

      await _startSession(
        snapshot.session.id,
        autoPlay: false,
        initialPosition: initialPosition,
      );
    });
  }

  Future<void> _startSession(
    int sessionId, {
    required bool autoPlay,
    Duration initialPosition = Duration.zero,
    QueuePlaybackEntry? overrideCurrentItem,
    PlaybackTransitionCause cause = PlaybackTransitionCause.queueReplacement,
  }) async {
    final snapshot = await _queueRepo.getSessionSnapshot(sessionId);
    final currentItem = overrideCurrentItem ?? snapshot?.currentItem;
    if (snapshot == null || currentItem == null || snapshot.totalCount == 0) {
      throw StateError('Cannot start an empty queue session');
    }

    final seedEntries = await _window.seedEntriesForPlayPosition(
      sessionId,
      currentItem.playPosition,
    );
    if (seedEntries.isEmpty) {
      throw StateError('Failed to seed the player queue');
    }
    // Read everything before touching the engine (commit last): a failed
    // read leaves engine, window and state as they were.
    final currentTrack = await _queueRepo.getTrackForItem(
      sessionId,
      currentItem.itemId,
    );
    if (currentTrack == null) {
      throw StateError('Current queue item could not be loaded');
    }

    _resetFailureRun();
    await _player.setSeed(
      seedEntries,
      currentItemId: currentItem.itemId,
      sessionId: sessionId,
      cause: cause,
      initialPosition: initialPosition,
      autoPlay: autoPlay,
      shuffleEnabled: snapshot.session.shuffleEnabled,
    );
    _seed = (
      revision: _player.playlistRevision,
      itemId: currentItem.itemId,
      trackUuid: currentTrack.track.uuidId,
    );

    _window.replaceWindow(
      start: seedEntries.map((entry) => entry.playPosition).reduce(min),
      end: seedEntries.map((entry) => entry.playPosition).reduce(max) + 1,
    );
    await _syncLoopMode(
        _repeatModeFrom(snapshot.session.repeatMode), snapshot.totalCount);

    state = state.copyWith(
      playback: state.playback.copyWith(
        currentTrack: currentTrack.track,
        status: autoPlay ? PlayerStatus.playing : PlayerStatus.paused,
        playWhenReady: autoPlay,
        position: initialPosition,
        catalogDuration: _playbackDuration(currentTrack.track.duration),
        measuredDuration: null,
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
    _scheduleForwardHydration();
  }

  bool get _isOffline => ref.read(offlineModeProvider);

  /// The core is the applier: it publishes what the resolver found, on
  /// success and on rejection (SC-27 invariant 8).
  Future<PlaybackTargetResolution> _publishIssuesOf(
      PlaybackTargetResolution resolution) async {
    await reportIssues(resolution.issues);
    return resolution;
  }

  /// Publishes [issues] as their applier (SC-27 invariant 8). A missing
  /// download confirmed by a file check (resolver or playback) also stops
  /// being claimed by the catalog (D32), so no later seed, rebuild or tap
  /// hands the engine the dead path again.
  ///
  /// With [publish] false (a request superseded while resolving: its issues
  /// are not reported) a confirmed missing download is still reconciled: it
  /// is a fact about the catalog, not about the request.
  Future<void> reportIssues(Iterable<PlaybackIssue> issues,
      {bool publish = true}) async {
    for (final issue in issues) {
      if (publish) _issues.publish(issue);
      if (issue is LocalFileMissing) await _reconcileMissingDownload(issue.trackUuid);
    }
  }

  Future<void> _reconcileMissingDownload(String trackUuid) async {
    if (!ref.mounted) return;
    try {
      await ref.read(downloadReconciliationServiceProvider).reconcileTrack(trackUuid);
    } catch (error, stackTrace) {
      // Callers never depend on it: the next resume reconciles again.
      developer.log('Reconciling a missing download failed',
          name: 'QueuePlayer', error: error, stackTrace: stackTrace);
    }
  }

  /// Picks the next entry the player should land on for skipNext / skipPrev /
  /// natural advance. Offline searches the FULL queue (not just the loaded
  /// window) for the nearest entry with a verified local file in [direction];
  /// online uses the immediate next/previous play position. Honours the
  /// current repeat mode for wrapping.
  Future<QueuePlaybackEntry?> _resolveAdvanceTarget({
    required int sessionId,
    required PlayOrderDirection direction,
  }) async {
    final resolution = await _publishIssuesOf(await _targetResolver.resolveAdvance(
      sessionId: sessionId,
      fromPlayPosition: state.queue.currentPlayPosition,
      direction: direction,
      repeatMode: state.queue.repeatMode.name,
      totalCount: state.queue.totalCount,
      offline: _isOffline,
    ));
    return resolution.target?.entry;
  }

  Future<void> _onUnavailableAdvance(UnavailableAdvance event) async {
    if (_stopInProgress) return;
    final sessionId = state.queue.sessionId;
    if (sessionId == null) return;
    // The engine reports the item it moved onto without committing it: a
    // natural advance lands on the next position (wrapping at the end), a
    // refresh rescue concerns the current item. Anything else queued behind
    // a move elsewhere and is stale.
    final current = state.queue.currentPlayPosition;
    final atEnd = current + 1 >= state.queue.totalCount;
    final next = !atEnd
        ? current + 1
        : (state.queue.repeatMode == QueueRepeatMode.all ? 0 : -1);
    if (event.itemId != state.queue.currentItemId &&
        event.playPosition != next) {
      return;
    }

    final resolution = await _publishIssuesOf(await _targetResolver.resolveAdvance(
      sessionId: sessionId,
      fromPlayPosition: event.playPosition,
      direction: PlayOrderDirection.forward,
      repeatMode: state.queue.repeatMode.name,
      totalCount: state.queue.totalCount,
      offline: true,
    ));
    final target = resolution.target?.entry;
    if (target == null) {
      await _player.stop();
      return;
    }
    await _ensureItemLoaded(sessionId, target,
        cause: PlaybackTransitionCause.naturalAdvance);
    await _player.seekToItem(target.itemId,
        cause: PlaybackTransitionCause.naturalAdvance);
    await _player.play();
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

    final windowEntries = await _window.seedEntriesForPlayPosition(
      sessionId,
      rebuiltCurrentEntry.playPosition,
    );
    await _player.rebuildAroundCurrent(
      currentItemId: currentItemId,
      entries: windowEntries,
    );
    _window.replaceWindow(
      start: windowEntries.isEmpty
          ? rebuiltCurrentEntry.playPosition
          : windowEntries.first.playPosition,
      end: windowEntries.isEmpty
          ? rebuiltCurrentEntry.playPosition + 1
          : windowEntries.last.playPosition + 1,
    );
    await _syncLoopMode(state.queue.repeatMode, state.queue.totalCount);
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

    final sameItem = currentTrack.itemId == state.queue.currentItemId;
    state = state.copyWith(
      playback: state.playback.copyWith(
        currentTrack: currentTrack.track,
        position: preservePlaybackPosition
            ? state.playback.position
            : Duration.zero,
        catalogDuration: _playbackDuration(currentTrack.track.duration),
        measuredDuration: sameItem ? state.playback.measuredDuration : null,
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

  Future<void> _refreshLoadedSourcesForDownloadChange() async {
    final sessionId = state.queue.sessionId;
    if (sessionId == null) return;
    final itemIds = _player.loadedItemIds;
    if (itemIds.isEmpty) return;

    final entries = await _queueRepo.getPlaybackEntriesForItemIds(
      sessionId,
      itemIds,
    );
    await _player.refreshLoadedSourcesForAvailabilityChanges(entries);
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
      limit: QueueWindow.seedNextCount,
    );
    await _player.replaceFutureEntries(
      currentItemId: currentItemId,
      entries: futureEntries,
    );
    _window.replaceWindow(
      start: _window.windowStartPlayPosition ?? currentEntry.playPosition,
      end: futureEntries.isEmpty
          ? currentEntry.playPosition + 1
          : futureEntries.last.playPosition + 1,
    );
  }

  /// Makes [entry] loaded. Inside the window it already is (the window is
  /// one contiguous interval, invariant 7); outside it, the window is
  /// rebased around [entry] instead of gaining a distant range, so a
  /// natural advance can never skip positions.
  Future<void> _ensureItemLoaded(int sessionId, QueuePlaybackEntry entry,
      {PlaybackTransitionCause cause = PlaybackTransitionCause.userSkip}) async {
    if (_player.hasItem(entry.itemId)) return;
    final entries =
        await _window.seedEntriesForPlayPosition(sessionId, entry.playPosition);
    if (entries.isEmpty) return;
    await _player.setSeed(entries,
        currentItemId: entry.itemId, sessionId: sessionId, cause: cause);
    _seed = (
      revision: _player.playlistRevision,
      itemId: entry.itemId,
      trackUuid: entry.uuidId,
    );
    _window.replaceWindow(
      start: entries.first.playPosition,
      end: entries.last.playPosition + 1,
    );
    await _syncLoopMode(state.queue.repeatMode, state.queue.totalCount);
    // A seed commits its current item silently: publish the change here
    // (state, cursor, hydration), as an engine item change would.
    await _onCurrentItemChanged(entry.itemId);
  }

  /// Applies a forward hydration proposal in the lane, only while it is
  /// still current: same session, queue, window and source configuration
  /// as when it was started. A stale one is dropped and a fresh one
  /// scheduled. Reports whether it was applied.
  Future<bool> _applyHydration(QueueWindowProposal proposal) {
    var applied = false;
    return _serialize(() async {
      if (proposal.context != _hydrationContext() ||
          proposal.windowRevision != _window.windowRevision) {
        _scheduleForwardHydration();
        return;
      }
      if (proposal.entries.isNotEmpty) {
        await _player.addEntries(proposal.entries);
      }
      applied = _window.acknowledge(proposal);
      if (applied) {
        await _syncLoopMode(state.queue.repeatMode, state.queue.totalCount);
      }
    }).then((_) => applied, onError: (Object error, StackTrace stackTrace) {
      developer.log('Window hydration failed', name: 'QueuePlayer',
          error: error, stackTrace: stackTrace);
      _issues.publish(PlaybackTaskFailed('window hydration', error));
      return false;
    });
  }

  /// What a hydration proposal must still match when it is applied.
  ({int? sessionId, int queueVersion, int sourceConfigVersion})
      _hydrationContext() => (
            sessionId: state.queue.sessionId,
            queueVersion: state.queue.queueVersion,
            sourceConfigVersion: _sourceConfigVersion,
          );

  /// Native looping only where it cannot skip positions: repeat-all loops
  /// natively only when the window holds the whole queue; otherwise the
  /// model wraps at the logical end ([_onEngineEnded]).
  Future<void> _syncLoopMode(QueueRepeatMode mode, int totalCount) =>
      _player.setLoopMode(switch (mode) {
        QueueRepeatMode.off => EngineLoopMode.off,
        QueueRepeatMode.one => EngineLoopMode.one,
        QueueRepeatMode.all => _window.coversQueue(totalCount)
            ? EngineLoopMode.all
            : EngineLoopMode.off,
      });

  /// The engine finished its playlist. Before the logical end of the
  /// queue (hydration lagged) playback continues with the next item; at
  /// the end, repeat-all wraps to the first playable item.
  Future<void> _onEngineEnded() async {
    final sessionId = state.queue.sessionId;
    if (sessionId == null) return;
    // At the logical end the resolver wraps only under repeat-all.
    final target = await _resolveAdvanceTarget(
      sessionId: sessionId,
      direction: PlayOrderDirection.forward,
    );
    if (target == null) return;
    await _ensureItemLoaded(sessionId, target,
        cause: PlaybackTransitionCause.naturalAdvance);
    await _player.seekToItem(target.itemId,
        cause: PlaybackTransitionCause.naturalAdvance);
    await _resumeInLane();
  }

  void _scheduleForwardHydration() {
    final sessionId = state.queue.sessionId;
    if (sessionId == null) return;
    _window.scheduleForwardHydration(
      sessionId: sessionId,
      totalCount: state.queue.totalCount,
      currentPlayPosition: state.queue.currentPlayPosition,
      context: _hydrationContext(),
      apply: _applyHydration,
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
        catalogDuration: _playbackDuration(currentTrack.track.duration),
        measuredDuration: null,
      ),
      queue: state.queue.copyWith(
        currentItemId: currentTrack.itemId,
        currentPlayPosition: currentTrack.playPosition,
      ),
    );
    await _persistPlaybackCursor(
      resetPosition: true,
      resumeMainItemId: currentTrack.queueType == QueueItemTypes.main
          ? currentTrack.itemId
          : null,
      updateResumeMainItemId: currentTrack.queueType == QueueItemTypes.main,
    );
    _scheduleForwardHydration();
  }

  /// The engine is the authoritative echo of desired transport (it also
  /// clears it at the end of the queue); both axes are published as
  /// reported, plus the derived status.
  /// Every async task started from a listener runs in the lane with an
  /// error sink (SC-27 invariant 13): logged and published as a diagnostic.
  void _runTask(String task, Future<void> Function() body) =>
      _offLaneTask(task, () => _serialize(body));

  /// Slow work that must not hold the lane (network checks), with the same
  /// error sink; whatever it decides is applied through [_runTask].
  void _offLaneTask(String task, Future<void> Function() body) {
    unawaited(body().catchError((Object error, StackTrace stack) {
      developer.log('Playback task "$task" failed',
          name: 'QueuePlayer', error: error, stackTrace: stack);
      _issues.publish(PlaybackTaskFailed(task, error));
    }));
  }

  // One failure run (SC-27 §2.9): sources already acted on, items already
  // skipped. Reset by a new session or once a source plays.
  final Set<int> _attemptedSources = {};
  final Set<int> _failedItems = {};
  bool _recoveryExhausted = false;

  /// The latest seed: its playlist revision (its load events carry it) and
  /// the item it seeded, which is what a failed load is about (the
  /// published state may not have caught up yet after a rebase).
  ({int revision, int itemId, String trackUuid})? _seed;

  void _resetFailureRun() {
    _attemptedSources.clear();
    _failedItems.clear();
    _recoveryExhausted = false;
  }

  void _onLoadEvent(EngineLoadEvent event) {
    if (event.outcome != EngineLoadOutcome.failed) return;
    // A load belongs to its seed; later structural bumps (a refresh, a
    // quality rebuild) do not make its failure stale, a newer seed does.
    final seed = _seed;
    if (seed == null || event.playlistRevision != seed.revision) return;
    final itemId = seed.itemId;
    final trackUuid = seed.trackUuid;
    _offLaneTask('load failure', () => _onSourceFailure(
          itemId: itemId,
          trackUuid: trackUuid,
          sourceKey: -event.playlistRevision,
          uncertain: false,
          errorCode: event.errorCode,
          errorMessage: event.errorMessage,
        ));
  }

  /// Classifies a failed source off the lane (the check may wait on the
  /// network; pause, stop and focus loss must not), then applies the
  /// recovery in the lane only if the same item is still current. A confirmed
  /// missing file falls back to the stream online (never the same missing
  /// URI) or is skipped offline; a confirmed gone track is skipped;
  /// transient and unknown failures never skip. A failure run that would
  /// return to an item it already skipped stops instead of looping.
  Future<void> _onSourceFailure({
    required int? itemId,
    required String? trackUuid,
    required int? sourceKey,
    required bool uncertain,
    int? errorCode,
    String? errorMessage,
  }) async {
    final sessionId = state.queue.sessionId;
    if (sessionId == null || _recoveryExhausted) return;
    if (uncertain || itemId == null) {
      _issues.publish(PlaybackSourceFailed(null, SourceFailureKind.unknown,
          errorCode: errorCode, errorMessage: errorMessage));
      return;
    }
    // A source reported again is not classified (or probed) again.
    if (sourceKey != null && !_attemptedSources.add(sourceKey)) return;
    // The entry joins the catalog: a tombstoned track has none, but the
    // failing source's identity still names it.
    final entry = await _queueRepo.getPlaybackEntryForItem(sessionId, itemId);
    final uuid = entry?.uuidId ?? trackUuid;
    if (uuid == null) return;
    final kind = await _classifier.classify(
        trackUuid: uuid,
        filePath: entry?.filePath,
        uncertain: false);
    if (kind == SourceFailureKind.missingLocalFile) {
      // The catalog stops claiming the download, so every later rebuild
      // (rebase, refresh, reseed) loads the stream, and a later failure is
      // classified as a stream failure.
      await reportIssues([LocalFileMissing(uuid, entry!.filePath!)]);
    }
    _issues.publish(PlaybackSourceFailed(uuid, kind,
        errorCode: errorCode, errorMessage: errorMessage));
    if (kind == SourceFailureKind.transient ||
        kind == SourceFailureKind.unknown) {
      return;
    }
    _runTask('source recovery', () async {
      if (state.queue.sessionId != sessionId ||
          state.queue.currentItemId != itemId ||
          _recoveryExhausted) {
        return; // the decision is stale
      }
      await _recover(sessionId, itemId, entry, kind);
    });
  }

  Future<void> _recover(int sessionId, int itemId, QueuePlaybackEntry? entry,
      SourceFailureKind kind) async {
    switch (kind) {
      case SourceFailureKind.transient:
      case SourceFailureKind.unknown:
        return;
      case SourceFailureKind.missingLocalFile when !_isOffline && entry != null:
        await _player.refreshLoadedSourcesForAvailabilityChanges([
          QueuePlaybackEntry(
            itemId: entry.itemId,
            queueType: entry.queueType,
            canonicalPosition: entry.canonicalPosition,
            playPosition: entry.playPosition,
            uuidId: entry.uuidId,
          ),
        ]);
        return;
      case SourceFailureKind.missingLocalFile:
      case SourceFailureKind.gone:
        await _skipFailedItem(sessionId, itemId);
    }
  }

  Future<void> _skipFailedItem(int sessionId, int itemId) async {
    _failedItems.add(itemId);
    final target = await _resolveAdvanceTarget(
      sessionId: sessionId,
      direction: PlayOrderDirection.forward,
    );
    if (target == null || _failedItems.contains(target.itemId)) {
      _recoveryExhausted = true;
      await _player.stop();
      _setPlayWhenReady(false);
      _issues.publish(PlaybackRecoveryExhausted(sessionId));
      return;
    }
    await _ensureItemLoaded(sessionId, target,
        cause: PlaybackTransitionCause.naturalAdvance);
    await _player.seekToItem(target.itemId,
        cause: PlaybackTransitionCause.naturalAdvance);
    if (state.playback.playWhenReady) await _player.play();
  }

  void _onObservation(PlaybackObservation observation) {
    if (_stopInProgress || observation.uncertain) return;
    final playingItem = observation.source?.itemId;
    if (observation.playing &&
        observation.processingState == EngineProcessingState.ready &&
        playingItem != null &&
        !_failedItems.contains(playingItem) &&
        (_attemptedSources.isNotEmpty || _failedItems.isNotEmpty)) {
      _resetFailureRun(); // a source plays: the failure run is over
    }
    final itemId = observation.source?.itemId;
    if (itemId == null || itemId != state.queue.currentItemId) return;
    if (observation.duration == state.playback.measuredDuration) return;
    state = state.copyWith(
      playback:
          state.playback.copyWith(measuredDuration: observation.duration),
    );
  }

  void _onPlayerStateChanged(EngineTransportState playerState) {
    if (_stopInProgress) return;
    final completed =
        playerState.processingState == EngineProcessingState.completed;
    if (completed &&
        state.playback.processing != EngineProcessingState.completed) {
      _runTask('engine ended', _onEngineEnded);
    }
    final next = state.playback.copyWith(
      playWhenReady: playerState.playing,
      processing: playerState.processingState,
      // Without a session there is nothing to pause: a late engine echo
      // (after a stop or an emptied queue) never shows a paused player.
      status: completed || state.queue.sessionId == null
          ? PlayerStatus.idle
          : _mapStatus(playerState),
    );
    final previous = state.playback;
    if (next.playWhenReady == previous.playWhenReady &&
        next.processing == previous.processing &&
        next.status == previous.status) {
      return;
    }
    state = state.copyWith(playback: next);
  }

  void _onPositionChanged(Duration position) {
    state = state.copyWith(
      playback: state.playback.copyWith(position: position),
    );

    // Once a quiesce closed admission, nothing is persisted any more.
    if (_admissionClosed) return;
    final since = _sinceCursorSave;
    if (since == null || since.elapsed > const Duration(seconds: 5)) {
      _sinceCursorSave = _clock.stopwatch();
      // Through the lane: a save never interleaves a structural operation
      // and reads the state that operation leaves behind.
      _runTask('cursor save', _persistPlaybackCursor);
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

    try {
      await _queueRepo.updatePlaybackCursor(
        sessionId: sessionId,
        currentItemId: currentItemId,
        positionMs: resetPosition ? 0 : state.playback.position.inMilliseconds,
        resumeMainItemId: resumeMainItemId,
        updateResumeMainItemId: updateResumeMainItemId,
      );
    } on BindingFencedException {
      // The reset fence deleted the binding: this session's cursor no longer
      // has a store to go to. A quiet no-op (SC-01 rule 4).
    }
  }

  /// Runs [action] on the playback lane. Once a quiesce has closed
  /// admission (`stopping`/`quiesced`) nothing is admitted: the action is
  /// dropped and a completed future returned.
  Future<void> _serialize(Future<void> Function() action) {
    if (_admissionClosed) return Future.value();
    final future = _mutationTail.then((_) => action());
    _mutationTail = future.catchError((_) {});
    return future;
  }

  void _invalidateQueueTracks() {
    state = state.copyWith(
      queue: state.queue.copyWith(queueVersion: state.queue.queueVersion + 1),
    );
  }

  void _setPlayWhenReady(bool value) {
    state = state.copyWith(
      playback: state.playback.copyWith(playWhenReady: value),
    );
  }

  void _setPlaybackStatus(PlayerStatus status) {
    state = state.copyWith(playback: state.playback.copyWith(status: status));
  }


  static QueueRepeatMode _repeatModeFrom(String value) {
    return switch (value) {
      'all' => QueueRepeatMode.all,
      'one' => QueueRepeatMode.one,
      _ => QueueRepeatMode.off,
    };
  }

  static PlayerStatus _mapStatus(EngineTransportState playerState) {
    final processingState = playerState.processingState;
    if (processingState == EngineProcessingState.loading ||
        processingState == EngineProcessingState.buffering) {
      return PlayerStatus.loading;
    }
    if (processingState == EngineProcessingState.completed ||
        processingState == EngineProcessingState.idle) {
      return PlayerStatus.idle;
    }
    return playerState.playing ? PlayerStatus.playing : PlayerStatus.paused;
  }
}

/// Catalog seconds -> the playback state's catalog duration; unknown stays
/// null (never zero).
Duration? _playbackDuration(double? seconds) =>
    seconds == null ? null : Duration(milliseconds: (seconds * 1000).round());
