import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/storage/owned_file_cleanup_providers.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/settings/phase5_settings.dart';

/// Owned-file cleanup's "Sync & storage" contribution (SC-21).
const storageCleanupDiagnosticsRow = DiagnosticsRow(
  id: 'storage_cleanup',
  order: 30,
  buildSummary: _summary,
  buildDetail: _detail,
);

Widget _summary(BuildContext context) => const _StorageCleanupRow();
Widget _detail(BuildContext context) => const _StorageCleanupDetail();

String _text(int pending) =>
    pending > 0 ? 'Storage cleanup pending ($pending)' : 'Nothing pending';

class _StorageCleanupRow extends ConsumerWidget {
  const _StorageCleanupRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Still loading is unknown, not zero: no subtitle.
    final pending = ref.watch(ownedFileCleanupPendingCountProvider).value;
    return ListTile(
      leading: const Icon(Icons.cleaning_services_outlined),
      title: const Text('Storage cleanup'),
      subtitle: pending == null ? null : Text(_text(pending)),
      onTap: () => openSession(context, SessionDestination.syncDiagnostics),
    );
  }
}

class _StorageCleanupDetail extends ConsumerWidget {
  const _StorageCleanupDetail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(ownedFileCleanupPendingCountProvider).value;
    if (pending == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Storage cleanup',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(_text(pending)),
          const Text(
            'Downloaded files that could not be deleted yet are retried '
            'automatically; a local reset removes them.',
          ),
        ],
      ),
    );
  }
}
