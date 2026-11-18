// The words a user reads for an upload item (spec §7; plan O13): the one
// place an item's state and error code become text, so the Uploads page, the
// review flow and the duplicate banners say the same thing. Plain words: no
// error codes, paths, IDs, and never the server's raw `message`. Model code:
// nothing from ui/.
import 'package:frontend/services/uploads/upload_manager.dart'
    show LeftOutReason, ReselectOutcome, RetryOutcome;

/// What to tell the user about a retry's [outcome]; null when it was
/// accepted (nothing to say).
String? retryOutcomeText(RetryOutcome outcome) => switch (outcome) {
  RetryOutcome.accepted => null,
  RetryOutcome.notRetryable => "This file can't be retried.",
  RetryOutcome.changed =>
    'This file changed on the server. Check its status and try again.',
};

/// The status of an adopted item whose bytes another device is sending.
const otherDeviceSendingStatus = 'Uploading from another device';

/// Its explanation.
const otherDeviceSendingText = 'Another device is sending this upload.';

/// The short status of an item in [state] (a server item state or a local
/// `UploadIntentState`), given its last [errorCode].
/// [paused]: network work is off, so a transfer isn't moving.
String uploadStatusText(
  String state, {
  String? errorCode,
  bool paused = false,
}) =>
    switch ((state, errorCode)) {
      ('allocated', 'upload_slots_busy' || 'upload_write_failed') =>
        'Waiting for the server',
      (
        'allocated',
        'user_staged_quota_exceeded' ||
            'staged_quota_exceeded' ||
            'insufficient_storage' ||
            'free_space_unknown',
      ) =>
        'Waiting for space',
      ('allocating', _) => 'Preparing',
      ('allocated', _) => 'Queued',
      ('transferring' || 'receiving', _) => paused ? 'Paused' : 'Uploading',
      ('validating', _) => 'Checking',
      ('review_submitted', _) => 'Sending',
      ('review_ready', 'upload_library_links_unsupported') =>
        "Can't be imported",
      ('review_ready', _) => 'Ready for review',
      ('committing', _) => 'Importing',
      ('imported', _) => 'Imported',
      ('duplicate', _) => 'Already in your library',
      ('expanded', _) => 'Archive unpacked',
      ('failed', _) => 'Failed',
      ('duplicate_conflict', _) => 'Needs a decision',
      ('expired', _) => 'Expired',
      ('cancelled', _) => 'Cancelled',
      ('cancelling', _) => 'Cancelling',
      ('source_changed', _) => 'File changed',
      ('needs_reselect', _) => 'Reselect file to retry',
      ('rejected', _) => 'Not accepted',
      ('on_other_device', _) => 'Waiting for the file',
      _ => 'Unknown status',
    };

/// A longer explanation for an item in [state], or null when the status
/// says it all. [bytesHere]: this device holds the file's bytes (it was
/// picked here); false for an adopted row.
String? uploadDetailText(
  String state, {
  String? errorCode,
  bool bytesHere = true,
}) =>
    switch (state) {
      'allocated' => switch (errorCode) {
        'upload_slots_busy' =>
          'The server is busy with other uploads. This one will start soon.',
        'user_staged_quota_exceeded' =>
          'Your upload space on the server is full. Import or cancel other '
              'files first.',
        'staged_quota_exceeded' =>
          "The server's upload space is full. This file will be sent when "
              'space is free.',
        'insufficient_storage' =>
          "The server doesn't have enough free space right now. This file "
              'will be sent when space is free.',
        'free_space_unknown' =>
          "The server can't check its free space right now. This file will "
              'be sent when it can.',
        'upload_write_failed' =>
          "The server couldn't store the file. It will be sent again.",
        'upload_interrupted' ||
        'upload_idle_timeout' ||
        'upload_incomplete' =>
          'The upload was interrupted. It will start again.',
        _ => null,
      },
      // Only a device that holds the bytes sends it. Shown only while no
      // other device is seen sending the upload (otherDeviceSendingText
      // then); also reached on the device that added it, after it lost its
      // record (a sign-out and sign-in, a reset), so name no device
      // (sign-off s7-app-texts, owner 2026-11-17).
      'on_other_device' =>
        "This device cannot find this file, so it can't send it. Cancel it "
            'and add it again.',
      'needs_reselect' =>
        'This app can no longer open the file. Pick the same file again to '
            'continue.',
      'source_changed' =>
        'The file changed after it was picked. Pick the original file again, '
            'or cancel it and add it again.',
      'failed' || 'rejected' => switch (errorCode) {
        'upload_too_large' => 'This file is larger than the server accepts.',
        'upload_limit_exceeded' =>
          'This upload is over a limit set by the server.',
        'upload_digest_mismatch' ||
        'upload_length_mismatch' =>
          'The server received different bytes than the file you picked.',
        'upload_write_failed' => 'The server could not store the file.',
        'user_staged_quota_exceeded' =>
          'Your upload space on the server is full. Import or cancel other '
              'files, then try again.',
        'staged_quota_exceeded' =>
          "The server's upload space is full. Try again later.",
        'insufficient_storage' =>
          "The server doesn't have enough free space. Try again later.",
        'free_space_unknown' =>
          "The server can't check its free space right now. Try again later.",
        'upload_item_not_receivable' =>
          'The server no longer accepts this file.',
        'source_unavailable' => "The file couldn't be read.",
        'upload_invalid_audio' => "This file isn't readable audio.",
        'upload_unsupported_audio' =>
          "The server doesn't accept this audio format.",
        'probe_timeout' =>
          "The server couldn't check this file in time. Try again.",
        'probe_unavailable' =>
          "The server can't check files right now. Try again later.",
        'upload_validation_failed' =>
          "The server couldn't finish checking this file. Try again.",
        // Retry needs the bytes again: only a device that has them can
        // send it (sign-off s7-app-texts review r1 #2). The device that
        // added it is not named: it often can't retry either (review-8 #3).
        'upload_source_missing' when !bytesHere =>
          'The server no longer has the received file, and this device '
              'cannot find it. Cancel it and add it again.',
        'upload_source_missing' =>
          'The server no longer has the received file. Try again to send it.',
        'upload_archive_unsupported' =>
          "This server doesn't accept ZIP archives.",
        'upload_archive_invalid' => "This isn't a valid ZIP archive.",
        'upload_archive_corrupt' => 'The ZIP archive is damaged.',
        'upload_archive_unsafe_path' ||
        'upload_archive_unsafe_member' =>
          "The ZIP archive contains a file that isn't allowed.",
        'upload_archive_encrypted' => 'The ZIP archive is password-protected.',
        'upload_archive_unsupported_compression' =>
          "The ZIP archive uses a compression method that isn't supported.",
        'upload_archive_duplicate_names' =>
          'The ZIP archive has two files with the same name.',
        'upload_archive_nested' => 'The ZIP archive contains another archive.',
        'upload_archive_too_many_members' =>
          'The ZIP archive contains too many files.',
        'upload_archive_too_many_audio' =>
          'The ZIP archive contains too many audio files.',
        'upload_archive_member_too_large' =>
          'A file in the ZIP archive is too large.',
        'upload_archive_expanded_too_large' =>
          'The ZIP archive is too large once unpacked.',
        'upload_archive_ratio_exceeded' =>
          'The ZIP archive looks unsafe to unpack.',
        'upload_batch_expired' =>
          'The server no longer has this upload. Add the file again.',
        _ => "The upload couldn't be completed.",
      },
      'review_ready' => switch (errorCode) {
        null => null,
        'upload_library_links_unsupported' =>
          "This server's music library can't accept uploads. Ask whoever "
              'runs the server to check its storage.',
        'upload_review_version_conflict' =>
          'This file changed on the server since you opened it. Check it and '
              'confirm again.',
        'tag_write_unsupported' =>
          "This file type can't take written tags. Import without writing "
              'tags.',
        'tag_write_failed' =>
          "The tags couldn't be written to the copy. Try again, or import "
              'without writing tags.',
        'insufficient_storage' || 'free_space_unknown' =>
          "The server doesn't have enough free space to import this file "
              'right now.',
        'user_staged_quota_exceeded' =>
          'Your upload space on the server is full. Import or cancel other '
              'files first.',
        'staged_quota_exceeded' =>
          "The server's upload space is full. Try again later.",
        'probe_timeout' ||
        'probe_unavailable' =>
          "The server couldn't check this file right now. Try again.",
        'upload_item_not_committable' =>
          "This file can't be imported in its current state.",
        'operation_conflict' =>
          'This import was already sent with other choices. Check the file '
              'and confirm again.',
        'upload_item_not_resolvable' =>
          "This file can't be marked as already in your library now.",
        'upload_duplicate_match_unavailable' =>
          'That library track is no longer available.',
        'upload_prepared_unreadable' =>
          "The server couldn't read the file after preparing it.",
        _ => "The import couldn't be finished. Try again.",
      },
      'duplicate_conflict' =>
        'A matching track was added to your library after review.',
      'expired' when errorCode == 'upload_batch_not_found' =>
        'The server no longer has a record of this upload. Check your '
            "library, and add the file again if it isn't there.",
      'expired' =>
        'This file was kept too long without being imported. Add it again '
            'to upload it.',
      _ => null,
    };

/// Why a picked file was left out of an upload.
String leftOutReasonText(LeftOutReason reason) => switch (reason) {
  LeftOutReason.empty => 'The file is empty.',
  LeftOutReason.tooLarge => 'The file is larger than the server accepts.',
  LeftOutReason.unreadable => "The file couldn't be read.",
  LeftOutReason.changedWhileReading =>
    'The file changed while it was being read.',
};

/// What to tell the user after a reselect, or null for nothing.
String? reselectOutcomeText(ReselectOutcome outcome) => switch (outcome) {
  ReselectOutcome.accepted || ReselectOutcome.notNeeded => null,
  ReselectOutcome.differentFile =>
    "That's a different file. Pick the same file that was added.",
  ReselectOutcome.unreadable => "That file couldn't be read.",
};
