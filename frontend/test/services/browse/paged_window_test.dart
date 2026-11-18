import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/browse/paged_window.dart';

/// The paging window as a model on its own (A.16): its state, when it tells
/// its listeners, and that dispose releases everything it owns. The
/// behaviour seen through a page is pinned by
/// test/ui/mixins/paging_window_characterization_test.dart.
void main() {
  late List<StreamController<List<int>>> windows;
  late List<int> limits;
  late PagedWindow<int> window;
  late int notified;
  late int restarts;

  setUp(() {
    windows = [];
    limits = [];
    notified = 0;
    restarts = 0;
    window = PagedWindow<int>(
      pageSize: 2,
      watch: ({required limit}) {
        limits.add(limit);
        final c = StreamController<List<int>>();
        windows.add(c);
        return c.stream;
      },
      beforeRestart: () => restarts++,
    )..addListener(() => notified++);
  });

  tearDown(() => window.dispose());

  int listening() => windows.where((c) => c.hasListener).length;

  testWidgets('has more: not settled until the first answer, more after a '
      'full one, settled after a short one', (tester) async {
    window.start();
    expect(window.hasMore, isTrue);
    expect(window.loadedEmpty, isFalse);
    windows.last.add([1, 2]);
    await tester.pump();
    expect(window.hasMore, isTrue);
    window.loadMore();
    windows.last.add([1, 2, 3]);
    await tester.pump(const Duration(milliseconds: 200));
    expect(window.items, [1, 2, 3]);
    expect(window.hasMore, isFalse);
    expect(window.hasTrailing, isFalse);
    window.loadMore();
    expect(limits, [2, 4], reason: 'nothing past the last page');
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('listeners are told on delivery, failure, retry and restart, '
      'not on growth or suspend', (tester) async {
    window.start();
    expect(notified, 0);
    windows.last.add([1, 2]);
    await tester.pump(const Duration(milliseconds: 200));
    expect(notified, 1, reason: 'delivery');
    window.loadMore();
    expect(notified, 1, reason: 'growth tells nobody');
    windows.last.addError(StateError('x'));
    await tester.pump();
    expect(notified, 2, reason: 'failure');
    expect(window.failed, isTrue);
    expect(window.hasMore, isFalse);
    window.loadMore();
    expect(limits, [2, 4], reason: 'a failure does not grow');
    window.retry();
    expect(notified, 3, reason: 'retry');
    expect(window.hasMore, isTrue, reason: 'loading again');
    expect(limits, [2, 4, 4]);
    window.suspend();
    expect(notified, 3, reason: 'suspend tells nobody');
    window.resume();
    expect(notified, 4, reason: 'restart clears the rows');
    expect(restarts, 1);
    expect(window.items, isEmpty);
    expect(limits.last, 2);
  });

  testWidgets('a restart tells its listeners with the state already reset',
      (tester) async {
    window.start();
    windows.last.addError(StateError('x')); // failed, nothing loaded
    await tester.pump();
    expect(window.failedEmpty, isTrue);
    final seen = <(bool, bool, bool, bool)>[];
    window.addListener(
      () => seen.add((
        window.failed,
        window.failedEmpty,
        window.isLoading,
        window.hasMore,
      )),
    );
    window.refresh();
    expect(seen, [(false, false, false, true)]);
  });

  testWidgets('dispose closes the subscription and the quiet timer; later '
      'commands do nothing; a second dispose is harmless', (tester) async {
    window.start();
    windows.last.add([1, 2]);
    await tester.pump(); // delivered; the quiet timer is armed
    windows.last.add([3, 4]); // held for the trailing edge
    await tester.pump();
    expect(listening(), 1);

    window.dispose();
    expect(listening(), 0);
    window.refresh();
    window.retry();
    window.loadMore();
    window.resume();
    window.start();
    expect(limits, [2]);
    expect(restarts, 0);
    window.dispose();
    // The binding fails the test if the quiet timer were still pending.
  });
}
