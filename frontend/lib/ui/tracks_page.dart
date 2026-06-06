import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/downloading_page.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/settings_dialog.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

class TracksPage extends ConsumerStatefulWidget {
  final int? artistId;
  final int? albumId;

  /// True when rendered as a root tab inside [AppShell]; the page then owns
  /// its own [Scaffold] + [AppBar]. False when pushed as a sub-route.
  final bool isRoot;

  const TracksPage({
    super.key,
    this.artistId,
    this.albumId,
    this.isRoot = false,
  });

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
      cursorFilters: useCursor ? _buildCursorFromLast(paginatedItems.last) : [],
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
      cursorFilters: useCursor ? _buildCursorFromLast(paginatedItems.last) : [],
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

  void _patchDownloadStates() async {
    if (!mounted) return;
    final uuids = paginatedItems.map((t) => t.uuidId).toList();
    if (uuids.isEmpty) return;
    final db = ref.read(databaseProvider);
    final states = await db.getTrackDownloadStates(uuids);
    if (!mounted) return;
    setState(() {
      paginatedItems = paginatedItems.map((t) {
        final s = states[t.uuidId];
        if (s == null) return t;
        return t.copyWith(
          filePath: s.filePath,
          downloadedBitrateKbps: s.downloadedBitrateKbps,
          fileSizeBytes: s.fileSizeBytes,
          downloadedQuality: s.downloadedQuality,
        );
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(downloadStatusVersionProvider, (_, _) => _patchDownloadStates());

    final manager = ref.watch(downloadManagerListenableProvider);
    final isOffline = ref.watch(offlineModeProvider);

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
              final job = manager.state.jobs
                  .where((j) => j.uuidId == track.uuidId)
                  .firstOrNull;
              Widget? trailing;
              if (job != null) {
                trailing = switch (job.status) {
                  Active(:final progress) => SizedBox(
                    width: 80,
                    child: LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                    ),
                  ),
                  Queued() => const Icon(Icons.schedule, size: 16),
                  Completed() || Failed() => null,
                };
              }
              // Offline: keep all rows visible for visual consistency with
              // the same album/artist viewed online, but dim and disable any
              // track that isn't locally downloaded.
              final isInteractive = !isOffline || track.isDownloaded;
              return TrackTile(
                track: track,
                trailing: trailing,
                isDimmed: isOffline && !track.isDownloaded,
                isInteractive: isInteractive,
                onTap: () => ref
                    .read(audioProvider.notifier)
                    .playFromQueue(
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
                onDownload: () => downloadScope(ref, TrackScope(track)),
                onDownloadAtQuality: (q) =>
                    downloadScope(ref, TrackScope(track), quality: q),
                onDeleteDownload: () => deleteScope(ref, TrackScope(track)),
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

/// Standard top-bar action set used by every page that shows a top bar.
/// Replaces the old standalone disconnect button with a downloads-page
/// shortcut and a settings menu.
List<Widget> buildTopBarActions(BuildContext context, WidgetRef ref) {
  return [
    IconButton(
      icon: const Icon(Icons.download),
      tooltip: 'Downloads',
      onPressed: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const DownloadingPage()));
      },
    ),
    IconButton(
      icon: const Icon(Icons.settings),
      tooltip: 'Settings',
      onPressed: () {
        showDialog<void>(
          context: context,
          useRootNavigator: false,
          builder: (_) => const SettingsDialog(),
        );
      },
    ),
  ];
}
