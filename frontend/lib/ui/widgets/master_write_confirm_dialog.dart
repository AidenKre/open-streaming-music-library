import 'package:flutter/material.dart';

/// Confirms a permanent write to the master file on the backend server's disk
/// (DB+master mode): rewriting its tags and possibly moving it to match the
/// new artist/album folder. Returns `true` if the user confirms,
/// `false`/`null` otherwise.
Future<bool> showMasterWriteConfirmDialog(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Update the master file on the server?'),
      content: const Text(
        'This permanently rewrites the master audio file’s tags on the backend '
        'server’s disk. If the artist or album changed, the server may move '
        'the file. The app cannot undo this.',
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
