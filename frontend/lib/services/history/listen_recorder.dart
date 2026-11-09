import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:frontend/models/history_event.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/history/listen_tracker.dart';

/// Durable listen accounting (5B.3, Phase 5 §7): turns [ListenTracker]
/// occurrences into `active_listens` drafts and finalized play events. An
/// observer of engine observations (SC-27 invariant 10); listen continuity
/// (invariant 16) is the tracker's.
///
/// * Startup barrier: [start] first settles the drafts a previous run left
///   (a frozen draft lands its frozen payload; an accumulating one lands
///   its persisted total, never extrapolated across the downtime; a
///   zero-credit one is deleted). Observations arriving meanwhile are
///   buffered with their arrival times and processed afterwards, in order.
/// * A listen gets its UUID (the play event's UUID) and binding token when
///   it first earns credit; its draft is checkpointed on pauses, buffering
///   and transitions, and at least every [checkpointEvery] of new credit.
/// * Closing a listen with credit finalizes it: the play event is inserted
///   (pending upload) and the draft deleted in one fenced transaction. A
///   failed finalization freezes the draft with that exact payload; it is
///   retried after the next successful finalization and at the next start,
///   never re-accumulated. A fenced write (the binding was replaced) drops
///   the listen.
/// * All writes run on one serialized chain; the tracker itself is pure and
///   runs on arrival.
class ListenRecorder {
  ListenRecorder({
    required Stream<PlaybackObservation> observations,
    required HistoryRepository history,
    required ServerBindingRepository binding,
    required Clock clock,
    String Function()? newListenUuid,
    void Function(Object error)? onError,
  })  : _history = history,
        _binding = binding,
        _clock = clock,
        _stopwatch = clock.stopwatch(),
        _newListenUuid = newListenUuid ?? (() => const Uuid().v4()),
        _onError = onError ??
            ((error) => developer.log('Listen not recorded',
                name: 'ListenRecorder', error: error)) {
    _subscription = observations.listen(_onObservation);
  }

  static const checkpointEvery = Duration(seconds: 5);

  /// In-memory finalizations kept while storage refuses them (§7).
  static const maxRecoveryIntents = 32;

  final HistoryRepository _history;
  final ServerBindingRepository _binding;
  final Clock _clock;
  final MonotonicStopwatch _stopwatch;
  final String Function() _newListenUuid;
  final void Function(Object error) _onError;
  late final StreamSubscription<PlaybackObservation> _subscription;

  final _tracker = ListenTracker();
  final _buffer = <_Arrival>[];
  final _listens = <int, _Listen>{}; // by occurrence generation
  final _retries = <_Retry>[];
  bool _unfrozen = false;
  Future<void> _tail = Future<void>.value();
  Future<void>? _started;
  bool _ready = false;
  bool _quiesced = false;
  ListenOccurrence? _current;

  /// The startup barrier: settles drafts of a previous run first.
  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    await _enqueue(_recover);
    if (_quiesced) return;
    _ready = true;
    final buffered = List.of(_buffer);
    _buffer.clear();
    for (final arrival in buffered) {
      _process(arrival);
    }
    await _tail;
  }

  /// What the app lifecycle means for listen accounting (D35): leaving
  /// the foreground checkpoints the current listen (the OS may kill a
  /// backgrounded app; the next start lands the checkpointed total). It
  /// never finalizes: with a media session the engine, and playback, can
  /// outlive a detached UI, and the listen goes on.
  Future<void> appLifecycleChanged(AppLifecycleState state) => switch (state) {
        AppLifecycleState.hidden ||
        AppLifecycleState.paused ||
        AppLifecycleState.detached =>
          checkpoint(),
        AppLifecycleState.resumed || AppLifecycleState.inactive => _tail,
      };

  /// Persists the current listen now.
  Future<void> checkpoint() {
    final current = _current;
    if (!_ready || _quiesced || current == null) return _tail;
    return _enqueue(() => _persist(current, force: true));
  }

  /// Reset participant: stops recording (writes are fenced anyway) and
  /// waits out the write in flight.
  Future<void> quiesce() async {
    _quiesced = true;
    _buffer.clear();
    await _subscription.cancel();
    await _tail;
  }

  /// Settled when everything observed so far has been processed.
  Future<void> get idle => _tail;

  void _onObservation(PlaybackObservation observation) {
    if (_quiesced) return;
    final arrival = _Arrival(observation, _stopwatch.elapsed.inMicroseconds,
        _clock.nowUtcMs());
    if (_ready) {
      _process(arrival);
    } else {
      _buffer.add(arrival);
    }
  }

  void _process(_Arrival arrival) {
    _apply(_tracker.observe(arrival.observation,
        monotonicMicros: arrival.monotonicMicros, nowUtcMs: arrival.nowUtcMs));
  }

  void _apply(ListenUpdate update) {
    final closed = update.closed;
    final current = update.current;
    _current = current;
    if (closed != null) unawaited(_enqueue(() => _finish(closed)));
    // A listen's credit can be withdrawn (a stall settles, a stale anchor is
    // corrected): one that proves nothing keeps no draft, which would else
    // block the next draft (one accumulating row) and land as a play at the
    // next start. The tracker never closes a listen whose credit just fell
    // to zero without first observing it here.
    if (current != null) {
      unawaited(_enqueue(() => current.creditedMicros > 0
          ? _persist(current, force: update.checkpoint)
          : _discard(current)));
    }
  }

  /// Deletes the draft of a listen that no longer proves any credit.
  Future<void> _discard(ListenOccurrence occurrence) async {
    final listen = _listens.remove(occurrence.generation);
    if (listen == null) return;
    try {
      await _history.deleteDraft(listen.token, listen.uuid);
    } on BindingFencedException {
      // its store is gone already
    }
  }

  Future<void> _enqueue(Future<void> Function() task) {
    final next = _tail.then((_) async {
      if (_quiesced && _ready) return;
      try {
        await task();
      } catch (error) {
        _onError(error);
      }
    });
    _tail = next;
    return next;
  }

  /// The listen's identity, made when it first earns credit. Null when
  /// there is no binding to write under.
  Future<_Listen?> _listenFor(ListenOccurrence occurrence) async {
    final known = _listens[occurrence.generation];
    if (known != null) return known;
    final token = (await _binding.current())?.localBindingId;
    if (token == null) return null;
    return _listens[occurrence.generation] =
        _Listen(_newListenUuid(), token);
  }

  Future<void> _persist(ListenOccurrence occurrence,
      {required bool force}) async {
    if (occurrence.creditedMicros <= 0) return;
    final known = _listens.containsKey(occurrence.generation);
    // A finalization that could not even freeze may still hold the one
    // accumulating row: land it before this listen's first draft.
    if (!known && _unfrozen) await _retryFrozen();
    final listen = await _listenFor(occurrence);
    final sessionId = occurrence.sessionId;
    if (listen == null || sessionId == null) return;
    if (known &&
        !force &&
        occurrence.creditedMicros - listen.persistedMicros <
            checkpointEvery.inMicroseconds) {
      return;
    }
    final credited = occurrence.creditedMicros;
    try {
      await _history.checkpointDraft(
          listen.token,
          ListenDraft(
            listenUuid: listen.uuid,
            queueSessionId: sessionId,
            queueItemId: occurrence.itemId,
            trackUuid: occurrence.trackUuid,
            startedAt: occurrence.startedAtUtcMs,
            durationSeconds: _seconds(occurrence.trackLength),
            accumulatedMicros: credited,
            lastCheckpointAt: _clock.nowUtcMs(),
          ));
    } on BindingFencedException {
      // A replaced binding: this run's listens are not recorded.
    } catch (error) {
      // Retried at the checkpoint cadence, not per observation (§7: no
      // busy loop); reported once per listen.
      if (!listen.reported) {
        listen.reported = true;
        _onError(error);
      }
    }
    listen.persistedMicros = credited; // attempted
  }

  Future<void> _finish(ListenOccurrence occurrence) async {
    final listen = await _listenFor(occurrence);
    _listens.remove(occurrence.generation);
    if (listen == null) return;
    final play = HistoryEventPayload(
      eventUuid: listen.uuid,
      kind: 'play',
      entityType: 'track',
      entityRef: occurrence.trackUuid,
      occurredAt: occurrence.startedAtUtcMs,
      secondsPlayed: occurrence.creditedMicros / Duration.microsecondsPerSecond,
      trackLength: _seconds(occurrence.trackLength),
    );
    if (await _finalize(listen.token, play)) await _retryFrozen();
  }

  /// Lands [play]; on failure freezes its draft for a later retry. True
  /// when it landed (or was already there).
  Future<bool> _finalize(String token, HistoryEventPayload play) async {
    try {
      final result = await _history.finalizeDraft(token, play);
      if (result != DraftFinalization.conflict) return true;
      // Never overwritten (§7): the draft is kept, frozen, as the visible
      // record of the conflict, and stops holding the accumulating slot.
      _onError(StateError(
          'Listen ${play.eventUuid} conflicts with a stored event'));
      await _history.freezeDraft(token, play.eventUuid, play);
      return false;
    } on BindingFencedException {
      return false; // dropped with its binding
    } on ArgumentError catch (error) {
      // Never valid, so never retried; its draft would block the next one.
      _onError(error);
      try {
        await _history.deleteDraft(token, play.eventUuid);
      } catch (deleteError) {
        _onError(deleteError); // may hold the accumulating slot until restart
      }
      return false;
    } catch (error) {
      _onError(error);
      try {
        await _history.freezeDraft(token, play.eventUuid, play);
      } on BindingFencedException {
        return false;
      } catch (freezeError) {
        _onError(freezeError); // still retried from memory this run
        _unfrozen = true;
      }
      _retries.add(_Retry(token, play));
      if (_retries.length > maxRecoveryIntents) {
        final dropped = _retries.removeAt(0);
        _onError(StateError('Listen ${dropped.play.eventUuid}: no more '
            'retries this run (lost unless its draft was frozen)'));
      }
      return false;
    }
  }

  Future<void> _retryFrozen() async {
    _unfrozen = false; // a retry that fails to freeze again sets it again
    final pending = List.of(_retries);
    _retries.clear();
    for (final retry in pending) {
      await _finalize(retry.token, retry.play);
    }
  }

  Future<void> _recover() async {
    final token = (await _binding.current())?.localBindingId;
    if (token == null) return; // no binding: nothing of ours to settle
    for (final draft in await _history.drafts()) {
      final play = draft.finalPayload ??
          (draft.accumulatedMicros > 0
              ? HistoryEventPayload(
                  eventUuid: draft.listenUuid,
                  kind: 'play',
                  entityType: 'track',
                  entityRef: draft.trackUuid,
                  occurredAt: draft.startedAt,
                  secondsPlayed: draft.accumulatedMicros /
                      Duration.microsecondsPerSecond,
                  trackLength: draft.durationSeconds,
                )
              : null);
      try {
        if (play == null) {
          await _history.deleteDraft(token, draft.listenUuid);
        } else {
          await _finalize(token, play);
        }
      } on BindingFencedException {
        return;
      } catch (error) {
        _onError(error);
      }
    }
  }

  static double? _seconds(Duration? duration) =>
      duration == null || duration <= Duration.zero
          ? null
          : duration.inMicroseconds / Duration.microsecondsPerSecond;
}

class _Arrival {
  const _Arrival(this.observation, this.monotonicMicros, this.nowUtcMs);
  final PlaybackObservation observation;
  final int monotonicMicros;
  final int nowUtcMs;
}

class _Listen {
  _Listen(this.uuid, this.token);
  final String uuid;
  final String token;
  int persistedMicros = 0; // last attempted checkpoint
  bool reported = false;
}

class _Retry {
  const _Retry(this.token, this.play);
  final String token;
  final HistoryEventPayload play;
}

/// What the listen recorder observes: the scope engine's observations.
final listenObservationsProvider = Provider<Stream<PlaybackObservation>>(
    (ref) => ref.read(playbackEngineProvider).observations);

/// The scope's listen recorder. Built (and started, behind its startup
/// barrier) by the playback wiring once the session is ready; a reset
/// quiesces it after playback (SC-15). Failures surface in the history
/// diagnostics (SC-21; the playback issue bus is for appliers, SC-27).
final listenRecorderProvider = Provider<ListenRecorder>((ref) {
  final recorder = ListenRecorder(
    observations: ref.read(listenObservationsProvider),
    history: ref.read(historyRepositoryProvider),
    binding: ref.read(serverBindingRepositoryProvider),
    clock: ref.read(clockProvider),
    onError: (error) {
      if (!ref.mounted) return;
      ref.read(listenRecordingErrorProvider).value = '$error';
    },
  );
  ref.onDispose(recorder.quiesce);
  return recorder;
});
