import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/conversions_page.dart';
import 'package:frontend/ui/convert_flow.dart';
import 'package:frontend/ui/downloading_page.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/mixins/in_page_search_mixin.dart';
import 'package:frontend/ui/settings_dialog.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/library_search_field.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';
import 'package:frontend/ui/widgets/search_status.dart';
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
    with
        CursorPaginationMixin<TrackUI>,
        InPageSearchMixin<TracksPage, TrackUI> {
  @override
  final scrollController = ScrollController();

  @override
  int get pageSize => 50;

  /// Chip selection for the root tab; session-only. Offline switches
  /// Downloaded on but the user may switch it off again (see
  /// [BrowseFilters]). Detail sub-routes (an album's tracks) show no
  /// [FilterBar] and never filter by it.
  late BrowseFilters _filters;

  /// The downloaded-only filter this list (and the queue built from a tap)
  /// uses. Root: the chip. Detail: never. Whenever a list shows tracks that
  /// can't play offline, it dims and disables them.
  bool get _downloadedOnly => widget.isRoot && _filters.downloaded;

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
    _filters = BrowseFilters.initial(isOffline: ref.read(offlineModeProvider));
    initPagination();
    if (widget.isRoot) {
      initInPageSearch(
        type: SearchType.tracks,
        downloadedOnly: () => _downloadedOnly,
      );
    }
  }

  void sync() {
    Future.microtask(
      () => ref.read(trackSyncProvider.notifier).sync(),
    );
  }

  @override
  void dispose() {
    disposeInPageSearch();
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

  /// A filtered window that settled with nothing in it (root only — detail
  /// lists never filter).
  bool get _showFilteredEmpty =>
      _downloadedOnly && !hasMore && paginatedItems.isEmpty;

  void _onFiltersChanged(BrowseFilters filters) {
    if (filters == _filters) return;
    setState(() => _filters = filters);
    onBrowseParamsChanged();
  }

  @override
  Widget build(BuildContext context) {
    // Offline switches the root tab's chip on (and reconnecting may switch
    // it back off), which re-fetches from page 1 (or re-runs the search).
    // Detail lists don't filter (they dim instead), so they needn't refresh.
    ref.listen<bool>(offlineModeProvider, (prev, next) {
      if (!widget.isRoot || prev == next) return;
      _onFiltersChanged(next ? _filters.wentOffline() : _filters.cameOnline());
    });
    ref.listen(downloadStatusVersionProvider, (_, _) {
      onDownloadStatusChanged();
    });
    final _RowContext rows = (
      manager: ref.watch(downloadManagerListenableProvider),
      isOffline: ref.watch(offlineModeProvider),
      conversionJobs: ref.watch(conversionJobsProvider),
      appInfo: ref.watch(appInfoProvider).value,
    );

    final body = Column(
      children: [
        if (widget.isRoot) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: LibrarySearchField(
              hintText: 'Search tracks',
              onChanged: search.onQueryChanged,
              onCleared: search.clear,
            ),
          ),
          FilterBar(filters: _filters, onChanged: _onFiltersChanged),
        ],
        Expanded(
          child: isSearchMode
              ? _buildSearchResults(rows)
              : _showFilteredEmpty
              ? const ListStatusMessage('No downloaded tracks yet.')
              : _buildBrowseList(rows),
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

  Widget _buildBrowseList(_RowContext rows) {
    return ListView.builder(
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
        return _buildTrackTile(
          track,
          rows,
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
        );
      },
    );
  }

  Widget _buildSearchResults(_RowContext rows) {
    final tracks = search.results.tracks;
    if (tracks.isEmpty) {
      if (search.isSearching) {
        return const Center(child: CircularProgressIndicator());
      }
      return ListStatusMessage(
        noSearchResultsMessage(
          noun: 'tracks',
          query: search.query,
          downloadedOnly: _downloadedOnly,
        ),
      );
    }
    return Column(
      children: [
        if (search.isCapped) const SearchCappedHint(cap: kInPageSearchCap),
        Expanded(
          // No controller: scrolling results must never reach the browse
          // window's load-more listener.
          child: ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (_, index) {
              final track = tracks[index];
              return _buildTrackTile(
                track,
                rows,
                // Play the visible result list, like the global search.
                onTap: () => ref
                    .read(audioProvider.notifier)
                    .playFromTrackList(
                      tracks.map((t) => t.uuidId).toList(),
                      track,
                      sourceType: 'search',
                    ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// One track row, shared by browse and search mode so download progress,
  /// conversion state and row actions stay identical in both.
  Widget _buildTrackTile(
    TrackUI track,
    _RowContext rows, {
    required VoidCallback onTap,
  }) {
    final job = rows.manager.state.jobs
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
    final isOffline = rows.isOffline;
    // Offline, an unfiltered list (a detail route, or the root tab with the
    // chip switched off) keeps every row visible but dims and disables any
    // track that isn't locally downloaded.
    final isInteractive = !isOffline || track.isDownloaded;
    final conversionJob = rows.conversionJobs
        .where((j) => j.uuidId == track.uuidId && j.isActive)
        .firstOrNull;
    return TrackTile(
      track: track,
      trailing: trailing,
      isDimmed: isOffline && !track.isDownloaded,
      isInteractive: isInteractive,
      onTap: onTap,
      onPlayNext: () => ref.read(audioProvider.notifier).playNext([track]),
      onAddToQueue: () => ref.read(audioProvider.notifier).addToQueue([track]),
      onDownload: () => downloadScope(ref, TrackScope(track)),
      onDownloadAtQuality: (q) =>
          downloadScope(ref, TrackScope(track), quality: q),
      onDeleteDownload: () => deleteScope(ref, TrackScope(track)),
      conversionJob: conversionJob,
      onConvert:
          canConvertTrack(
            isOffline: isOffline,
            appInfo: rows.appInfo,
            codec: track.codec,
          )
          ? () => startConversion(context, ref, track.uuidId)
          : null,
      onCancelConvert: conversionJob != null
          ? () => cancelConversion(context, ref, conversionJob.jobId)
          : null,
    );
  }

}

/// Per-build inputs every track row needs, watched once in `build`.
typedef _RowContext = ({
  DownloadManager manager,
  bool isOffline,
  List<ConversionJob> conversionJobs,
  AppInfo? appInfo,
});

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
