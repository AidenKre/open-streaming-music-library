import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_manager.dart' show formatBytes;
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/services/stale_downloads_provider.dart';

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
@visibleForTesting
String staleDownloadsBannerLabel(int count) =>
    '$count downloaded track${count == 1 ? '' : 's'} changed on the server '
    'since you downloaded ${count == 1 ? 'it' : 'them'} '
    '(audio, tags, or artwork).';

/// The per-track "what changed" line: the downloaded copy's codec, bitrate
/// and file size (each when known) against the current master's codec and
/// bitrate. When the downloaded audio already
/// matches the current master (same codec, bitrate within 1 kbps), the change
/// must have been to tags or artwork, so say that instead of an identical
/// "flac, 900 kbps -> flac, 900 kbps". The tolerance is needed because the
/// server's `X-Audio-Bitrate-Kbps` header (stored as the downloaded bitrate)
/// is the TRUNCATED master bitrate, so 899.7 kbps downloads as 899.
@visibleForTesting
String staleDownloadDiffLabel(TrackUI track) {
  final oldCodec = track.downloadedCodec;
  final newCodec = track.codec;
  final oldBitrate = track.downloadedBitrateKbps;
  final newBitrate = track.bitrateKbps.round();
  if (oldCodec != null &&
      newCodec != null &&
      oldBitrate != null &&
      oldCodec.toLowerCase() == newCodec.toLowerCase() &&
      (oldBitrate - track.bitrateKbps).abs() <= 1) {
    return 'Audio unchanged — tags or artwork updated';
  }
  final size = track.fileSizeBytes;
  final oldPart = [
    oldCodec ?? '?',
    if (oldBitrate != null) '$oldBitrate kbps',
    if (size != null) formatBytes(size),
  ].join(', ');
  return 'Your download: $oldPart  →  '
      'Server: ${newCodec ?? '?'}, $newBitrate kbps';
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
                          .read(databaseProvider)
                          .dismissStaleDownloads(stale.map((t) => t.uuidId)),
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
                          .read(databaseProvider)
                          .dismissStaleDownload(track.uuidId),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Queues a forced replacement download for each of [tracks] at the
  /// quality its stale copy was downloaded at -- the existing two-phase
  /// `replacements` path, so a failure keeps the stale-but-playable copy.
  /// A stored quality that's no longer a valid preset falls back to the
  /// current download-quality setting instead of throwing. Each quality group
  /// is queued independently, so one failing group doesn't stop the rest.
  Future<void> _redownload(
    BuildContext context,
    WidgetRef ref,
    List<TrackUI> tracks,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final fallback =
        ref.read(settingsProvider).value?.downloadQuality ?? originalQuality;
    final byQuality = <String, List<TrackUI>>{};
    for (final t in tracks) {
      final stored = t.downloadedQuality;
      final quality = isValidQuality(stored) ? stored! : fallback;
      (byQuality[quality] ??= []).add(t);
    }
    final manager = ref.read(downloadManagerProvider);
    var failed = 0;
    for (final entry in byQuality.entries) {
      try {
        await manager.enqueueTracksAtQuality(
          entry.value,
          quality: entry.key,
          force: true,
        );
      } catch (e) {
        failed += entry.value.length;
        developer.log('re-download enqueue failed (${entry.key}): $e',
            name: 'StaleDownloads');
      }
    }
    final message = failed == 0
        ? 'Re-download queued'
        : failed == tracks.length
            ? 'Couldn’t queue re-download. Try again.'
            : 'Couldn’t queue re-download for $failed of ${tracks.length} '
                'tracks. Try again.';
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
        track.title ?? track.uuidId,
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
