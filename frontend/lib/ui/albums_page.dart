import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/browse_controller.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/utils/cover_art_prefetcher.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/downloaded_only_badge.dart';

class AlbumsPage extends ConsumerStatefulWidget {
  final int? artistId;
  const AlbumsPage({super.key, this.artistId});

  @override
  ConsumerState<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends ConsumerState<AlbumsPage>
    with CursorPaginationMixin<AlbumUI> {
  @override
  final scrollController = ScrollController();

  @override
  int get pageSize => 30;

  @override
  void initState() {
    super.initState();
    sync();
    initPagination();
  }

  void sync() {
    Future.microtask(() => ref.read(browseControlsProvider).refreshLibrary());
  }

  @override
  void dispose() {
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
      offline: ref.read(offlineModeProvider),
    );
  }


  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(offlineModeProvider, (prev, next) {
      if (prev != next) refresh();
    });
    final isOffline = ref.watch(offlineModeProvider);
    final body = Column(
      children: [
        if (isOffline) const DownloadedOnlyBadge(),
        Expanded(
          child: GridView.builder(
            controller: scrollController,
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              childAspectRatio: 0.75,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: paginatedItems.length + (hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= paginatedItems.length) {
                return const Center(child: CircularProgressIndicator());
              }
              final album = paginatedItems[index];
              if (index % 6 == 0) {
                final end = (index + 12).clamp(0, paginatedItems.length);
                final ids = paginatedItems
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
          ),
        ),
      ],
    );

    return body;
  }
}
