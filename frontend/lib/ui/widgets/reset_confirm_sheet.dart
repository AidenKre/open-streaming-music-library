import 'dart:async';

import 'package:flutter/material.dart';
import 'package:frontend/ui/session_controller.dart';

/// The shared confirmation for every local reset (Disconnect, the blocked
/// banner's Reset): a bottom sheet with explicit Cancel / confirm that pops
/// only itself, listing [losses] ("will be lost", SC-15) when there are any.
/// A null [lossesLabel] lists them without a header; [footer] is an extra line
/// under the list. Resolves true only when the user confirmed.
Future<bool> showResetConfirmSheet(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  required List<String> losses,
  String? lossesLabel = 'These will be lost:',
  String? footer,
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
                  Text(
                    '${lossesLabel == null ? '' : '$lossesLabel\n'}'
                    '${losses.join('\n')}',
                  ),
                ],
                if (footer != null) ...[
                  const SizedBox(height: 12),
                  Text(footer),
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

/// The Log out confirmation (DEV-7-22, DEV-8-14): the unsent changes of this
/// sign-in are discarded, so [losses] lists them before the user confirms.
Future<bool> showLogOutConfirmSheet(
  BuildContext context, {
  required List<String> losses,
}) => showResetConfirmSheet(
  context,
  title: 'Log out and discard unsent changes?',
  body:
      "This device hasn't finished sending these to the server. If you log "
      'out, this device stops trying.',
  confirmLabel: 'Log out and discard',
  losses: losses,
  lossesLabel: null,
  footer: 'Downloads and your library stay on this device.',
);

/// Per session controller: a call still counting makes a second one return at
/// once. Released before the sheet opens (its barrier blocks taps).
final _logOutAsking = Expando<bool>();

/// Settings' Log out, asking first only when the model says unsent changes
/// would be discarded; the view only shows the model's lines.
Future<void> logOutAfterWarning(
  BuildContext context,
  SessionControls session,
) async {
  if (_logOutAsking[session] ?? false) return;
  _logOutAsking[session] = true;
  try {
    final losses = await session.pendingLogoutLosses();
    if (losses.isEmpty) {
      unawaited(session.logout());
      return;
    }
    if (!context.mounted) return;
    // Released before the sheet: its barrier blocks taps while it is open, and
    // a route removed without completing can't leave the guard stuck.
    _logOutAsking[session] = false;
    if (await showLogOutConfirmSheet(context, losses: losses.lines)) {
      unawaited(session.logout());
    }
  } finally {
    _logOutAsking[session] = false;
  }
}
