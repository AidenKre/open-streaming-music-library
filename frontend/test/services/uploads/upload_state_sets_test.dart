// Refactor APP-UPLOAD (guide A.4): before the upload state sets get one home,
// every copy of "ended" and every spelling of "reviewable" is shown to hold
// exactly the same members, by what it does, over every state name. A wrong
// member in an `onlyIfStateIn` guard lets a late read overwrite a newer local
// state, so each copy is checked through its own behaviour. The expected sets
// are written here by hand, never taken from production code.
import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/uploads/upload_duplicate_decisions.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_item_rules.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_review.dart';
import 'package:frontend/services/uploads/upload_review_rules.dart';
import 'package:frontend/services/uploads/upload_review_transport.dart';
import 'package:frontend/services/uploads/upload_source.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

/// Every server item state, every local intent state, and one unknown name.
const _every = [
  'allocating', 'allocated', 'transferring', 'receiving', 'validating',
  'review_ready', 'committing', 'imported', 'duplicate', 'expanded',
  'failed', 'duplicate_conflict', 'expired', 'cancelled', 'cancelling',
  'source_changed', 'needs_reselect', 'rejected', 'on_other_device',
  'review_submitted', 'teleporting',
];

/// Ended: nothing left to do.
const _ended = {'imported', 'duplicate', 'cancelled', 'expired'};

/// Reviewable: needs a decision in the review.
const _reviewable = {'review_ready', 'duplicate_conflict'};

UploadItem _item(String uuid, String state, {int reviewVersion = 0}) =>
    UploadItem.fromJson(
      itemJson(uuid, state: state, reviewVersion: reviewVersion),
    );

NewUploadIntent _new(String uuid) => NewUploadIntent(
  itemUuid: uuid,
  batchUuid: 'b-1',
  selectionIndex: 0,
  displayName: '$uuid.flac',
  descriptor: UploadSourceDescriptor(
    path: '/music/$uuid.flac',
    length: 3,
    sha256: 'ab' * 32,
  ),
);

/// Inserts one picked-here intent per state, item `i-<state>`.
Future<void> _seed(UploadHarness h) async {
  for (final s in _every) {
    await h.store.insertAll(h.token, [_new('i-$s')], state: s);
  }
}

Future<Map<String, (String, int)>> _rows(UploadHarness h) async => {
  for (final r in await h.db
      .customSelect(
        'SELECT item_uuid, last_state, updated_at FROM upload_intents',
      )
      .get())
    r.data['item_uuid'] as String: (
      r.data['last_state'] as String,
      r.data['updated_at'] as int,
    ),
};

class _Transport implements UploadReviewTransport {
  final sent = <String>[];
  @override
  Future<Map<String, dynamic>> send(
    ReviewActionKind kind,
    String itemUuid,
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) async {
    sent.add(itemUuid);
    return itemJson(itemUuid, state: 'duplicate', reviewVersion: 3);
  }
}

void main() {
  late UploadHarness h;
  tearDown(() => h.dispose());

  group('"ended" copies', () {
    setUp(() async => h = await UploadHarness.create());

    test('the server listing adopts a top-level item unless it ended', () async {
      await h.store.adoptListedItems(h.token, [
        for (final s in _every) _item('i-$s', s),
      ]);
      final rows = await _rows(h);
      for (final s in _every) {
        expect(rows.containsKey('i-$s'), !_ended.contains(s), reason: s);
      }
    });

    test('a ready row takes the state of a read only when that state ended',
        () async {
      for (final s in _every) {
        await h.store.insertAll(h.token, [_new('i-$s')], state: 'review_ready');
      }
      await h.store.mirrorReviewStates(h.token, [
        for (final s in _every) _item('i-$s', s),
      ]);
      final rows = await _rows(h);
      for (final s in _every) {
        expect(
          rows['i-$s']!.$1,
          _ended.contains(s) ? s : 'review_ready',
          reason: s,
        );
      }
    });

    test('Cancel writes nothing to an ended row and writes every other row',
        () async {
      h.offline = true; // no pass sends anything
      await _seed(h);
      final before = await _rows(h);
      h.clock.advance(const Duration(seconds: 1));
      for (final s in _every) {
        await h.manager.cancel('i-$s');
      }
      await h.pump();
      final after = await _rows(h);
      for (final s in _every) {
        expect(
          after['i-$s']!.$2 != before['i-$s']!.$2,
          !_ended.contains(s),
          reason: s,
        );
      }
    });
  });

  group('"reviewable" spellings', () {
    test('a review action marks the row submitted only from a reviewable '
        'state', () async {
      h = await UploadHarness.create();
      h.offline = true;
      await _seed(h);
      for (final s in _every) {
        await h.manager.submitReviewAction(
          'i-$s',
          ReviewActionKind.commit,
          reviewVersion: 1,
          body: {'base_review_version': 1, 'edits': {}, 'write_tags': false},
        );
      }
      final rows = await _rows(h);
      for (final s in _every) {
        expect(
          rows['i-$s']!.$1,
          _reviewable.contains(s) ? 'review_submitted' : s,
          reason: s,
        );
      }
    });

    test('a resolve-duplicate whose answer was lost is sent again only while '
        'the server still has the item reviewable at its version', () async {
      final transport = _Transport();
      h = await UploadHarness.create(review: transport);
      h.offline = true;
      for (final s in _every) {
        await h.store.insertAll(
          h.token,
          [_new('i-$s')],
          state: 'duplicate_conflict',
        );
        await h.manager.submitReviewAction(
          'i-$s',
          ReviewActionKind.resolveDuplicate,
          reviewVersion: 3,
          body: {'expected_review_version': 3, 'existing_track_uuid': 't-1'},
        );
      }
      await h.pump();
      expect(transport.sent, isEmpty);
      // Every action was sent before the app stopped; no answer arrived.
      await h.db.customUpdate(
        "UPDATE durable_submissions SET state = 'sent' "
        "WHERE kind = 'upload_resolve_duplicate'",
      );
      h.api.onGetItem = (uuid) async =>
          _item(uuid, uuid.substring(2), reviewVersion: 3);
      h.offline = false;
      await h.verify();
      h.manager.request('test', bypassBackoff: true);
      await h.pump();
      for (final s in _every) {
        expect(
          transport.sent.contains('i-$s'),
          _reviewable.contains(s),
          reason: s,
        );
      }
    });

    test('a row with a draft counts as an unsent review draft only in a '
        'reviewable state', () async {
      h = await UploadHarness.create();
      await _seed(h);
      await h.db.customUpdate(
        'UPDATE upload_intents SET draft_json = ?',
        variables: [Variable('{"v":1,"edits":{"title":"x"}}')],
      );
      final counts = await UploadLossReporter(
        intents: h.store,
        binding: h.binding,
      ).counts();
      expect(counts!.reviewDrafts, _reviewable.length);
      // Each reviewable state alone counts one.
      for (final s in _every) {
        await h.db.customUpdate(
          'UPDATE upload_intents SET draft_json = NULL',
        );
        await h.store.update(
          h.token,
          ['i-$s'],
          draftJson: const Value('{"v":1,"edits":{"title":"x"}}'),
        );
        final one = await UploadLossReporter(
          intents: h.store,
          binding: h.binding,
        ).counts();
        expect(one!.reviewDrafts, _reviewable.contains(s) ? 1 : 0, reason: s);
      }
    });

    // Pre-merge A7-01 widened the mirror rule: a failed or unpacked row also
    // follows the server's read when the page opens (DEV-7-23 point 4).
    test('an ended read replaces a row only while it is reviewable, failed, '
        'unpacked or waiting for another device', () async {
      h = await UploadHarness.create();
      await _seed(h);
      await h.store.mirrorReviewStates(h.token, [
        for (final s in _every) _item('i-$s', 'expired'),
      ]);
      final rows = await _rows(h);
      for (final s in _every) {
        final replaced =
            _reviewable.contains(s) ||
            const {'on_other_device', 'failed', 'expanded'}.contains(s);
        expect(rows['i-$s']!.$1, replaced ? 'expired' : s, reason: s);
      }
    });

    test('a read past the file that has not ended replaces only a failed '
        'row or one waiting for another device', () async {
      h = await UploadHarness.create();
      await _seed(h);
      await h.store.mirrorReviewStates(h.token, [
        for (final s in _every) _item('i-$s', 'validating'),
      ]);
      final rows = await _rows(h);
      for (final s in _every) {
        final replaced = const {'on_other_device', 'failed'}.contains(s);
        expect(rows['i-$s']!.$1, replaced ? 'validating' : s, reason: s);
      }
    });

    test('a read that still waits for the file replaces nothing: a failed '
        'row whose file never arrived keeps its Retry', () async {
      h = await UploadHarness.create();
      await _seed(h);
      for (final waiting in ['allocated', 'receiving', 'transferring']) {
        await h.store.mirrorReviewStates(h.token, [
          for (final s in _every) _item('i-$s', waiting),
        ]);
      }
      final rows = await _rows(h);
      for (final s in _every) {
        expect(rows['i-$s']!.$1, s, reason: s);
      }
    });

    test('the review snapshot holds the reviewable items', () async {
      h = await UploadHarness.create();
      h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
        'items': [for (final s in _every) itemJson('i-$s', state: s)],
        'next_after': null,
      });
      final review = UploadReview(
        api: h.api,
        intents: h.store,
        binding: h.binding,
        manager: h.manager,
        decisions: UploadDuplicateDecisions(),
      );
      final listed = {
        for (final i in await review.snapshot('b-1')) i.rawState,
      };
      expect(listed, _reviewable);
    });

    test('a review row offers Cancel and Play existing only when reviewable',
        () async {
      h = await UploadHarness.create();
      for (final s in _every) {
        final view = ReviewItemView.of(item: _item('i', s), online: true);
        expect(view.canCancel, _reviewable.contains(s), reason: s);
        expect(view.canPlayExisting, _reviewable.contains(s), reason: s);
      }
    });

    test('Review tags is offered for the reviewable states', () async {
      h = await UploadHarness.create();
      for (final s in _every) {
        expect(offersReview(s, null), _reviewable.contains(s), reason: s);
      }
    });
  });
}
