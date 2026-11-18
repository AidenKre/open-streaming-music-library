import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Where a restored rail lands.
@immutable
class RailRestore {
  const RailRestore({required this.offset, required this.newBefore});

  final double offset;
  final bool newBefore;
}

/// The first visible entity of a horizontally scrolled rail.
@immutable
class RailAnchor {
  const RailAnchor({
    required this.key,
    required this.index,
    required this.intraOffset,
  });

  final Key key;
  final int index;
  final double intraOffset;

  /// Captures the first visible item, or null at the start or when empty.
  static RailAnchor? capture({
    required List<Key> keys,
    required double offset,
    required double itemExtent,
    required double padding,
  }) {
    if (offset <= 0 || keys.isEmpty) return null;
    final index = ((offset - padding) / itemExtent).floor().clamp(
      0,
      keys.length - 1,
    );
    return RailAnchor(
      key: keys[index],
      index: index,
      intraOffset: offset - padding - index * itemExtent,
    );
  }

  /// The offset that keeps this anchor (or its first surviving successor) at
  /// the same pixel, clamped to the new content. [RailRestore.newBefore] is
  /// true when something not previously before the anchor now precedes it.
  RailRestore restore({
    required List<Key> oldKeys,
    required List<Key> newKeys,
    required double itemExtent,
    required double padding,
    required double viewportExtent,
  }) {
    final max = math.max(
      0.0,
      2 * padding + newKeys.length * itemExtent - viewportExtent,
    );
    // A full replacement: nothing the user saw survives, so start over.
    final kept = newKeys.toSet();
    if (!oldKeys.any(kept.contains)) {
      return const RailRestore(offset: 0, newBefore: false);
    }
    var newIndex = newKeys.indexOf(key);
    if (newIndex < 0) {
      for (var i = index + 1; i < oldKeys.length && newIndex < 0; i++) {
        newIndex = newKeys.indexOf(oldKeys[i]);
      }
    }
    if (newIndex < 0) return RailRestore(offset: max, newBefore: false);
    final before = oldKeys.take(index).toSet();
    return RailRestore(
      offset: (padding + newIndex * itemExtent + intraOffset).clamp(0.0, max),
      newBefore: newKeys.take(newIndex).any((k) => !before.contains(k)),
    );
  }
}
