import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/services/history/listen_accumulator.dart';

const _s = 1000000; // micros per second

void main() {
  late ListenAccumulator acc;
  setUp(() => acc = ListenAccumulator());

  void at(double positionSeconds, double monotonicSeconds) => acc.sample(
      positionMicros: (positionSeconds * _s).round(),
      monotonicMicros: (monotonicSeconds * _s).round());

  void anchorAt(double positionSeconds, double monotonicSeconds) => acc.anchor(
      positionMicros: (positionSeconds * _s).round(),
      monotonicMicros: (monotonicSeconds * _s).round());

  test('positions 0, 0, 1 s at 0, .5, 1 s credit exactly 1 s', () {
    anchorAt(0, 0);
    at(0, 0.5);
    at(1, 1);
    expect(acc.creditedMicros, 1 * _s);
  });

  test('steady playback credits each second exactly once', () {
    anchorAt(0, 0);
    at(1, 1);
    at(2, 2);
    at(3, 3);
    expect(acc.creditedMicros, 3 * _s);
  });

  test('credit is bounded by elapsed time (a position jump is not credit)',
      () {
    anchorAt(0, 0);
    at(30, 1); // the plugin's position leapt: only 1 s really passed
    expect(acc.creditedMicros, 1 * _s);
  });

  test('credit is bounded by position (a stalled position earns nothing)',
      () {
    anchorAt(10, 0);
    at(10, 5);
    expect(acc.creditedMicros, 0);
    at(11, 6);
    expect(acc.creditedMicros, 1 * _s);
  });

  test('4 s play + 20 s paused + 3 s play = 7 s', () {
    anchorAt(0, 0);
    at(4, 4);
    acc.close(); // pause: the tail was sampled first
    anchorAt(4, 24); // resume 20 s later
    at(7, 27);
    expect(acc.creditedMicros, 7 * _s);
  });

  test('4 s play + seek + 2 s play = 6 s (the jump is excluded)', () {
    anchorAt(0, 0);
    at(4, 4);
    acc.close();
    anchorAt(60, 4);
    at(62, 6);
    expect(acc.creditedMicros, 6 * _s);
  });

  test('backward positions within an interval are not credited (a stray '
      'step back is ignored; re-specified after the branch audit)', () {
    anchorAt(10, 0);
    at(12, 2);
    at(11, 3); // backwards, no boundary, not settling: ignored
    expect(acc.creditedMicros, 2 * _s);
    at(13, 4); // still nothing twice: 12 → 13 only
    expect(acc.creditedMicros, 3 * _s);
  });

  test('a position behind the anchor re-anchors there: a stale anchor (the '
      'previous item\'s end, seen live at auto-advance) never zeroes a listen', () {
    anchorAt(45, 0); // the new item's first observation still says 45 s
    at(0.2, 0.2); // real positions restart near 0
    at(3, 3);
    expect(acc.creditedMicros, (2.8 * _s).round());
  });

  test('a snap back after credit (a stall after the plugin extrapolated '
      'ahead, seen live) never credits the replayed span twice', () {
    anchorAt(3, 0);
    at(5, 2); // credited 2 s, the last 1 s extrapolated during a stall
    acc.sample(positionMicros: 4 * _s, monotonicMicros: (2.5 * _s).round(),
        settling: true); // buffering reports the real 4 s
    acc.close();
    anchorAt(4, 3); // resume where audio is
    at(5.5, 4.5);
    expect(acc.creditedMicros, (2.5 * _s).round(), reason: '3 → 5.5 s heard');
  });

  test('a stall the plugin reported late: credit falls back to the position '
      'actually reached (seen live: 7.76 s extrapolated, 3.77 s real)', () {
    anchorAt(0, 0);
    at(7.76, 7.76); // "ready and playing" while the stream had stalled
    acc.sample(positionMicros: (3.77 * _s).round(),
        monotonicMicros: 8 * _s, settling: true); // buffering: the real position
    expect(acc.creditedMicros, (3.77 * _s).round());
  });

  group('branch audit (5B): stale anchors, late stalls, stray ticks', () {
    void settle(double positionSeconds, double monotonicSeconds) => acc.sample(
        positionMicros: (positionSeconds * _s).round(),
        monotonicMicros: (monotonicSeconds * _s).round(),
        settling: true);

    test('short → long advance: a stale anchor with one extrapolated tick '
        'still re-anchors (M2)', () {
      anchorAt(3, 0); // the previous (3 s) item's end, not clamped
      at(3.2, 0.2); // one extrapolated tick earns 0.2 s
      at(0.2, 0.3); // the real position: behind the anchor
      at(30.2, 30.3);
      expect(acc.creditedMicros, 30 * _s);
    });

    test('a stray cause-less tick near 0 before a loop restart is ignored '
        '(M3)', () {
      anchorAt(0, 0);
      at(10, 10);
      at(0.05, 10.1); // ordering race: a tick of the next loop
      expect(acc.creditedMicros, 10 * _s);
      anchorAt(3, 20); // a later interval after a pause at 3 s
      at(10, 27);
      at(0.05, 27.1);
      expect(acc.creditedMicros, 17 * _s);
    });

    test('a stall snap-back reported with buffering withdraws, bounded', () {
      anchorAt(0, 0);
      at(7.76, 7.76);
      settle(3.77, 8); // buffering at the real position
      expect(acc.creditedMicros, (3.77 * _s).round());
      acc.close();
      anchorAt(100, 100);
      at(130, 130);
      settle(110, 131); // 20 s back: beyond any stall extrapolation
      expect(acc.creditedMicros, (3.77 * _s).round() + 30 * _s);
    });
  });

  test('unused budget never carries across a closed interval', () {
    anchorAt(0, 0);
    at(0, 10); // 10 s elapsed, no progress
    acc.close();
    anchorAt(0, 10);
    at(5, 11); // only 1 s elapsed in this interval
    expect(acc.creditedMicros, 1 * _s);
  });

  test('a rate bounds credit by elapsed time times rate', () {
    anchorAt(0, 0);
    acc.sample(positionMicros: 4 * _s, monotonicMicros: 2 * _s, rate: 2.0);
    expect(acc.creditedMicros, 4 * _s);
  });

  test('a sample with no interval anchors instead of crediting', () {
    expect(acc.anchored, isFalse);
    at(50, 100);
    expect(acc.anchored, isTrue);
    expect(acc.creditedMicros, 0);
    at(51, 101);
    expect(acc.creditedMicros, 1 * _s);
  });
}
