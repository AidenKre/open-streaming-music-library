import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';

/// Minimal host that mixes in [CursorPaginationMixin] so the reactive window can
/// be driven directly, without a full ConsumerState/widget tree.
class _Host with CursorPaginationMixin<int> {
  _Host(this._watchPage);

  final Stream<List<int>> Function({required int limit}) _watchPage;

  @override
  bool mounted = true;

  @override
  final ScrollController scrollController = ScrollController();

  @override
  int get pageSize => 2;

  @override
  void setState(VoidCallback fn) => fn();

  @override
  Stream<List<int>> watchPage({required int limit}) =>
      _watchPage(limit: limit);
}

/// Waits past the mixin's 150ms coalescing quiet window so a trailing-edge
/// delivery (an emission that landed mid-burst) has flushed.
Future<void> _pump() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  test('reactive window re-emits update the list with no refresh', () async {
    final controller = StreamController<List<int>>.broadcast();
    addTearDown(controller.close);
    final host = _Host(
      ({required limit}) =>
          controller.stream.map((all) => all.take(limit).toList()),
    );
    addTearDown(host.disposePagination);
    addTearDown(host.scrollController.dispose);

    host.initPagination(); // subscribes with limit == pageSize (2)
    controller.add([1, 2]);
    await _pump();
    expect(host.paginatedItems, [1, 2]);
    expect(host.hasMore, isTrue);

    // An underlying edit changes a row; the stream re-emits and the list
    // updates on its own — the core fix (no loadMore/refresh called).
    controller.add([1, 20]);
    await _pump();
    expect(host.paginatedItems, [1, 20]);
  });

  test('loadMore grows the watched window by one page', () async {
    final controller = StreamController<List<int>>.broadcast();
    addTearDown(controller.close);
    final host = _Host(
      ({required limit}) =>
          controller.stream.map((all) => all.take(limit).toList()),
    );
    addTearDown(host.disposePagination);
    addTearDown(host.scrollController.dispose);

    host.initPagination();
    controller.add([1, 2]);
    await _pump();

    host.loadMore(); // limit -> 4, re-subscribes
    controller.add([1, 2, 3, 4, 5]);
    await _pump();
    expect(host.paginatedItems, [1, 2, 3, 4]); // window of 4
    expect(host.hasMore, isTrue); // full window → maybe more
    expect(host.isLoading, isFalse);
  });

  test('a write burst coalesces into one rebuild on the latest window',
      () async {
    final controller = StreamController<List<int>>.broadcast();
    addTearDown(controller.close);
    final host = _Host(
      ({required limit}) =>
          controller.stream.map((all) => all.take(limit).toList()),
    );
    addTearDown(host.disposePagination);
    addTearDown(host.scrollController.dispose);

    host.initPagination();
    controller.add([1, 2]);
    await Future<void>.delayed(Duration.zero);
    // Leading edge: the first emission renders immediately.
    expect(host.paginatedItems, [1, 2]);

    // Burst inside the quiet window (a paging sync re-firing the query):
    // intermediate windows are held, not rendered...
    controller.add([9, 2]);
    controller.add([9, 9]);
    await Future<void>.delayed(Duration.zero);
    expect(host.paginatedItems, [1, 2]);

    // ...and the trailing edge lands exactly on the latest rows.
    await _pump();
    expect(host.paginatedItems, [9, 9]);
  });

  test('refresh resets the window to the first page', () async {
    final controller = StreamController<List<int>>.broadcast();
    addTearDown(controller.close);
    final host = _Host(
      ({required limit}) =>
          controller.stream.map((all) => all.take(limit).toList()),
    );
    addTearDown(host.disposePagination);
    addTearDown(host.scrollController.dispose);

    host.initPagination();
    controller.add([1, 2]);
    await _pump();
    host.loadMore();
    controller.add([1, 2, 3, 4]);
    await _pump();
    expect(host.paginatedItems, hasLength(4));

    host.refresh(); // window back to pageSize (2)
    controller.add([1, 2, 3, 4]);
    await _pump();
    expect(host.paginatedItems, [1, 2]);
  });
}
