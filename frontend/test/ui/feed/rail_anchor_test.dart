// Phase 6 §6 (6-R06): a live rail keeps the first visible entity and its
// intra-card pixel offset across inserts, reorders and removals; at offset
// zero it shows the newest; a removed anchor clamps. Pure arithmetic over a
// fixed item extent.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/feed/rail_anchor.dart';

void main() {
  const w = 160.0; // item extent
  const pad = 8.0; // leading and trailing padding
  const viewport = 400.0;

  List<Key> keys(List<String> ids) => [for (final id in ids) ValueKey(id)];

  /// The offset at which item [index] starts [intra] pixels scrolled past
  /// the viewport's leading edge.
  double at(int index, double intra) => pad + index * w + intra;

  final old = keys(['k0', 'k1', 'k2', 'k3', 'k4', 'k5']);

  RailRestore restore(RailAnchor a, List<Key> next) => a.restore(
    oldKeys: old,
    newKeys: next,
    itemExtent: w,
    padding: pad,
    viewportExtent: viewport,
  );

  group('capture', () {
    test('at the start (offset zero) there is no anchor', () {
      expect(
        RailAnchor.capture(keys: old, offset: 0, itemExtent: w, padding: pad),
        isNull,
      );
    });

    test('an empty rail has no anchor', () {
      expect(
        RailAnchor.capture(keys: const [], offset: 50, itemExtent: w,
            padding: pad),
        isNull,
      );
    });

    test('records the first visible key and the intra-card offset', () {
      final a = RailAnchor.capture(
        keys: old,
        offset: at(2, 30),
        itemExtent: w,
        padding: pad,
      )!;
      expect(a.key, const ValueKey('k2'));
      expect(a.index, 2);
      expect(a.intraOffset, closeTo(30, 1e-9));
    });
  });

  group('restore', () {
    late RailAnchor a;
    setUp(() {
      a = RailAnchor.capture(
        keys: old,
        offset: at(2, 30),
        itemExtent: w,
        padding: pad,
      )!;
    });

    test('a payload-only update keeps the same offset, nothing new', () {
      final r = restore(a, old);
      expect(r.offset, closeTo(at(2, 30), 1e-9));
      expect(r.newBefore, isFalse);
    });

    test('a prepend keeps the anchor key at the same pixel, not the same '
        'numeric offset', () {
      final r = restore(a, keys(['n1', 'n0', ...old.map(_id)]));
      expect(r.offset, closeTo(at(4, 30), 1e-9));
      expect(r.newBefore, isTrue);
    });

    test('an existing entity moving to the front (a newer click) keeps the '
        'anchor and reports new activity', () {
      final r = restore(a, keys(['k5', 'k0', 'k1', 'k2', 'k3', 'k4']));
      expect(r.offset, closeTo(at(3, 30), 1e-9));
      expect(r.newBefore, isTrue);
    });

    test('an entity moving from before the anchor to after it shifts the '
        'anchor back without new activity', () {
      final r = restore(a, keys(['k0', 'k2', 'k1', 'k3', 'k4', 'k5']));
      expect(r.offset, closeTo(at(1, 30), 1e-9));
      expect(r.newBefore, isFalse);
    });

    test('a removal before the anchor shifts it back', () {
      final r = restore(a, keys(['k1', 'k2', 'k3', 'k4', 'k5']));
      expect(r.offset, closeTo(at(1, 30), 1e-9));
      expect(r.newBefore, isFalse);
    });

    test('a removed anchor is replaced by its next surviving successor at '
        'the same pixel', () {
      // (Two later arrivals keep the content long enough not to clamp.)
      final r = restore(a, keys(['k0', 'k1', 'k4', 'k5', 'x0', 'x1']));
      // k3 is gone too; k4 is the first survivor after k2, now index 2.
      expect(r.offset, closeTo(at(2, 30), 1e-9));
      expect(r.newBefore, isFalse);
    });

    test('a removed anchor with no survivor after it clamps to the end', () {
      final next = keys(['n0', 'n1', 'k0', 'k1']);
      final r = restore(a, next);
      final max = 2 * pad + next.length * w - viewport;
      expect(max, greaterThan(0));
      expect(r.offset, closeTo(max, 1e-9));
    });

    test('the restored offset never exceeds the new maximum', () {
      // Anchor k2 survives as the last of three: its pixel position would
      // overshoot the content end.
      final r = restore(a, keys(['k0', 'k1', 'k2']));
      expect(r.offset, closeTo(2 * pad + 3 * w - viewport, 1e-9));
    });

    // Review r1 nit 3: nothing of the old rail survives → the start.
    test('a full replacement restores to the start', () {
      final r = restore(a, keys(['x0', 'x1', 'x2', 'x3', 'x4', 'x5']));
      expect(r.offset, 0);
    });

    test('a rail shorter than the viewport restores to zero', () {
      expect(restore(a, keys(['k2'])).offset, 0);
      expect(restore(a, const []).offset, 0);
    });
  });
}

String _id(Key k) => (k as ValueKey<String>).value;
