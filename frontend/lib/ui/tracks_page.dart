import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/conversions_page.dart';
import 'package:frontend/ui/downloading_page.dart';
import 'package:frontend/ui/mixins/cursor_pagination_mixin.dart';
import 'package:frontend/ui/settings_dialog.dart';
import 'package:frontend/ui/widgets/convert_confirm_sheet.dart';
import 'package:frontend/ui/widgets/convert_target_sheet.dart';
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(downloadManagerListenableProvider);
    final isOffline = ref.watch(offlineModeProvider);
    final conversionJobs = ref.watch(conversionJobsProvider);
    final appInfoAsync = ref.watch(appInfoProvider);
    final canConvert =
        !isOffline &&
        (appInfoAsync.value?.entity('track')?.actions.contains('convert') ??
            false);

    final body = Column(
      children: [
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
                onConvert: canConvert
                    ? () => startConversion(context, ref, track.uuidId)
                    : null,
                onCancelConvert: conversionJob != null
                    ? () => ref
                          .read(conversionJobsProvider.notifier)
                          .cancel(conversionJob.jobId)
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

/// Starts a master-type conversion for the track at [uuidId]. Always
/// re-fetches fresh state first (sync, then a DB read) rather than trusting
/// a possibly-stale in-memory `TrackUI` the caller captured at build time.
///
/// Sequence: flush pending edits + pull `/changes` -> gate on no pending edit
/// remaining for this track -> re-fetch the track (bails if it's gone) ->
/// pick a target codec/bitrate -> irreversible confirm -> enqueue. Bails
/// silently (no snackbar) at any dismissed-sheet step; a pending edit shows
/// one, since that's not a choice the user just made.
Future<void> startConversion(
  BuildContext context,
  WidgetRef ref,
  String uuidId,
) async {
  await ref.read(trackSyncProvider.notifier).sync();
  if (!context.mounted) return;

  final db = ref.read(databaseProvider);
  final pendingMode = await db.pendingWriteMode(uuidId);
  if (pendingMode != null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Finish syncing this track's pending edit before converting.",
          ),
        ),
      );
    }
    return;
  }

  final current = await ref.read(browseRepositoryProvider).getTrack(uuidId);
  if (current == null || !context.mounted) return;

  final appInfo = await ref.read(appInfoProvider.future);
  final allowedTargets = appInfo.conversion.allowedFor(current.codec);
  if (allowedTargets.isEmpty || !context.mounted) return;

  final choice = await showConvertTargetSheet(
    context,
    allowedTargets: allowedTargets,
    bitratePresets: appInfo.conversion.bitratePresets,
  );
  if (choice == null || !context.mounted) return;

  final confirmed = await showConvertConfirmSheet(
    context,
    targetCodec: choice.codec,
    targetBitrateKbps: choice.bitrateKbps,
  );
  if (!confirmed || !context.mounted) return;

  try {
    await ref
        .read(conversionJobsProvider.notifier)
        .enqueue(
          uuidId: current.uuidId,
          targetCodec: choice.codec,
          targetBitrateKbps: choice.bitrateKbps,
          baseRevision: current.revision,
        );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not start conversion: $e')));
    }
  }
}
