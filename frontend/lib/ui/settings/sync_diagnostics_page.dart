import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/settings/phase5_settings.dart';

/// The Sync & storage diagnostics page (SC-21), reached through
/// `SessionDestination.syncDiagnostics`: each contributed
/// [DiagnosticsRow]'s detail.
class SyncDiagnosticsPage extends ConsumerWidget {
  const SyncDiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = [...ref.watch(diagnosticsRowsProvider)]
      ..sort((a, b) => a.order.compareTo(b.order));
    return Scaffold(
      appBar: AppBar(title: const Text('Sync & storage')),
      body: ListView(
        children: [for (final row in rows) row.buildDetail(context)],
      ),
    );
  }
}
