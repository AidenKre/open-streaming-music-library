import 'dart:async';

import 'package:flutter/material.dart';

mixin CursorPaginationMixin<T> {
  bool get mounted;
  void setState(VoidCallback fn);

  int get pageSize;
  ScrollController get scrollController;

  Future<List<T>> loadPage({required bool useCursor});
  Stream<int> watchItemCount({required bool useCursor});

  List<T> paginatedItems = [];
  bool hasMore = true;
  bool isLoading = false;
  int newItemCount = 0;
  StreamSubscription<int>? _paginationWatchSub;

  /// Bumped by [refresh] whenever the underlying filter changes (e.g. an
  /// offline-mode toggle flips the downloaded-only filter). Each [loadMore]
  /// captures the generation at its start; a load that resolves after the
  /// generation has moved on is stale and its results are discarded.
  int _generation = 0;

  void initPagination() {
    scrollController.addListener(_onScroll);
    loadMore();
  }

  void disposePagination() {
    _paginationWatchSub?.cancel();
  }

  void _onScroll() {
    if (scrollController.position.pixels >=
        scrollController.position.maxScrollExtent - 200) {
      loadMore();
    }
  }

  Future<void> loadMore() async {
    if (isLoading || !hasMore) return;
    isLoading = true;
    final generation = _generation;

    final items = await loadPage(useCursor: paginatedItems.isNotEmpty);

    if (!mounted) return;
    // A refresh() ran while this load was in flight: it cleared state and
    // started its own load. Discard these now-stale results, and leave
    // isLoading alone — the current generation's load owns that flag.
    if (generation != _generation) return;
    setState(() {
      paginatedItems.addAll(items);
      hasMore = items.length == pageSize;
      isLoading = false;
    });
    _startWatching();
  }

  void _startWatching() {
    _paginationWatchSub?.cancel();
    final useCursor = hasMore && paginatedItems.isNotEmpty;
    _paginationWatchSub = watchItemCount(useCursor: useCursor).listen((count) {
      if (!mounted) return;
      final diff = count - paginatedItems.length;
      if (diff != newItemCount) {
        setState(() => newItemCount = diff > 0 ? diff : 0);
      }
    });
  }

  void refresh() {
    _paginationWatchSub?.cancel();
    // Invalidate any in-flight loadMore() and release the isLoading lock it
    // holds, so the reload below is not skipped by loadMore()'s guard.
    _generation++;
    isLoading = false;
    setState(() {
      paginatedItems = [];
      hasMore = true;
      newItemCount = 0;
    });
    loadMore();
  }

  Widget buildNewItemsBanner(String itemName) {
    if (newItemCount <= 0) return const SizedBox.shrink();
    return MaterialBanner(
      content: Text('$newItemCount new $itemName available'),
      actions: [
        TextButton(onPressed: refresh, child: const Text('Refresh')),
      ],
    );
  }
}
