import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/ui/widgets/edit_conflict_dialog.dart';

/// Always-evaluated surface (visible online too — edits can be pending while
/// connected, mid-flush) showing the outbox state. Hidden when empty; shows
/// the pending count plus tappable conflict/rejection counts that open the
/// resolver sheet — a permanent rejection must be user-visible, not just a
/// silent revert (the "Saved" toast has already fired by the time it lands).
class PendingEditsBanner extends ConsumerWidget {
  const PendingEditsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(pendingEditCountsProvider).value;
    if (counts == null) return const SizedBox.shrink();
    final total = counts.pending + counts.conflicted + counts.rejected;
    if (total == 0) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    final needsAttention = counts.conflicted > 0 || counts.rejected > 0;
    final parts = <String>[
      if (counts.pending > 0) '${counts.pending} edit(s) pending',
      if (counts.conflicted > 0) '${counts.conflicted} conflict(s)',
      if (counts.rejected > 0) '${counts.rejected} rejected',
    ];

    return Material(
      color:
          needsAttention ? colors.errorContainer : colors.secondaryContainer,
      child: InkWell(
        onTap: needsAttention ? () => _openIssues(context, ref) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                needsAttention ? Icons.sync_problem : Icons.sync,
                size: 18,
                color: needsAttention
                    ? colors.onErrorContainer
                    : colors.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(parts.join(' • '))),
              if (needsAttention) const Text('Review'),
            ],
          ),
        ),
      ),
    );
  }

  void _openIssues(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => const _OutboxIssuesList(),
    );
  }
}

String _labelFor(PendingEdit row) {
  try {
    final values = jsonDecode(row.valuesJson) as Map<String, dynamic>;
    final title = values['title'];
    if (title is String && title.isNotEmpty) return title;
  } catch (_) {}
  return row.uuidId;
}

/// Conflicts (keep-mine / take-server) and rejections (reason + dismiss) in
/// one sheet, both driven by live outbox streams.
class _OutboxIssuesList extends ConsumerWidget {
  const _OutboxIssuesList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflicts = ref.watch(conflictedEditsProvider).value ?? const [];
    final rejected = ref.watch(rejectedEditsProvider).value ?? const [];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (conflicts.isNotEmpty) ...[
            const ListTile(title: Text('Edit conflicts')),
            for (final row in conflicts)
              ListTile(
                leading: const Icon(Icons.sync_problem),
                title: Text(_labelFor(row)),
                onTap: () async {
                  final choice = await showEditConflictDialog(
                    context,
                    trackLabel: _labelFor(row),
                  );
                  if (choice == null) return;
                  final outbox = ref.read(editOutboxProvider);
                  if (choice == ConflictResolution.keepMine) {
                    await outbox.resolveKeepMine(row.uuidId);
                  } else {
                    await outbox.resolveTakeServer(row.uuidId);
                  }
                },
              ),
          ],
          if (rejected.isNotEmpty) ...[
            const ListTile(title: Text('Rejected edits')),
            for (final row in rejected)
              ListTile(
                leading: const Icon(Icons.block),
                title: Text(_labelFor(row)),
                subtitle: Text(
                  row.rejectionReason ?? 'Rejected by the server',
                ),
                trailing: TextButton(
                  onPressed: () =>
                      ref.read(editOutboxProvider).dismissRejected(row.uuidId),
                  child: const Text('Dismiss'),
                ),
              ),
          ],
          if (conflicts.isEmpty && rejected.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Nothing to review'),
            ),
        ],
      ),
    );
  }
}
