import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/track_names.dart';
import 'package:frontend/models/app_info.dart'
    show isDownloadedAudioUnchanged;
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/models/byte_text.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/services/stale_downloads_provider.dart';
import 'package:frontend/ui/downloads_controller.dart';
import 'package:frontend/ui/library_actions.dart' show redownloadResultMessage;

/// Always-evaluated surface for downloads whose track changed on the server
/// (audio, tags or artwork) since the download completed -- structural mirror
/// of `PendingEditsBanner`. Hidden when empty, or when the user has turned off
/// the global "don't notify" pref.
class StaleDownloadsBanner extends ConsumerWidget {
  const StaleDownloadsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notify =
        ref.watch(settingsProvider).value?.notifyStaleDownloads ?? true;
    if (!notify) return const SizedBox.shrink();

    final stale = ref.watch(staleDownloadsProvider).value ?? const [];
    if (stale.isEmpty) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.secondaryContainer,
      child: InkWell(
        onTap: () => _openStaleList(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.sync_problem,
                size: 18,
                color: colors.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  staleDownloadsBannerLabel(stale.length),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Text('Review'),
            ],
          ),
        ),
      ),
    );
  }

  void _openStaleList(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      // Without this the sheet is capped at half the screen and a long list
      // overflows instead of scrolling.
      isScrollControlled: true,
      builder: (ctx) => const _StaleDownloadsList(),
    );
  }
}

/// Banner copy. Deliberately names all three kinds of server-side change:
/// staleness is revision-derived, so a tag or artwork edit made elsewhere
/// flags a download just like a master conversion does.
String staleDownloadsBannerLabel(int count) =>
    '$count downloaded track${count == 1 ? '' : 's'} changed on the server '
    'since you downloaded ${count == 1 ? 'it' : 'them'} '
    '(audio, tags, or artwork).';

/// The per-track "what changed" line: the downloaded copy's codec, bitrate
/// and file size (each when known) against the current master's codec and
/// bitrate. An unknown (null) bitrate is omitted; a real 0 is shown.
///
/// When the downloaded audio already matches the current master
/// ([isDownloadedAudioUnchanged]), the change must have been to tags or
/// artwork, so say that instead of an identical
/// "flac, 900 kbps -> flac, 900 kbps".
String staleDownloadDiffLabel(TrackUI track) {
  final oldCodec = track.downloadedCodec;
  final newCodec = track.codec;
  final oldBitrate = track.downloadedBitrateKbps?.toDouble();
  final newBitrate = track.bitrateKbps;
  if (isDownloadedAudioUnchanged(
    downloadedCodec: oldCodec,
    codec: newCodec,
    downloadedBitrateKbps: oldBitrate,
    bitrateKbps: newBitrate,
  )) {
    return 'Audio unchanged — tags or artwork updated';
  }
  final size = track.fileSizeBytes;
  final oldPart = [
    oldCodec ?? '?',
    if (oldBitrate != null) '${oldBitrate.round()} kbps',
    if (size != null) formatBytes(size),
  ].join(', ');
  final newPart = [
    newCodec ?? '?',
    if (newBitrate != null) '${newBitrate.round()} kbps',
  ].join(', ');
  return 'Your download: $oldPart  →  Server: $newPart';
}

class _StaleDownloadsList extends ConsumerWidget {
  const _StaleDownloadsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stale = ref.watch(staleDownloadsProvider).value ?? const [];
    // Rebuild when a job is queued/finishes so "Re-downloading..." tracks the
    // live queue.
    final downloads = ref.watch(downloadManagerListenableProvider).state;
    final redownloadable = [
      for (final t in stale)
        if (!downloads.isPending(t.uuidId)) t,
    ];
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: const Text('Downloads changed on the server'),
              subtitle: stale.isEmpty
                  ? null
                  : Text(staleDownloadsBannerLabel(stale.length)),
            ),
            if (stale.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      icon: const Icon(Icons.download),
                      label: const Text('Re-download all'),
                      onPressed: redownloadable.isEmpty
                          ? null
                          : () => _redownload(context, ref, redownloadable),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.close),
                      label: const Text('Dismiss all'),
                      onPressed: () => ref
                          .read(downloadsControlsProvider)
                          .dismissAllStale(stale.map((t) => t.uuidId)),
                    ),
                  ],
                ),
              ),
            const Divider(height: 1),
            if (stale.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Nothing to review'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: stale.length,
                  itemBuilder: (context, i) {
                    final track = stale[i];
                    return _StaleRow(
                      track: track,
                      redownloading: downloads.isPending(track.uuidId),
                      onRedownload: () => _redownload(context, ref, [track]),
                      onDismiss: () => ref
                          .read(downloadsControlsProvider)
                          .dismissStale(track.uuidId),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Re-download through the controller; the quality rule is the model's.
  Future<void> _redownload(
    BuildContext context,
    WidgetRef ref,
    List<TrackUI> tracks,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await ref
        .read(downloadsControlsProvider)
        .redownloadStale(tracks);
    final message = redownloadResultMessage(result) ?? 'Re-download queued';
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}

class _StaleRow extends StatelessWidget {
  const _StaleRow({
    required this.track,
    required this.redownloading,
    required this.onRedownload,
    required this.onDismiss,
  });

  final TrackUI track;
  final bool redownloading;
  final VoidCallback onRedownload;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        trackTitleOrUnknown(track.title),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        staleDownloadDiffLabel(track),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: redownloading
          ? const Text('Re-downloading…')
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: 'Re-download',
                  onPressed: onRedownload,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Dismiss',
                  onPressed: onDismiss,
                ),
              ],
            ),
    );
  }
}
