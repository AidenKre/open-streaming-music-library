import 'dart:async';

import 'package:flutter/foundation.dart';

/// Opens a reactive window of the first [limit] rows in display order.
typedef WatchWindow<T> = Stream<List<T>> Function({required int limit});

/// Where the window stands on "are there more rows?".
enum _Extent {
  /// No answer yet for the current window (after a start, a restart or a
  /// retry). Loading, not empty.
  unsettled,

  /// The last answer filled the window: more rows may follow.
  more,

  /// The last answer was short (the end of the list), or the window failed.
  /// Scrolling grows nothing from here; only a retry or a restart does.
  settled,
}

/// An infinite-scroll list's model: a *reactive* growing window. It watches
/// the first `N` rows in display order and grows `N` by [pageSize] on
/// [loadMore]. Because the window is a drift `.watch()` stream, the rows
/// re-render whenever the underlying tables change (an edit, a `/changes`
/// sync, an orphan prune, a download), with no manual refresh and without
/// losing scroll position.
///
/// Listeners are told when what a page shows changes: a restart (rows
/// cleared), a retry, a failure, and a delivered window. Growing the window
/// ([loadMore]) and suspending it change no shown state and tell nobody.
/// One subscription is open at a time; [dispose] closes it and the quiet
/// timer.
class PagedWindow<T> extends ChangeNotifier {
  PagedWindow({
    required this.pageSize,
    required WatchWindow<T> watch,
    VoidCallback? beforeRestart,
  }) : _watch = watch,
       _beforeRestart = beforeRestart;

  /// Rows the window grows by.
  final int pageSize;
  final WatchWindow<T> _watch;

  /// Called first when the window starts again from page 1 ([refresh],
  /// [resume]), before the rows are cleared: the page scrolls back to the
  /// top there.
  final VoidCallback? _beforeRestart;

  List<T> _items = [];
  _Extent _extent = _Extent.unsettled;
  bool _isLoading = false;
  bool _failed = false;
  bool _suspended = false;
  bool _disposed = false;

  /// Target size of the watched window; grows by [pageSize] on [loadMore].
  int _loadedCount = 0;
  StreamSubscription<List<T>>? _pageSub;
  Timer? _quietTimer;
  List<T>? _pendingItems;

  /// The rows of the last delivered window.
  List<T> get items => _items;

  /// More rows may follow, or the window has not answered yet.
  bool get hasMore => _extent != _Extent.settled;

  /// A grown window was asked for and has not answered yet.
  bool get isLoading => _isLoading;

  /// The window's stream failed (a local query error); pages may show a
  /// retry. Cleared by [retry], by a restart and by a later answer.
  bool get failed => _failed;

  /// The window settled with nothing in it. The one "loaded and empty"
  /// test: a failed read is unknown, never empty.
  bool get loadedEmpty =>
      !_failed && _extent == _Extent.settled && _items.isEmpty;

  /// The read failed and there is nothing to show.
  bool get failedEmpty => _failed && _items.isEmpty;

  /// A list needs a trailing slot: the load-more spinner, or the compact
  /// failure notice after a failure with rows kept.
  bool get hasTrailing => hasMore || _failed;

  /// True between [suspend] and [resume].
  bool get isSuspended => _suspended;

  /// Subscribe to the first page.
  void start() {
    if (_disposed) return;
    _loadedCount = pageSize;
    _subscribe();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pageSub?.cancel();
    _quietTimer?.cancel();
    _quietTimer = null;
    super.dispose();
  }

  /// Put the window to sleep while another view (e.g. in-page search results)
  /// replaces the list: cancels the live subscription and any held trailing
  /// emission, and makes [loadMore] and [refresh] no-ops so neither a scroll
  /// nor a parameter change can re-subscribe it. [items] are kept but
  /// dormant. Only [resume] wakes it.
  void suspend() {
    if (_disposed) return;
    _suspended = true;
    _pageSub?.cancel();
    _pageSub = null;
    _quietTimer?.cancel();
    _quietTimer = null;
    _pendingItems = null;
    _isLoading = false;
  }

  /// Grow the reactive window by one page. The stream re-emits the larger
  /// window (or the same rows if there are no more), clearing [isLoading].
  /// Nothing after a failure: only [retry] resubscribes then.
  void loadMore() {
    if (_disposed || _suspended || _isLoading || !hasMore) return;
    _isLoading = true;
    _loadedCount += pageSize;
    _subscribe();
  }

  /// Wake a suspended window. It restarts from page 1, so "has more" and the
  /// window can't be stale, and it picks up whatever the query parameters
  /// became while it slept.
  void resume() {
    if (_disposed || !_suspended) return;
    _suspended = false;
    _restart();
  }

  /// Re-subscribe from the first page. Needed when a query *parameter*
  /// changes (e.g. the Downloaded filter), which the stream can't observe on
  /// its own. Clears the current window immediately so the old parameter's
  /// rows don't linger on screen until the new stream's first emission
  /// lands.
  ///
  /// A no-op while suspended: whatever replaced the list stays in charge,
  /// and [resume] restarts with the parameters current by then.
  void refresh() {
    if (_disposed || _suspended) return;
    _restart();
  }

  void _restart() {
    _beforeRestart?.call();
    // A burst-coalescing quiet timer from before this refresh must not
    // suppress the new subscription's leading-edge delivery.
    _quietTimer?.cancel();
    _quietTimer = null;
    _items = [];
    _extent = _Extent.unsettled;
    _loadedCount = pageSize;
    _isLoading = false;
    _failed = false; // as _subscribe sets it; listeners see the new state
    notifyListeners();
    _subscribe();
  }

  void _subscribe() {
    _pageSub?.cancel();
    _pendingItems = null; // never deliver a stale window from the old query
    _failed = false;
    _pageSub = _watch(
      limit: _loadedCount,
    ).listen(_onWindowEmission, onError: _onWindowError);
  }

  /// Resubscribes at the current window after a failure.
  void retry() {
    if (_disposed || _suspended) return;
    _failed = false;
    _extent = _Extent.unsettled; // loading again: not "empty" until it answers
    notifyListeners();
    _subscribe();
  }

  void _onWindowError(Object error, StackTrace stack) {
    // Only the type: an error's text can carry paths or SQL.
    debugPrint('pagination failed: ${error.runtimeType}');
    _failed = true;
    _extent = _Extent.settled;
    _isLoading = false;
    notifyListeners();
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
    _items = items;
    _failed = false;
    _extent = items.length == _loadedCount ? _Extent.more : _Extent.settled;
    _isLoading = false;
    notifyListeners();
  }
}
