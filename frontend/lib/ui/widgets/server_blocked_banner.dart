import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/widgets/reset_confirm_sheet.dart';

/// The persistent "blocked: different server" banner (SC-01 rule 1): Reset
/// (keep the URL) or Disconnect, each confirmed. Renders nothing unless the
/// session controller reports the block.
class ServerBlockedBanner extends ConsumerWidget {
  const ServerBlockedBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControlsProvider);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (!session.serverBlocked) return const SizedBox.shrink();
        final colors = Theme.of(context).colorScheme;
        final onBanner = colors.onError;
        return Material(
          color: colors.error,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.dns_outlined, size: 16, color: onBanner),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Different server: this library belongs to another '
                      'server. Network features are paused.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onBanner,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: onBanner),
                    onPressed: () => _reset(context, session),
                    child: const Text('Reset'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: onBanner),
                    onPressed: () => _disconnect(context, session),
                    child: const Text('Disconnect'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _reset(BuildContext context, SessionControls session) async {
    final losses = await session.pendingLossSummaries();
    if (!context.mounted) return;
    final confirmed = await showResetConfirmSheet(
      context,
      title: 'Reset for this server?',
      body:
          "This deletes this device's local library, downloads, queue and "
          'settings, then reconnects to the server at the saved address.',
      confirmLabel: 'Reset and reconnect',
      losses: losses,
    );
    if (confirmed) unawaited(session.resetBlockedServer());
  }

  Future<void> _disconnect(
    BuildContext context,
    SessionControls session,
  ) async {
    final losses = await session.pendingLossSummaries();
    if (!context.mounted) return;
    final confirmed = await showDisconnectConfirmSheet(
      context,
      losses: losses,
    );
    if (confirmed) unawaited(session.disconnect());
  }
}
