// Sign-off (owner, 2026-11-17): the server could not read the prepared copy
// it made for an import (`upload_prepared_unreadable`, retryable true; the
// item goes back to `review_ready`). The app says exactly the approved words
// (one function, upload_status_text.dart; never the code or the server's
// message), and the item can be confirmed again: it stays ready for review,
// not "needs attention".
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_review_rules.dart';
import 'package:frontend/services/uploads/upload_status_text.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

const _code = 'upload_prepared_unreadable';
const _words = "The server couldn't read the file after preparing it.";

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

UploadIntentRecord _intent() => const UploadIntentRecord(
  itemUuid: 'i-1',
  batchUuid: 'b-1',
  parentItemUuid: null,
  selectionIndex: 0,
  displayName: 'song.flac',
  lastState: 'review_ready',
  lastErrorCode: _code,
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
  test('the detail says exactly the approved words; the status stays '
      '"Ready for review"', () {
    expect(uploadDetailText('review_ready', errorCode: _code), _words);
    expect(uploadStatusText('review_ready', errorCode: _code),
        'Ready for review');
  });

  test('on the Uploads page it is ready for review, not needing attention',
      () {
    final overview = UploadsOverview.of(
      intents: [_intent()],
      progress: const {},
      availability: UploadsAvailability.available,
    );
    final row = overview.rows.single;
    expect(row.detailText, _words);
    expect(row.needsAttention, isFalse);
    expect(row.offersReviewTags, isTrue);
    expect(row.canReviewTags, isTrue);
    expect(row.offersCancel, isTrue);
    expect(overview.counts.readyForReview, 1);
    expect(overview.counts.needsAttention, 0);
  });

  test('in review the import can be confirmed again (Retry), from the '
      'local intent', () {
    final v = ReviewItemView.of(
      item: _item(),
      intent: _intent(),
      online: true,
    );
    expect(v.errorText, _words);
    expect(v.canConfirm, isTrue);
    expect(v.canSkip, isTrue);
    expect(v.canCancel, isTrue);
  });

  test('from the item read alone, the same', () {
    final v = ReviewItemView.of(
      item: _item(error: {
        'code': _code,
        'message': 'raw server text',
        'retryable': true,
      }),
      online: true,
    );
    expect(v.errorText, _words);
    expect(v.canConfirm, isTrue);
    expect(v.canSkip, isTrue);
  });
}
