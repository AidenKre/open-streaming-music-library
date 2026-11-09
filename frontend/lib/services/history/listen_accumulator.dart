import 'dart:math';

/// Pure listen credit arithmetic (Phase 5 §7), in integer microseconds.
///
/// Credit is media time actually traversed while playing and ready. An
/// interval is anchored at a (position, monotonic time) pair; its budget is
/// `min(max(0, position − anchorPosition), (monotonic − anchorTime) × rate)`
/// and only the budget's increase over what the interval already credited
/// is added. Unused elapsed budget is kept across duplicated or quantized
/// positions (0, 0, 1 s at 0, .5, 1 s credits 1 s), a position jump earns
/// at most the elapsed time, and closing the interval (pause, buffering,
/// seek, any transition) drops its unused budget.
///
/// A position going backward with no boundary is normally ignored (never
/// credited twice). Two cases seen live on macOS correct earlier data:
///  * Provisional anchor: an interval that has credited less than
///    [provisionalCredit] and sees a position behind its anchor was anchored
///    on stale data (an auto-advance's first observation still carries the
///    previous item's position): it withdraws that credit and re-anchors.
///  * Settling: the observation that reports a stall (buffering, a pause)
///    carries the real position after the plugin extrapolated ahead for
///    seconds; credit beyond it is withdrawn, at most [maxWithdraw] (a larger
///    step back is not a stall and is ignored).
class ListenAccumulator {
  static const provisionalCredit = 2000000; // 2 s
  static const maxWithdraw = 10000000; // 10 s

  int _creditedMicros = 0;
  _Interval? _interval;

  int get creditedMicros => _creditedMicros;
  bool get anchored => _interval != null;

  void anchor({required int positionMicros, required int monotonicMicros}) {
    _interval = _Interval(positionMicros, monotonicMicros);
  }

  /// Credits what this observation proves; with no interval, anchors one.
  void sample({
    required int positionMicros,
    required int monotonicMicros,
    double rate = 1.0,
    bool settling = false,
  }) {
    final interval = _interval;
    if (interval == null) {
      anchor(positionMicros: positionMicros, monotonicMicros: monotonicMicros);
      return;
    }
    if (positionMicros < interval.startPosition &&
        interval.credited < provisionalCredit) {
      // A provisional anchor proved stale: re-anchor where audio is.
      _withdraw(interval, interval.credited);
      anchor(positionMicros: positionMicros, monotonicMicros: monotonicMicros);
      return;
    }
    final traversed = max(0, positionMicros - interval.startPosition);
    if (traversed < interval.credited) {
      final excess = interval.credited - traversed;
      if (settling && excess <= maxWithdraw) _withdraw(interval, excess);
      return; // otherwise a stray backward position: ignored
    }
    final elapsed =
        ((monotonicMicros - interval.startMonotonic) * rate).floor();
    final budget = min(traversed, max(0, elapsed));
    if (budget > interval.credited) {
      _creditedMicros += budget - interval.credited;
      interval.credited = budget;
    }
  }

  void _withdraw(_Interval interval, int micros) {
    _creditedMicros -= micros;
    interval.credited -= micros;
  }

  void close() => _interval = null;

  /// A new listen: no credit, no interval.
  void reset() {
    _interval = null;
    _creditedMicros = 0;
  }
}

class _Interval {
  _Interval(this.startPosition, this.startMonotonic);
  final int startPosition;
  final int startMonotonic;
  int credited = 0;
}
