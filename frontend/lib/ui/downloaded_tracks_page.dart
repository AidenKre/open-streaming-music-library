import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/tracks_page.dart' show buildTopBarActions;
import 'package:frontend/ui/widgets/track_tile.dart';

class DownloadedTracksPage extends ConsumerStatefulWidget {
  const DownloadedTracksPage({super.key});

  @override
  ConsumerState<DownloadedTracksPage> createState() =>
      _DownloadedTracksPageState();
}

class _DownloadedTracksPageState extends ConsumerState<DownloadedTracksPage>
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
    initPagination();
  }

  @override
  void dispose() {
    disposePagination();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Stream<List<TrackUI>> watchPage({required int limit}) {
    final repo = ref.read(browseRepositoryProvider);
    return repo.watchTracks(
      orderBy: _orderParams,
      limit: limit,
      downloadedOnly: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(downloadManagerListenableProvider);
    final statsAsync = ref.watch(downloadedStatsProvider);

    final header = statsAsync.maybeWhen(
      data: (stats) {
        if (stats.count == 0) return const SizedBox.shrink();
        final sizeStr = stats.totalBytes > 0 ? formatBytes(stats.totalBytes) : null;
        final label = sizeStr != null
            ? '${stats.count} tracks \u2022 $sizeStr'
            : '${stats.count} tracks';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('OSML'),
        actions: buildTopBarActions(context, ref),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          Expanded(
            child: paginatedItems.isEmpty && !hasMore
                ? const Center(child: Text('No downloaded tracks yet.'))
                : ListView.builder(
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
                      return TrackTile(
                        track: track,
                        trailing: trailing,
                        onTap: () =>
                            ref.read(audioProvider.notifier).playFromQueue(
                          track: track,
                          sourceType: 'library',
                          orderParams: _orderParams,
                          downloadedOnly: true,
                        ),
                        onPlayNext: () =>
                            ref.read(audioProvider.notifier).playNext([track]),
                        onAddToQueue: () =>
                            ref.read(audioProvider.notifier).addToQueue([track]),
                        onDownload: () => downloadScope(ref, TrackScope(track)),
                        onDownloadAtQuality: (q) =>
                            downloadScope(ref, TrackScope(track), quality: q),
                        onDeleteDownload: () =>
                            deleteScope(ref, TrackScope(track)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
