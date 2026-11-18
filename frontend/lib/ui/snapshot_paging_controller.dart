import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:frontend/repositories/history_snapshot.dart';

/// The lifecycle shared by the two "See all" pages (the statistics ranking
/// and Recently played; SC-10): keyset pages of one history snapshot, one
/// request at a time, a freshness watch on the snapshot, Retry for a failed
/// request, and a new snapshot on Refresh.
///
/// * Every new snapshot (Refresh) and dispose bump a generation; a capture,
///   page or freshness value of an older one is ignored.
/// * The freshness watch starts as soon as the snapshot's token is known:
///   before page 1 is read when the token comes first (entry; Recently
///   played's Refresh), or before page 1 is shown when the capture reads
///   both in one transaction (the ranking's Refresh). A change during the
///   first load thus shows the notice (the owner's answer of 2026-11-17).
/// * An expired page stops paging and keeps what is loaded; its notice says
///   history changed and no later freshness value undoes it.
/// * A failure keeps what is loaded; [retry] repeats the failed request once.
///   Nothing runs after the page was closed ([dispose]), Retry included.
///
/// A subclass reads pages ([fetchPage]), captures snapshots
/// ([captureSnapshot]), watches freshness ([watchFreshness]) and keeps its
/// rows ([onPage], [onExpired], [resetRows], [cancelLoaded], [onDispose]).
abstract class SnapshotPagingController<R, K> extends ChangeNotifier {
  int _generation = 0;
  bool _disposed = false;
  HistorySnapshotToken? _token;
  StreamSubscription<SnapshotStaleness>? _freshness;
  K? _cursor;
  bool _hasMore = false;
  bool _failed = false;
  bool _inFlight = false;
  bool _expired = false;
  SnapshotStaleness _notice = SnapshotStaleness.fresh;
  void Function()? _retry;

  /// Another page can be loaded.
  bool get hasMore => _hasMore;

  /// The last request failed; [retry] repeats it.
  bool get failed => _failed;

  /// The snapshot changed under the list: paging stopped.
  bool get expired => _expired;

  /// Which notice to show: [SnapshotStaleness.fresh] shows none.
  SnapshotStaleness get notice => _notice;

  /// Bumped for every new snapshot; the view resets its scroll position.
  int get snapshotEpoch => _generation;

  /// Reads one page of [token] after [after] (null: page 1).
  @protected
  Future<SnapshotPageResult<R, K>> fetchPage(
    HistorySnapshotToken token,
    K? after,
  );

  /// Captures a new snapshot. A pager that reads page 1 in the capture's
  /// transaction returns it as the second value; null means "not read",
  /// and page 1 is then loaded with [fetchPage].
  @protected
  Future<(HistorySnapshotToken, SnapshotPageResult<R, K>?)> captureSnapshot();

  /// Watches [token] for changes.
  @protected
  Stream<SnapshotStaleness> watchFreshness(HistorySnapshotToken token);

  /// Takes a loaded page's [rows] (appended after what is loaded) of
  /// [token], read for [generation].
  @protected
  void onPage(List<R> rows, int generation, HistorySnapshotToken token);

  /// The page of the snapshot expired: keep what is loaded (none loaded:
  /// an empty list, not "loading").
  @protected
  void onExpired();

  /// A new snapshot starts: forget the loaded rows.
  @protected
  void resetRows();

  /// Stops watching the loaded rows.
  @protected
  void cancelLoaded();

  /// Releases the subclass's own resources when the page closes (after the
  /// watches are cancelled), once.
  @protected
  void onDispose() {}

  /// Whether a continuation of [generation] must be dropped.
  @protected
  bool isStale(int generation) => _disposed || generation != _generation;

  /// Starts on a snapshot captured elsewhere (page 1 of [token]).
  @protected
  void startOn(HistorySnapshotToken token) {
    _token = token;
    _startFreshness(_generation, token);
    _loadPage(_generation, token, null);
  }

  /// Loads the next page (no-op while one is in flight, after a failure or
  /// expiry, when none is left, or after the page was closed).
  void loadMore() {
    final token = _token;
    if (token == null ||
        !_hasMore ||
        _inFlight ||
        _failed ||
        _expired ||
        _disposed) {
      return;
    }
    _loadPage(_generation, token, _cursor);
  }

  /// Repeats the failed request once; nothing after the page was closed.
  void retry() {
    final again = _retry;
    if (_disposed || !_failed || again == null) return;
    _failed = false;
    _retry = null;
    notifyListeners();
    again();
  }

  /// Captures a new snapshot and starts at page 1.
  void refresh() {
    if (_disposed) return;
    final generation = ++_generation;
    _cancelLive();
    _token = null;
    resetRows();
    _cursor = null;
    _hasMore = false;
    _failed = false;
    _expired = false;
    _inFlight = false;
    _notice = SnapshotStaleness.fresh;
    _retry = null;
    notifyListeners();
    _capture(generation);
  }

  void _capture(int generation) {
    _inFlight = true;
    captureSnapshot().then(
      (captured) {
        if (isStale(generation)) return;
        final (token, first) = captured;
        _token = token;
        _startFreshness(generation, token);
        if (first == null) {
          _loadPage(generation, token, null);
        } else {
          _show(generation, token, first);
        }
      },
      onError: (Object _) {
        if (isStale(generation)) return;
        _fail(() => _capture(generation));
      },
    );
  }

  void _loadPage(int generation, HistorySnapshotToken token, K? after) {
    _inFlight = true;
    fetchPage(token, after).then(
      (result) {
        if (isStale(generation)) return;
        _show(generation, token, result);
      },
      onError: (Object _) {
        if (isStale(generation)) return;
        _fail(() => _loadPage(generation, token, after));
      },
    );
  }

  void _show(
    int generation,
    HistorySnapshotToken token,
    SnapshotPageResult<R, K> result,
  ) {
    _inFlight = false;
    switch (result) {
      case SnapshotPage(:final items, :final nextCursor, :final hasMore):
        _cursor = nextCursor;
        _hasMore = hasMore;
        onPage(items, generation, token);
      case SnapshotExpired():
        _hasMore = false;
        _expired = true;
        _notice = SnapshotStaleness.historyChanged;
        onExpired();
    }
    notifyListeners();
  }

  void _startFreshness(int generation, HistorySnapshotToken token) {
    if (_freshness != null) return;
    _freshness = watchFreshness(token).listen(
      (value) {
        if (isStale(generation) || _expired || value == _notice) return;
        _notice = value;
        notifyListeners();
      },
      // A failed freshness check leaves the notice as it was.
      onError: (Object _) {},
    );
  }

  void _fail(void Function() again) {
    _inFlight = false;
    _failed = true;
    _retry = again;
    notifyListeners();
  }

  void _cancelLive() {
    cancelLoaded();
    _freshness?.cancel();
    _freshness = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _cancelLive();
    onDispose();
    super.dispose();
  }
}
