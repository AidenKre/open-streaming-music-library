import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_focus.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/playback/local_source_policy.dart';
import 'package:frontend/playback/media_token_binding.dart';
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
import 'package:frontend/services/server_binding_gate.dart';
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
///     Asked to relinquish ([FocusRelinquisher]) it pauses in the lane and
///     acknowledges outside it once the engine reports not playing; while
///     it has yielded the output, automatic continuations do not play.
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
///  13. Every listener task has an error sink; recovery is bounded. A typed
///     engine command failure that diverged the engine is rebuilt from
///     queue data, at most 3 times per run.
///  14. Its dependencies are scope-bound providers; a reset rebuilds them.
///  15. Unknown duration is null, never zero.
class QueuePlayer extends Notifier<AudioState>
    implements AudioFocusOwner, FocusRelinquisher {
  static const _volumePreferenceKey = 'audioVolume';

  /// How soon after the queue's real end an added track still continues
  /// playback (sign-off OPEN-6-04, owner 2026-11-17): "If you add a track to
  /// your queue within X milliseconds of the queue finishing, then it should
  /// start playback. For now, 250ms is a good buffer, but it shouldn't be
  /// hardcoded." The add is measured from its submission (the tap). Later
  /// adds rest paused on the added track at 0:00.
  static const queueEndResumeGrace = Duration(milliseconds: 250);

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

  /// The engine's last reported desired transport.
  bool _engineReportsPlaying = false;

  /// An engine end was accepted and the engine has not reported ready since.
  /// A completed report while armed repeats that end (for example the wrap's
  /// own playlist edit settling) and is dropped; any ready report disarms it.
  bool _endAccepted = false;

  /// The queue's real end, recorded by [_onEngineEnded] when no next item
  /// was found (no wrap). Owner, sign-off OPEN-6-04: after the end, an added
  /// track "should not start playback"; it becomes the current track at
  /// 0:00, paused, unless it was added within [queueEndResumeGrace] of the
  /// end. [since] started when the engine reported the end. The record only
  /// counts while [_queueHasEnded] holds. A ready report or a newly accepted
  /// end clears it, so only the end being handled now can set it.
  ({int sessionId, int itemId, MonotonicStopwatch since})? _queueEnd;

  /// Whether the recorded end still stands: same session, same current item,
  /// and the engine still completed. A seek back into the track (ready), a
  /// new queue or a move elsewhere voids it.
  bool get _queueHasEnded {
    final end = _queueEnd;
    return end != null &&
        state.queue.sessionId == end.sessionId &&
        state.queue.currentItemId == end.itemId &&
        state.playback.processing == EngineProcessingState.completed;
  }

  /// Newest admitted replacement request (SC-27 principle 5).
  int _requestRevision = 0;
  PlaybackLifecycle _lifecycle = PlaybackLifecycle.none;
  Future<void>? _quiescing;
  late Clock _clock;
  late PlaybackIssueBus _issues;
  late SourceFailureClassifier _classifier;
  late LocalSourcePolicy _localSources;

  /// Monotonic time since the last throttled cursor save (SC-20).
  MonotonicStopwatch? _sinceCursorSave;

  @override
  AudioState build() {
    _player = ref.read(playbackEngineProvider);
    _queueRepo = ref.read(queueRepositoryProvider);
    _targetResolver = ref.read(playbackTargetResolverProvider);
    _orderManager = ref.read(queueOrderManagerProvider);
    _window = ref.read(queueWindowProvider);
    _focus = ref.read(audioFocusProvider);
    _clock = ref.read(clockProvider);
    _issues = ref.read(playbackIssueBusProvider);
    _classifier = ref.read(sourceFailureClassifierProvider);
    _localSources = ref.read(localSourcePolicyProvider);
    _focus.bind(AudioOutput.queue, this);

    // Decision 1 (5B.0d M2): a stream that failed transiently while online
    // is rescued under the offline policy once the app knows it is offline.
    ref.listen<bool>(offlineModeProvider, (previous, offline) {
      if (previous == false && offline) _rescueStreamFailureOffline();
    });

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

    // The binding gate's verdicts reach the engine's media-token sources in
    // this lane (sign-off OPEN-M-11 step D).
    _subscriptions.add(
      ref.read(serverBindingGateProvider).states.listen((gateState) {
        final action = mediaTokenActionFor(gateState);
        if (action == MediaTokenAction.none) return;
        _sourceConfigVersion++;
        _runTask('media token', () => _applyMediaTokenAction(action));
      }),
    );

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
              sourcePath: failure.source?.localPath,
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
    _subscriptions.add(_player.commandFailures.listen((failure) {
      _issues.publish(PlaybackEngineCommandFailed(failure));
      if (failure.diverged) {
        // Untrusted from now on, even if the rebuild cannot finish.
        if (failure.seedRevision == _seed?.revision) _engineDiverged = true;
        _runTask('engine rebuild', () => _rebuildAfterCommandFailure(failure));
      }
    }));
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
    PlaybackTarget target, {
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
            autoPlay: autoPlay,
            overrideCurrentItem: target.entry,
            currentSourceKind: target.sourceKind);
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
      _startRebuildRun();
      final sessionId = state.queue.sessionId;
      final currentItemId = state.queue.currentItemId;
      if (sessionId == null || currentItemId == null) return;

      if (state.queue.repeatMode == QueueRepeatMode.one) {
        await _seekCurrentInLane(Duration.zero, wantPlay: true);
        await _player.play();
        return;
      }

      final target = await _resolveAdvanceTarget(
        sessionId: sessionId,
        direction: PlayOrderDirection.forward,
      );
      if (target == null) return;

      // An untrusted engine is reseeded onto the item: no seek on it.
      final reseeding = _engineDiverged;
      await _ensureItemLoaded(sessionId, target.entry,
          sourceKind: target.sourceKind);
      if (!reseeding) await _player.seekToItem(target.entry.itemId);
      await _player.play();
    });
  }

  Future<void> skipPrevious() {
    return _serialize(() async {
      _resetFailureRun(); // a user move starts a new failure run
      _startRebuildRun();
      if (state.playback.position.inSeconds > 3) {
        await _seekCurrentInLane(Duration.zero,
            wantPlay: state.playback.playWhenReady);
        return;
      }

      final sessionId = state.queue.sessionId;
      final currentItemId = state.queue.currentItemId;
      if (sessionId == null || currentItemId == null) {
        await _seekCurrentInLane(Duration.zero,
            wantPlay: state.playback.playWhenReady);
        return;
      }

      if (state.queue.repeatMode == QueueRepeatMode.one) {
        await _seekCurrentInLane(Duration.zero, wantPlay: true);
        await _player.play();
        return;
      }

      final target = await _resolveAdvanceTarget(
        sessionId: sessionId,
        direction: PlayOrderDirection.backward,
      );
      if (target == null) {
        await _seekCurrentInLane(Duration.zero,
            wantPlay: state.playback.playWhenReady);
        return;
      }

      // An untrusted engine is reseeded onto the item: no seek on it.
      final reseeding = _engineDiverged;
      await _ensureItemLoaded(sessionId, target.entry,
          sourceKind: target.sourceKind);
      if (!reseeding) await _player.seekToItem(target.entry.itemId);
      await _player.play();
    });
  }

  Future<void> skipToTrack(int itemId) {
    return _serialize(() async {
      _resetFailureRun(); // a user move starts a new failure run
      _startRebuildRun();
      final sessionId = state.queue.sessionId;
      if (sessionId == null) return;

      var entry = await _queueRepo.getPlaybackEntryForItem(sessionId, itemId);
      if (entry == null) return;

      // The resolver lands the tap with its kind: online the tapped entry;
      // offline, if its file is no longer on disk, the nearest locally
      // playable entry (forward, then backward).
      final resolution = await _publishIssuesOf(await _targetResolver.resolveStart(
        sessionId: sessionId,
        preferredItemId: entry.itemId,
        totalCount: state.queue.totalCount,
        offline: _isOffline,
      ));
      final landing = resolution.target;
      if (landing == null && _isOffline) return;
      if (landing != null) entry = landing.entry;

      // An untrusted engine is reseeded onto the item: no seek on it.
      final reseeding = _engineDiverged;
      await _ensureItemLoaded(sessionId, entry,
          sourceKind: landing?.sourceKind);
      if (!reseeding) await _player.seekToItem(entry.itemId);
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

      await _syncLoopModeForCurrent(mode: nextMode);

      final sessionId = state.queue.sessionId;
      if (sessionId != null) {
        await _queueRepo.updateRepeatMode(sessionId, nextMode.name);
      }

      state = state.copyWith(queue: state.queue.copyWith(repeatMode: nextMode));
    });
  }

  /// SC-27 conditional enqueue: applies only to [expectedSessionId] (an
  /// enqueue for a session replaced meanwhile is superseded).
  /// [sinceSubmitted] started at the add's submission (the tap); by default
  /// when this is called.
  Future<EnqueueResult> enqueue(List<String> uuids, EnqueuePosition position,
      {required int expectedSessionId,
      MonotonicStopwatch? sinceSubmitted}) async {
    final submitted = sinceSubmitted ?? _clock.stopwatch();
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
      // Decided before the edit: the edit and engine events may change the
      // processing state.
      final end = _queueHasEnded ? _queueEnd : null;
      await _applyQueueEdit(sessionId, currentItemId, () => switch (position) {
            EnqueuePosition.next =>
              _queueRepo.prependManualItems(sessionId, uuids),
            EnqueuePosition.end =>
              _queueRepo.appendManualItems(sessionId, uuids),
          });
      result = EnqueueResult.applied;
      if (end != null) {
        // OPEN-6-04: after the end, the first added track becomes current at
        // 0:00; it plays only when added (tapped) at most the grace after
        // the end, else it rests paused.
        final withinGrace = end.since.elapsed - submitted.elapsed <=
            queueEndResumeGrace;
        await _advanceFromCurrent(sessionId, play: withinGrace);
        _queueEnd = null;
      }
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
    await _syncLoopModeForCurrent();
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

      await _refreshCurrentQueueState(
        sessionId,
        preservePlaybackPosition: true,
      );
      await _syncLoopModeForCurrent();
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
      _startRebuildRun();
      if (state.playback.playWhenReady) {
        await _pauseInLane();
      } else {
        await _resumeInLane(user: true);
      }
    });
  }

  Future<void> resume() {
    return _serialize(() async {
      if (state.queue.sessionId == null) return;
      _startRebuildRun();
      await _resumeInLane(user: true);
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
  /// [user] marks an explicit user resume: it plays even while preview holds
  /// the output (the engine's `beforePlay` takes it back). Automatic callers
  /// leave it false and keep the yield guard.
  Future<void> _resumeInLane({bool user = false}) async {
    _resumeAfterInterruption = false;
    // A user resume starts a new failure run (a pending check stays valid).
    _resetFailureRun(staleChecks: false);
    _setPlayWhenReady(true);
    final sessionId = state.queue.sessionId;
    final entry = _engineDiverged && sessionId != null
        ? await _engineCurrentEntry(sessionId)
        : null;
    if (entry != null) {
      await _reseedCurrent(sessionId!, entry, _rebuildPosition(entry.itemId, null),
          PlaybackTransitionCause.reconcileContinuation,
          wantPlay: true, takeFocus: user);
    } else {
      await _player.play();
    }
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

  /// Pauses in the lane (ordered after admitted work; the engine pause also
  /// cancels a play queued behind a load), then acknowledges outside the
  /// lane once the engine reports not playing.
  @override
  Future<void> relinquishFocus() async {
    if (_lifecycle == PlaybackLifecycle.quiesced) return;
    if (_admissionClosed) {
      final inFlight = _quiescing;
      if (inFlight != null) {
        try {
          await inFlight;
        } catch (_) {}
      }
      return;
    }
    try {
      await _serialize(() async {
        // A transfer refused at the bound leaves the library the holder.
        if (_focus.yieldedBy(AudioOutput.queue)) await _pauseInLane();
      });
    } catch (error, stack) {
      developer.log('Playback task "relinquish" failed',
          name: 'QueuePlayer', error: error, stackTrace: stack);
      _issues.publish(PlaybackTaskFailed('relinquish', error));
    }
    if (!_engineReportsPlaying) return;
    await _player.transportStateStream
        .firstWhere((s) => !s.playing, orElse: () => const EngineTransportState(false, EngineProcessingState.idle));
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
        state =
            AudioState(playback: PlaybackSlice(volume: state.playback.volume));
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
        currentSourceKind:
            preservePosition ? _player.sourceKindOf(nextCurrentItem.itemId) : null,
        // Only a reconcile that keeps the current item continues it.
        cause: preservePosition
            ? PlaybackTransitionCause.reconcileContinuation
            : PlaybackTransitionCause.queueReplacement,
      );
      await _persistPlaybackCursor(
        resetPosition: !preservePosition,
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
      _startRebuildRun();
      await _seekCurrentInLane(position,
          wantPlay: state.playback.playWhenReady);
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
      final resolution = await _publishIssuesOf(await _targetResolver.resolveStart(
        sessionId: snapshot.session.id,
        preferredItemId: snapshot.currentItem!.itemId,
        totalCount: snapshot.totalCount,
        offline: _isOffline,
      ));
      final target = resolution.target;
      // Offline with no playable target there is nothing to seed; online the
      // persisted item is started even without a target (kind unknown).
      if (target == null && _isOffline) return;
      final usePreferred =
          target == null || target.entry.itemId == snapshot.currentItem!.itemId;
      await _startSession(
        snapshot.session.id,
        autoPlay: false,
        initialPosition: usePreferred ? initialPosition : Duration.zero,
        overrideCurrentItem: usePreferred ? null : target.entry,
        currentSourceKind: target?.sourceKind,
      );
    });
  }

  Future<void> _startSession(
    int sessionId, {
    required bool autoPlay,
    Duration initialPosition = Duration.zero,
    QueuePlaybackEntry? overrideCurrentItem,
    PlaybackTransitionCause cause = PlaybackTransitionCause.queueReplacement,
    PlaybackSourceKind? currentSourceKind,
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
    _startRebuildRun();
    await _player.setSeed(
      seedEntries,
      currentItemId: currentItem.itemId,
      sessionId: sessionId,
      cause: cause,
      initialPosition: initialPosition,
      autoPlay: autoPlay,
      shuffleEnabled: snapshot.session.shuffleEnabled,
      currentSourceKind: currentSourceKind,
    );
    _seed = (
      revision: _player.playlistRevision,
      itemId: currentItem.itemId,
      trackUuid: currentTrack.track.uuidId,
    );
    _engineDiverged = false;

    _window.replaceWindow(
      start: seedEntries.map((entry) => entry.playPosition).reduce(min),
      end: seedEntries.map((entry) => entry.playPosition).reduce(max) + 1,
    );
    await _syncLoopMode(
      _repeatModeFrom(snapshot.session.repeatMode),
      snapshot.totalCount,
      sessionId: sessionId,
    );

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

  /// Offline, or the server check failed: a stream is then handled like a
  /// non-downloaded item offline (sign-off OPEN-M-11 step D).
  bool get _isOffline => ref.read(streamsUnavailableProvider)();

  Future<void> _applyMediaTokenAction(MediaTokenAction action) async {
    final Object player = _player;
    if (player is! MediaTokenSources) return;
    switch (action) {
      case MediaTokenAction.none:
        return;
      case MediaTokenAction.refresh:
        await player.refreshWithheldMediaTokens();
      case MediaTokenAction.releaseAhead:
        await player.releaseRemoteSources(includeCurrent: false);
      case MediaTokenAction.releaseAll:
        final currentItemId = state.queue.currentItemId;
        if (currentItemId != null &&
            _player.sourceKindOf(currentItemId) == PlaybackSourceKind.remote) {
          await _player.stop();
        }
        await player.releaseRemoteSources(includeCurrent: true);
    }
  }

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

  Future<void> _markDamagedDownload(String trackUuid, String path) async {
    if (!ref.mounted) return;
    try {
      await ref
          .read(downloadReconciliationServiceProvider)
          .markDamaged(trackUuid, path);
    } catch (error, stackTrace) {
      // The recovery still streams or skips; the next failure marks it.
      developer.log('Marking a damaged download failed',
          name: 'QueuePlayer', error: error, stackTrace: stackTrace);
    }
  }

  /// Picks the next entry the player should land on for skipNext / skipPrev /
  /// natural advance. Offline searches the FULL queue (not just the loaded
  /// window) for the nearest entry with a verified local file in [direction];
  /// online uses the immediate next/previous play position. Honours the
  /// current repeat mode for wrapping.
  Future<PlaybackTarget?> _resolveAdvanceTarget({
    required int sessionId,
    required PlayOrderDirection direction,
  }) async {
    return (await _resolveAdvance(
      sessionId: sessionId,
      fromPlayPosition: state.queue.currentPlayPosition,
      direction: direction,
      offline: _isOffline,
    ))
        .target;
  }

  /// Resolves the landing with the current repeat mode and queue length, and
  /// publishes the resolution's issues. The order is played as stored.
  Future<PlaybackTargetResolution> _resolveAdvance({
    required int sessionId,
    required int fromPlayPosition,
    required PlayOrderDirection direction,
    required bool offline,
  }) async =>
      _publishIssuesOf(await _targetResolver.resolveAdvance(
        sessionId: sessionId,
        fromPlayPosition: fromPlayPosition,
        direction: direction,
        repeatMode: state.queue.repeatMode.name,
        totalCount: state.queue.totalCount,
        offline: offline,
      ));

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

    final resolution = await _resolveAdvance(
      sessionId: sessionId,
      fromPlayPosition: event.playPosition,
      direction: PlayOrderDirection.forward,
      offline: true,
    );
    final target = resolution.target;
    if (target == null) {
      await _player.stop();
      return;
    }
    await _ensureItemLoaded(sessionId, target.entry,
        sourceKind: target.sourceKind,
        cause: PlaybackTransitionCause.naturalAdvance);
    await _player.seekToItem(target.entry.itemId,
        cause: PlaybackTransitionCause.naturalAdvance);
    if (_focus.yieldedBy(AudioOutput.queue)) return;
    await _player.play();
  }

  bool get _hasHydratedSessionState =>
      state.queue.sessionId != null ||
      _player.queueLength > 0 ||
      state.playback.status != PlayerStatus.idle;

  /// Off: the whole queue returns to its original order (see
  /// [QueueOrderManager.restoreCanonicalOrder]). On: what is ahead of the
  /// current item is shuffled and the rest stays as played.
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
    if (enable) {
      await _orderManager.rebuildEffectiveOrder(
        sessionId,
        currentItemId: currentItemId,
        preserveShuffledMainFuture: false,
        shuffleMainFuture: true,
        isShuffleOn: state.shuffle.shuffleOn,
      );
    } else {
      await _orderManager.restoreCanonicalOrder(sessionId);
    }
    await _reseatEngineAroundCurrent(sessionId, currentItemId,
        shuffleOn: enable);
  }

  /// Reseats the engine and queue state around [currentItemId] after the play
  /// order was rewritten by the shuffle toggle. Returns false when the item is
  /// gone from the order. A non-null [shuffleOn] is published before the
  /// track caches are invalidated.
  Future<bool> _reseatEngineAroundCurrent(
    int sessionId,
    int currentItemId, {
    bool? shuffleOn,
  }) async {
    final rebuiltCurrentEntry = await _queueRepo.getPlaybackEntryForItem(
      sessionId,
      currentItemId,
    );
    if (rebuiltCurrentEntry == null) return false;

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
    await _syncLoopMode(state.queue.repeatMode, state.queue.totalCount,
        sessionId: sessionId);
    await _refreshCurrentQueueState(sessionId, preservePlaybackPosition: true);
    if (shuffleOn != null) {
      state = state.copyWith(shuffle: ShuffleSlice(shuffleOn: shuffleOn));
    }

    _invalidateQueueTracks();
    _scheduleForwardHydration();
    return true;
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
    final snapshot = await _queueRepo.getSessionSnapshot(sessionId);

    final sameItem = currentTrack.itemId == state.queue.currentItemId;
    state = state.copyWith(
      playback: state.playback.copyWith(
        currentTrack: currentTrack.track,
        position: preservePlaybackPosition && sameItem
            ? state.playback.position
            : Duration.zero,
        catalogDuration: _playbackDuration(currentTrack.track.duration),
        measuredDuration: sameItem ? state.playback.measuredDuration : null,
      ),
      queue: state.queue.copyWith(
        currentItemId: currentTrack.itemId,
        currentPlayPosition: currentTrack.playPosition,
        totalCount: snapshot?.totalCount ?? state.queue.totalCount,
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
  ///
  /// [sourceKind] is the landing's kind: a loaded item built the other way is
  /// reseeded to apply it. A reseed without a new decision keeps the kind the
  /// engine had applied to the item.
  Future<void> _ensureItemLoaded(int sessionId, QueuePlaybackEntry entry,
      {PlaybackTransitionCause cause = PlaybackTransitionCause.userSkip,
      bool reseed = false,
      PlaybackSourceKind? sourceKind,
      Duration initialPosition = Duration.zero}) async {
    final applied = _player.sourceKindOf(entry.itemId);
    reseed = reseed ||
        _engineDiverged ||
        (sourceKind != null && applied != null && applied != sourceKind);
    if (!reseed && _player.hasItem(entry.itemId)) return;
    final entries =
        await _window.seedEntriesForPlayPosition(sessionId, entry.playPosition);
    if (entries.isEmpty) return;
    await _player.setSeed(entries,
        currentItemId: entry.itemId,
        sessionId: sessionId,
        cause: cause,
        initialPosition: initialPosition,
        currentSourceKind: sourceKind ?? applied);
    _seed = (
      revision: _player.playlistRevision,
      itemId: entry.itemId,
      trackUuid: entry.uuidId,
    );
    _engineDiverged = false;
    _window.replaceWindow(
      start: entries.first.playPosition,
      end: entries.last.playPosition + 1,
    );
    await _syncLoopModeForCurrent();
    // A seed commits its current item silently: publish the change here
    // (state, cursor, hydration), as an engine item change would.
    await _onCurrentItemChanged(entry.itemId);
  }

  /// The engine's playlist diverged from what the core asked for (a failed
  /// native command): reseeds from queue data, continuing the same item.
  /// Dropped when a newer seed already replaced the diverged playlist.
  Future<void> _rebuildAfterCommandFailure(EngineCommandFailure failure) async {
    final sessionId = state.queue.sessionId;
    if (_stopInProgress ||
        sessionId == null ||
        failure.seedRevision != _seed?.revision) {
      return;
    }
    if (++_rebuildsInRun > _maxRebuildsPerRun) {
      // Rebuilding again would loop: stop honestly, keep the queue, and
      // reseed on the next user command.
      _engineDiverged = true;
      await _player.stop();
      _setPlayWhenReady(false);
      developer.log('Rebuild stopped: the engine kept failing after '
          '$_maxRebuildsPerRun rebuilds', name: 'QueuePlayer');
      return;
    }
    final entry = await _engineCurrentEntry(sessionId);
    if (entry == null) return;
    final item = entry.itemId;
    final wantPlay = state.playback.playWhenReady;
    final isSeek = failure.command == EngineCommand.seek;
    final position = _rebuildPosition(item, failure);
    final cause = isSeek &&
            failure.target?.itemId == item &&
            failure.cause != null &&
            failure.cause != PlaybackTransitionCause.userSeek
        ? failure.cause!
        : PlaybackTransitionCause.reconcileContinuation;
    await _reseedCurrent(sessionId, entry, position, cause,
        wantPlay: wantPlay);
  }

  /// Reseeds [entry] at [position] from queue data, then plays if wanted
  /// and the library still owns the output.
  /// Seeks the current item; an untrusted engine is reseeded there instead.
  Future<void> _seekCurrentInLane(Duration position,
      {required bool wantPlay}) async {
    final sessionId = state.queue.sessionId;
    final entry = _engineDiverged && sessionId != null
        ? await _engineCurrentEntry(sessionId)
        : null;
    if (entry != null) {
      await _reseedCurrent(sessionId!, entry, position,
          PlaybackTransitionCause.userSeek,
          wantPlay: wantPlay);
    } else {
      await _player.seek(position);
    }
  }

  /// Where a reseed of [item] resumes: a failed seek's position for its own
  /// item; the engine's when it belongs to [item] (the last settled one, or
  /// nothing settled yet); else the start.
  Duration _rebuildPosition(int item, EngineCommandFailure? failure) {
    if (failure != null &&
        failure.command == EngineCommand.seek &&
        failure.position != null &&
        failure.target?.itemId == item) {
      return failure.position!;
    }
    return _lastSettledItemId == null || item == _lastSettledItemId
        ? _player.position
        : Duration.zero;
  }

  /// The queue entry of the item the engine was last asked for.
  Future<QueuePlaybackEntry?> _engineCurrentEntry(int sessionId) async {
    final item = _player.currentItemId ?? state.queue.currentItemId;
    return item == null
        ? null
        : _queueRepo.getPlaybackEntryForItem(sessionId, item);
  }

  /// The yield guard on [wantPlay] is for automatic plays, which never take
  /// the output back from preview. A user play sets [takeFocus] and plays
  /// regardless; the engine's `beforePlay` then takes the output back.
  Future<void> _reseedCurrent(int sessionId, QueuePlaybackEntry entry,
      Duration position, PlaybackTransitionCause cause,
      {required bool wantPlay, bool takeFocus = false}) async {
    await _ensureItemLoaded(sessionId, entry,
        cause: cause, reseed: true, initialPosition: position);
    if (wantPlay && (takeFocus || !_focus.yieldedBy(AudioOutput.queue))) {
      await _player.play();
    }
  }

  /// Applies a forward hydration proposal in the lane, only while it is
  /// still current: same session, queue, window and source configuration
  /// as when it was started. A stale one is dropped and a fresh one
  /// scheduled. Reports whether it was applied.
  Future<bool> _applyHydration(QueueWindowProposal proposal) async {
    try {
      // Issue in the lane; the native application is awaited outside it (a
      // stalled load must never hold the lane, invariant 3).
      Future<bool>? application;
      await _serialize(() async {
        if (proposal.context != _hydrationContext() ||
            proposal.windowRevision != _window.windowRevision) {
          _scheduleForwardHydration();
          return;
        }
        if (proposal.entries.isNotEmpty) {
          await _player.addEntries(proposal.entries);
        }
        application = _player.whenApplied();
      });
      if (application == null || !await application!) return false;
      var applied = false;
      await _serialize(() async {
        if (proposal.context != _hydrationContext()) return;
        applied = _window.acknowledge(proposal);
        if (applied) await _syncLoopModeForCurrent();
      });
      return applied;
    } catch (error, stackTrace) {
      developer.log('Window hydration failed', name: 'QueuePlayer',
          error: error, stackTrace: stackTrace);
      _issues.publish(PlaybackTaskFailed('window hydration', error));
      return false;
    }
  }

  /// What a hydration proposal must still match when it is applied.
  ({int? sessionId, int queueVersion, int sourceConfigVersion})
      _hydrationContext() => (
            sessionId: state.queue.sessionId,
            queueVersion: state.queue.queueVersion,
            sourceConfigVersion: _sourceConfigVersion,
          );

  /// [_syncLoopMode] for the session already committed in [state].
  Future<void> _syncLoopModeForCurrent({QueueRepeatMode? mode}) =>
      _syncLoopMode(
        mode ?? state.queue.repeatMode,
        state.queue.totalCount,
        sessionId: state.queue.sessionId,
      );

  /// Decides the engine's native loop mode for the given session, never from
  /// whatever [state] holds (it may not yet show the session being
  /// activated). Native looping only where it cannot skip positions:
  /// repeat-all loops natively when the window holds the whole queue, which
  /// replays the order as stored; otherwise the model wraps through
  /// [_onEngineEnded]. With no session there is nothing to loop; the session
  /// that starts later decides again.
  Future<void> _syncLoopMode(
    QueueRepeatMode mode,
    int totalCount, {
    required int? sessionId,
  }) async {
    final EngineLoopMode loop;
    switch (mode) {
      case QueueRepeatMode.off:
        loop = EngineLoopMode.off;
      case QueueRepeatMode.one:
        loop = EngineLoopMode.one;
      case QueueRepeatMode.all:
        loop = sessionId != null && _window.coversQueue(totalCount)
            ? EngineLoopMode.all
            : EngineLoopMode.off;
    }
    await _player.setLoopMode(loop);
  }

  /// The engine finished its playlist. Before the logical end of the
  /// queue (hydration lagged) playback continues with the next item; at
  /// the end, repeat-all wraps to the first playable item. With no next item
  /// the queue has really ended, and that end is recorded ([_queueEnd]) with
  /// [endedSince], started when the engine reported it.
  Future<void> _onEngineEnded(
      int? endedSession, int endedItem, MonotonicStopwatch endedSince) async {
    final sessionId = state.queue.sessionId;
    if (sessionId == null ||
        sessionId != endedSession ||
        _player.currentItemId != endedItem) {
      return;
    }
    // At the logical end the resolver wraps only under repeat-all.
    if (!await _advanceFromCurrent(sessionId, play: true)) {
      _queueEnd =
          (sessionId: sessionId, itemId: endedItem, since: endedSince);
    }
  }

  /// Moves the engine forward from the current item as a natural advance:
  /// resolves the target (offline aware, issues published), loads it and
  /// seeks to it. Plays only with [play], and not while another output holds
  /// focus. Returns false, changing nothing, when there is no target.
  Future<bool> _advanceFromCurrent(int sessionId, {required bool play}) async {
    final target = await _resolveAdvanceTarget(
      sessionId: sessionId,
      direction: PlayOrderDirection.forward,
    );
    if (target == null) return false;
    await _ensureItemLoaded(sessionId, target.entry,
        sourceKind: target.sourceKind,
        cause: PlaybackTransitionCause.naturalAdvance);
    await _player.seekToItem(target.entry.itemId,
        cause: PlaybackTransitionCause.naturalAdvance);
    if (!play || _focus.yieldedBy(AudioOutput.queue)) return true;
    await _resumeInLane();
    return true;
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
    await _persistPlaybackCursor(resetPosition: true);
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

  /// Bumped when a failure run ends by a move, a new seed or a source
  /// playing: a classification that started in an earlier run is stale.
  int _failureRun = 0;

  static const _maxRebuildsPerRun = 3;

  /// Rebuilds after diverging engine command failures in this run.
  int _rebuildsInRun = 0;

  /// The engine kept failing and was stopped: its playlist is not trusted
  /// until the next seed.
  bool _engineDiverged = false;

  /// The item the last certain engine observation named: the engine's
  /// position belongs to it.
  int? _lastSettledItemId;

  /// Starts a new rebuild run. Separate from [_resetFailureRun], which also
  /// resets when a source plays: a rebuild that plays and fails again must
  /// still count toward the bound.
  void _startRebuildRun() => _rebuildsInRun = 0;

  /// The current item's stream failed transiently while online: going
  /// offline skips it (decision 1). Part of the failure run.
  ({int sessionId, int itemId})? _transientStreamFailure;

  /// The latest seed: its playlist revision (its load events carry it) and
  /// the item it seeded, which is what a failed load is about (the
  /// published state may not have caught up yet after a rebase).
  ({int revision, int itemId, String trackUuid})? _seed;

  /// A download that failed to play online and now streams, waiting for
  /// evidence before it is marked damaged (review major 1): the stream of
  /// the same item playing shows the device can play audio, so the file is
  /// at fault. Anything else (the stream fails too, the user moves on, a new
  /// session) drops the suspicion without a mark, so a platform failure can
  /// never mark downloads. Offline nothing is suspected or marked.
  ({int sessionId, int itemId, String trackUuid, String path})?
      _damageEvidence;

  void _dropDamageEvidence() {
    final evidence = _damageEvidence;
    if (evidence == null) return;
    _damageEvidence = null;
    _localSources.clearSuspect(evidence.trackUuid, evidence.path);
  }

  void _resetFailureRun({bool staleChecks = true}) {
    if (staleChecks) _failureRun++;
    _dropDamageEvidence();
    _attemptedSources.clear();
    _failedItems.clear();
    _recoveryExhausted = false;
    _transientStreamFailure = null;
  }

  void _rescueStreamFailureOffline() {
    final failure = _transientStreamFailure;
    if (failure == null) return;
    _transientStreamFailure = null;
    _runTask('offline stream rescue', () async {
      if (state.queue.sessionId != failure.sessionId ||
          state.queue.currentItemId != failure.itemId ||
          _recoveryExhausted) {
        return; // the decision is stale
      }
      await _skipFailedItem(failure.sessionId, failure.itemId);
    });
  }

  void _onLoadEvent(EngineLoadEvent event) {
    if (event.outcome != EngineLoadOutcome.failed) return;
    // A load belongs to its seed; later structural bumps (a refresh, a
    // quality rebuild) do not make its failure stale, a newer seed does.
    final seed = _seed;
    if (seed == null || event.playlistRevision != seed.revision) return;
    // The failing source's own identity (what the engine built), not the
    // catalog plan; a fake engine without one is treated as a stream.
    final source = event.source;
    final itemId = source?.itemId ?? seed.itemId;
    final trackUuid = source?.trackUuid ?? seed.trackUuid;
    final sourcePath = source?.localPath;
    _offLaneTask('load failure', () => _onSourceFailure(
          itemId: itemId,
          trackUuid: trackUuid,
          sourcePath: sourcePath,
          sourceKey: -event.playlistRevision,
          uncertain: false,
          errorCode: event.errorCode,
          errorMessage: event.errorMessage,
        ));
  }

  /// Classifies a failed source off the lane (the check may wait on the
  /// network; pause, stop and focus loss must not), then applies the
  /// recovery in the lane only if the same item is still current. It is
  /// classified by what the failing source loaded ([sourcePath]: its local
  /// file, null for a stream), not the catalog's current path, which may
  /// have changed since (a download committed meanwhile). A confirmed
  /// missing or damaged file (the damaged one is kept, decision 6) falls
  /// back to the stream online (never the same missing URI) or is skipped
  /// offline; a confirmed gone track is skipped; a transient stream failure
  /// is skipped offline (now, or once the app goes offline); other transient
  /// and unknown failures never skip. A failure run that would return to an
  /// item it already skipped stops instead of looping.
  Future<void> _onSourceFailure({
    required int? itemId,
    required String? trackUuid,
    required String? sourcePath,
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
    // The stream standing in for a suspected download failed too: there is
    // no evidence against the file (major 1).
    final evidence = _damageEvidence;
    if (evidence != null &&
        sourcePath == null &&
        evidence.sessionId == sessionId &&
        evidence.itemId == itemId) {
      _dropDamageEvidence();
    }
    final run = _failureRun;
    // The entry joins the catalog: a tombstoned track has none, but the
    // failing source's identity still names it.
    final entry = await _queueRepo.getPlaybackEntryForItem(sessionId, itemId);
    final uuid = entry?.uuidId ?? trackUuid;
    if (uuid == null) return;
    final kind = await _classifier.classify(
        trackUuid: uuid,
        filePath: sourcePath,
        uncertain: false);
    // The listener moved on (every user move and new seed starts a new run)
    // or the run ended while this was checked: stale, nothing is written. A
    // natural advance is not a move.
    if (state.queue.sessionId != sessionId || _failureRun != run) return;
    if (kind == SourceFailureKind.missingLocalFile) {
      // The catalog stops claiming the download, so every later rebuild
      // (rebase, refresh, reseed) loads the stream, and a later failure is
      // classified as a stream failure. (Only that path: a newer download
      // is kept.)
      await reportIssues([LocalFileMissing(uuid, sourcePath!)]);
    } else if (kind == SourceFailureKind.damagedLocalFile && !_isOffline) {
      // A present download that failed (decision 6) is only suspected
      // (major 1): it streams (the recovery below) and is marked damaged
      // once that stream plays. Offline it is skipped and never marked: a
      // platform failure there would else mark every download in the run.
      _dropDamageEvidence();
      _localSources.suspect(uuid, sourcePath!);
      _damageEvidence = (
        sessionId: sessionId,
        itemId: itemId,
        trackUuid: uuid,
        path: sourcePath,
      );
    }
    _issues.publish(PlaybackSourceFailed(uuid, kind,
        errorCode: errorCode, errorMessage: errorMessage));
    // A stream (no recorded download) that fails transiently: offline, it is
    // unavailable like any streaming item and is skipped to the next
    // downloaded one (decision 1); online it never skips, but going offline
    // later still rescues it. The classifier's own track check may be what
    // took the app offline, so offline is read after classifying.
    final streamed = sourcePath == null;
    if (kind == SourceFailureKind.transient && streamed) {
      if (_isOffline) {
        _runTask('source recovery', () async {
          if (state.queue.sessionId != sessionId ||
              state.queue.currentItemId != itemId ||
              _recoveryExhausted) {
            return; // the decision is stale
          }
          await _skipFailedItem(sessionId, itemId);
        });
      } else {
        _transientStreamFailure = (sessionId: sessionId, itemId: itemId);
      }
      return;
    }
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
      case SourceFailureKind.missingLocalFile ||
              SourceFailureKind.damagedLocalFile
          when !_isOffline && entry != null:
        await _player.refreshLoadedSourcesForAvailabilityChanges([
          // The stream stand-in: no file, but its codecs, so an "original"
          // stream of a codec this device can't decode streams transcoded.
          QueuePlaybackEntry(
            itemId: entry.itemId,
            queueType: entry.queueType,
            canonicalPosition: entry.canonicalPosition,
            playPosition: entry.playPosition,
            uuidId: entry.uuidId,
            downloadedCodec: entry.downloadedCodec,
            sourceCodec: entry.sourceCodec,
          ),
        ]);
        return;
      case SourceFailureKind.missingLocalFile:
      case SourceFailureKind.damagedLocalFile:
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
    if (target == null || _failedItems.contains(target.entry.itemId)) {
      _recoveryExhausted = true;
      await _player.stop();
      _setPlayWhenReady(false);
      // No summary issue (user decision 2026-11-07): each failed item
      // already published its PlaybackSourceFailed; a future error banner
      // adds a summary issue only if it needs one.
      developer.log(
          target == null
              ? 'Recovery stopped: no playable item after the failed one'
              : 'Recovery stopped: every item in the failure run failed',
          name: 'QueuePlayer');
      return;
    }
    // Re-seeded, not seeked (live gate 2026-11-07): after a failed load the
    // plugin sits idle with its platform deactivated, and on macOS a seek
    // (or a later play) never loads the target. A new seed replaces the
    // playlist, does not wait behind the failed native work, and loads.
    await _ensureItemLoaded(sessionId, target.entry,
        sourceKind: target.sourceKind,
        cause: PlaybackTransitionCause.naturalAdvance,
        reseed: true);
    if (state.playback.playWhenReady) await _player.play();
  }

  /// The stream standing in for a suspected download plays: the device
  /// plays audio, so the file is damaged (major 1). Marked off the lane;
  /// the suspicion stays until the mark is written, so no rebuild meanwhile
  /// returns to the file.
  void _checkDamageEvidence(PlaybackObservation observation) {
    final evidence = _damageEvidence;
    final source = observation.source;
    if (evidence == null ||
        source == null ||
        !observation.playing ||
        observation.processingState != EngineProcessingState.ready ||
        state.queue.sessionId != evidence.sessionId ||
        source.itemId != evidence.itemId ||
        source.localPath != null) {
      return;
    }
    _damageEvidence = null; // confirmed: a reset no longer drops it
    _offLaneTask('damage mark', () async {
      await _markDamagedDownload(evidence.trackUuid, evidence.path);
      _localSources.clearSuspect(evidence.trackUuid, evidence.path);
    });
  }

  void _onObservation(PlaybackObservation observation) {
    if (_stopInProgress || observation.uncertain) return;
    _lastSettledItemId = observation.source?.itemId;
    _checkDamageEvidence(observation);
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
    _engineReportsPlaying = playerState.playing;
    if (playerState.processingState == EngineProcessingState.ready) {
      _endAccepted = false;
      _queueEnd = null;
    }
    if (_stopInProgress) return;
    final completed =
        playerState.processingState == EngineProcessingState.completed;
    // Only a new end is handled. A new real end needs the engine to have
    // played since the accepted one (been ready), so a completed with no
    // ready since is the same end re-reported (e.g. the wrap's own playlist
    // edit settling) and is dropped. A completion masked by a pending insert
    // and re-reported at its settle was never accepted, so it is handled.
    // The task also drops out if the queue or the engine's item moved on
    // since the report (a wrap's own playlist edit, or a new queue
    // activating).
    if (completed &&
        state.playback.processing != EngineProcessingState.completed) {
      final endedSession = state.queue.sessionId;
      final endedItem = _player.currentItemId;
      if (endedItem != null && !_endAccepted) {
        _endAccepted = true;
        _queueEnd = null;
        final endedSince = _clock.stopwatch();
        _runTask('engine ended',
            () => _onEngineEnded(endedSession, endedItem, endedSince));
      }
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

  Future<void> _persistPlaybackCursor({bool resetPosition = false}) async {
    final sessionId = state.queue.sessionId;
    final currentItemId = state.queue.currentItemId;
    if (sessionId == null || currentItemId == null) return;

    try {
      await _queueRepo.updatePlaybackCursor(
        sessionId: sessionId,
        currentItemId: currentItemId,
        positionMs: resetPosition ? 0 : state.playback.position.inMilliseconds,
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
