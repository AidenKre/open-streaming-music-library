// Phase 8 spec §6 paras 2-3: deletion history (jobs and receipts). SC-26
// view: it renders ManageLibraryControls and forwards input; every word comes
// from the controller's views (an unknown title: `trackTitleOrUnknown`).
import 'package:flutter/material.dart';
import 'package:frontend/models/track_names.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/ui/manage_library/manage_library_controller.dart';

class DeleteJobsPage extends StatefulWidget {
  const DeleteJobsPage({super.key, required this.controls});

  final ManageLibraryControls controls;

  @override
  State<DeleteJobsPage> createState() => _DeleteJobsPageState();
}

class _DeleteJobsPageState extends State<DeleteJobsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controls.loadReceipts();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controls = widget.controls;
    return Scaffold(
      appBar: AppBar(title: const Text('Deletion history')),
      body: ListenableBuilder(
        listenable: controls,
        builder: (context, _) {
          final theme = Theme.of(context);
          final load = controls.receiptsLoad;
          final failed = load == ReceiptsLoad.failed;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (controls.jobs.isNotEmpty) ...[
                Text('Deletions', style: theme.textTheme.titleMedium),
                for (final job in controls.jobs) _JobCard(job),
                const SizedBox(height: 16),
              ],
              Text('Receipts', style: theme.textTheme.titleMedium),
              for (final r in controls.receipts)
                ListTile(
                  key: Key('receipt-${r.operationUuid}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(r.statusText),
                  subtitle: Text(
                    r.itemCount == 1 ? '1 track' : '${r.itemCount} tracks',
                  ),
                  onTap: () => controls.openReceipt(r.operationUuid),
                ),
              if (controls.receiptsLoad == ReceiptsLoad.loading)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (failed) ...[
                Text(
                  "Couldn't load your deletion history.",
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: controls.retryReceipts,
                    child: const Text('Retry'),
                  ),
                ),
              ],
              if (load == ReceiptsLoad.needsConnection) ...[
                Text(controls.receiptsUnreachableText),
                if (controls.receiptsRetryHelps)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: controls.retryReceipts,
                      child: const Text('Retry'),
                    ),
                  ),
              ],
              if (load == ReceiptsLoad.loaded &&
                  controls.receipts.isEmpty &&
                  controls.jobs.isEmpty)
                const Text('No deletions yet.'),
              if (controls.hasMoreReceipts &&
                  controls.receiptsLoad != ReceiptsLoad.loading)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: controls.loadMoreReceipts,
                    child: const Text('Load more'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard(this.job);

  final DeleteJobView job;

  @override
  Widget build(BuildContext context) {
    final refusal = job.refusal;
    return Card(
      key: Key('job-${job.operationUuid}'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(job.phaseText, style: Theme.of(context).textTheme.titleSmall),
            if (refusal != null)
              Text(
                refusal,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            for (final t in job.targets)
              Padding(
                key: Key('job-target-${job.operationUuid}-${t.uuid}'),
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(trackTitleOrUnknown(t.title)),
                    if (t.artist != null) Text(t.artist!),
                    // A refused job never processed its targets: no per-target outcome.
                    if (job.phase != DeleteJobPhase.rejected) Text(t.outcome),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
