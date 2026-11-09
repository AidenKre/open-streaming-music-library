import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/services/history/history_diagnostics.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/settings/phase5_settings.dart';
import 'package:frontend/ui/settings/sync_diagnostics_controller.dart';

/// History sync's "Sync & storage" contribution (SC-21).
const historyDiagnosticsRow = DiagnosticsRow(
  id: 'history',
  order: 0,
  buildSummary: _summary,
  buildDetail: _detail,
);

Widget _summary(BuildContext context) => const _HistorySyncRow();
Widget _detail(BuildContext context) => const _HistorySyncDetail();

String _count(int n, String one, String many) => n == 1 ? one : '$n $many';

/// The one-line state, most important first.
String _summaryText(HistoryDiagnostics d) {
  if (d.serverRegressed) return 'Server history looks restored';
  if (d.conflicts.isNotEmpty) {
    return _count(
      d.conflicts.length,
      '1 conflict needs your choice',
      'conflicts need your choice',
    );
  }
  if (d.waitingForServerSupport) return 'Waiting for server history support';
  if (d.quarantined > 0) {
    return _count(d.quarantined, '1 event held back', 'events held back');
  }
  if (d.pending > 0) {
    return _count(
      d.pending,
      '1 event waiting to upload',
      'events waiting to upload',
    );
  }
  if (d.lastError != null) return 'Last sync failed';
  if (d.frozenListens > 0) {
    return _count(d.frozenListens, '1 listen waiting to be saved',
        'listens waiting to be saved');
  }
  if (d.listenError != null) return 'A listen could not be saved';
  return 'Up to date';
}

class _HistorySyncRow extends ConsumerWidget {
  const _HistorySyncRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diagnostics = ref.watch(historyDiagnosticsProvider).value;
    return ListTile(
      leading: const Icon(Icons.history),
      title: const Text('History sync'),
      subtitle: diagnostics == null ? null : Text(_summaryText(diagnostics)),
      onTap: () => openSession(context, SessionDestination.syncDiagnostics),
    );
  }
}

String _seconds(double? value) {
  if (value == null) return 'unknown time played';
  final text = value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toString();
  return '$text s played';
}

String _describe(HistoryEventPayload p) =>
    '${p.kind} · ${p.entityType} · ${p.entityRef}\n'
    'Occurred: ${DateTime.fromMillisecondsSinceEpoch(p.occurredAt, isUtc: true).toIso8601String()}\n'
    '${_seconds(p.secondsPlayed)} · track length: '
    '${p.trackLength == null ? 'unknown' : '${p.trackLength} s'}';

class _HistorySyncDetail extends ConsumerWidget {
  const _HistorySyncDetail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(historyDiagnosticsProvider).value;
    if (d == null) return const SizedBox.shrink();
    final controls = ref.read(syncDiagnosticsControlsProvider);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('History sync', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('Waiting to upload: ${d.pending}'),
          Text('Held back: ${d.quarantined}'),
          if (d.lastError != null) Text('Last error: ${d.lastError}'),
          if (d.frozenListens > 0)
            Text('Listens waiting to be saved: ${d.frozenListens}'),
          if (d.listenError != null)
            Text('Last listen recording error: ${d.listenError}'),
          const Text(
            'Listening time is saved as you play. If the app is closed '
            'unexpectedly, about the last 5 seconds of playback may not be '
            'counted (more if the system suspended the app).',
          ),
          if (d.waitingForServerSupport) ...[
            const SizedBox(height: 12),
            const Text('Waiting for server history support'),
            const Text(
              'This server does not sync listening history yet. This device '
              'keeps every event and uploads them once the server supports '
              'history sync.',
            ),
          ],
          if (d.serverRegressed) ...[
            const SizedBox(height: 12),
            const Text(
              "The server's history looks restored from an older backup. To "
              'recover, reset this device with Settings → Disconnect and sign '
              "in again; history this device hasn't uploaded yet may be lost.",
            ),
            const Text(
              'Restore detection is best effort: writes from other clients '
              'can raise the server revision past this device’s cursor and '
              'hide a restored backup.',
            ),
          ],
          for (final pair in d.conflicts)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('This device: ${_describe(pair.local)}'),
                    Text('Server: ${_describe(pair.server.payload)}'),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () =>
                          _confirmKeepServer(context, controls, pair.server),
                      child: const Text('Keep server version'),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: controls.retryHistory,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmKeepServer(
    BuildContext context,
    SyncDiagnosticsControls controls,
    HistoryServerEvent server,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Keep the server's version?"),
        content: const Text(
          "This device's copy of the event is replaced with the server's.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Keep server version'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controls.keepServerVersion(server);
  }
}
