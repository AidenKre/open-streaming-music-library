import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/library_sync_status.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/widgets/reset_confirm_sheet.dart';

/// The library sync's feedback for a feed (Home, Search): a bounded
/// progress line while syncing, an error with Retry after a failure, and
/// nothing otherwise. A server whose library looks restored from an older
/// backup gets its own text and a Reset… that opens the "Reset and
/// disconnect?" sheet instead of Retry (decision 3 (a)); the app never resets
/// on its own. Observes the model status; input goes to the session
/// controller (SC-26).
class LibrarySyncStatusView extends ConsumerWidget {
  const LibrarySyncStatusView({super.key});

  /// The last library sync failed.
  static const failedMessage = "Couldn't sync your library.";

  static const serverRestoredMessage =
      "The server's library looks restored from an older backup. This device "
      "can't sync with it until it is reset.";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final status = ref.watch(librarySyncStatusProvider);
    switch (status) {
      case LibrarySyncStatus.idle:
        return const SizedBox.shrink();
      case LibrarySyncStatus.syncing:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const LinearProgressIndicator(),
              const SizedBox(height: 6),
              Text('Syncing your library…', style: muted),
            ],
          ),
        );
      case LibrarySyncStatus.failed:
      case LibrarySyncStatus.serverRestored:
        final restored = status == LibrarySyncStatus.serverRestored;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Icon(
                Icons.sync_problem,
                size: 18,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  restored
                      ? serverRestoredMessage
                      : failedMessage,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              if (restored)
                const _RestoredResetButton()
              else
                TextButton(
                  onPressed: () =>
                      ref.read(sessionControlsProvider).retryLibrarySync(),
                  child: const Text('Retry'),
                ),
            ],
          ),
        );
    }
  }
}

/// The restored-server line's Reset…: the existing Disconnect confirmation,
/// with what would be lost; only a confirmed sheet resets. One sheet at a
/// time: a second tap while the loss lines are read or the sheet is open
/// does nothing (pre-merge review D4-06).
class _RestoredResetButton extends ConsumerStatefulWidget {
  const _RestoredResetButton();

  @override
  ConsumerState<_RestoredResetButton> createState() =>
      _RestoredResetButtonState();
}

class _RestoredResetButtonState extends ConsumerState<_RestoredResetButton> {
  bool _asking = false;

  Future<void> _reset() async {
    if (_asking) return;
    _asking = true;
    try {
      final session = ref.read(sessionControlsProvider);
      final losses = await session.pendingLossSummaries();
      if (!mounted) return;
      final confirmed = await showDisconnectConfirmSheet(
        context,
        losses: losses,
      );
      if (confirmed) unawaited(session.disconnect());
    } finally {
      _asking = false;
    }
  }

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: _reset, child: const Text('Reset…'));
}
