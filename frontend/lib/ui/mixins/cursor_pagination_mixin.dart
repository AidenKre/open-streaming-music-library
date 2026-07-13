import 'dart:async';

import 'package:flutter/material.dart';

/// Drives an infinite-scroll list off a *reactive* growing window: it watches
/// the first `N` rows in display order and grows `N` by [pageSize] as the user
/// scrolls. Because the window is a drift `.watch()` stream, the list re-renders
/// itself whenever the underlying tables change (an edit, a `/changes` sync, an
/// orphan prune, a download), with no manual refresh and without losing scroll
/// position.
mixin CursorPaginationMixin<T> {
  bool get mounted;
  void setState(VoidCallback fn);

  int get pageSize;
  ScrollController get scrollController;

  /// A reactive window of the first [limit] rows in display order.
  Stream<List<T>> watchPage({required int limit});

  List<T> paginatedItems = [];
  bool hasMore = true;
  bool isLoading = false;

  /// Target size of the watched window; grows by [pageSize] on [loadMore].
  int _loadedCount = 0;
  StreamSubscription<List<T>>? _pageSub;

  void initPagination() {
    scrollController.addListener(_onScroll);
    _loadedCount = pageSize;
    _subscribe();
  }

  void disposePagination() {
    _pageSub?.cancel();
  }

  void _onScroll() {
    if (scrollController.position.pixels >=
        scrollController.position.maxScrollExtent - 200) {
      loadMore();
    }
  }

  /// Grow the reactive window by one page. The stream re-emits the larger window
  /// (or the same rows if there are no more), clearing [isLoading].
  void loadMore() {
    if (isLoading || !hasMore) return;
    isLoading = true;
    _loadedCount += pageSize;
    _subscribe();
  }

  /// Re-subscribe from the first page. Needed when a query *parameter* changes
  /// (e.g. the offline → downloaded-only filter), which the stream can't observe
  /// on its own.
  void refresh() {
    _loadedCount = pageSize;
    isLoading = false;
    _subscribe();
  }

  void _subscribe() {
    _pageSub?.cancel();
    _pageSub = watchPage(limit: _loadedCount).listen((items) {
      if (!mounted) return;
      setState(() {
        paginatedItems = items;
        hasMore = items.length == _loadedCount;
        isLoading = false;
      });
    });
  }

}
