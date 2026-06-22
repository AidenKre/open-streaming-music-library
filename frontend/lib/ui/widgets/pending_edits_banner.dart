import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/ui/widgets/edit_conflict_dialog.dart';

/// Always-evaluated surface (visible online too — edits can be pending while
/// connected, mid-flush) showing the outbox state. Hidden when empty; shows the
/// pending count, and a tappable conflict count that opens the resolver.
class PendingEditsBanner extends ConsumerWidget {
  const PendingEditsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(pendingEditCountsProvider).value;
    if (counts == null) return const SizedBox.shrink();
    final total = counts.pending + counts.conflicted;
    if (total == 0) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    final hasConflicts = counts.conflicted > 0;
    final label = hasConflicts
        ? '$total edit(s) pending • ${counts.conflicted} conflict(s)'
        : '$total edit(s) pending';

    return Material(
      color: hasConflicts ? colors.errorContainer : colors.secondaryContainer,
      child: InkWell(
        onTap: hasConflicts ? () => _openConflicts(context, ref) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                hasConflicts ? Icons.sync_problem : Icons.sync,
                size: 18,
                color: hasConflicts
                    ? colors.onErrorContainer
                    : colors.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(label)),
              if (hasConflicts) const Text('Resolve'),
            ],
          ),
        ),
      ),
    );
  }

  void _openConflicts(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => const _ConflictList(),
    );
  }
}

class _ConflictList extends ConsumerWidget {
  const _ConflictList();

  String _labelFor(PendingEdit row) {
    try {
      final values = jsonDecode(row.valuesJson) as Map<String, dynamic>;
      final title = values['title'];
      if (title is String && title.isNotEmpty) return title;
    } catch (_) {}
    return row.uuidId;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflicts = ref.watch(conflictedEditsProvider).value ?? const [];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
          if (conflicts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No conflicts'),
            ),
        ],
      ),
    );
  }
}
