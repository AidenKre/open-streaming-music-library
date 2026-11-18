import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/credential_storage_status.dart';
import 'package:frontend/providers/credential_storage_status_provider.dart';
import 'package:frontend/ui/settings/phase5_settings.dart';

/// Where the sign-in is stored (spec 7.1, decision O4): secure storage, or
/// the owner-only fallback file and why. A view only: it observes the store's
/// status.
const credentialStorageDiagnosticsRow = DiagnosticsRow(
  id: 'sign_in_storage',
  order: 10,
  buildSummary: _summary,
  buildDetail: _detail,
);

Widget _summary(BuildContext context) => const _StorageLine(summary: true);
Widget _detail(BuildContext context) => const _StorageLine(summary: false);

class _StorageLine extends ConsumerWidget {
  const _StorageLine({required this.summary});

  final bool summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(credentialStorageStatusProvider);
    return ValueListenableBuilder<CredentialStorageStatus>(
      valueListenable: status,
      builder: (context, value, _) => ListTile(
        leading: const Icon(Icons.lock_outline),
        title: const Text('Sign-in storage'),
        subtitle: Text(value.diagnosticsLine),
        dense: !summary,
      ),
    );
  }
}
