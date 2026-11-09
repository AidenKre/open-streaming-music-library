// SC-13 BackoffSchedule: one injectable pacing schedule for background passes
// (binding gate in 5A.0; history runner in 5A; uploads/delete polling later).
// Exponential steps with jitter, reset on success, Retry-After honored, and
// distinct non-growing waits for offline / capability missing / permanent so
// none of them busy-loops.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/background/backoff_schedule.dart';

class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final double value;
  @override
  double nextDouble() => value;
  @override
  int nextInt(int max) => (value * max).floor();
  @override
  bool nextBool() => value >= 0.5;
}

const _s = Duration(seconds: 1);

void main() {
  test('Phase 5 default steps are 1, 2, 4, 8, 16, 30 s, capped at 30', () {
    final b = BackoffSchedule(jitter: 0);
    final delays = [for (var i = 0; i < 8; i++) b.nextDelay()];
    expect(delays, [_s, _s * 2, _s * 4, _s * 8, _s * 16, _s * 30, _s * 30, _s * 30]);
    expect(b.attempts, 8);
  });

  test('success resets to the first step', () {
    final b = BackoffSchedule(jitter: 0);
    b.nextDelay();
    b.nextDelay();
    b.nextDelay();
    b.reset();
    expect(b.attempts, 0);
    expect(b.nextDelay(), _s);
  });

  test('jitter spreads each step symmetrically by the injected random', () {
    final low = BackoffSchedule(jitter: 0.2, random: _FixedRandom(0.0));
    final high = BackoffSchedule(jitter: 0.2, random: _FixedRandom(1.0));
    final mid = BackoffSchedule(jitter: 0.2, random: _FixedRandom(0.5));
    expect(low.nextDelay(), const Duration(milliseconds: 800));
    expect(high.nextDelay(), const Duration(milliseconds: 1200));
    expect(mid.nextDelay(), _s);
    expect(low.nextDelay(), const Duration(milliseconds: 1600));
  });

  test('custom steps', () {
    final b = BackoffSchedule(steps: const [Duration(milliseconds: 5), Duration(milliseconds: 7)], jitter: 0);
    expect([b.nextDelay(), b.nextDelay(), b.nextDelay()], [
      const Duration(milliseconds: 5),
      const Duration(milliseconds: 7),
      const Duration(milliseconds: 7),
    ]);
  });

  test('Retry-After is honored: never shorter than the server asked', () {
    final b = BackoffSchedule(jitter: 0.2, random: _FixedRandom(0.0));
    expect(b.nextDelay(retryAfter: _s * 10), _s * 10);
    // A Retry-After shorter than the step does not shorten the step.
    expect(
      b.nextDelay(retryAfter: const Duration(milliseconds: 1)),
      const Duration(milliseconds: 1600),
    );
  });

  test('offline / capability missing / permanent use their own fixed waits',
      () {
    final b = BackoffSchedule(
      jitter: 0,
      offlineWait: _s * 60,
      capabilityWait: _s * 300,
      permanentWait: _s * 1800,
    );
    expect(b.nextDelay(reason: BackoffReason.offline), _s * 60);
    expect(b.nextDelay(reason: BackoffReason.offline), _s * 60, reason: 'no growth');
    expect(b.nextDelay(reason: BackoffReason.capabilityMissing), _s * 300);
    expect(b.nextDelay(reason: BackoffReason.permanent), _s * 1800);
    // They do not consume the transient ladder.
    expect(b.attempts, 0);
    expect(b.nextDelay(), _s);
  });

  test('the special waits are long enough not to busy-loop by default', () {
    final b = BackoffSchedule();
    for (final reason in [
      BackoffReason.offline,
      BackoffReason.capabilityMissing,
      BackoffReason.permanent,
    ]) {
      expect(b.nextDelay(reason: reason), greaterThanOrEqualTo(_s * 30), reason: '$reason');
    }
  });

  test('invalid configuration is rejected', () {
    expect(() => BackoffSchedule(steps: const []), throwsArgumentError);
    expect(() => BackoffSchedule(jitter: -0.1), throwsArgumentError);
    expect(() => BackoffSchedule(jitter: 1.0), throwsArgumentError);
  });
}
