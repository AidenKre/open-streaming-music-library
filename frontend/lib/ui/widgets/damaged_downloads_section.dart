import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/damaged_downloads_provider.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/downloads_controller.dart';

/// The Downloaded page's damaged downloads (Phase 5 decision 6): files that
/// exist but failed to play. Until the user acts, those tracks stream online
/// and are skipped offline; the files are kept. Hidden when there are none.
class DamagedDownloadsSection extends ConsumerWidget {
  const DamagedDownloadsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final damaged = ref.watch(damagedDownloadsProvider).value ?? const [];
    if (damaged.isEmpty) return const SizedBox.shrink();
    final offline = ref.watch(offlineModeProvider);
    final downloads = ref.watch(downloadManagerListenableProvider).state;
    final redownloadable = [
      for (final t in damaged)
        if (!downloads.isPending(t.uuidId)) t,
    ];
    final controls = ref.read(downloadsControlsProvider);
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(Icons.report_problem_outlined,
                color: colors.onErrorContainer),
            title: Text(damagedDownloadsLabel(damaged.length)),
            subtitle: Text(
              offline
                  ? 'They are skipped while offline. Re-download them when '
                      'you are back online.'
                  : 'They stream until you re-download them.',
            ),
          ),
          // Its own row: as a ListTile trailing the button squeezes the
          // title on a phone.
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextButton(
                onPressed: offline || redownloadable.isEmpty
                    ? null
                    : () => controls.redownloadDamaged(redownloadable),
                child: const Text('Re-download all'),
              ),
            ),
          ),
          // Bounded: many damaged rows scroll inside the section instead of
          // squeezing the Downloaded list out (about three rows show).
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 168),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: damaged.length,
              itemBuilder: (context, i) {
                final track = damaged[i];
                return _DamagedRow(
                  track: track,
                  redownloading: downloads.isPending(track.uuidId),
                  onRedownload: offline
                      ? null
                      : () => controls.redownloadDamaged([track]),
                  onDelete: () => controls.deleteDamaged(track.uuidId),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

@visibleForTesting
String damagedDownloadsLabel(int count) => count == 1
    ? '1 download couldn’t be played (the file looks damaged)'
    : '$count downloads couldn’t be played (the files look damaged)';

class _DamagedRow extends StatelessWidget {
  const _DamagedRow({
    required this.track,
    required this.redownloading,
    required this.onRedownload,
    required this.onDelete,
  });

  final TrackUI track;
  final bool redownloading;
  final VoidCallback? onRedownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(track.title ?? track.uuidId,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle:
          Text(track.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      // Delete stays available while a re-download waits (e.g. queued
      // offline): it also cancels the queued job.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (redownloading)
            const Text('Re-downloading…')
          else
            IconButton(
              icon: const Icon(Icons.download),
              tooltip: 'Re-download',
              onPressed: onRedownload,
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete damaged file',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
