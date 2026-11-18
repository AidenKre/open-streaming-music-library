import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/server_blocked_reason.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/widgets/reset_confirm_sheet.dart';

/// The persistent blocked banner, by the session's reason. Different server
/// (SC-01 rule 1): Reset (keep the URL) or Disconnect, each confirmed.
/// Signed out (Phase M 7.7): Log in, which logs out first. Renders nothing
/// when the session is not blocked.
class ServerBlockedBanner extends ConsumerWidget {
  const ServerBlockedBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControlsProvider);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final reason = session.serverBlocked;
        if (reason == ServerBlockedReason.none) {
          return const SizedBox.shrink();
        }
        final signedOut = reason == ServerBlockedReason.signedOut;
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
                  Icon(
                    signedOut ? Icons.lock_outline : Icons.dns_outlined,
                    size: 16,
                    color: onBanner,
                  ),
                  const SizedBox(width: 8),
                  // Text then buttons; the buttons wrap below the text when
                  // there is no room (narrow width, large text).
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          signedOut
                              ? 'Signed out: sign in again to resume network '
                                    'features.'
                              : 'Different server: this library belongs to '
                                    'another server. Network features are '
                                    'paused.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: onBanner,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        if (signedOut)
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: onBanner,
                            ),
                            onPressed: () => unawaited(session.logout()),
                            child: const Text('Log in'),
                          )
                        else ...[
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: onBanner,
                            ),
                            onPressed: () => _reset(context, session),
                            child: const Text('Reset'),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: onBanner,
                            ),
                            onPressed: () => _disconnect(context, session),
                            child: const Text('Disconnect'),
                          ),
                        ],
                      ],
                    ),
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
