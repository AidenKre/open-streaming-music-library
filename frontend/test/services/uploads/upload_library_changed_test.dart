// The server refuses to import a file when its library folder, or the
// file's place in it, was changed outside the server (replaced by a symbolic
// link by hand): `upload_library_changed`, not retryable; the item goes back
// to `review_ready` with that code. Confirming again would be refused again,
// and the item stays refused for good: after the server's admin fixes the
// folder, the file is added again. The item says so in plain words
// (one function, upload_status_text.dart; never the code or the server's
// message), is not offered for import again, and keeps Cancel. On the
// Uploads page it needs attention rather than review, and it is not news for
// "More items ready". A code the app does not know keeps the generic words
// (upload_unknown_review_code_test.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_review_rules.dart';
import 'package:frontend/services/uploads/upload_status_text.dart';
import 'package:frontend/services/uploads/upload_zip_children.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

import '../../helpers/fake_uploads_api.dart' show FakeUploadsApi, itemJson;
import '../../helpers/upload_intent_record.dart';

const _code = 'upload_library_changed';
// A single file: Cancel removes the refused copy (added again without it,
// the new file would meet a "Same audio as" notice that says both will be
// imported, untrue for the refused copy).
const _words =
    "This file could not be imported: the server's library folder was "
    "changed outside the server. After the server's admin fixes it, cancel "
    'this upload and add the file again.';

// A file of an archive: the person added the archive, and neither the
// archive's row nor its file list offers Cancel, so adding the archive again
// is what they can do.
const _archiveWords =
    "This file could not be imported: the server's library folder was "
    "changed outside the server. After the server's admin fixes it, add the "
    'archive again.';

UploadItem _item({Map<String, dynamic>? error, String? parent}) =>
    UploadItem.fromJson({
      ...itemJson(
        'i-1',
        state: 'review_ready',
        expectedBytes: 3,
        receivedBytes: 3,
        reviewVersion: 2,
        error: error,
      ),
      'tag_write_supported': true,
      'result_track_uuid': null,
      'parent_item_uuid': parent,
    });

UploadIntentRecord _intent(String state, {String? code}) => intentRecord(
  'i-1',
  batchUuid: 'b-1',
  displayName: 'song.flac',
  state: state,
  lastErrorCode: code,
  lastErrorMessage: 'raw server text',
  localBindingId: 'bind-1',
  expectedLength: 3,
);

void main() {
  group('words', () {
    test('the detail says what is wrong and who can fix it', () {
      expect(uploadDetailText('review_ready', errorCode: _code), _words);
    });

    test('a file from an archive is told to add the archive again', () {
      expect(
        uploadDetailText('review_ready', errorCode: _code, fromArchive: true),
        _archiveWords,
      );
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

    test('a file from an archive, in the review: the archive words', () {
      final v = ReviewItemView.of(
        item: _item(
          parent: 'zip',
          error: {'code': _code, 'message': 'x', 'retryable': false},
        ),
        online: true,
      );
      expect(v.errorText, _archiveWords);
      expect(v.canConfirm, isFalse);
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

  test('it is not news for "More items ready"', () {
    expect(
      moreItemsReady(
        snapshot: const {},
        batchUuid: 'b-1',
        intents: [_intent('review_ready', code: _code)],
      ),
      isFalse,
    );
  });

  test('a file of an archive with it offers no review, needs attention and '
      'counts as failed', () async {
    final api = FakeUploadsApi();
    api.onListItems = (batch, after) async => UploadItemPage.fromJson({
      'items': [
        {
          ...itemJson('c1', batchUuid: 'b-1', state: 'review_ready',
              error: {'code': _code, 'message': 'x', 'retryable': false}),
          'parent_item_uuid': 'zip',
          'member_order_key': 'd/01.flac',
        },
        {
          ...itemJson('c2', batchUuid: 'b-1', state: 'review_ready',
              selectionIndex: 1),
          'parent_item_uuid': 'zip',
          'member_order_key': 'd/02.flac',
        },
      ],
      'next_after': null,
    });
    final result = await UploadZipChildren(api).load('b-1', 'zip');
    final [refused, ready] = result.children;
    expect(refused.offersReviewTags, isFalse);
    expect(refused.needsAttention, isTrue);
    expect(refused.detailText, _archiveWords);
    expect(ready.offersReviewTags, isTrue);
    expect(result.valid, 1);
    expect(result.failed, 1);
  });
}
