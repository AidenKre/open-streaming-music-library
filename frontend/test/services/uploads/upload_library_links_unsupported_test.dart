// 7-R1-UI-01 (review r1 addendum): the server's library cannot take an
// uploaded file (backend 7-R1-10: `upload_library_links_unsupported`,
// retryable false; the item goes back to `review_ready` with that error).
// Confirming again would fail again, and the user cannot fix it: the item
// says so in plain words (one function, upload_status_text.dart; never the
// code or the server's message), is not offered again for import, and keeps
// Cancel. On the Uploads page it needs attention rather than review.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_review_rules.dart';
import 'package:frontend/services/uploads/upload_status_text.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

const _code = 'upload_library_links_unsupported';
const _words =
    "This server's music library can't accept uploads. Ask whoever runs the "
    'server to check its storage.';

UploadItem _item({Map<String, dynamic>? error}) => UploadItem.fromJson({
  'item_uuid': 'i-1',
  'batch_uuid': 'b-1',
  'parent_item_uuid': null,
  'filename': 'song.flac',
  'selection_index': 0,
  'member_order_key': '',
  'state': 'review_ready',
  'expected_bytes': 3,
  'expected_sha256': null,
  'received_bytes': 3,
  'review_version': 2,
  'error': error,
  'created_at': 1,
  'updated_at': 1,
  'tag_write_supported': true,
  'result_track_uuid': null,
});

UploadIntentRecord _intent(String state, {String? code}) => UploadIntentRecord(
  itemUuid: 'i-1',
  batchUuid: 'b-1',
  parentItemUuid: null,
  selectionIndex: 0,
  displayName: 'song.flac',
  lastState: state,
  lastErrorCode: code,
  lastErrorMessage: 'raw server text',
  operationUuid: null,
  transferOperationUuid: null,
  reviewGeneration: null,
  draftJson: null,
  localBindingId: 'bind-1',
  createdAtMs: 0,
  updatedAtMs: 0,
  expectedLength: 3,
  expectedSha256: null,
  descriptor: null,
);

void main() {
  group('words', () {
    test('the detail says what is wrong and who can fix it', () {
      expect(uploadDetailText('review_ready', errorCode: _code), _words);
    });

    test('the status does not call it ready for review', () {
      expect(
        uploadStatusText('review_ready', errorCode: _code),
        "Can't be imported",
      );
    });
  });

  group('Uploads page row', () {
    UploadsOverview overview({
      UploadsAvailability availability = UploadsAvailability.available,
    }) => UploadsOverview.of(
      intents: [_intent('review_ready', code: _code)],
      progress: const {},
      availability: availability,
    );

    test('it needs attention, offers Cancel, and neither review nor retry',
        () {
      final row = overview().rows.single;
      expect(row.statusText, "Can't be imported");
      expect(row.detailText, _words);
      expect(row.needsAttention, isTrue);
      expect(row.offersCancel, isTrue);
      expect(row.canCancel, isTrue);
      expect(row.offersReviewTags, isFalse);
      expect(row.offersRetry, isFalse);
    });

    test('the counts put it under attention, not ready for review', () {
      final counts = overview().counts;
      expect(counts.needsAttention, 1);
      expect(counts.readyForReview, 0);
    });

    test('offline, Cancel is offered but off', () {
      final row = overview(
        availability: UploadsAvailability.offline,
      ).rows.single;
      expect(row.offersCancel, isTrue);
      expect(row.canCancel, isFalse);
    });

    test('another ready item is untouched', () {
      final row = UploadsOverview.of(
        intents: [_intent('review_ready')],
        progress: const {},
        availability: UploadsAvailability.available,
      ).rows.single;
      expect(row.statusText, 'Ready for review');
      expect(row.offersReviewTags, isTrue);
      expect(row.needsAttention, isFalse);
    });
  });

  group('review', () {
    test('from the local intent: no import again, Cancel kept, the words '
        'shown', () {
      final v = ReviewItemView.of(
        item: _item(),
        intent: _intent('review_ready', code: _code),
        online: true,
      );
      expect(v.statusText, "Can't be imported");
      expect(v.errorText, _words);
      expect(v.canConfirm, isFalse);
      expect(v.canSkip, isFalse);
      expect(v.canCancel, isTrue);
    });

    test('from the item read alone, the same', () {
      final v = ReviewItemView.of(
        item: _item(error: {
          'code': _code,
          'message': 'raw server text',
          'retryable': false,
        }),
        online: true,
      );
      expect(v.errorText, _words);
      expect(v.canConfirm, isFalse);
      expect(v.canSkip, isFalse);
      expect(v.canCancel, isTrue);
    });

    test('a retryable commit failure can still be confirmed again', () {
      final v = ReviewItemView.of(
        item: _item(),
        intent: _intent('review_ready', code: 'upload_commit_failed'),
        online: true,
      );
      expect(v.canConfirm, isTrue);
      expect(v.canSkip, isTrue);
    });
  });
}
