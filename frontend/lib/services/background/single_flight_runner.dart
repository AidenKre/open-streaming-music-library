import 'dart:async';
import 'dart:developer' as developer;

import 'package:frontend/services/background/backoff_schedule.dart';

/// What one pass of a [SingleFlightRunner] reports.
sealed class PassOutcome {
  const PassOutcome();
}

/// Caught up: the backoff resets; nothing is scheduled.
final class PassDone extends PassOutcome {
  const PassDone();
}

/// The pass used its budget and work remains: run again after a yield.
final class PassMoreWork extends PassOutcome {
  const PassMoreWork();
}

/// The pass failed: retry after the backoff for [reason] ([retryAfter] is a
/// floor, e.g. a server Retry-After).
final class PassFailed extends PassOutcome {
  const PassFailed(this.reason, {this.retryAfter});
  final BackoffReason reason;
  final Duration? retryAfter;
}

/// SC-13: runs one subsystem's pass at a time. Requests (from any trigger)
/// start a pass, or coalesce into exactly one rerun while a pass runs or a
/// failure backs off. A budgeted pass that reports [PassMoreWork] runs again
/// after a yield; a [PassFailed] (or a pass that throws) schedules one
/// retry paced by the [BackoffSchedule]; [PassDone] resets the backoff.
/// Generic: it knows nothing about the subsystem it runs.
class SingleFlightRunner {
  SingleFlightRunner({
    required this.name,
    required Future<PassOutcome> Function(Set<String> reasons) pass,
    required BackoffSchedule backoff,
    Timer Function(Duration, void Function()) timer = Timer.new,
  }) : _pass = pass,
       _backoff = backoff,
       _timer = timer;

  final String name;
  final Future<PassOutcome> Function(Set<String> reasons) _pass;
  final BackoffSchedule _backoff;
  final Timer Function(Duration, void Function()) _timer;

  /// Reasons collected since the last pass started.
  final _reasons = <String>{};
  bool _running = false;
  bool _bypassPending = false;
  bool _closed = false;
  Timer? _retry;
  Future<void>? _loop;
  final _idleWaiters = <Completer<void>>[];

  /// Start a pass now, or (while one runs, or while a failure backs off)
  /// coalesce into one later pass. [bypassBackoff]: a recovery edge runs
  /// now and cancels a pending backoff retry.
  void request(String reason, {bool bypassBackoff = false}) {
    if (_closed) return;
    _reasons.add(reason);
    if (_running) {
      _bypassPending |= bypassBackoff;
      return; // the rerun after this pass picks it up
    }
    final retry = _retry;
    if (retry != null && retry.isActive && !bypassBackoff) return;
    retry?.cancel();
    _retry = null;
    _start();
  }

  bool get isRunning => _running;

  /// Completes when no pass is running or queued to run without waiting
  /// (a pending backoff retry does not count).
  Future<void> whenIdle() {
    if (!_running) return Future.value();
    final waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }

  /// SC-15 quiesce: no further passes; cancels a pending retry; completes
  /// once the pass in flight (if any) has finished. Idempotent.
  Future<void> quiesce() async {
    _closed = true;
    _retry?.cancel();
    _retry = null;
    _reasons.clear();
    await _loop;
  }

  void _start() {
    _running = true;
    // Promptly, but never inside the caller's own stack.
    _loop = Future<void>.microtask(_drive);
  }

  Future<void> _drive() async {
    try {
      while (!_closed) {
        final reasons = {..._reasons};
        _reasons.clear();
        _bypassPending = false;
        PassOutcome outcome;
        try {
          outcome = await _pass(reasons);
        } catch (e, st) {
          developer.log(
            '$name pass failed',
            name: 'SingleFlightRunner',
            error: e,
            stackTrace: st,
          );
          outcome = const PassFailed(BackoffReason.transient);
        }
        if (_closed) return;
        switch (outcome) {
          case PassDone():
            _backoff.reset();
            if (_reasons.isEmpty) return;
          case PassMoreWork():
            await Future<void>.delayed(Duration.zero);
          case PassFailed(:final reason, :final retryAfter):
            if (_bypassPending) continue;
            _retry = _timer(
              _backoff.nextDelay(reason: reason, retryAfter: retryAfter),
              _onRetry,
            );
            return;
        }
      }
    } finally {
      _running = false;
      for (final waiter in _idleWaiters) {
        waiter.complete();
      }
      _idleWaiters.clear();
    }
  }

  void _onRetry() {
    _retry = null;
    if (_closed || _running) return;
    _start();
  }
}
