import 'package:flutter/material.dart';

/// The shared confirmation for every local reset (Disconnect, the blocked
/// banner's Reset): a bottom sheet with explicit Cancel / confirm that pops
/// only itself, listing [losses] ("will be lost", SC-15) when there are any.
/// Resolves true only when the user confirmed.
Future<bool> showResetConfirmSheet(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  required List<String> losses,
}) async {
  return await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 12),
                Text(body),
                if (losses.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('These will be lost:\n${losses.join('\n')}'),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Text(confirmLabel),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ) ??
      false;
}

/// The Disconnect confirmation copy, shared by Settings and the blocked
/// banner.
Future<bool> showDisconnectConfirmSheet(
  BuildContext context, {
  required List<String> losses,
}) => showResetConfirmSheet(
  context,
  title: 'Reset and disconnect?',
  body:
      'This deletes the local library database, downloads, caches, '
      'queue, playback state, and saved settings on this device.',
  confirmLabel: 'Reset and disconnect',
  losses: losses,
);
