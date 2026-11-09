import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Elapsed time from a monotonic source (never jumps with wall-clock
/// changes).
abstract interface class MonotonicStopwatch {
  Duration get elapsed;
}

/// SC-20: the one clock. Playback (cursor-save throttle, listen
/// accounting, click acceptance times), Phase 6 snapshot capture and
/// Phase 9 `capturedNow` read it, so controlled-clock tests override one
/// provider.
abstract interface class Clock {
  /// Wall-clock now, Unix milliseconds UTC.
  int nowUtcMs();

  /// A started monotonic stopwatch.
  MonotonicStopwatch stopwatch();
}

class SystemClock implements Clock {
  const SystemClock();

  @override
  int nowUtcMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

  @override
  MonotonicStopwatch stopwatch() => _SystemStopwatch(Stopwatch()..start());
}

class _SystemStopwatch implements MonotonicStopwatch {
  _SystemStopwatch(this._stopwatch);
  final Stopwatch _stopwatch;

  @override
  Duration get elapsed => _stopwatch.elapsed;
}

final clockProvider = Provider<Clock>((ref) => const SystemClock());
