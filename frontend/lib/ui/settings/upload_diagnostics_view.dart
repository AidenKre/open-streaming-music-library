import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/count_text.dart';
import 'package:frontend/services/uploads/upload_diagnostics.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/settings/phase5_settings.dart';

/// Uploads' "Sync & storage" contribution (SC-21).
const uploadDiagnosticsRow = DiagnosticsRow(
  id: 'uploads',
  order: 20,
  buildSummary: _summary,
  buildDetail: _detail,
);

Widget _summary(BuildContext context) => const _UploadsRow();
Widget _detail(BuildContext context) => const _UploadsDetail();

String _summaryText(UploadDiagnostics d) {
  if (d.quarantined > 0) {
    return countText(
      d.quarantined,
      '1 upload needs your attention',
      'uploads need your attention',
    );
  }
  if (d.pending > 0) {
    return countText(
      d.pending,
      '1 upload waiting to send',
      'uploads waiting to send',
    );
  }
  return 'Nothing waiting';
}

class _UploadsRow extends ConsumerWidget {
  const _UploadsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(uploadDiagnosticsProvider).value;
    return ListTile(
      leading: const Icon(Icons.upload_outlined),
      title: const Text('Uploads'),
      subtitle: d == null ? null : Text(_summaryText(d)),
      onTap: () => openSession(context, SessionDestination.syncDiagnostics),
    );
  }
}

class _UploadsDetail extends ConsumerWidget {
  const _UploadsDetail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(uploadDiagnosticsProvider).value;
    if (d == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Uploads', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('Waiting to send: ${d.pending}'),
          Text('Need your attention: ${d.quarantined}'),
          Text('From an earlier sign-in: ${d.earlierSignIn}'),
          const Text(
            'Uploads from an earlier sign-in are never sent; Disconnect '
            'clears them.',
          ),
        ],
      ),
    );
  }
}
