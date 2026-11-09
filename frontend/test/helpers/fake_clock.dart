import 'package:frontend/services/clock.dart';

/// A controllable SC-20 clock: [advance] moves both wall and monotonic time.
class FakeClock implements Clock {
  FakeClock({int startUtcMs = 1800000000000}) : _wallMs = startUtcMs;
  int _wallMs;
  Duration _monotonic = Duration.zero;

  void advance(Duration by) {
    _wallMs += by.inMilliseconds;
    _monotonic += by;
  }

  /// Moves only wall time (a clock correction); stopwatches are unaffected.
  void jumpWallClock(Duration by) => _wallMs += by.inMilliseconds;

  @override
  int nowUtcMs() => _wallMs;

  @override
  MonotonicStopwatch stopwatch() => _FakeStopwatch(this, _monotonic);
}

class _FakeStopwatch implements MonotonicStopwatch {
  _FakeStopwatch(this._clock, this._start);
  final FakeClock _clock;
  final Duration _start;

  @override
  Duration get elapsed => _clock._monotonic - _start;
}
