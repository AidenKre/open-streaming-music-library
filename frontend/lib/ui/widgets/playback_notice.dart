import 'package:flutter/material.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/ui/library_actions.dart';

/// Shows the outcome of a row tap's playback request as a short notice at
/// the bottom when there is something to say (owner decision 5,
/// 2026-11-17): the text of [playbackOutcomeMessage], nothing when the
/// request was accepted or superseded.
///
/// The messenger is captured before awaiting, so the notice still shows
/// when the tapped row is gone by then. A thrown error is not caught.
Future<void> showPlaybackOutcome(
  BuildContext context,
  Future<PlaybackOutcome> pending,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final message = playbackOutcomeMessage(await pending);
  if (message == null || messenger == null || !messenger.mounted) return;
  messenger.showSnackBar(SnackBar(content: Text(message)));
}
