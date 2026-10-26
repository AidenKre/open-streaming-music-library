import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/ui/convert_flow.dart';

/// Resolves a track's current title/artist for display on a job row. The
/// job itself only carries a uuid (unlike `DownloadJob`, which denormalizes
/// title/artist at download time) -- conversion jobs are server-sourced, so
/// this looks the track up locally instead. A live DB watch, so a track
/// that isn't synced yet gets its title as soon as a pull lands it (and a
/// renamed one updates); auto-disposed once no row shows it.
final _trackByUuidProvider =
    StreamProvider.autoDispose.family((ref, String uuidId) {
  return ref.watch(browseRepositoryProvider).watchTrack(uuidId);
});

/// Monitor/cancel view of conversion jobs -- structural mirror of
/// `downloading_page.dart`. Only starts a job via a failed row's Retry,
/// which runs the same convert flow as the per-track context menu's
/// "Convert…" entry (`convert_flow.dart`) with the target preselected.
class ConversionsPage extends ConsumerWidget {
  const ConversionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(conversionJobsProvider);
    final active = jobs.where((j) => j.isActive).toList();
    final finished = jobs.where((j) => j.isTerminal).toList();

    // Keyed by job so per-row state (Retry's in-progress flag) can never
    // attach to a different job when the list reorders. Retry runs with the
    // PAGE's context/ref: a row can unmount mid-flow (scrolled away, or its
    // job moved sections), which would otherwise silently abort the flow.
    Widget tile(ConversionJob job) => _ConversionTile(
          key: ValueKey(job.jobId),
          job: job,
          onRetry: () => startConversion(
            context,
            ref,
            job.uuidId,
            presetCodec: job.targetCodec,
            presetBitrateKbps: job.targetBitrate,
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Conversions')),
      body: jobs.isEmpty
          ? const Center(child: Text('No conversions yet.'))
          : ListView(
              children: [
                if (active.isNotEmpty) const _SectionHeader('Active'),
                for (final job in active) tile(job),
                if (finished.isNotEmpty) const _SectionHeader('Finished'),
                for (final job in finished) tile(job),
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

class _ConversionTile extends ConsumerStatefulWidget {
  final ConversionJob job;

  /// Runs the convert flow for this job's track (see [ConversionsPage]).
  final Future<bool> Function() onRetry;

  const _ConversionTile({
    super.key,
    required this.job,
    required this.onRetry,
  });

  @override
  ConsumerState<_ConversionTile> createState() => _ConversionTileState();
}

class _ConversionTileState extends ConsumerState<_ConversionTile> {
  /// True while a Retry's convert flow (sync, sheets, POST) is running --
  /// disables the button so a second tap can't start a duplicate flow.
  bool _retrying = false;

  /// Retry goes through the SAME flow as the per-track menu (online,
  /// capability and pending-edit gates, fresh sync, confirm sheet) with the
  /// failed job's target preselected -- never a bare re-POST.
  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
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
          onPressed: () => cancelConversion(context, ref, job.jobId),
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
          onPressed: _retrying ? null : _retry,
        ),
      ConversionCancelled() =>
        Icon(Icons.cancel_outlined, color: colors.onSurfaceVariant),
    };

    return ListTile(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitle,
        maxLines: status is ConversionFailed ? 3 : 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing,
    );
  }
}
