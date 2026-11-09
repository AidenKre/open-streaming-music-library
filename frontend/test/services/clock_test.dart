import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/services/clock.dart';

import '../helpers/fake_clock.dart';

void main() {
  test('the system clock reports UTC milliseconds and monotonic time', () {
    const clock = SystemClock();
    final before = DateTime.now().toUtc().millisecondsSinceEpoch;
    final now = clock.nowUtcMs();
    expect(now, greaterThanOrEqualTo(before));
    final stopwatch = clock.stopwatch();
    expect(stopwatch.elapsed, greaterThanOrEqualTo(Duration.zero));
  });

  test('a fake clock moves wall and monotonic time independently', () {
    final clock = FakeClock(startUtcMs: 1000);
    final stopwatch = clock.stopwatch();
    clock.advance(const Duration(seconds: 2));
    expect(clock.nowUtcMs(), 3000);
    expect(stopwatch.elapsed, const Duration(seconds: 2));
    clock.jumpWallClock(const Duration(hours: -1));
    expect(stopwatch.elapsed, const Duration(seconds: 2),
        reason: 'monotonic time ignores wall-clock corrections');
  });
}
