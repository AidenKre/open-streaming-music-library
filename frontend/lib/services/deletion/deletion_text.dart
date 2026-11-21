// The words a user reads about server deletion (Phase 8 spec §4, §6): the
// one place a preview verdict, a target's outcome, a job phase, a server
// error code or an unavailable reason becomes text. Plain words: no codes,
// ids, paths or raw server text. Model code: nothing from ui/.
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';

/// What a preview verdict means for one target.
String previewVerdictText(PreviewVerdict verdict) => switch (verdict) {
  PreviewVerdict.unknownTrack => 'Track not found on the server.',
  PreviewVerdict.alreadyDeleted => 'Already deleted on the server.',
  PreviewVerdict.revisionUnknown =>
    "The app doesn't know which version of this track you selected. Refresh "
        "to review the server's current version.",
  PreviewVerdict.conflict =>
    'This track changed since you selected it. Refresh it or remove it from '
        'the selection.',
  PreviewVerdict.busy =>
    'The server is working on this track. Remove it from the selection or '
        'try again later.',
  PreviewVerdict.missingMaster =>
    'Remove missing-file catalog entry: the file is already gone from the '
        'server, so only the catalog entry will be deleted.',
  PreviewVerdict.fileStatusUnknown =>
    "The server can't check this file, so it may refuse to delete it.",
  PreviewVerdict.ready => 'Ready to delete.',
};

/// What happened to one target of a delete job.
String deleteItemOutcomeText(DeleteJobItem item) => switch (item.status) {
  DeleteItemStatus.pending => 'Waiting to be deleted',
  DeleteItemStatus.running => 'Deleting',
  DeleteItemStatus.deleted =>
    item.details.contains('storage_cleanup_pending')
        ? 'Deleted; storage cleanup pending'
        : item.details.contains('master_missing')
        ? 'Deleted; the file was already missing'
        : 'Deleted',
  DeleteItemStatus.alreadyDeleted => 'Already deleted',
  DeleteItemStatus.conflict =>
    'Not deleted: the track changed after you selected it',
  DeleteItemStatus.busy => 'Not deleted: the server was working on it',
  DeleteItemStatus.failed => switch (item.errorCode) {
    'not_found' => 'Not deleted: the track was not found',
    'path_rejected' =>
      'Not deleted: the server refused to remove the file from where it is '
          'stored',
    'rename' =>
      "Not deleted: the server couldn't move the file, so nothing was removed",
    'recovery_required' =>
      "Not deleted: the server couldn't finish or safely undo the deletion "
          'and needs attention',
    'internal_error' =>
      "Not deleted: the server couldn't finish the deletion, so nothing was "
          'removed',
    _ => 'Not deleted',
  },
  DeleteItemStatus.unrecognized => 'Status unknown',
};

/// Where a whole delete job stands.
String jobPhaseText(DeleteJobPhase phase) => switch (phase) {
  DeleteJobPhase.submitting => 'Sending to the server',
  DeleteJobPhase.unconfirmed =>
    'Checking with the server: the answer was lost. It will not be sent '
        "again until the answer is known.",
  DeleteJobPhase.rejected => 'The server refused the request',
  DeleteJobPhase.accepted => 'Accepted by the server',
  DeleteJobPhase.running => 'Deleting',
  DeleteJobPhase.completed => 'Deleted',
  DeleteJobPhase.partial => 'Some tracks were not deleted',
  DeleteJobPhase.failed => 'Nothing was deleted',
};

/// Why the server refused a request (or could not run it). Never echoes
/// [code].
String deletionErrorText(String? code) =>
    _knownErrorText(code) ??
    'The server refused this request. Nothing was deleted.';

/// The text for a server error code this app knows; null for any other.
String? _knownErrorText(String? code) => switch (code) {
  'library_delete_disabled' =>
    'Server deletion has been turned off on this server. Nothing was '
        'deleted.',
  'track_pending_deletion' =>
    'A track in this request is already being deleted. Nothing was deleted.',
  _ => null,
};

/// Why a preview's request failed with HTTP [status] and [code]: a known
/// code keeps its text; otherwise a 5xx is a server failure, a 2xx an answer
/// whose body could not be read, the rest a refusal.
String deletionPreviewErrorText(int status, String? code) =>
    _knownErrorText(code) ??
    (status >= 500
        ? serverCouldNotCheckText()
        : status >= 200 && status < 300
        ? unexpectedAnswerText()
        : deletionErrorText(code));

/// Why server deletion can't be used now.
String unavailableText(DeleteJobsUnavailableReason reason) => switch (reason) {
  DeleteJobsUnavailableReason.notAdvertised =>
    "This server doesn't offer library tools.",
  DeleteJobsUnavailableReason.notConfirmedLive =>
    "Can't confirm that this server allows deletion right now.",
  DeleteJobsUnavailableReason.switchedOff =>
    'Server deletion is turned off on this server.',
  DeleteJobsUnavailableReason.offline => "You're offline.",
  DeleteJobsUnavailableReason.noSession => 'Sign in to delete from the server.',
  DeleteJobsUnavailableReason.notConnected =>
    "The connection to the server isn't verified.",
  DeleteJobsUnavailableReason.closed =>
    'Deletion is not available right now. Try again in a moment.',
};

/// A server job status, as shown on a receipt.
String receiptStatusText(String status) => switch (status) {
  'pending' => 'Waiting to start',
  'running' => 'In progress',
  'succeeded' => 'Finished',
  'partial' => 'Finished with some tracks not deleted',
  'failed' => 'Failed',
  _ => 'Status unknown',
};

/// More tracks selected than one deletion may carry.
String tooManyTracksText(int limit) =>
    'You can delete up to $limit tracks at a time. Select fewer and delete '
    'them in batches.';

/// The preview could not reach the server; also every other preview failure
/// that is not an answer from the server (the session closing, a local
/// fault).
String couldNotReachServerText() =>
    "Couldn't reach the server. Nothing was deleted.";

/// The server failed while making the preview.
String serverCouldNotCheckText() =>
    "The server couldn't check these tracks. Nothing was deleted.";

/// The preview's answer could not be read by this app.
String unexpectedAnswerText() =>
    'The server sent an unexpected answer. Nothing was deleted.';

/// A sync finished, so an open review no longer shows the library.
String libraryChangedText() =>
    'The library changed. Review the selection again before deleting.';

/// An earlier deletion of some of these tracks has no answer yet.
String awaitingAnswerText() =>
    'An earlier deletion of some of these tracks is still waiting for the '
    "server's answer. They can't be sent again until it's known.";

/// The preview has targets that can't be deleted as they are.
String notConfirmableText({required bool needsRefresh}) => needsRefresh
    ? "The app doesn't know which version of some tracks you selected. "
          'Refresh them first.'
    : "Some tracks can't be deleted as they are: refresh or remove them "
          'first.';

/// The confirmation shows something other than the current selection.
String reviewOutOfDateText() =>
    'This review is out of date. Nothing was deleted. Review the selection '
    'again.';

/// Confirming was refused because deletion became unavailable.
String confirmUnavailableText(DeleteJobsUnavailableReason reason) =>
    '${unavailableText(reason)} Nothing was deleted.';

/// Handing the deletion over failed in a way that sent nothing: only a
/// local fault (its database rows) of unknown cause, which a retry is not
/// known to fix, so no "Try again." (sign-off s7-app-texts).
String notSentText() =>
    "This device couldn't start the deletion. Nothing was sent.";

/// Manage library banner: deletion is available.
String deletionEnabledBannerText() =>
    'Server deletion is enabled on this server. Deleting removes music from '
    'the server permanently.';

/// Manage library banner: the server can't be reached to confirm.
String deletionUnreachableBannerText() =>
    "Can't reach the server right now. Server deletion needs a connection.";

/// Manage library banner: still asking the server.
String deletionCheckingBannerText() => 'Checking what this server allows…';
