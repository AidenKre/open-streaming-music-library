import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/utils/library_search_controller.dart';

/// Rows per in-page search. Capped by design (no infinite scroll in search
/// mode); kept far below 999 because hydration binds one SQL variable per
/// hit.
const kInPageSearchCap = 100;

/// Switches a browse page between its reactive browse window and capped
/// in-page search results, without the two racing:
///
/// * entering search mode suspends the window, so a DB write can't
///   `setState` the dormant list underneath the results and a scroll can't
///   re-subscribe it;
/// * leaving search mode goes through [refresh] — never a bare rebuild — so
///   the window restarts from page 1 with fresh `hasMore`;
/// * a query-parameter change ([onBrowseParamsChanged]) re-runs whichever
///   mode is showing.
///
/// Only root tabs call [initInPageSearch]; elsewhere the page stays in browse
/// mode and [onBrowseParamsChanged] is just [refresh].
mixin InPageSearchMixin<W extends ConsumerStatefulWidget, T>
    on ConsumerState<W>, CursorPaginationMixin<T> {
  LibrarySearchController? _search;

  /// The page's search controller. Only valid after [initInPageSearch].
  LibrarySearchController get search => _search!;

  /// Showing search results instead of the browse window.
  bool get isSearchMode => _search?.isActive ?? false;

  void initInPageSearch({
    required SearchType type,
    required bool Function() downloadedOnly,
  }) {
    _search = LibrarySearchController(
      repository: ref.read(browseRepositoryProvider),
      types: {type},
      limitPerType: kInPageSearchCap,
      downloadedOnly: downloadedOnly,
    )..addListener(_onSearchChanged);
  }

  void disposeInPageSearch() {
    _search?.dispose();
    _search = null;
  }

  void _onSearchChanged() {
    if (!mounted) return;
    final active = search.isActive;
    if (active && !isPaginationSuspended) {
      suspendPagination();
    } else if (!active && isPaginationSuspended) {
      refresh();
    }
    setState(() {});
  }

  /// A query parameter (a filter chip, offline mode) changed; neither the
  /// live window nor a search snapshot can observe that on its own.
  void onBrowseParamsChanged() {
    if (isSearchMode) {
      search.rerun();
    } else {
      refresh();
    }
  }

  /// A download finished or was deleted. The browse window is a live query
  /// and updates itself; search results are a snapshot and need help.
  void onDownloadStatusChanged() {
    if (isSearchMode) search.onDownloadStatusChanged();
  }
}
