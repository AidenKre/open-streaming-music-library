import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/mixins/root_browse_mixin.dart';
import 'package:frontend/ui/utils/cover_art_prefetcher.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
import 'package:frontend/ui/widgets/downloaded_only_badge.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';

class ArtistsPage extends ConsumerStatefulWidget {
  /// Browse-all capability (the Downloaded chip and in-page search), not
  /// "navigator root". The page owns no chrome (`ArtistsBrowsePage` does).
  final bool browseAll;
  const ArtistsPage({super.key, this.browseAll = false});

  @override
  ConsumerState<ArtistsPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends ConsumerState<ArtistsPage>
    with
        CursorPaginationMixin<ArtistUI>,
        RootBrowseMixin<ArtistsPage, ArtistUI> {
  @override
  final scrollController = ScrollController();

  @override
  int get pageSize => 30;

  @override
  void initState() {
    super.initState();
    if (widget.browseAll) initRootBrowse(type: SearchType.artists);
    initPagination();
  }

  @override
  void dispose() {
    disposeRootBrowse();
    disposePagination();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Stream<List<ArtistUI>> watchPage({required int limit}) {
    final repo = ref.read(browseRepositoryProvider);
    return repo.watchArtists(
      limit: limit,
      // Root: the chip. A non-root instance has no chip; it passes the
      // observed offline flag and the model narrows the grid.
      downloadedOnly: filters.downloaded,
      offline: !hasBrowseControls && ref.read(offlineModeProvider),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A non-root instance filters by the offline flag itself, so a flip
    // means the items on screen came from a different filter.
    listenForBrowseChanges(refreshOnOfflineChange: true);
    final isOffline = ref.watch(offlineModeProvider);
    final body = Column(
      children: [
        if (hasBrowseControls)
          buildBrowseHeader(hintText: 'Search artists')
        else if (isOffline)
          const DownloadedOnlyBadge(),
        Expanded(
          child: isSearchMode
              ? _buildSearchResults(isOffline)
              : showDownloadedEmpty
              ? const ListStatusMessage('No downloaded artists yet.')
              : _buildGrid(
                  paginatedItems,
                  showLoader: hasMore,
                  controller: scrollController,
                  isOffline: isOffline,
                ),
        ),
      ],
    );

    return body;
  }

  Widget _buildSearchResults(bool isOffline) {
    return buildSearchBody(
      results: search.results.artists,
      noun: 'artists',
      // Its own (absent) scroll controller: scrolling results must never
      // reach the browse window's load-more listener.
      builder: (artists) =>
          _buildGrid(artists, showLoader: false, isOffline: isOffline),
    );
  }

  /// The artist grid, shared by browse mode ([paginatedItems], with a
  /// trailing loader while [hasMore]) and search mode (a capped snapshot).
  Widget _buildGrid(
    List<ArtistUI> artists, {
    required bool showLoader,
    ScrollController? controller,
    required bool isOffline,
  }) {
    return GridView.builder(
      controller: controller,
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        childAspectRatio: 0.78,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: artists.length + (showLoader ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= artists.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final artist = artists[index];
        if (index % 6 == 0) {
          final end = (index + 12).clamp(0, artists.length);
          final ids = artists
              .sublist(index, end)
              .map((a) => a.coverArtId)
              .whereType<int>()
              .toList();
          prefetchCoverArt(ids);
        }
        return ArtistCard(
          artist: artist,
          onTap: () => openArtistDetail(context, artist),
        );
      },
    );
  }
}
