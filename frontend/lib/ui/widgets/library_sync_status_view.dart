import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/library_sync_status.dart';
import 'package:frontend/ui/session_controller.dart';

/// The library sync's feedback for a feed (Home, Search): a bounded
/// progress line while syncing, an error with Retry after a failure, and
/// nothing otherwise. Observes the model status; Retry goes to the session
/// controller (SC-26).
class LibrarySyncStatusView extends ConsumerWidget {
  const LibrarySyncStatusView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    switch (ref.watch(librarySyncStatusProvider)) {
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
                  "Couldn't sync your library.",
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
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
