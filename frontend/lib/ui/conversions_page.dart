import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';

/// Resolves a track's current title/artist for display on a job row. The
/// job itself only carries a uuid (unlike `DownloadJob`, which denormalizes
/// title/artist at download time) -- conversion jobs are server-sourced, so
/// this looks the track up locally instead.
final _trackByUuidProvider = FutureProvider.family((ref, String uuidId) {
  return ref.read(browseRepositoryProvider).getTrack(uuidId);
});

/// Read/monitor/cancel-only view of conversion jobs -- structural mirror of
/// `downloading_page.dart`. Never starts a new job; that's the per-track
/// context menu's "Convert…" entry (`tracks_page.dart`).
class ConversionsPage extends ConsumerWidget {
  const ConversionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(conversionJobsProvider);
    final active = jobs.where((j) => j.isActive).toList();
    final finished = jobs.where((j) => j.isTerminal).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Conversions')),
      body: jobs.isEmpty
          ? const Center(child: Text('No conversions yet.'))
          : ListView(
              children: [
                if (active.isNotEmpty) const _SectionHeader('Active'),
                for (final job in active) _ConversionTile(job: job),
                if (finished.isNotEmpty) const _SectionHeader('Finished'),
                for (final job in finished) _ConversionTile(job: job),
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

class _ConversionTile extends ConsumerWidget {
  final ConversionJob job;
  const _ConversionTile({required this.job});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final trackAsync = ref.watch(_trackByUuidProvider(job.uuidId));
    final title = trackAsync.value?.title ?? job.uuidId;
    final targetLabel = job.targetCodec.toUpperCase() +
        (job.targetBitrate != null ? ' • ${job.targetBitrate} kbps' : '');

    final status = job.status;
    final subtitle = status is ConversionFailed
        ? 'Failed: ${status.message}'
        : 'Convert to $targetLabel';

    Widget cancelButton() => IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () =>
              ref.read(conversionJobsProvider.notifier).cancel(job.jobId),
        );

    final trailing = switch (status) {
      ConversionQueued() => cancelButton(),
      ConversionRunning() => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 80,
              child: LinearProgressIndicator(value: null),
            ),
            cancelButton(),
          ],
        ),
      ConversionDone() => Icon(Icons.check_circle, color: colors.primary),
      ConversionFailed() => IconButton(
          icon: Icon(Icons.error_outline, color: colors.error),
          tooltip: 'Retry',
          onPressed: () async {
            final track = await ref.read(browseRepositoryProvider).getTrack(job.uuidId);
            if (track == null) return;
            await ref.read(conversionJobsProvider.notifier).enqueue(
                  uuidId: job.uuidId,
                  targetCodec: job.targetCodec,
                  targetBitrateKbps: job.targetBitrate,
                  baseRevision: track.revision,
                );
          },
        ),
      ConversionCancelled() => Icon(Icons.cancel_outlined, color: colors.onSurfaceVariant),
    };

    return ListTile(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: trailing,
    );
  }
}
