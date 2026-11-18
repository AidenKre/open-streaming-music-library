// Phase 7B.2c S5: the words for every code the server added since 7B.2b
// (DEV-7-12 validation, DEV-7-13 commit, DEV-7-14 the 13 archive refusals,
// 7A.3b `upload_commit_failed` / resolve-duplicate refusals, 7A.3c
// `upload_batch_expired`), and the local `review_submitted` state. One
// function: plain words, never a code, path, ID or the server's message.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_status_text.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

final _leak = RegExp(
  r'[a-z]+_[a-z_]+|/[A-Za-z]|[0-9a-f]{8}-[0-9a-f]{4}-',
);

const _validationCodes = [
  'probe_timeout',
  'probe_unavailable',
  'upload_invalid_audio',
  'upload_unsupported_audio',
  'upload_source_missing',
  'upload_archive_unsupported',
  'upload_validation_failed',
];

const _archiveCodes = [
  'upload_archive_invalid',
  'upload_archive_corrupt',
  'upload_archive_unsafe_path',
  'upload_archive_unsafe_member',
  'upload_archive_encrypted',
  'upload_archive_unsupported_compression',
  'upload_archive_duplicate_names',
  'upload_archive_nested',
  'upload_archive_too_many_members',
  'upload_archive_too_many_audio',
  'upload_archive_member_too_large',
  'upload_archive_expanded_too_large',
  'upload_archive_ratio_exceeded',
];

/// Codes an item can carry back in `review_ready` after a refused or failed
/// import, or that a review answer gives.
const _reviewCodes = [
  'upload_review_version_conflict',
  'tag_write_unsupported',
  'tag_write_failed',
  'upload_commit_failed',
  'insufficient_storage',
  'free_space_unknown',
  'user_staged_quota_exceeded',
  'staged_quota_exceeded',
  'probe_timeout',
  'probe_unavailable',
  'upload_item_not_committable',
  'operation_conflict',
  'upload_item_not_resolvable',
  'upload_duplicate_match_unavailable',
];

void main() {
  test('a submitted review action reads "Sending"', () {
    expect(uploadStatusText('review_submitted'), 'Sending');
    expect(uploadDetailText('review_submitted'), isNull);
  });

  group('failed items', () {
    final generic = uploadDetailText('failed', errorCode: 'some_future_code');

    test('each validation and archive code has its own words', () {
      final seen = <String>{};
      for (final code in [..._validationCodes, ..._archiveCodes]) {
        final text = uploadDetailText('failed', errorCode: code);
        expect(text, isNotNull, reason: code);
        expect(text, isNot(generic), reason: code);
        expect(text, isNot(matches(_leak)), reason: code);
        seen.add(text!);
      }
      // The unsafe-path and unsafe-member refusals may share words; every
      // other code says something of its own.
      expect(seen.length, greaterThanOrEqualTo(
          _validationCodes.length + _archiveCodes.length - 2));
    });

    test('the key validation answers in words', () {
      expect(uploadDetailText('failed', errorCode: 'upload_invalid_audio'),
          "This file isn't readable audio.");
      expect(uploadDetailText('failed', errorCode: 'upload_unsupported_audio'),
          "The server doesn't accept this audio format.");
      expect(uploadDetailText('failed', errorCode: 'probe_timeout'),
          "The server couldn't check this file in time. Try again.");
      expect(uploadDetailText('failed', errorCode: 'upload_archive_encrypted'),
          'The ZIP archive is password-protected.');
    });
  });

  group('review answers on a reviewable item', () {
    test('a review_ready item with an error explains it; without one it '
        'needs no detail', () {
      expect(uploadDetailText('review_ready'), isNull);
      for (final code in _reviewCodes) {
        final text = uploadDetailText('review_ready', errorCode: code);
        expect(text, isNotNull, reason: code);
        expect(text, isNot(matches(_leak)), reason: code);
      }
    });

    test('the stale version, write-tags and failed-import answers in words',
        () {
      expect(
        uploadDetailText('review_ready',
            errorCode: 'upload_review_version_conflict'),
        'This file changed on the server since you opened it. Check it and '
        'confirm again.',
      );
      expect(
        uploadDetailText('review_ready', errorCode: 'tag_write_unsupported'),
        "This file type can't take written tags. Import without writing "
        'tags.',
      );
      expect(
        uploadDetailText('review_ready', errorCode: 'upload_commit_failed'),
        "The import couldn't be finished. Try again.",
      );
    });

    test('an unknown review code still gives plain words', () {
      expect(
        uploadDetailText('review_ready', errorCode: 'some_future_code'),
        "The import couldn't be finished. Try again.",
      );
    });
  });

  test('a batch the server pruned is gone for good (410 upload_batch_expired)',
      () {
    expect(uploadStatusText('rejected', errorCode: 'upload_batch_expired'),
        'Not accepted');
    expect(
      uploadDetailText('rejected', errorCode: 'upload_batch_expired'),
      'The server no longer has this upload. Add the file again.',
    );
  });

  test('a submitted item is in progress on the Uploads page and offers no '
      'cancel', () {
    final overview = UploadsOverview.of(
      intents: [
        UploadIntentRecord(
          itemUuid: 'i',
          batchUuid: 'b',
          parentItemUuid: null,
          selectionIndex: 0,
          displayName: 'a.flac',
          lastState: 'review_submitted',
          lastErrorCode: null,
          lastErrorMessage: null,
          operationUuid: 'op',
          transferOperationUuid: null,
          reviewGeneration: 1,
          draftJson: null,
          localBindingId: 'bind',
          createdAtMs: 0,
          updatedAtMs: 0,
          expectedLength: null,
          expectedSha256: null,
          descriptor: null,
        ),
      ],
      progress: const {},
      availability: UploadsAvailability.available,
    );
    expect(overview.counts.inProgress, 1);
    expect(overview.rows.single.statusText, 'Sending');
    expect(overview.rows.single.offersCancel, isFalse);
    expect(overview.rows.single.offersReviewTags, isFalse);
  });

  test('guard: an allocation replay of a pruned batch (410) rejects the '
      'local batch for good, with the code', () async {
    final h = await UploadHarness.create();
    addTearDown(h.dispose);
    h.api.onAllocate = (_) async =>
        throw apiError(410, 'upload_batch_expired', retryable: false);
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    h.timers.fire();
    await h.pump();

    final row = (await h.intents()).single;
    expect(row['last_state'], UploadIntentState.rejected);
    expect(row['last_error_code'], 'upload_batch_expired');
    expect(h.api.calls.where((c) => c.startsWith('allocate')), hasLength(1));
  });

  test('no new code ever shows itself on screen, in any state', () {
    for (final state in [
      'failed',
      'rejected',
      'review_ready',
      'review_submitted',
      'duplicate_conflict',
      'expired',
    ]) {
      for (final code in [
        ..._validationCodes,
        ..._archiveCodes,
        ..._reviewCodes,
        'upload_batch_expired',
        'upload_item_not_retryable',
      ]) {
        for (final text in [
          uploadStatusText(state, errorCode: code),
          ?uploadDetailText(state, errorCode: code),
        ]) {
          expect(text, isNot(matches(_leak)), reason: '$state / $code');
        }
      }
    }
  });
}
