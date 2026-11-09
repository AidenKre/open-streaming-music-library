import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/widgets/damaged_downloads_section.dart';
import 'package:frontend/ui/widgets/top_bar_actions.dart';
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
    return repo.watchTracks(limit: limit, downloadedOnly: true);
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(downloadManagerListenableProvider);
    final statsAsync = ref.watch(downloadedStatsProvider);

    final header = statsAsync.maybeWhen(
      data: (stats) {
        if (stats.count == 0) return const SizedBox.shrink();
        final sizeStr = stats.totalBytes > 0
            ? formatBytes(stats.totalBytes)
            : null;
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
        title: const Text('Downloaded'),
        actions: buildTopBarActions(context, ref),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DamagedDownloadsSection(),
          header,
          Expanded(
            child: paginatedItems.isEmpty && !hasMore
                // Centred above the shell's floating chrome (audit 4B(c)).
                ? const ListStatusMessage('No downloaded tracks yet.')
                : ListView.builder(
                    controller: scrollController,
                    // Ends above the shell's floating bottom chrome (4B).
                    padding: ShellChromeInsets.padEnd(context),
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
                      return LibraryTrackTile(
                        track: track,
                        trailing: trailing,
                        onTap: () => ref
                            .read(libraryActionsProvider)
                            .playQuery(track, downloadedOnly: true),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
