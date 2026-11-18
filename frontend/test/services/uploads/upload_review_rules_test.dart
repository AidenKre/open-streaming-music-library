// Phase 7B.2c S9: the review rules (model, pure; SC-26 keeps them out of the
// controller). Spec §7 para 4: "On submit disable duplicate action, poll
// accepted commit, advance only after durable imported/duplicate result or
// explicit user navigation; a failed item stays reviewable. New arriving
// ready items appear through `More items ready — Refresh` … not changing X
// mid-flow." The local intent is the live mirror of the item (the manager
// writes submit outcomes and poll results there), so its state and error
// win over the last item read; the item read gives the version, detected
// tags, tag-write support and the result track. Unknown tag-write support
// stays unknown. An item that expired or was cancelled meanwhile is no
// longer reviewable and offers nothing (7A.3c: ready items can expire).
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_review_rules.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

import '../../helpers/fake_uploads_api.dart' show itemJson;
import '../../helpers/upload_intent_record.dart';

UploadItem _item({
  String state = 'review_ready',
  int version = 2,
  bool? tagWrite = true,
  String? result,
  Map<String, dynamic>? error,
}) => UploadItem.fromJson({
  ...itemJson(
    'i-1',
    filename: 'disc1/song.flac',
    state: state,
    expectedBytes: 3,
    receivedBytes: 3,
    reviewVersion: version,
    error: error,
  ),
  'tag_write_supported': tagWrite,
  'result_track_uuid': result,
});

UploadIntentRecord _intent(String state, {String? code, String uuid = 'i-1',
    String batch = 'b-1', String? sha256}) => intentRecord(
  uuid,
  batchUuid: batch,
  displayName: 'song.flac',
  state: state,
  lastErrorCode: code,
  localBindingId: 'bind',
  expectedSha256: sha256,
);

ReviewItemView _view(UploadItem item, {UploadIntentRecord? intent,
    bool online = true}) =>
    ReviewItemView.of(item: item, intent: intent, online: online);

void main() {
  group('one item', () {
    test('a ready item can be confirmed, skipped, cancelled and previewed',
        () {
      final v = _view(_item(), intent: _intent('review_ready'));
      expect(v.itemUuid, 'i-1');
      expect(v.reviewVersion, 2);
      expect(v.displayName, 'disc1/song.flac');
      expect(v.statusText, 'Ready for review');
      expect(v.errorText, isNull);
      expect(v.reviewable, isTrue);
      expect(v.inFlight, isFalse);
      expect(v.done, isFalse);
      expect(v.canConfirm, isTrue);
      expect(v.canSkip, isTrue);
      expect(v.canCancel, isTrue);
      expect(v.canPreview, isTrue);
    });

    test('once submitted, nothing can be sent again until the answer is in',
        () {
      for (final s in ['review_submitted', 'committing']) {
        final v = _view(_item(), intent: _intent(s));
        expect(v.inFlight, isTrue, reason: s);
        expect(v.canConfirm, isFalse, reason: s);
        expect(v.canSkip, isFalse, reason: s);
        expect(v.canCancel, isFalse, reason: s);
        expect(v.reviewable, isFalse, reason: s);
      }
      expect(_view(_item(), intent: _intent('review_submitted')).statusText,
          'Sending');
      expect(_view(_item(), intent: _intent('committing')).statusText,
          'Importing');
    });

    test('the local intent wins over an older item read', () {
      final v = _view(_item(state: 'review_ready'),
          intent: _intent('imported'));
      expect(v.done, isTrue);
      expect(v.statusText, 'Imported');
    });

    test('without a local intent the item read decides', () {
      expect(_view(_item(state: 'committing')).inFlight, isTrue);
    });

    test('a refused or failed import stays reviewable with the reason in '
        'words', () {
      final stale = _view(_item(version: 3),
          intent: _intent('review_ready',
              code: 'upload_review_version_conflict'));
      expect(stale.reviewable, isTrue);
      expect(stale.canConfirm, isTrue);
      expect(stale.reviewVersion, 3);
      expect(stale.errorText,
          'This file changed on the server since you opened it. Check it '
          'and confirm again.');

      final failed = _view(_item(),
          intent: _intent('review_ready', code: 'upload_commit_failed'));
      expect(failed.reviewable, isTrue);
      expect(failed.errorText, "The import couldn't be finished. Try again.");
    });

    test('imported and duplicate are done: no action, the result track is '
        'known', () {
      for (final s in ['imported', 'duplicate']) {
        final v = _view(_item(state: s, result: 't-1'), intent: _intent(s));
        expect(v.done, isTrue, reason: s);
        expect(v.resultTrackUuid, 't-1');
        expect(v.canConfirm || v.canSkip || v.canCancel || v.canPreview,
            isFalse, reason: s);
      }
    });

    test('an item that expired or was cancelled meanwhile offers nothing and '
        'says so once, without an error loop', () {
      for (final s in ['expired', 'cancelled']) {
        final v = _view(_item(), intent: _intent(s));
        expect(v.reviewable, isFalse, reason: s);
        expect(v.inFlight, isFalse, reason: s);
        expect(v.done, isFalse, reason: s);
        expect(v.canConfirm || v.canSkip || v.canCancel || v.canPreview,
            isFalse, reason: s);
      }
      expect(_view(_item(), intent: _intent('expired')).statusText, 'Expired');
      expect(_view(_item(), intent: _intent('cancelled')).statusText,
          'Cancelled');
    });

    test('a duplicate conflict can still be cancelled; nothing else here '
        '(7B.2d adds its choices)', () {
      final v = _view(_item(state: 'duplicate_conflict'),
          intent: _intent('duplicate_conflict'));
      expect(v.statusText, 'Needs a decision');
      expect(v.canCancel, isTrue);
      expect(v.canConfirm, isFalse);
      expect(v.reviewable, isFalse);
    });

    test('offline: drafts stay editable, every network action is off', () {
      final v = _view(_item(), intent: _intent('review_ready'), online: false);
      expect(v.reviewable, isTrue);
      expect(v.canConfirm || v.canSkip || v.canCancel || v.canPreview, isFalse);
    });

    test('tag-write support: known yes, known no, and unknown stay apart', () {
      expect(_view(_item(tagWrite: true)).tagWriteSupported, isTrue);
      expect(_view(_item(tagWrite: false)).tagWriteSupported, isFalse);
      expect(_view(_item(tagWrite: null)).tagWriteSupported, isNull);
    });
  });

  group('advance', () {
    test('only a durable imported or duplicate result advances', () {
      for (final before in ['review_submitted', 'committing', 'review_ready']) {
        expect(reviewAdvances(before: before, after: 'imported'), isTrue);
        expect(reviewAdvances(before: before, after: 'duplicate'), isTrue);
      }
    });

    test('a failure, a conflict, a refusal or an expiry never advances', () {
      for (final after in [
        'review_ready',
        'failed',
        'duplicate_conflict',
        'expired',
        'cancelled',
        'committing',
        'review_submitted',
      ]) {
        expect(reviewAdvances(before: 'committing', after: after), isFalse,
            reason: after);
      }
    });

    test('an item already done does not advance again', () {
      expect(reviewAdvances(before: 'imported', after: 'imported'), isFalse);
      expect(reviewAdvances(before: null, after: 'imported'), isFalse);
    });
  });

  group('more items ready', () {
    // 7-R2-05: a ready item the server refuses to import is not news.
    test('7-R2-05 a ready item the server refuses to import is not', () {
      expect(
        moreItemsReady(
          snapshot: {'a'},
          batchUuid: 'b-1',
          intents: [
            _intent('review_ready', uuid: 'a'),
            _intent('review_ready',
                uuid: 'c', code: 'upload_library_links_unsupported'),
          ],
        ),
        isFalse,
      );
    });

    test('a ready item of this batch outside the snapshot is news', () {
      expect(
        moreItemsReady(
          snapshot: {'a', 'b'},
          batchUuid: 'b-1',
          intents: [
            _intent('review_ready', uuid: 'a'),
            _intent('review_ready', uuid: 'c'),
          ],
        ),
        isTrue,
      );
    });

    test('items held already, items not ready yet, and other batches are '
        'not', () {
      expect(
        moreItemsReady(
          snapshot: {'a'},
          batchUuid: 'b-1',
          intents: [
            _intent('review_ready', uuid: 'a'),
            _intent('validating', uuid: 'c'),
            _intent('review_ready', uuid: 'd', batch: 'b-2'),
          ],
        ),
        isFalse,
      );
    });
  });

  // Sign-off s7-app-texts review-8 #1: the review page words a lost received
  // file like the Uploads page: only a device with the file can send it.
  group('the server lost the received file', () {
    test('picked on this device: try again', () {
      final v = _view(_item(), intent: _intent('failed',
          code: 'upload_source_missing', sha256: 'abc'));
      expect(v.errorText,
          'The server no longer has the received file. Try again to send it.');
    });

    test('not on this device (or no record here): the true step', () {
      // The owner's wording (2026-11-17).
      const notHere = "The server no longer has the received file, and this "
          'device cannot find it. Cancel it and add it again.';
      expect(
          _view(_item(), intent: _intent('failed',
              code: 'upload_source_missing')).errorText,
          notHere);
      expect(
          _view(_item(state: 'failed', error: {
            'code': 'upload_source_missing',
            'message': 'gone',
            'retryable': true,
          }))
              .errorText,
          notHere);
    });
  });

  // Refactor APP-UPLOAD (sign-off s7-app-texts, cascade-8 review #1): the
  // review page reads the other-device check the way the Uploads page does,
  // so both pages say the same thing about an item in every state.
  group('another device is sending the upload', () {
    test('a waiting row of an upload being sent says so on the review page',
        () {
      final v = ReviewItemView.of(
        item: _item(state: 'allocated'),
        intent: _intent('on_other_device'),
        online: true,
        otherDeviceSending: {'b-1'},
      );
      expect(v.statusText, 'Waiting for the file');
      expect(v.errorText, 'Another device is sending this upload.');
    });

    test('the review page and the Uploads page show the same status and '
        'detail in every state', () {
      const states = [
        'allocating', 'allocated', 'transferring', 'receiving', 'validating',
        'review_ready', 'committing', 'imported', 'duplicate', 'expanded',
        'failed', 'duplicate_conflict', 'expired', 'cancelled', 'cancelling',
        'source_changed', 'needs_reselect', 'rejected', 'on_other_device',
        'review_submitted', 'teleporting',
      ];
      for (final state in states) {
        for (final code in [null, 'upload_source_missing', 'upload_slots_busy']) {
          for (final sha in [null, 'ab' * 32]) {
            for (final sending in [<String>{}, {'b-1'}]) {
              for (final a in [
                UploadsAvailability.available,
                UploadsAvailability.offline,
              ]) {
                for (final paused in [false, true]) {
                  final intent = _intent(state, code: code, sha256: sha);
                  final row = UploadsOverview.of(
                    intents: [intent],
                    progress: const {},
                    availability: a,
                    otherDeviceSending: sending,
                    transfersPaused: paused,
                  ).rows.single;
                  final view = ReviewItemView.of(
                    item: _item(state: state),
                    intent: intent,
                    online: a == UploadsAvailability.available,
                    otherDeviceSending: sending,
                    transfersPaused: paused,
                  );
                  expect(
                    (view.statusText, view.errorText),
                    (row.statusText, row.detailText),
                    reason: '$state $code here=${sha != null} '
                        'sending=$sending $a paused=$paused',
                  );
                }
              }
            }
          }
        }
      }
    });
  });

  // Refactor APP-UPLOAD: a file of an unpacked archive whose copy the server
  // lost reads the same on the review page as in the archive's file list.
  test('a lost file of an archive says to add the archive again', () {
    final child = UploadItem.fromJson({
      ..._item(state: 'failed', error: {'code': 'upload_source_missing'})
          .toJson(),
      'parent_item_uuid': 'zip-1',
    });
    final v = ReviewItemView.of(item: child, online: true);
    expect(
      v.errorText,
      'The server no longer has this file from the archive. Add the archive '
      'again to upload it.',
    );
  });

  // Review F7: without a local record the review reads the server's state,
  // with no bytes on this device, through the same check as the Uploads page.
  test('an item with no local record that the server is receiving reads as '
      'sent from another device; offline it reads Paused', () {
    final online = ReviewItemView.of(
      item: _item(state: 'receiving'),
      online: true,
    );
    expect(online.statusText, 'Uploading from another device');
    expect(online.errorText, 'Another device is sending this upload.');
    final offline = ReviewItemView.of(
      item: _item(state: 'receiving'),
      online: false,
    );
    expect(offline.statusText, 'Paused');
  });
}
