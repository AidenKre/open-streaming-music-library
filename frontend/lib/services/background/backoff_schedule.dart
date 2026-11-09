import 'dart:math';

/// Why a background pass is backing off; selects the wait in
/// [BackoffSchedule.nextDelay].
enum BackoffReason {
  /// A failure worth retrying soon: walks the exponential ladder.
  transient,

  /// No connectivity: a fixed wait (connectivity recovery usually wakes the
  /// pass earlier).
  offline,

  /// The server lacks a required capability: a fixed, longer wait.
  capabilityMissing,

  /// A permanent / quarantined failure: a fixed, long wait.
  permanent,
}

/// Paces repeated background passes (SC-13). Transient failures walk an
/// exponential ladder with symmetric jitter, capped at its last step; a
/// success [reset]s it. A server `Retry-After` is a floor, never shortened.
/// Offline, capability-missing and permanent failures get their own fixed
/// waits that neither grow nor consume the ladder, so none of them
/// busy-loops.
///
/// Complements the per-request `RetryPolicy` (api/retry_policy.dart), which
/// retries one HTTP call; this schedule paces whole passes.
class BackoffSchedule {
  BackoffSchedule({
    List<Duration> steps = defaultSteps,
    double jitter = 0.2,
    Random? random,
    Duration offlineWait = defaultOfflineWait,
    Duration capabilityWait = defaultCapabilityWait,
    Duration permanentWait = defaultPermanentWait,
  }) : _steps = List.unmodifiable(steps),
       _jitter = jitter,
       _random = random ?? Random(),
       _offlineWait = offlineWait,
       _capabilityWait = capabilityWait,
       _permanentWait = permanentWait {
    if (steps.isEmpty) {
      throw ArgumentError.value(steps, 'steps', 'must not be empty');
    }
    if (jitter < 0 || jitter >= 1) {
      throw ArgumentError.value(jitter, 'jitter', 'must be in [0, 1)');
    }
  }

  /// The Phase 5 transient ladder: 1, 2, 4, 8, 16, 30 s (then 30 s).
  static const defaultSteps = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  /// Offline: re-check once a minute.
  static const defaultOfflineWait = Duration(minutes: 1);

  /// Capability missing: a server upgrade is rare, so every 5 minutes.
  static const defaultCapabilityWait = Duration(minutes: 5);

  /// Permanent / quarantined: every 30 minutes.
  static const defaultPermanentWait = Duration(minutes: 30);

  final List<Duration> _steps;
  final double _jitter;
  final Random _random;
  final Duration _offlineWait;
  final Duration _capabilityWait;
  final Duration _permanentWait;
  int _attempts = 0;

  /// Transient delays handed out since construction or the last [reset].
  int get attempts => _attempts;

  /// The wait before the next pass. A transient delay advances the ladder;
  /// the other reasons return their fixed wait. [retryAfter] (the server's
  /// `Retry-After`) is a floor on the result.
  Duration nextDelay({
    BackoffReason reason = BackoffReason.transient,
    Duration? retryAfter,
  }) {
    final delay = switch (reason) {
      BackoffReason.transient => _nextTransient(),
      BackoffReason.offline => _offlineWait,
      BackoffReason.capabilityMissing => _capabilityWait,
      BackoffReason.permanent => _permanentWait,
    };
    if (retryAfter != null && retryAfter > delay) return retryAfter;
    return delay;
  }

  /// Back to the first step (call after a successful pass).
  void reset() => _attempts = 0;

  Duration _nextTransient() {
    final step = _steps[min(_attempts, _steps.length - 1)];
    _attempts++;
    final factor = 1 + _jitter * (2 * _random.nextDouble() - 1);
    return Duration(microseconds: (step.inMicroseconds * factor).round());
  }
}
