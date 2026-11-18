import 'dart:async';

import 'package:flutter/material.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';

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

  /// The window's stream failed (a local query error); pages may show a
  /// retry. Cleared by [retryPagination] and by a restart.
  bool paginationFailed = false;

  /// The window settled with nothing in it. The one "loaded and empty"
  /// test: a failed read is unknown, never empty.
  bool get paginationLoadedEmpty =>
      !paginationFailed && !hasMore && paginatedItems.isEmpty;

  /// The read failed and there is nothing to show: pages put
  /// [buildPaginationFailure] in place of the list, before any empty state.
  bool get paginationFailedEmpty => paginationFailed && paginatedItems.isEmpty;

  Widget buildPaginationFailure() =>
      LoadFailureNotice(onRetry: retryPagination);

  /// Whether a list needs a trailing slot: the load-more spinner, or the
  /// compact failure notice after a failure with rows kept.
  bool get paginationHasTrailing => hasMore || paginationFailed;

  /// The trailing slot's content (see [paginationHasTrailing]).
  Widget buildPaginationTrailing() => paginationFailed
      ? LoadFailureNotice(onRetry: retryPagination, compact: true)
      : const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        );

  /// Target size of the watched window; grows by [pageSize] on [loadMore].
  int _loadedCount = 0;
  StreamSubscription<List<T>>? _pageSub;
  Timer? _quietTimer;
  List<T>? _pendingItems;

  void initPagination() {
    scrollController.addListener(_onScroll);
    _loadedCount = pageSize;
    _subscribe();
  }

  void disposePagination() {
    _pageSub?.cancel();
    _quietTimer?.cancel();
    _quietTimer = null;
  }

  bool _suspended = false;

  /// True between [suspendPagination] and [resumePagination].
  bool get isPaginationSuspended => _suspended;

  /// Put the window to sleep while another view (e.g. in-page search results)
  /// replaces the list: cancels the live subscription and any held trailing
  /// emission, and makes [loadMore] and [refresh] no-ops so neither a scroll
  /// nor a parameter change can re-subscribe it. [paginatedItems] are kept
  /// but dormant. Only [resumePagination] wakes it.
  void suspendPagination() {
    _suspended = true;
    _pageSub?.cancel();
    _pageSub = null;
    _quietTimer?.cancel();
    _quietTimer = null;
    _pendingItems = null;
    isLoading = false;
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
    if (_suspended || isLoading || !hasMore) return;
    isLoading = true;
    _loadedCount += pageSize;
    _subscribe();
  }

  /// Wake a suspended window. It restarts from page 1 at the top, so
  /// `hasMore`/the window can't be stale, and it picks up whatever the query
  /// parameters became while it slept.
  void resumePagination() {
    if (!_suspended) return;
    _suspended = false;
    _restart();
  }

  /// Re-subscribe from the first page, at the top. Needed when a query
  /// *parameter* changes (e.g. the Downloaded filter), which the stream can't
  /// observe on its own. Clears the current window immediately so the old
  /// parameter's rows don't linger on screen until the new stream's first
  /// emission lands.
  ///
  /// A no-op while suspended: whatever replaced the list stays in charge,
  /// and [resumePagination] restarts with the parameters current by then.
  void refresh() {
    if (_suspended) return;
    _restart();
  }

  void _restart() {
    // Back to the top. Otherwise a narrower first page clamps a deep offset
    // to its bottom, which fires no scroll notification, stranding the user
    // at a load-more spinner that never loads.
    if (scrollController.hasClients &&
        scrollController.position.hasPixels &&
        scrollController.offset != 0) {
      scrollController.jumpTo(0);
    }
    // A burst-coalescing quiet timer from before this refresh must not
    // suppress the new subscription's leading-edge delivery.
    _quietTimer?.cancel();
    _quietTimer = null;
    if (mounted) {
      setState(() {
        paginatedItems = [];
        hasMore = true;
      });
    }
    _loadedCount = pageSize;
    isLoading = false;
    _subscribe();
  }

  void _subscribe() {
    _pageSub?.cancel();
    _pendingItems = null; // never deliver a stale window from the old query
    paginationFailed = false;
    _pageSub = watchPage(
      limit: _loadedCount,
    ).listen(_onWindowEmission, onError: _onWindowError);
  }

  /// Resubscribes at the current window after a failure.
  void retryPagination() {
    if (_suspended) return;
    if (mounted) {
      setState(() {
        paginationFailed = false;
        hasMore = true; // loading again: not "empty" until the window answers
      });
    }
    _subscribe();
  }

  void _onWindowError(Object error, StackTrace stack) {
    // Only the type: an error's text can carry paths or SQL.
    debugPrint('pagination failed: ${error.runtimeType}');
    if (!mounted) return;
    setState(() {
      paginationFailed = true;
      hasMore = false;
      isLoading = false;
    });
  }

  /// Leading + trailing coalescing: the first emission renders immediately;
  /// a burst of table writes (a paging `/changes` sync upserting hundreds of
  /// rows re-fires the window query per batch) collapses into at most one
  /// extra rebuild per quiet window, always ending on the latest rows.
  void _onWindowEmission(List<T> items) {
    if (_quietTimer != null) {
      _pendingItems = items;
      return;
    }
    _deliver(items);
    _quietTimer = Timer(const Duration(milliseconds: 150), () {
      _quietTimer = null;
      final pending = _pendingItems;
      _pendingItems = null;
      if (pending != null) _onWindowEmission(pending);
    });
  }

  void _deliver(List<T> items) {
    if (!mounted) return;
    setState(() {
      paginatedItems = items;
      paginationFailed = false;
      hasMore = items.length == _loadedCount;
      isLoading = false;
    });
  }
}
