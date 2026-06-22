import 'package:flutter/material.dart';

/// How the user chose to resolve an edit conflict (the track changed on the
/// server since the edit's base revision).
enum ConflictResolution { keepMine, takeServer }

/// Minimal per-track conflict prompt. Default is non-destructive: dismissing
/// leaves the edit queued as `conflicted` for later. Returns the choice, or
/// `null` if dismissed.
Future<ConflictResolution?> showEditConflictDialog(
  BuildContext context, {
  required String trackLabel,
}) {
  return showDialog<ConflictResolution>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Edit conflict'),
      content: Text(
        '“$trackLabel” changed on the server since you edited it. Keep your '
        'changes (re-apply on top of the server version) or discard them and '
        'take the server version?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Decide later'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(ctx).pop(ConflictResolution.takeServer),
          child: const Text('Take server'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(ConflictResolution.keepMine),
          child: const Text('Keep mine'),
        ),
      ],
    ),
  );
}
