// A ready item carrying an error code the app does not know (a new server
// refusal, or `upload_library_links_unsupported`, which no server raises any
// more) shows the app's generic words for a failed import, never the code,
// and stays offered for import: the app does not guess that the server would
// refuse it again.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_review_rules.dart';
import 'package:frontend/services/uploads/upload_status_text.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

import '../../helpers/fake_uploads_api.dart' show itemJson;
import '../../helpers/upload_intent_record.dart';

const _codes = ['upload_library_links_unsupported', 'a_refusal_from_later'];
const _generic = "The import couldn't be finished. Try again.";

UploadItem _item({String? code}) => UploadItem.fromJson({
  ...itemJson(
    'i-1',
    state: 'review_ready',
    expectedBytes: 3,
    receivedBytes: 3,
    reviewVersion: 2,
    error: code == null
        ? null
        : {'code': code, 'message': 'raw server text', 'retryable': false},
  ),
  'tag_write_supported': true,
  'result_track_uuid': null,
});

UploadIntentRecord _intent({String? code}) => intentRecord(
  'i-1',
  batchUuid: 'b-1',
  displayName: 'song.flac',
  state: 'review_ready',
  lastErrorCode: code,
  lastErrorMessage: 'raw server text',
  localBindingId: 'bind-1',
  expectedLength: 3,
);

void main() {
  for (final code in _codes) {
    group(code, () {
      test('the words are the generic ones for a failed import', () {
        expect(uploadStatusText('review_ready', errorCode: code),
            'Ready for review');
        expect(uploadDetailText('review_ready', errorCode: code), _generic);
      });

      test('the Uploads row offers review and counts as ready', () {
        final overview = UploadsOverview.of(
          intents: [_intent(code: code)],
          progress: const {},
          availability: UploadsAvailability.available,
        );
        final row = overview.rows.single;
        expect(row.statusText, 'Ready for review');
        expect(row.detailText, _generic);
        expect(row.offersReviewTags, isTrue);
        expect(row.needsAttention, isFalse);
        expect(overview.counts.readyForReview, 1);
      });

      test('the review offers Confirm and Skip, from the local row or the '
          'item read alone', () {
        for (final v in [
          ReviewItemView.of(
              item: _item(), intent: _intent(code: code), online: true),
          ReviewItemView.of(item: _item(code: code), online: true),
        ]) {
          expect(v.errorText, _generic);
          expect(v.canConfirm, isTrue);
          expect(v.canSkip, isTrue);
          expect(v.canCancel, isTrue);
        }
      });

      test('it is news for "More items ready" when outside the snapshot', () {
        expect(
          moreItemsReady(
            snapshot: const {},
            batchUuid: 'b-1',
            intents: [_intent(code: code)],
          ),
          isTrue,
        );
      });
    });
  }
}
