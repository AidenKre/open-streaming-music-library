import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/convert_flow.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/browse_controller.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/mixins/root_browse_mixin.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

class TracksPage extends ConsumerStatefulWidget {
  final int? artistId;
  final int? albumId;

  /// Browse-all capability (the whole library with the Downloaded chip and
  /// in-page search), not "navigator root". Requires no album. The page owns
  /// no chrome: `TracksBrowsePage` / the album detail route supply it.
  final bool browseAll;

  const TracksPage({
    super.key,
    this.artistId,
    this.albumId,
    this.browseAll = false,
  });

  @override
  ConsumerState<TracksPage> createState() => _TracksPageState();
}

class _TracksPageState extends ConsumerState<TracksPage>
    with CursorPaginationMixin<TrackUI>, RootBrowseMixin<TracksPage, TrackUI> {
  @override
  final scrollController = ScrollController();

  @override
  int get pageSize => 50;

  /// The downloaded-only filter this list (and the queue built from a tap)
  /// uses. Root: the chip. Detail sub-routes (an album's tracks) have no
  /// chip and never filter. Whenever a list shows tracks that can't play
  /// offline, it dims and disables them.
  bool get _downloadedOnly => filters.downloaded;

  /// The album this list shows, or null for the whole library.
  AlbumScope? get _album => widget.albumId == null
      ? null
      : AlbumScope(artistId: widget.artistId!, albumId: widget.albumId!);

  @override
  void initState() {
    super.initState();
    assert(!widget.browseAll || widget.albumId == null);
    // Creating a Tracks browse route refreshes the library (phase-4 §4);
    // the initial sync belongs to the session host, so details don't.
    if (widget.browseAll) {
      _refreshLibrary();
      initRootBrowse(type: SearchType.tracks);
    }
    initPagination();
  }

  void _refreshLibrary() {
    Future.microtask(() => ref.read(browseControlsProvider).refreshLibrary());
  }

  @override
  void dispose() {
    disposeRootBrowse();
    disposePagination();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Stream<List<TrackUI>> watchPage({required int limit}) {
    final repo = ref.read(browseRepositoryProvider);
    return repo.watchTracks(
      album: _album,
      limit: limit,
      downloadedOnly: _downloadedOnly,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Detail lists don't filter (they dim instead), so an offline flip
    // needn't re-fetch them.
    listenForBrowseChanges();
    final _RowContext rows = (
      manager: ref.watch(downloadManagerListenableProvider),
      isOffline: ref.watch(offlineModeProvider),
      conversionJobs: ref.watch(conversionJobsProvider),
      appInfo: ref.watch(appInfoProvider).value,
    );

    final body = Column(
      children: [
        if (hasBrowseControls) buildBrowseHeader(hintText: 'Search tracks'),
        Expanded(
          child: isSearchMode
              ? _buildSearchResults(rows)
              : showDownloadedEmpty
              ? const ListStatusMessage('No downloaded tracks yet.')
              : _buildBrowseList(rows),
        ),
      ],
    );

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
              .read(libraryActionsProvider)
              .playQuery(
                track,
                album: _album,
                // Queue exactly what the filtered list shows.
                downloadedOnly: _downloadedOnly,
              ),
        );
      },
    );
  }

  Widget _buildSearchResults(_RowContext rows) {
    return buildSearchBody(
      results: search.results.tracks,
      noun: 'tracks',
      // No controller: scrolling results must never reach the browse
      // window's load-more listener.
      builder: (tracks) => ListView.builder(
        itemCount: tracks.length,
        itemBuilder: (_, index) {
          final track = tracks[index];
          return _buildTrackTile(
            track,
            rows,
            // Play the visible result list, like the global search.
            onTap: () => ref
                .read(libraryActionsProvider)
                .playFromList(tracks, index, source: 'search'),
          );
        },
      ),
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
          child: LinearProgressIndicator(value: progress > 0 ? progress : null),
        ),
        Queued() => const Icon(Icons.schedule, size: 16),
        Completed() || Failed() => null,
      };
    }
    final conversionJob = rows.conversionJobs
        .where((j) => j.uuidId == track.uuidId && j.isActive)
        .firstOrNull;
    // Offline, an unfiltered list (a detail route, or the root tab with the
    // chip switched off) keeps every row visible; LibraryTrackTile dims and
    // disables any track that can't play (PlaybackAvailability).
    return LibraryTrackTile(
      track: track,
      trailing: trailing,
      onTap: onTap,
      conversionJob: conversionJob,
      extraActions: conversionMenuEntries(
        conversionJob: conversionJob,
        onConvert:
            canConvertTrack(
              isOffline: rows.isOffline,
              appInfo: rows.appInfo,
              codec: track.codec,
            )
            ? () => startConversion(context, ref, track.uuidId)
            : null,
        onCancelConvert: conversionJob != null
            ? () => cancelConversion(context, ref, conversionJob.jobId)
            : null,
      ),
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
