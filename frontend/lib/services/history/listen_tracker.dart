import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/services/history/listen_accumulator.dart';

/// One listen occurrence (Phase 5 §7): a queue item played from a start,
/// across pauses, seeks and same-item rebuilds, until a genuine boundary.
class ListenOccurrence {
  ListenOccurrence({
    required this.generation,
    required this.runtimeId,
    required this.sessionId,
    required this.itemId,
    required this.trackUuid,
    required this.startedAtUtcMs,
    this.trackLength,
  });
  final int generation;
  final int runtimeId;
  final int? sessionId;
  final int itemId;
  final String trackUuid;
  final int startedAtUtcMs;
  Duration? trackLength;
  int creditedMicros = 0;
}

/// What one observation changed. [closed]: a listen that ended with credit
/// (zero-credit occurrences end silently). [checkpoint]: a moment to persist
/// the current listen (pause, buffering, a transition).
class ListenUpdate {
  const ListenUpdate({this.closed, this.current, this.checkpoint = false});
  final ListenOccurrence? closed;
  final ListenOccurrence? current;
  final bool checkpoint;
}

/// Consumes provenance-carrying engine observations (5B.2, Phase 5 §7) and
/// turns them into listen occurrences. It never reads playback state
/// (SC-27 invariant 10: an observer) and keeps a listen across same-item
/// rebuilds, seeks and edits (invariant 16: listen continuity).
///
/// * Uncertain observations (identity not settled), observations of a
///   replaced engine runtime and older-sequence observations of the
///   current runtime (delivered out of order) are never credited.
/// * A different item (or session), a stop or the end of the queue closes
///   the listen (with what its closing observation proved); a repeat-one
///   restart, or an advance or skip that wraps onto the same item, closes
///   it and starts a new generation of that item.
/// * A listen starts with audio: a paused or buffering item (a restored
///   queue) has no listen until it plays.
/// * A user seek, a queue edit, a quality or source rebuild or a reconcile
///   that keeps the item re-anchors the same listen: the jump is not
///   credited, the listen continues.
/// * Pausing or buffering credits the tail and closes the interval (a
///   checkpoint), without closing the listen; resuming re-anchors.
class ListenTracker {
  ListenOccurrence? _current;
  final _accumulator = ListenAccumulator();
  int _generation = 0;
  int? _runtimeId;
  int _lastSequence = 0;

  /// An advance or skip that lands on the same item is a new listen only
  /// when it restarts it (a wrap): back near its start after real credit.
  /// Anything else on the same item (a rebase settling twice on its
  /// target, a failed seek falling back) continues the listen.
  static const _wraps = {
    PlaybackTransitionCause.naturalAdvance,
    PlaybackTransitionCause.userSkip,
  };
  static const restartWindow = Duration(seconds: 2);

  static const _continuations = {
    PlaybackTransitionCause.userSeek,
    PlaybackTransitionCause.queueEdit,
    PlaybackTransitionCause.qualityRebuild,
    PlaybackTransitionCause.sourceRefresh,
    PlaybackTransitionCause.reconcileContinuation,
  };

  ListenUpdate observe(PlaybackObservation o,
      {required int monotonicMicros, required int nowUtcMs}) {
    final runtime = _runtimeId;
    if (runtime != null && o.runtimeId < runtime) {
      return ListenUpdate(current: _current); // a replaced engine
    }
    if (o.runtimeId == runtime && o.sequence <= _lastSequence) {
      return ListenUpdate(current: _current); // delivered out of order
    }
    _lastSequence = o.sequence;
    ListenOccurrence? closed;
    if (runtime != null && o.runtimeId > runtime) closed = _close();
    _runtimeId = o.runtimeId;

    final source = o.source;
    if (o.uncertain || source == null) {
      _accumulator.close(); // nothing trustworthy to credit or anchor on
      return ListenUpdate(closed: closed, current: _current);
    }

    final position = o.position.inMicroseconds;
    final cause = o.transitionCause;
    var current = _current;
    final otherItem = current != null &&
        (current.itemId != source.itemId ||
            current.sessionId != source.sessionId);
    var checkpoint = false;

    final restart = cause == PlaybackTransitionCause.repeatOneRestart ||
        (current != null &&
            _wraps.contains(cause) &&
            _accumulator.creditedMicros >= restartWindow.inMicroseconds &&
            position < restartWindow.inMicroseconds);
    if (otherItem || restart) {
      closed = _close() ?? closed;
      current = null;
    } else if (cause == PlaybackTransitionCause.stop) {
      if (current != null && o.playing &&
          o.processingState == EngineProcessingState.ready) {
        _accumulator.sample(
            positionMicros: position, monotonicMicros: monotonicMicros,
            rate: o.rate);
      }
      closed = _close() ?? closed;
      return ListenUpdate(closed: closed, current: null, checkpoint: true);
    } else if (cause != null &&
        (_continuations.contains(cause) || _wraps.contains(cause))) {
      _accumulator.close(); // re-anchor below; the jump is not credited
      checkpoint = true;
    }

    if (o.processingState == EngineProcessingState.completed) {
      if (current != null) {
        _accumulator.sample(
            positionMicros: position, monotonicMicros: monotonicMicros,
            rate: o.rate);
        closed = _close() ?? closed;
      }
      return ListenUpdate(closed: closed, current: null, checkpoint: true);
    }

    final active =
        o.playing && o.processingState == EngineProcessingState.ready;
    // A listen starts when audio does (a restored, paused item is not one).
    if (current == null && !active) {
      return ListenUpdate(closed: closed, current: null, checkpoint: checkpoint);
    }
    current ??= _current = ListenOccurrence(
      generation: ++_generation,
      runtimeId: o.runtimeId,
      sessionId: source.sessionId,
      itemId: source.itemId,
      trackUuid: source.trackUuid,
      startedAtUtcMs: nowUtcMs,
    );
    current.trackLength ??= o.duration;

    if (active) {
      _accumulator.sample(
          positionMicros: position, monotonicMicros: monotonicMicros,
          rate: o.rate);
    } else if (_accumulator.anchored) {
      // Pause or buffering: credit the tail with this position, then close.
      // This observation settles the interval: a stall the plugin reported
      // late carries the real position here.
      _accumulator.sample(
          positionMicros: position, monotonicMicros: monotonicMicros,
          rate: o.rate, settling: true);
      _accumulator.close();
      checkpoint = true;
    }
    current.creditedMicros = _accumulator.creditedMicros;
    return ListenUpdate(closed: closed, current: current, checkpoint: checkpoint);
  }

  ListenOccurrence? _close() {
    final current = _current;
    _current = null;
    // What the closing observation itself proved (a stop or completion
    // sample) belongs to this listen.
    if (current != null) current.creditedMicros = _accumulator.creditedMicros;
    _accumulator.reset();
    if (current == null || current.creditedMicros <= 0) return null;
    return current;
  }
}
