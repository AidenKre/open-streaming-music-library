// Phase 7B.2d S4: the review rules with duplicates (model, pure).
// Spec §7 Duplicate UX: exact library match → "Until the user picks one,
// `Confirm and import` and `Skip edits and import` are disabled for that
// item, because an exact match requires an explicit decision. After Import
// as separate track they work normally." Staged exact match: "Until one is
// chosen, Confirm and Skip are disabled, as for a library exact match."
// Fingerprint: "advisory: the default remains importing (Confirm/Skip edits
// work unchanged)". `duplicate_conflict`: "Use existing track or Back to
// review". Every duplicate action is a network action (online only) and is
// offered only while the item is in the state it applies to: an item that
// expired or was cancelled while its banner is on screen offers none.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/uploads/upload_duplicate_banners.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_review_rules.dart';

import '../../helpers/duplicate_check_fixtures.dart';
import '../../helpers/upload_intent_record.dart';

UploadIntentRecord _intent(String state) => intentRecord(
  'i-1',
  batchUuid: 'b-1',
  displayName: 'i-1.flac',
  state: state,
  localBindingId: 'bind',
);

ReviewItemView _view(UploadItem item, {String? state, bool online = true,
    Set<DuplicateGroup> chosen = const {}}) =>
    ReviewItemView.of(
      item: item,
      intent: _intent(state ?? item.rawState),
      online: online,
      chosen: chosen,
    );

void main() {
  final exactLibrary = reviewItem('i-1', check: duplicateCheckJson(matches: [
    libraryMatchJson('t-1'),
  ]));
  final exactStaged = reviewItem('i-1', check: duplicateCheckJson(matches: [
    stagedMatchJson('i-0'),
  ]));
  final fingerprintOnly = reviewItem('i-1', check: duplicateCheckJson(
    matches: [
      libraryMatchJson('t-fp', kind: 'fingerprint', score: 0.9),
      stagedMatchJson('i-0', kind: 'fingerprint', score: 0.9),
    ],
  ));

  test('an exact library match disables Confirm and Skip until Import as '
      'separate track is chosen', () {
    final before = _view(exactLibrary);
    expect(before.canConfirm, isFalse);
    expect(before.canSkip, isFalse);
    expect(before.canCancel, isTrue);
    expect(before.canPreview, isTrue);
    expect(before.canDecideDuplicates, isTrue);
    expect(before.useExistingTrackUuid, 't-1');
    expect(before.duplicates.needsChoice, isTrue);

    final after = _view(exactLibrary, chosen: {DuplicateGroup.library});
    expect(after.canConfirm, isTrue);
    expect(after.canSkip, isTrue);
    expect(after.duplicates.needsChoice, isFalse);
  });

  test('an exact staged match disables Confirm and Skip until Import both',
      () {
    expect(_view(exactStaged).canConfirm, isFalse);
    expect(_view(exactStaged).canSkip, isFalse);
    final after = _view(exactStaged, chosen: {DuplicateGroup.staged});
    expect(after.canConfirm, isTrue);
    expect(after.canSkip, isTrue);
  });

  test('a fingerprint-only match never disables Confirm or Skip; Don\'t '
      'import is offered', () {
    final v = _view(fingerprintOnly);
    expect(v.canConfirm, isTrue);
    expect(v.canSkip, isTrue);
    expect(v.dontImportTrackUuid, 't-fp');
    expect(v.useExistingTrackUuid, isNull);
  });

  test('a report not checked yet blocks nothing (the server enforces exact '
      'matches) and is shown as not checked', () {
    final v = _view(reviewItem('i-1'));
    expect(v.canConfirm, isTrue);
    expect(v.duplicates.coverage, 'Not checked for duplicates yet');
  });

  test('offline: no duplicate action', () {
    final v = _view(exactLibrary, online: false);
    expect(v.canDecideDuplicates, isFalse);
    expect(v.useExistingTrackUuid, isNull);
    expect(_view(fingerprintOnly, online: false).dontImportTrackUuid,
        isNull);
  });

  test('an item that is no longer reviewable (sent, expired, cancelled, '
      'imported) offers no duplicate action', () {
    for (final s in ['review_submitted', 'committing', 'expired',
        'cancelled', 'imported', 'duplicate']) {
      final v = _view(exactLibrary, state: s);
      expect(v.canDecideDuplicates, isFalse, reason: s);
      expect(v.useExistingTrackUuid, isNull, reason: s);
      expect(v.dontImportTrackUuid, isNull, reason: s);
      expect(v.canBackToReview, isFalse, reason: s);
      expect(v.conflict, isNull, reason: s);
    }
  });

  group('duplicate_conflict', () {
    final conflicted = reviewItem('i-1', state: 'duplicate_conflict',
        check: duplicateCheckJson(),
        conflicts: [
          libraryMatchJson('t-gone', available: false),
          libraryMatchJson('t-new'),
        ]);

    test('Use existing (the first available new match) and Back to review',
        () {
      final v = _view(conflicted);
      expect(v.conflict, isA<DuplicateConflictView>());
      expect(v.conflict!.rows, hasLength(2));
      expect(v.useExistingTrackUuid, 't-new');
      expect(v.canBackToReview, isTrue);
      expect(v.canConfirm, isFalse);
      expect(v.canSkip, isFalse);
      expect(v.canDecideDuplicates, isFalse);
      expect(v.statusText, 'Needs a decision');
    });

    test('offline: shown, but nothing can be sent', () {
      final v = _view(conflicted, online: false);
      expect(v.conflict, isNotNull);
      expect(v.useExistingTrackUuid, isNull);
      expect(v.canBackToReview, isFalse);
    });
  });

  test('Play existing: a reviewable item or a conflict, online only', () {
    expect(_view(exactLibrary).canPlayExisting, isTrue);
    expect(_view(exactLibrary, online: false).canPlayExisting, isFalse);
    expect(_view(exactLibrary, state: 'expired').canPlayExisting, isFalse);
    expect(_view(exactLibrary, state: 'duplicate_conflict').canPlayExisting,
        isTrue);
    expect(
        _view(exactLibrary, state: 'duplicate_conflict', online: false)
            .canPlayExisting,
        isFalse);
  });
}
