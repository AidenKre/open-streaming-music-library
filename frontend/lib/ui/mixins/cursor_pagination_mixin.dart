import 'package:flutter/material.dart';
import 'package:frontend/services/browse/paged_window.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';

/// Shows an infinite-scroll list over a [PagedWindow] (the model: a reactive
/// growing window of the first `N` rows in display order, see there). The
/// mixin connects it to the page: it rebuilds the page when the window says
/// what it shows changed, grows the window when the list is scrolled near
/// its end, scrolls back to the top when the window starts again from page
/// 1, and builds the two failure notices and the trailing loader.
mixin CursorPaginationMixin<T> {
  bool get mounted;
  void setState(VoidCallback fn);

  int get pageSize;
  ScrollController get scrollController;

  /// A reactive window of the first [limit] rows in display order.
  Stream<List<T>> watchPage({required int limit});

  late final PagedWindow<T> _window = PagedWindow<T>(
    pageSize: pageSize,
    watch: watchPage,
    beforeRestart: _scrollToTop,
  );

  List<T> get paginatedItems => _window.items;
  bool get hasMore => _window.hasMore;
  bool get isLoading => _window.isLoading;

  /// The window's stream failed (a local query error); pages may show a
  /// retry. Cleared by [retryPagination] and by a restart.
  bool get paginationFailed => _window.failed;

  /// The window settled with nothing in it. The one "loaded and empty"
  /// test: a failed read is unknown, never empty.
  bool get paginationLoadedEmpty => _window.loadedEmpty;

  /// The read failed and there is nothing to show: pages put
  /// [buildPaginationFailure] in place of the list, before any empty state.
  bool get paginationFailedEmpty => _window.failedEmpty;

  Widget buildPaginationFailure() =>
      LoadFailureNotice(onRetry: retryPagination);

  /// Whether a list needs a trailing slot: the load-more spinner, or the
  /// compact failure notice after a failure with rows kept.
  bool get paginationHasTrailing => _window.hasTrailing;

  /// The trailing slot's content (see [paginationHasTrailing]).
  Widget buildPaginationTrailing() => paginationFailed
      ? LoadFailureNotice(onRetry: retryPagination, compact: true)
      : const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        );

  void initPagination() {
    _window.addListener(_onWindowChanged);
    scrollController.addListener(_onScroll);
    _window.start();
  }

  /// Closes the window's subscription and timer and stops listening to it.
  void disposePagination() {
    _window
      ..removeListener(_onWindowChanged)
      ..dispose();
  }

  /// True between [suspendPagination] and [resumePagination].
  bool get isPaginationSuspended => _window.isSuspended;

  /// Put the window to sleep while another view (e.g. in-page search
  /// results) replaces the list (see [PagedWindow.suspend]). Only
  /// [resumePagination] wakes it.
  void suspendPagination() => _window.suspend();

  void _onWindowChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (scrollController.position.pixels >=
        scrollController.position.maxScrollExtent - 200) {
      loadMore();
    }
  }

  /// Grow the reactive window by one page (see [PagedWindow.loadMore]).
  void loadMore() => _window.loadMore();

  /// Wake a suspended window. It restarts from page 1 at the top.
  void resumePagination() => _window.resume();

  /// Re-subscribe from the first page, at the top (see
  /// [PagedWindow.refresh]). A no-op while suspended.
  void refresh() => _window.refresh();

  /// Resubscribes at the current window after a failure.
  void retryPagination() => _window.retry();

  /// Back to the top when the window starts again from page 1. Otherwise a
  /// narrower first page clamps a deep offset to its bottom, which fires no
  /// scroll notification, stranding the user at a load-more spinner that
  /// never loads.
  void _scrollToTop() {
    if (scrollController.hasClients &&
        scrollController.position.hasPixels &&
        scrollController.offset != 0) {
      scrollController.jumpTo(0);
    }
  }
}
