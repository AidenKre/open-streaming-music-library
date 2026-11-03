import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/feed_header.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/utils/library_search_controller.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/library_sync_status_view.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';
import 'package:frontend/ui/widgets/search_status.dart';

/// The global Search (SC-19): a sectioned feed of Artists, Albums and Songs
/// rails under a live search header with the Downloaded chip.
///
/// Local FTS only, [cap] results per type, no pagination. The chip follows
/// SC-09 `autoApply`: offline turns it on, reconnecting undoes only that.
/// The header sits above the feed (never scrolls away), so its text and
/// focus survive scrolling. The field never autofocuses: the shell calls
/// [SearchPageState.focusSearchField] when Search is visible at its root.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  /// Results fetched per type.
  static const cap = 100;

  @override
  ConsumerState<SearchPage> createState() => SearchPageState();
}

class SearchPageState extends ConsumerState<SearchPage> {
  // Debounce, immediate clear, generation guard, retry and download patching
  // all live in the shared controller.
  late final LibrarySearchControls _search;

  // The page owns the text and focus (one owner, reused by the field).
  final _queryText = TextEditingController();
  final _focus = FocusNode(debugLabel: 'search.field');
  final _feed = GlobalKey<SectionedFeedViewState>();

  late BrowseFilters _filters;

  @override
  void initState() {
    super.initState();
    _filters = BrowseFilters.initial(isOffline: ref.read(offlineModeProvider));
    _search = ref.read(librarySearchControllerFactoryProvider)(
      types: SearchType.values.toSet(),
      limitPerType: SearchPage.cap,
      // Read at fetch time, so a chip change is picked up by rerun().
      downloadedOnly: () => _filters.downloaded,
    )..addListener(_onSearchChanged);
  }

  /// Bumped on every committed query and every filter change: the rails
  /// start at their beginning for each new result set (a counter, so a
  /// return to an earlier query or filter doesn't restore its old offset).
  int _railReset = 0;
  String _railQuery = '';

  void _onSearchChanged() {
    if (!mounted) return;
    setState(() {
      if (_search.query != _railQuery) {
        _railQuery = _search.query;
        _railReset++;
      }
    });
  }

  @override
  void dispose() {
    _search
      ..removeListener(_onSearchChanged)
      ..dispose();
    _queryText.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Put the keyboard in the search field (the shell calls this when Search
  /// is shown at its root).
  void focusSearchField() {
    if (mounted) _focus.requestFocus();
  }

  /// Scroll the results back to the top (shell re-tap).
  void scrollToTop() => _feed.currentState?.scrollToTop();

  void _onFiltersChanged(BrowseFilters next) {
    if (next == _filters) return;
    setState(() {
      _filters = next;
      _railReset++;
    });
    _search.rerun();
  }

  void _onTextChanged(String raw) {
    _search.onQueryChanged(raw);
    // Status text depends on the raw text too (typed but not committed).
    setState(() {});
  }

  void _onCleared() {
    _search.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // A results snapshot needs help after a download/delete (the controller
    // patches or re-searches; no-op while inactive).
    ref.listen(downloadStatusVersionProvider, (_, _) {
      _search.onDownloadStatusChanged();
    });
    ref.listen<bool>(offlineModeProvider, (prev, next) {
      if (prev == next) return;
      _onFiltersChanged(next ? _filters.wentOffline() : _filters.cameOnline());
    });

    // The shell owns the top bar (shown while Search is at its root).
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FeedHeader.live(
            controller: _queryText,
            focusNode: _focus,
            onChanged: _onTextChanged,
            onSubmitted: _search.submit,
            onClear: _onCleared,
            filterBar: FilterBar(
              filters: _filters,
              onChanged: _onFiltersChanged,
            ),
          ),
          // Bounded progress for a first query and for updating results;
          // the space is reserved so the feed never jumps.
          SizedBox(
            height: 4,
            child: _search.isSearching ? const LinearProgressIndicator() : null,
          ),
          Expanded(
            child: SectionedFeedView(key: _feed, sections: _sections(context)),
          ),
        ],
      ),
    );
  }

  List<FeedSection> _sections(BuildContext context) => [
    // The library sync's feedback: results come from the local mirror.
    const FeedStatusSection(
      id: 'search.sync_status',
      child: LibrarySyncStatusView(),
    ),
    ..._resultSections(context),
  ];

  List<FeedSection> _resultSections(BuildContext context) {
    final search = _search;
    FeedSection status(Widget child) =>
        FeedStatusSection(id: 'search.status', child: child);

    if (!search.isActive) {
      // Typed but not committed yet: say nothing rather than "search".
      if (_queryText.text.trim().isNotEmpty) return const [];
      return [status(const ListStatusMessage('Search your library'))];
    }
    if (!search.hasResults) {
      if (search.isSearching) return const [];
      if (search.failed) {
        return [status(SearchFailedNotice(onRetry: search.retry))];
      }
      return [
        status(
          ListStatusMessage(
            noSearchResultsMessage(
              noun: 'results',
              query: search.query,
              downloadedOnly: _filters.downloaded,
            ),
          ),
        ),
      ];
    }

    final results = search.results;
    final tracks = results.tracks;
    final rails = _railReset;
    Widget? capHint(SearchType type, String noun) => search.cappedFor(type)
        ? SearchCappedHint(cap: SearchPage.cap, noun: noun)
        : null;

    return [
      // Results kept from before a failure sit under the error.
      if (search.failed)
        status(SearchFailedNotice(compact: true, onRetry: search.retry)),
      EntityRailSection(
        id: 'search.artists',
        title: 'Artists',
        entities: [for (final a in results.artists) ArtistEntity(a)],
        onTap: (entity, _) =>
            openArtistDetail(context, (entity as ArtistEntity).artist),
        resetToken: rails,
        footer: capHint(SearchType.artists, 'artists'),
      ),
      EntityRailSection(
        id: 'search.albums',
        title: 'Albums',
        entities: [for (final a in results.albums) AlbumEntity(a)],
        onTap: (entity, _) =>
            openAlbumDetail(context, (entity as AlbumEntity).album),
        resetToken: rails,
        footer: capHint(SearchType.albums, 'albums'),
      ),
      EntityRailSection(
        id: 'search.songs',
        title: 'Songs',
        entities: [for (final t in tracks) TrackEntity(t)],
        // The capped ranked list, from the tapped song.
        onTap: (_, index) => ref
            .read(libraryActionsProvider)
            .playFromList(tracks, index, source: 'search'),
        resetToken: rails,
        footer: capHint(SearchType.tracks, 'songs'),
      ),
    ];
  }
}
