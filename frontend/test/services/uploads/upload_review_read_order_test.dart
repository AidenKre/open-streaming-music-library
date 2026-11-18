// ReviewReadOrder (spec §7 para 4): reads of review items may land out of
// order. The newest-started read of an item wins, whichever kind it is (a
// re-read of one item or a snapshot of the batch); one counter serves both,
// and the snapshot's own order is kept apart from each item's.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/uploads/upload_review_rules.dart';

void main() {
  test('every read started gets a newer ticket than the one before', () {
    final order = ReviewReadOrder();
    final first = order.begin();
    final second = order.begin();
    final third = order.begin();
    expect(second, greaterThan(first));
    expect(third, greaterThan(second));
  });

  test('an item takes a newer read and refuses the same or an older one',
      () {
    final order = ReviewReadOrder();
    final older = order.begin();
    final newer = order.begin();

    expect(order.accept('i-1', newer), isTrue);
    expect(order.accept('i-1', newer), isFalse, reason: 'the same ticket');
    expect(order.accept('i-1', older), isFalse, reason: 'landing late');

    final newest = order.begin();
    expect(order.accept('i-1', newest), isTrue);
  });

  test('each item keeps its own order', () {
    final order = ReviewReadOrder();
    final older = order.begin();
    final newer = order.begin();

    expect(order.accept('i-1', newer), isTrue);
    // An older ticket is still the newest one for another item.
    expect(order.accept('i-2', older), isTrue);
    expect(order.accept('i-2', older), isFalse);
    expect(order.accept('i-1', older), isFalse);
  });

  test('a snapshot is taken only when newer than the last one taken', () {
    final order = ReviewReadOrder();
    final older = order.begin();
    final newer = order.begin();

    expect(order.acceptSnapshot(newer), isTrue);
    expect(order.acceptSnapshot(newer), isFalse, reason: 'the same ticket');
    expect(order.acceptSnapshot(older), isFalse, reason: 'landing late');
    expect(order.acceptSnapshot(order.begin()), isTrue);
  });

  test('an older snapshot landing after a newer item read keeps the batch '
      "but not that item's state", () {
    final order = ReviewReadOrder();
    final snapshot = order.begin();
    final reread = order.begin();

    expect(order.accept('i-1', reread), isTrue);
    // The snapshot is still the newest snapshot: its membership is taken.
    expect(order.acceptSnapshot(snapshot), isTrue);
    // Its copy of the re-read item is older than the re-read.
    expect(order.accept('i-1', snapshot), isFalse);
    // Its copy of any other item is the newest read of that item.
    expect(order.accept('i-2', snapshot), isTrue);
  });
}
