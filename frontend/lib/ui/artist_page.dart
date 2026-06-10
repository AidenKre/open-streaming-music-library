import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/tracks_page.dart' show buildTopBarActions;
import 'package:frontend/ui/utils/cover_art_prefetcher.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
import 'package:frontend/ui/widgets/downloaded_only_badge.dart';

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
    with CursorPaginationMixin<ArtistUI> {
  @override
  final scrollController = ScrollController();

  @override
  int get pageSize => 30;

  List<ArtistOrderParameter> get _orderParams => [
    ArtistOrderParameter(column: 'name'),
  ];

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(trackSyncProvider.notifier).sync());
    initPagination();
  }

  @override
  void dispose() {
    disposePagination();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Future<List<ArtistUI>> loadPage({required bool useCursor}) {
    final repo = ref.read(browseRepositoryProvider);
    final downloadedOnly = ref.read(offlineModeProvider);
    return repo.getArtists(
      orderBy: _orderParams,
      cursorFilters: useCursor ? _buildCursorFromLast(paginatedItems.last) : [],
      limit: pageSize,
      downloadedOnly: downloadedOnly,
    );
  }

  @override
  Stream<int> watchItemCount({required bool useCursor}) {
    final repo = ref.read(browseRepositoryProvider);
    final downloadedOnly = ref.read(offlineModeProvider);
    return repo.watchArtistCount(
      orderBy: useCursor ? _orderParams : [],
      cursorFilters: useCursor ? _buildCursorFromLast(paginatedItems.last) : [],
      downloadedOnly: downloadedOnly,
    );
  }

  List<ArtistRowFilterParameter> _buildCursorFromLast(ArtistUI last) {
    return [ArtistRowFilterParameter(column: 'name', value: last.name)];
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
    // Toggling offline mode flips the downloadedOnly filter, so we must
    // re-fetch from page 1; the existing items came from a different filter.
    ref.listen<bool>(offlineModeProvider, (prev, next) {
      if (prev != next) refresh();
    });
    // While offline, the downloaded-only filter is part of the query; a
    // delete that removes the last downloaded item in the visible set must
    // re-fetch from page 1 — without this the stale card stays on screen.
    ref.listen(downloadStatusVersionProvider, (_, _) {
      if (ref.read(offlineModeProvider)) refresh();
    });
    final isOffline = ref.watch(offlineModeProvider);
    final body = Column(
      children: [
        if (isOffline) const DownloadedOnlyBadge(),
        buildNewItemsBanner('artists'),
        Expanded(
          child: GridView.builder(
            controller: scrollController,
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              childAspectRatio: 0.78,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: paginatedItems.length + (hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= paginatedItems.length) {
                return const Center(child: CircularProgressIndicator());
              }
              final artist = paginatedItems[index];
              if (index % 6 == 0) {
                final end = (index + 12).clamp(0, paginatedItems.length);
                final ids = paginatedItems
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
}
