import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/services/stale_downloads_provider.dart';

/// Always-evaluated surface for downloads whose server master has changed
/// since the download completed (e.g. a Phase 2 conversion) -- structural
/// mirror of `PendingEditsBanner`. Hidden when empty, or when the user has
/// turned off the global "don't notify" pref.
class StaleDownloadsBanner extends ConsumerWidget {
  const StaleDownloadsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notify = ref.watch(settingsProvider).value?.notifyStaleDownloads ?? true;
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
                  '${stale.length} download(s) are outdated',
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
    showModalBottomSheet(
      context: context,
      builder: (ctx) => const _StaleDownloadsList(),
    );
  }
}

String _diffLabel(TrackUI track) {
  final oldCodec = track.downloadedCodec ?? '?';
  final newCodec = track.codec ?? '?';
  final oldBitrate = track.downloadedBitrateKbps;
  final newBitrate = track.bitrateKbps.round();
  final oldPart = oldBitrate != null ? '$oldCodec, $oldBitrate kbps' : oldCodec;
  return 'Your download: $oldPart  →  New master: $newCodec, $newBitrate kbps';
}

class _StaleDownloadsList extends ConsumerWidget {
  const _StaleDownloadsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stale = ref.watch(staleDownloadsProvider).value ?? const [];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Outdated downloads')),
          if (stale.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Nothing to review'),
            ),
          for (final track in stale)
            ListTile(
              title: Text(
                track.title ?? track.uuidId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                _diffLabel(track),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.download),
                    tooltip: 'Re-download',
                    onPressed: () => ref
                        .read(downloadManagerProvider)
                        .enqueueTracksAtQuality(
                          [track],
                          quality: track.downloadedQuality ?? originalQuality,
                          force: true,
                        ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Dismiss',
                    onPressed: () => ref
                        .read(databaseProvider)
                        .dismissStaleDownload(track.uuidId),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
