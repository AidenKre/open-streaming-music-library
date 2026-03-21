import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

class TracksPage extends ConsumerStatefulWidget {
  final int? artistId;
  final int? albumId;
  final VoidCallback? onDisconnect;

  const TracksPage({super.key, this.artistId, this.albumId, this.onDisconnect});

  @override
  ConsumerState<TracksPage> createState() => TracksPageState();
}

class TracksPageState extends ConsumerState<TracksPage>
    with CursorPaginationMixin<TrackUI> {
  @override
  final scrollController = ScrollController();

  @override
  int get pageSize => 50;

  List<OrderParameter> get _orderParams => [
    OrderParameter(column: 'artist'),
    OrderParameter(column: 'album'),
    OrderParameter(column: 'disc_number'),
    OrderParameter(column: 'track_number'),
    OrderParameter(column: 'uuid_id'),
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
          .sync(artistId: widget.artistId, albumId: widget.albumId),
    );
  }

  @override
  void dispose() {
    disposePagination();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Future<List<TrackUI>> loadPage({required bool useCursor}) {
    final repo = ref.read(browseRepositoryProvider);
    return repo.getTracks(
      orderBy: _orderParams,
      cursorFilters: useCursor
          ? _buildCursorFromLast(paginatedItems.last)
          : [],
      artistId: widget.artistId,
      albumId: widget.albumId,
      limit: pageSize,
    );
  }

  @override
  Stream<int> watchItemCount({required bool useCursor}) {
    final repo = ref.read(browseRepositoryProvider);
    return repo.watchTrackCount(
      orderBy: useCursor ? _orderParams : [],
      cursorFilters: useCursor
          ? _buildCursorFromLast(paginatedItems.last)
          : [],
      artistId: widget.artistId,
      albumId: widget.albumId,
    );
  }

  List<RowFilterParameter> _buildCursorFromLast(TrackUI last) {
    return [
      RowFilterParameter(column: 'artist', value: last.artist),
      RowFilterParameter(column: 'album', value: last.album),
      RowFilterParameter(column: 'disc_number', value: last.discNumber),
      RowFilterParameter(column: 'track_number', value: last.trackNumber),
      RowFilterParameter(column: 'uuid_id', value: last.uuidId),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        buildNewItemsBanner('tracks'),
        Expanded(
          child: ListView.builder(
            controller: scrollController,
            itemCount: paginatedItems.length + (hasMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= paginatedItems.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final track = paginatedItems[index];
              return TrackTile(
                track: track,
                onTap: () => ref.read(audioProvider.notifier).playFromQueue(
                  track: track,
                  sourceType: widget.albumId != null
                      ? 'album'
                      : widget.artistId != null
                          ? 'artist'
                          : 'library',
                  artistId: widget.artistId,
                  albumId: widget.albumId,
                  orderParams: _orderParams,
                ),
                onPlayNext: () =>
                    ref.read(audioProvider.notifier).playNext([track]),
                onAddToQueue: () =>
                    ref.read(audioProvider.notifier).addToQueue([track]),
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
