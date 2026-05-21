import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';

/// Minimal host that mixes in [CursorPaginationMixin] so the mixin can be
/// driven directly, without standing up a full ConsumerState/widget tree.
class _Host with CursorPaginationMixin<int> {
  _Host(this._loadPage);

  final Future<List<int>> Function({required bool useCursor}) _loadPage;

  @override
  bool mounted = true;

  @override
  final ScrollController scrollController = ScrollController();

  @override
  int get pageSize => 50;

  @override
  void setState(VoidCallback fn) => fn();

  @override
  Future<List<int>> loadPage({required bool useCursor}) =>
      _loadPage(useCursor: useCursor);

  @override
  Stream<int> watchItemCount({required bool useCursor}) =>
      const Stream<int>.empty();
}

void main() {
  test('a load that completes after refresh() is discarded', () async {
    final completers = <Completer<List<int>>>[];
    final host = _Host(({required useCursor}) {
      final c = Completer<List<int>>();
      completers.add(c);
      return c.future;
    });
    addTearDown(host.disposePagination);
    addTearDown(host.scrollController.dispose);

    // Generation-0 load starts (e.g. an online, all-content page).
    final firstLoad = host.loadMore();
    expect(completers, hasLength(1));

    // A refresh runs while load 0 is still in flight — e.g. offline mode
    // toggled, flipping the filter to downloaded-only (generation → 1).
    host.refresh();
    expect(completers, hasLength(2));

    // The stale generation-0 load resolves with old-filter data.
    completers[0].complete([1, 2, 3]);
    await firstLoad;
    expect(host.paginatedItems, isEmpty,
        reason: 'stale load must not append into the refreshed list');

    // The generation-1 load resolves with the new-filter data.
    completers[1].complete([9, 8, 7]);
    await Future<void>.delayed(Duration.zero);
    expect(host.paginatedItems, [9, 8, 7]);
  });

  test('refresh() during an in-flight load still starts a fresh load', () async {
    final completers = <Completer<List<int>>>[];
    final host = _Host(({required useCursor}) {
      final c = Completer<List<int>>();
      completers.add(c);
      return c.future;
    });
    addTearDown(host.disposePagination);
    addTearDown(host.scrollController.dispose);

    host.loadMore(); // generation 0 — isLoading is now true
    expect(host.isLoading, isTrue);

    host.refresh();
    expect(completers, hasLength(2),
        reason: 'refresh must not be skipped by the isLoading guard');

    completers[1].complete([5, 6]);
    await Future<void>.delayed(Duration.zero);
    expect(host.paginatedItems, [5, 6]);
  });
}
