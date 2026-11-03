import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/mixins/root_browse_mixin.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/utils/cover_art_prefetcher.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/downloaded_only_badge.dart';

class AlbumsPage extends ConsumerStatefulWidget {
  final int? artistId;

  /// Browse-all capability: every artist's albums with the Downloaded chip
  /// and album-only in-page search (`AlbumsBrowsePage`). Requires no
  /// [artistId]. Otherwise an artist's grid, which has no chip and narrows
  /// itself to downloads while offline (its existing detail behaviour).
  final bool browseAll;
  const AlbumsPage({super.key, this.artistId, this.browseAll = false})
    : assert(!browseAll || artistId == null);

  @override
  ConsumerState<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends ConsumerState<AlbumsPage>
    with CursorPaginationMixin<AlbumUI>, RootBrowseMixin<AlbumsPage, AlbumUI> {
  @override
  final scrollController = ScrollController();

  @override
  int get pageSize => 30;

  @override
  void initState() {
    super.initState();
    if (widget.browseAll) initRootBrowse(type: SearchType.albums);
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
  Stream<List<AlbumUI>> watchPage({required int limit}) {
    final repo = ref.read(browseRepositoryProvider);
    return repo.watchAlbums(
      artistId: widget.artistId,
      limit: limit,
      // Browse-all: the chip. An artist's grid has no chip; it passes the
      // observed offline flag and the model narrows it.
      downloadedOnly: filters.downloaded,
      offline: !hasBrowseControls && ref.read(offlineModeProvider),
    );
  }

  @override
  Widget build(BuildContext context) {
    listenForBrowseChanges(refreshOnOfflineChange: true);
    final isOffline = ref.watch(offlineModeProvider);
    return Column(
      children: [
        if (hasBrowseControls)
          buildBrowseHeader(hintText: 'Search albums')
        else if (isOffline)
          const DownloadedOnlyBadge(),
        Expanded(
          child: isSearchMode
              ? buildSearchBody(
                  results: search.results.albums,
                  noun: 'albums',
                  // No controller: scrolling results must never reach the
                  // browse window's load-more listener.
                  builder: (albums) => _buildGrid(albums, showLoader: false),
                )
              : showDownloadedEmpty
              ? const ListStatusMessage('No downloaded albums yet.')
              : _buildGrid(
                  paginatedItems,
                  showLoader: hasMore,
                  controller: scrollController,
                ),
        ),
      ],
    );
  }

  /// The album grid: browse mode ([paginatedItems], trailing loader while
  /// [hasMore]) or a capped search snapshot.
  Widget _buildGrid(
    List<AlbumUI> albums, {
    required bool showLoader,
    ScrollController? controller,
  }) {
    return GridView.builder(
      controller: controller,
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        childAspectRatio: 0.75,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: albums.length + (showLoader ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= albums.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final album = albums[index];
        if (index % 6 == 0) {
          final end = (index + 12).clamp(0, albums.length);
          final ids = albums
              .sublist(index, end)
              .map((a) => a.coverArtId)
              .whereType<int>()
              .toList();
          prefetchCoverArt(ids);
        }
        return AlbumCard(
          album: album,
          onTap: () => openAlbumDetail(context, album),
        );
      },
    );
  }
}
