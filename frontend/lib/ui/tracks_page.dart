import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/conversions_page.dart';
import 'package:frontend/ui/convert_flow.dart';
import 'package:frontend/ui/downloading_page.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/settings_dialog.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
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

  /// Chip selection for the root tab; session-only. Detail sub-routes (an
  /// album's tracks) show no [FilterBar] and never filter by it.
  BrowseFilters _filters = const BrowseFilters();

  /// The downloaded-only filter this list (and the queue built from a tap)
  /// uses. Root: the chip, forced on offline. Detail: never — offline it
  /// keeps every row and dims the ones that can't play.
  bool get _downloadedOnly => widget.isRoot
      ? _filters.effectiveDownloaded(isOffline: ref.read(offlineModeProvider))
      : false;

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
      () => ref.read(trackSyncProvider.notifier).sync(),
    );
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
      artistId: widget.artistId,
      albumId: widget.albumId,
      limit: limit,
      downloadedOnly: _downloadedOnly,
    );
  }

  void _onFiltersChanged(BrowseFilters filters) {
    if (filters == _filters) return;
    setState(() => _filters = filters);
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    // Offline flips the root tab's effective filter, so re-fetch from page 1.
    // Detail lists don't filter (they dim instead), so they needn't refresh.
    ref.listen<bool>(offlineModeProvider, (prev, next) {
      if (widget.isRoot && prev != next) refresh();
    });
    final manager = ref.watch(downloadManagerListenableProvider);
    final isOffline = ref.watch(offlineModeProvider);
    final conversionJobs = ref.watch(conversionJobsProvider);
    final appInfo = ref.watch(appInfoProvider).value;

    final body = Column(
      children: [
        if (widget.isRoot)
          FilterBar(
            filters: _filters,
            onChanged: _onFiltersChanged,
            isOffline: isOffline,
          ),
        Expanded(
          child: ListView.builder(
            controller: scrollController,
            itemCount: paginatedItems.length + (hasMore ? 1 : 0),
            // The builder's context is deliberately unnamed: long-lived flows
            // below (convert: a network sync plus two sheets) use the page's
            // own `context`, so their lifetime is tied to the page rather
            // than to list internals.
            itemBuilder: (_, index) {
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
              // Offline, a detail list keeps all rows visible for visual
              // consistency with the same album/artist viewed online, but
              // dims and disables any track that isn't locally downloaded.
              // (The root tab filters instead, so it never dims.)
              final isInteractive = !isOffline || track.isDownloaded;
              final conversionJob = conversionJobs
                  .where((j) => j.uuidId == track.uuidId && j.isActive)
                  .firstOrNull;
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
                      // Queue exactly what the filtered list shows.
                      downloadedOnly: _downloadedOnly,
                    ),
                onPlayNext: () =>
                    ref.read(audioProvider.notifier).playNext([track]),
                onAddToQueue: () =>
                    ref.read(audioProvider.notifier).addToQueue([track]),
                onDownload: () => downloadScope(ref, TrackScope(track)),
                onDownloadAtQuality: (q) =>
                    downloadScope(ref, TrackScope(track), quality: q),
                onDeleteDownload: () => deleteScope(ref, TrackScope(track)),
                conversionJob: conversionJob,
                onConvert:
                    canConvertTrack(
                      isOffline: isOffline,
                      appInfo: appInfo,
                      codec: track.codec,
                    )
                    ? () => startConversion(context, ref, track.uuidId)
                    : null,
                onCancelConvert: conversionJob != null
                    ? () => cancelConversion(context, ref, conversionJob.jobId)
                    : null,
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
      icon: const Icon(Icons.transform),
      tooltip: 'Conversions',
      onPressed: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const ConversionsPage()));
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
