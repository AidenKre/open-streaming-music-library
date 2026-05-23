import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';

/// Persistent view of the download queue. Active jobs sit at the top with
/// progress indicators, queued jobs in the middle, and finished jobs at the
/// bottom. The list resets only on app restart or by tapping "Clear" — that's
/// the user's explicit requirement, so we don't auto-prune.
class DownloadingPage extends ConsumerWidget {
  const DownloadingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(downloadManagerListenableProvider);
    final jobs = manager.snapshot();

    // Active first, queued in the middle, finished last. Stable order
    // within each bucket: insertion order, since we don't reorder underneath.
    final active = jobs.where((j) => j.isActive).toList();
    final queued = jobs.where((j) => j.isQueued).toList();
    final finished = jobs.where((j) => j.isCompleted || j.isFailed).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          if (finished.isNotEmpty)
            TextButton(
              onPressed: manager.clearFinished,
              child: const Text('Clear'),
            ),
        ],
      ),
      body: jobs.isEmpty
          ? const Center(child: Text('No downloads yet.'))
          : ListView(
              children: [
                if (active.isNotEmpty) const _SectionHeader('Active'),
                for (final job in active)
                  _DownloadTile(job: job, onCancel: null),
                if (queued.isNotEmpty) const _SectionHeader('Queued'),
                for (final job in queued)
                  _DownloadTile(
                    job: job,
                    onCancel: () => manager.cancelQueued(job.uuidId),
                  ),
                if (finished.isNotEmpty) const _SectionHeader('Finished'),
                for (final job in finished)
                  _DownloadTile(job: job, onCancel: null),
              ],
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: theme.textTheme.titleSmall),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  final DownloadJob job;
  final VoidCallback? onCancel;

  const _DownloadTile({required this.job, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final artistPart = job.artist ?? '';
    final status = job.status;
    final sizePart = status is Completed ? formatBytes(status.sizeBytes) : null;
    final subtitle = status is Failed
        ? 'Failed: ${status.message}'
        : [artistPart, sizePart].where((s) => s != null && s.isNotEmpty).join(' \u2022 ');

    return ListTile(
      title: Text(job.title ?? job.uuidId, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? Text('Quality: ${job.quality}')
          : Text(
              '$subtitle • ${job.quality}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: switch (status) {
        Active(:final progress) => SizedBox(
            width: 80,
            child: LinearProgressIndicator(
              value: progress > 0 ? progress : null,
            ),
          ),
        Queued() => onCancel != null
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: onCancel,
                tooltip: 'Cancel',
              )
            : const Icon(Icons.schedule),
        Completed() => Icon(Icons.check_circle, color: colors.primary),
        Failed() => Icon(Icons.error_outline, color: colors.error),
      },
    );
  }
}
