import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/album_card.dart';

class AlbumsPage extends ConsumerStatefulWidget {
  final int? artistId;
  final VoidCallback? onDisconnect;
  const AlbumsPage({super.key, this.artistId, this.onDisconnect});

  @override
  ConsumerState<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends ConsumerState<AlbumsPage>
    with CursorPaginationMixin<AlbumUI> {
  @override
  final scrollController = ScrollController();

  @override
  int get pageSize => 30;

  List<AlbumOrderParameter> get _orderParams => [
    AlbumOrderParameter(column: 'artist'),
    AlbumOrderParameter(column: 'year', isAscending: false, nullsLast: true),
    AlbumOrderParameter(column: 'is_single_grouping'),
    AlbumOrderParameter(column: 'name', nullsLast: true),
  ];

  @override
  void initState() {
    super.initState();
    sync();
    initPagination();
  }

  void sync() {
    Future.microtask(
      () => ref
          .read(trackSyncProvider.notifier)
          .sync(artistId: widget.artistId, albumId: null),
    );
  }

  @override
  void dispose() {
    disposePagination();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Future<List<AlbumUI>> loadPage({required bool useCursor}) {
    final repo = ref.read(browseRepositoryProvider);
    return repo.getAlbums(
      artistId: widget.artistId,
      orderBy: _orderParams,
      cursorFilters: useCursor
          ? _buildCursorFromLast(paginatedItems.last)
          : [],
      limit: pageSize,
    );
  }

  @override
  Stream<int> watchItemCount({required bool useCursor}) {
    final repo = ref.read(browseRepositoryProvider);
    return repo.watchAlbumsCount(
      artistId: widget.artistId,
      orderBy: useCursor ? _orderParams : [],
      cursorFilters: useCursor
          ? _buildCursorFromLast(paginatedItems.last)
          : [],
    );
  }

  List<AlbumRowFilterParameter> _buildCursorFromLast(AlbumUI last) {
    return [
      AlbumRowFilterParameter(column: 'artist', value: last.artist),
      AlbumRowFilterParameter(column: 'year', value: last.year),
      AlbumRowFilterParameter(
        column: 'is_single_grouping',
        value: last.isSingleGrouping ? 1 : 0,
      ),
      AlbumRowFilterParameter(column: 'name', value: last.name),
    ];
  }

  void _onAlbumTap(AlbumUI album) {
    final String appBarTitle;

    if (album.isSingleGrouping) {
      appBarTitle = '${album.artist ?? "Unknown Artist"} - Singles';
    } else {
      appBarTitle = album.name ?? 'Unknown Album';
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(appBarTitle)),
          body: TracksPage(artistId: album.artistId, albumId: album.id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        buildNewItemsBanner('albums'),
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
              return AlbumCard(
                album: album,
                onTap: () => _onAlbumTap(album),
                onPlayNext: () async {
                  final tracks = await ref.read(browseRepositoryProvider)
                      .getTracksForAlbum(album.artistId, album.id);
                  if (tracks.isNotEmpty) {
                    ref.read(audioProvider.notifier).playNext(tracks);
                  }
                },
                onAddToQueue: () async {
                  final tracks = await ref.read(browseRepositoryProvider)
                      .getTracksForAlbum(album.artistId, album.id);
                  if (tracks.isNotEmpty) {
                    ref.read(audioProvider.notifier).addToQueue(tracks);
                  }
                },
              );
            },
          ),
        ),
      ],
    );

    if (widget.onDisconnect != null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('OSML'),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Disconnect',
              onPressed: widget.onDisconnect,
            ),
          ],
        ),
        body: body,
      );
    }
    return body;
  }
}
