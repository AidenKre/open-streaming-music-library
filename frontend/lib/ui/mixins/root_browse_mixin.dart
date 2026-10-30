import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/utils/library_search_controller.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/library_search_field.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';
import 'package:frontend/ui/widgets/search_status.dart';

/// Rows per in-page search. Capped by design (no infinite scroll in search
/// mode); kept far below 999 because hydration binds one SQL variable per
/// hit.
const kInPageSearchCap = 100;

/// The browse controls of a root tab — a search field, the filter chips, and
/// all of their wiring — so every root browse page gets the same, race-free
/// behaviour from one copy. A page supplies only its `watchPage` query (which
/// reads [filters]) and its row builder.
///
/// * Filters are per page and session-only. Offline switches Downloaded on
///   and reconnecting undoes only that (see [BrowseFilters]).
/// * Entering search mode suspends the browse window, so a DB write can't
///   `setState` the dormant list underneath the results and neither a scroll
///   nor a [refresh] can re-subscribe it.
/// * Leaving search mode resumes the window from page 1 at the top, with
///   fresh `hasMore` and the filters current by then.
/// * A filter change re-runs whichever mode is showing.
///
/// Only root tabs call [initRootBrowse]. Without it the page has no controls
/// and stays in browse mode; [listenForBrowseChanges] then only re-fetches
/// on an offline flip if the page asks to.
mixin RootBrowseMixin<W extends ConsumerStatefulWidget, T>
    on ConsumerState<W>, CursorPaginationMixin<T> {
  LibrarySearchController? _search;
  BrowseFilters _filters = const BrowseFilters();

  /// Whether this page shows the controls ([initRootBrowse] ran).
  bool get hasBrowseControls => _search != null;

  /// The page's search controller. Only valid after [initRootBrowse].
  LibrarySearchController get search => _search!;

  /// The chip selection. Always the default without controls.
  BrowseFilters get filters => _filters;

  /// Showing search results instead of the browse window.
  bool get isSearchMode => _search?.isActive ?? false;

  /// Call from `initState`, before `initPagination` (the first page reads
  /// [filters]).
  void initRootBrowse({required SearchType type}) {
    _filters = BrowseFilters.initial(isOffline: ref.read(offlineModeProvider));
    _search = LibrarySearchController(
      repository: ref.read(browseRepositoryProvider),
      types: {type},
      limitPerType: kInPageSearchCap,
      downloadedOnly: () => _filters.downloaded,
    )..addListener(_onSearchChanged);
  }

  void disposeRootBrowse() {
    _search?.dispose();
    _search = null;
  }

  /// Call at the top of `build`. Routes offline flips and download events to
  /// the mode on screen. [refreshOnOfflineChange] is for a page without
  /// controls whose query reads the offline flag itself.
  void listenForBrowseChanges({bool refreshOnOfflineChange = false}) {
    ref.listen<bool>(offlineModeProvider, (prev, next) {
      if (prev == next) return;
      if (hasBrowseControls) {
        onFiltersChanged(next ? _filters.wentOffline() : _filters.cameOnline());
      } else if (refreshOnOfflineChange) {
        refresh();
      }
    });
    // The browse window is a live query and updates itself; search results
    // are a snapshot and need help.
    ref.listen(downloadStatusVersionProvider, (_, _) {
      if (isSearchMode) search.onDownloadStatusChanged();
    });
  }

  /// The chips changed (a tap or an offline flip). Neither the live window
  /// nor a search snapshot can observe that on its own, so re-run whichever
  /// is showing.
  void onFiltersChanged(BrowseFilters next) {
    if (next == _filters) return;
    setState(() => _filters = next);
    if (isSearchMode) {
      search.rerun();
    } else {
      refresh();
    }
  }

  void _onSearchChanged() {
    if (!mounted) return;
    final active = search.isActive;
    if (active && !isPaginationSuspended) {
      suspendPagination();
    } else if (!active && isPaginationSuspended) {
      resumePagination();
    }
    setState(() {});
  }

  /// The filtered browse window settled with nothing in it, so the page
  /// should say why instead of showing a blank list.
  bool get showDownloadedEmpty =>
      hasBrowseControls &&
      _filters.downloaded &&
      !hasMore &&
      paginatedItems.isEmpty;

  /// The search field and chip bar, shown above the list.
  Widget buildBrowseHeader({required String hintText}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: LibrarySearchField(
            hintText: hintText,
            onChanged: search.onQueryChanged,
            onSubmitted: search.submit,
            onCleared: search.clear,
          ),
        ),
        FilterBar(filters: _filters, onChanged: onFiltersChanged),
      ],
    );
  }

  /// Search mode's body: a spinner until the first results land, the
  /// no-match or failure copy, or [builder]'s list under the capped hint.
  /// [noun] names the rows in the copy ("tracks").
  Widget buildSearchBody<R>({
    required List<R> results,
    required String noun,
    required Widget Function(List<R> results) builder,
  }) {
    if (results.isEmpty) {
      if (search.isSearching) {
        return const Center(child: CircularProgressIndicator());
      }
      return ListStatusMessage(
        search.failed
            ? searchFailedMessage
            : noSearchResultsMessage(
                noun: noun,
                query: search.query,
                downloadedOnly: _filters.downloaded,
              ),
      );
    }
    return Column(
      children: [
        if (search.isCapped) const SearchCappedHint(cap: kInPageSearchCap),
        Expanded(child: builder(results)),
      ],
    );
  }
}
