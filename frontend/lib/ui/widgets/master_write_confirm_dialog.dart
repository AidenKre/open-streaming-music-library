import 'package:flutter/material.dart';

/// Confirms a permanent write to the master file on disk (DB+master mode):
/// rewriting its tags and possibly moving it to match the new artist/album
/// folder. Returns `true` if the user confirms, `false`/`null` otherwise.
Future<bool> showMasterWriteConfirmDialog(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Also edit the file on disk?'),
      content: const Text(
        'This permanently rewrites the audio file’s tags, and moves the '
        'file if the artist or album changed. The change cannot be undone from '
        'the app.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Edit file'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
