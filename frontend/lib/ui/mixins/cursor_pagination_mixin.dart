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

    final items = await loadPage(useCursor: paginatedItems.isNotEmpty);

    if (!mounted) return;
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
