import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/mixins/root_browse_mixin.dart';
import 'package:frontend/ui/utils/cover_art_prefetcher.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
import 'package:frontend/ui/widgets/downloaded_only_badge.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';
import 'package:frontend/ui/widgets/top_bar_actions.dart';

class ArtistsPage extends ConsumerStatefulWidget {
  /// True when rendered as a root tab inside [AppShell]; the page then owns
  /// its own [Scaffold] + [AppBar]. False when pushed as a sub-route (the
  /// parent route's Scaffold provides the chrome).
  final bool isRoot;
  const ArtistsPage({super.key, this.isRoot = false});

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

  /// Root: the chip. A non-root instance has no chip, so offline it filters
  /// to what's playable, as before Phase 3.
  bool get _downloadedOnly => hasBrowseControls
      ? filters.downloaded
      : ref.read(offlineModeProvider);

  List<ArtistOrderParameter> get _orderParams => [
    ArtistOrderParameter(column: 'name'),
  ];

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(trackSyncProvider.notifier).sync());
    if (widget.isRoot) initRootBrowse(type: SearchType.artists);
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
      orderBy: _orderParams,
      limit: limit,
      downloadedOnly: _downloadedOnly,
    );
  }

  void _onArtistTap(ArtistUI artist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(artist.name)),
          body: AlbumsPage(artistId: artist.id),
        ),
      ),
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

    if (widget.isRoot) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('OSML'),
          actions: buildTopBarActions(context, ref),
        ),
        body: body,
      );
    }
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
          onTap: () => _onArtistTap(artist),
          onPlayNext: () async {
            final tracks = await ref
                .read(browseRepositoryProvider)
                .getTracksForArtist(artist.id);
            if (tracks.isNotEmpty) {
              ref.read(audioProvider.notifier).playNext(tracks);
            }
          },
          onAddToQueue: () async {
            final tracks = await ref
                .read(browseRepositoryProvider)
                .getTracksForArtist(artist.id);
            if (tracks.isNotEmpty) {
              ref.read(audioProvider.notifier).addToQueue(tracks);
            }
          },
          onDownload: isOffline
              ? null
              : () => downloadScope(ref, ArtistScope(artistId: artist.id)),
          onDownloadAtQuality: isOffline
              ? null
              : (q) => downloadScope(
                  ref, ArtistScope(artistId: artist.id), quality: q),
          onDeleteDownload: () =>
              deleteScope(ref, ArtistScope(artistId: artist.id)),
        );
      },
    );
  }
}
