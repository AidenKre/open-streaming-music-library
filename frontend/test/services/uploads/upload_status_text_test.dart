// Phase 7 §7 / plan O13: the one function that turns an upload item's state
// and error code into the words a user reads. Plain words only: no codes,
// paths, IDs or raw server text.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/uploads/upload_manager.dart'
    show LeftOutReason, ReselectOutcome;
import 'package:frontend/services/uploads/upload_status_text.dart';

const _states = [
  // local
  'allocating', 'allocated', 'transferring', 'source_changed',
  'needs_reselect', 'rejected', 'cancelling', 'review_submitted',
  'on_other_device',
  // server
  'receiving', 'validating', 'review_ready', 'committing', 'imported',
  'duplicate', 'expanded', 'failed', 'duplicate_conflict', 'expired',
  'cancelled',
];

const _codes = <String?>[
  null,
  'upload_slots_busy',
  'upload_interrupted',
  'upload_idle_timeout',
  'upload_incomplete',
  'upload_too_large',
  'upload_limit_exceeded',
  'upload_digest_mismatch',
  'upload_length_mismatch',
  'upload_write_failed',
  'upload_item_not_receivable',
  'upload_item_cancelled',
  'source_changed',
  'source_unavailable',
  'some_future_code',
  '/Users/someone/Music/secret.flac',
  '3f2b1c9e-0000-4000-8000-000000000000',
];

/// Text a user must never see: a snake_case code, a path, a UUID.
final _leak = RegExp(
  r'[a-z]+_[a-z_]+|/[A-Za-z]|[0-9a-f]{8}-[0-9a-f]{4}-',
);

void main() {
  group('status', () {
    test('every state has its own plain status', () {
      expect(uploadStatusText('allocating'), 'Preparing');
      expect(uploadStatusText('allocated'), 'Queued');
      expect(uploadStatusText('transferring'), 'Uploading');
      expect(uploadStatusText('receiving'), 'Uploading');
      expect(uploadStatusText('validating'), 'Checking');
      expect(uploadStatusText('review_ready'), 'Ready for review');
      expect(uploadStatusText('committing'), 'Importing');
      expect(uploadStatusText('imported'), 'Imported');
      expect(uploadStatusText('duplicate'), 'Already in your library');
      expect(uploadStatusText('expanded'), 'Archive unpacked');
      expect(uploadStatusText('failed'), 'Failed');
      expect(uploadStatusText('duplicate_conflict'), 'Needs a decision');
      expect(uploadStatusText('expired'), 'Expired');
      expect(uploadStatusText('cancelled'), 'Cancelled');
      expect(uploadStatusText('cancelling'), 'Cancelling');
      expect(uploadStatusText('source_changed'), 'File changed');
      expect(uploadStatusText('needs_reselect'), 'Reselect file to retry');
      expect(uploadStatusText('rejected'), 'Not accepted');
    });

    test('a busy slot is "Waiting for the server", not an error (O13)', () {
      expect(
        uploadStatusText('allocated', errorCode: 'upload_slots_busy'),
        'Waiting for the server',
      );
      expect(
        uploadDetailText('allocated', errorCode: 'upload_slots_busy'),
        isNot(contains('failed')),
      );
    });

    test('an interrupted transfer says it will start again', () {
      for (final code in [
        'upload_interrupted',
        'upload_idle_timeout',
        'upload_incomplete',
      ]) {
        expect(uploadStatusText('allocated', errorCode: code), 'Queued');
        expect(
          uploadDetailText('allocated', errorCode: code),
          'The upload was interrupted. It will start again.',
        );
      }
    });

    test('a state this client does not know reads as unknown', () {
      expect(uploadStatusText('teleporting'), 'Unknown status');
      expect(uploadDetailText('teleporting'), isNull);
    });
  });

  group('detail', () {
    test('states that explain themselves have no detail', () {
      for (final s in [
        'allocating',
        'transferring',
        'receiving',
        'validating',
        'review_ready',
        'committing',
        'imported',
        'duplicate',
        'expanded',
        'cancelled',
        'cancelling',
      ]) {
        expect(uploadDetailText(s), isNull, reason: s);
      }
      expect(uploadDetailText('allocated'), isNull);
    });

    test('the reselect states tell the user what to do', () {
      expect(
        uploadDetailText('needs_reselect'),
        'This app can no longer open the file. Pick the same file again to '
        'continue.',
      );
      expect(
        uploadDetailText('source_changed'),
        'The file changed after it was picked. Pick the original file again, '
        'or cancel it and add it again.',
      );
    });

    test('failed and rejected items explain the server error in words', () {
      for (final state in ['failed', 'rejected']) {
        expect(
          uploadDetailText(state, errorCode: 'upload_too_large'),
          'This file is larger than the server accepts.',
        );
        expect(
          uploadDetailText(state, errorCode: 'upload_limit_exceeded'),
          'This upload is over a limit set by the server.',
        );
        expect(
          uploadDetailText(state, errorCode: 'upload_digest_mismatch'),
          'The server received different bytes than the file you picked.',
        );
        expect(
          uploadDetailText(state, errorCode: 'upload_length_mismatch'),
          'The server received different bytes than the file you picked.',
        );
        expect(
          uploadDetailText(state, errorCode: 'upload_write_failed'),
          'The server could not store the file.',
        );
        expect(
          uploadDetailText(state, errorCode: 'upload_item_not_receivable'),
          'The server no longer accepts this file.',
        );
        expect(
          uploadDetailText(state, errorCode: 'source_unavailable'),
          "The file couldn't be read.",
        );
        // Unknown, missing or hostile codes: one generic sentence.
        for (final code in [
          null,
          'some_future_code',
          '/Users/someone/Music/x.flac',
        ]) {
          expect(
            uploadDetailText(state, errorCode: code),
            "The upload couldn't be completed.",
            reason: '$state $code',
          );
        }
      }
    });

    test('duplicate_conflict and expired explain what happened', () {
      expect(
        uploadDetailText('duplicate_conflict'),
        'A matching track was added to your library after review.',
      );
      expect(
        uploadDetailText('expired'),
        'This file was kept too long without being imported. Add it again '
        'to upload it.',
      );
    });
  });

  test('no state and code ever produce a code, a path or an ID', () {
    for (final state in [..._states, 'teleporting']) {
      for (final code in _codes) {
        final status = uploadStatusText(state, errorCode: code);
        final detail = uploadDetailText(state, errorCode: code);
        for (final text in [status, ?detail]) {
          expect(text, isNot(matches(_leak)), reason: '$state / $code');
          expect(text.trim(), isNotEmpty);
        }
      }
    }
  });

  test('left-out reasons', () {
    expect(leftOutReasonText(LeftOutReason.empty), 'The file is empty.');
    expect(
      leftOutReasonText(LeftOutReason.tooLarge),
      'The file is larger than the server accepts.',
    );
    expect(
      leftOutReasonText(LeftOutReason.unreadable),
      "The file couldn't be read.",
    );
    expect(
      leftOutReasonText(LeftOutReason.changedWhileReading),
      'The file changed while it was being read.',
    );
  });

  test('reselect outcomes', () {
    expect(reselectOutcomeText(ReselectOutcome.accepted), isNull);
    expect(reselectOutcomeText(ReselectOutcome.notNeeded), isNull);
    expect(
      reselectOutcomeText(ReselectOutcome.differentFile),
      "That's a different file. Pick the same file that was added.",
    );
    expect(
      reselectOutcomeText(ReselectOutcome.unreadable),
      "That file couldn't be read.",
    );
  });

  test('a transfer without a network is paused; other states ignore it', () {
    expect(uploadStatusText('transferring', paused: true), 'Paused');
    expect(uploadStatusText('receiving', paused: true), 'Paused');
    expect(uploadStatusText('review_ready', paused: true), 'Ready for review');
    expect(
      uploadStatusText('allocated', errorCode: 'upload_slots_busy', paused: true),
      'Waiting for the server',
    );
  });

  // TR-UPLOAD-02: a transfer the server refused for space stays `allocated`
  // and is sent again on its own (paced); it says so, never a bare
  // "Queued". With the r3 backend quota rule (a Confirm is not refused by
  // the staged quota) the user-quota advice is true again.
  group('TR-UPLOAD-02 a transfer waiting for space', () {
    test('status and detail per storage refusal', () {
      for (final code in [
        'user_staged_quota_exceeded',
        'staged_quota_exceeded',
        'insufficient_storage',
        'free_space_unknown',
      ]) {
        expect(uploadStatusText('allocated', errorCode: code),
            'Waiting for space', reason: code);
      }
      expect(
        uploadDetailText('allocated', errorCode: 'user_staged_quota_exceeded'),
        'Your upload space on the server is full. Import or cancel other '
            'files first.',
      );
      expect(
        uploadDetailText('allocated', errorCode: 'staged_quota_exceeded'),
        "The server's upload space is full. This file will be sent when "
            'space is free.',
      );
      expect(
        uploadDetailText('allocated', errorCode: 'insufficient_storage'),
        "The server doesn't have enough free space right now. This file "
            'will be sent when space is free.',
      );
      // Unknown is not a shortage (review r1, rev-1 #5).
      expect(
        uploadDetailText('allocated', errorCode: 'free_space_unknown'),
        "The server can't check its free space right now. This file will "
            'be sent when it can.',
      );
    });

    test('a failed archive refused for space says what helps', () {
      expect(
        uploadDetailText('failed', errorCode: 'user_staged_quota_exceeded'),
        'Your upload space on the server is full. Import or cancel other '
            'files, then try again.',
      );
      expect(
        uploadDetailText('failed', errorCode: 'staged_quota_exceeded'),
        "The server's upload space is full. Try again later.",
      );
      expect(
        uploadDetailText('failed', errorCode: 'insufficient_storage'),
        "The server doesn't have enough free space. Try again later.",
      );
      expect(
        uploadDetailText('failed', errorCode: 'free_space_unknown'),
        "The server can't check its free space right now. Try again later.",
      );
    });
  });

  // The archive's file list offers no Retry or Cancel for a file,
  // so a failed file of an unpacked archive is never told to try again; a
  // single file keeps its text.
  group('a failed file of an archive is not told to try again', () {
    const texts = <String, (String, String)>{
      'probe_timeout': (
        "The server couldn't check this file in time. Try again.",
        "The server couldn't check this file in time.",
      ),
      'probe_unavailable': (
        "The server can't check files right now. Try again later.",
        "The server can't check files right now.",
      ),
      'upload_validation_failed': (
        "The server couldn't finish checking this file. Try again.",
        "The server couldn't finish checking this file.",
      ),
      'insufficient_storage': (
        "The server doesn't have enough free space. Try again later.",
        "The server doesn't have enough free space.",
      ),
      'free_space_unknown': (
        "The server can't check its free space right now. Try again later.",
        "The server can't check its free space right now.",
      ),
      'staged_quota_exceeded': (
        "The server's upload space is full. Try again later.",
        "The server's upload space is full.",
      ),
      'user_staged_quota_exceeded': (
        'Your upload space on the server is full. Import or cancel other '
            'files, then try again.',
        'Your upload space on the server is full.',
      ),
    };
    for (final MapEntry(key: code, value: (single, archive)) in texts.entries) {
      test(code, () {
        for (final state in ['failed', 'rejected']) {
          expect(
            uploadDetailText(state, errorCode: code, fromArchive: true),
            archive,
            reason: '$state, a file of an archive',
          );
          expect(
            uploadDetailText(state, errorCode: code),
            single,
            reason: '$state, a single file',
          );
        }
      });
    }
  });

  // TR-UPLOAD-05 r4: a row whose batch the server pruned (404
  // `upload_batch_not_found`) ends as `expired`. Its real end is unknown (an
  // item left `committing` was most likely imported), so the detail must not
  // claim it was never imported.
  test('TR-UPLOAD-05 r4 a forgotten batch does not claim the file was never '
      'imported', () {
    expect(uploadStatusText('expired', errorCode: 'upload_batch_not_found'),
        'Expired');
    expect(
      uploadDetailText('expired', errorCode: 'upload_batch_not_found'),
      'The server no longer has a record of this upload. Check your '
          "library, and add the file again if it isn't there.",
    );
  });

  // TR-UPLOAD-02 residue (V-FIX-P7): a transfer the server could not store
  // stays `allocated` and is sent again on its own; it says so, never a bare
  // "Queued".
  test('TR-UPLOAD-02 r4 a transfer the server could not store', () {
    expect(uploadStatusText('allocated', errorCode: 'upload_write_failed'),
        'Waiting for the server');
    expect(
      uploadDetailText('allocated', errorCode: 'upload_write_failed'),
      "The server couldn't store the file. It will be sent again.",
    );
  });
}
