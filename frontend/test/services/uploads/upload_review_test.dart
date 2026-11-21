// Phase 7B.2c S8: the review model (spec §7 para 4; §4 commit).
//  * Snapshot: the ready items of the batch over ALL item pages (not just
//    the first 100), in the server's stable order; on Refresh the items
//    already in the snapshot are kept, whatever their state now, and newly
//    ready ones join in server order. ZIP children of a local archive get a
//    local intent (their draft and commit live there).
//  * Drafts: per item in the local intent (`draft_json`), explicit nulls
//    kept apart from untouched fields; a malformed draft reads as no edits.
//    Local keystrokes never change the server version.
//  * Submit: Confirm sends the draft's edits and the write-tags choice at
//    the item's review version; Skip sends empty edits and `write_tags:
//    false` whatever the draft holds; the acknowledged duplicates come from
//    the one place the duplicate decisions live (empty until the user
//    decides); Cancel this item is the manager's cancel.
import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_duplicate_decisions.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_review.dart';
import 'package:frontend/services/uploads/upload_review_transport.dart';

import '../../helpers/duplicate_check_fixtures.dart';
import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

class _Review implements UploadReviewTransport {
  final sent = <(ReviewActionKind, String, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> send(
    ReviewActionKind kind,
    String itemUuid,
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) async {
    sent.add((kind, itemUuid,
        jsonDecode(frozenBodyJson) as Map<String, dynamic>));
    return itemJson(itemUuid, state: 'committing', reviewVersion: 1);
  }
}

class _Decisions implements UploadDuplicateDecisions {
  AcknowledgedDuplicates acks = AcknowledgedDuplicates.none;
  final asked = <String>[];
  @override
  AcknowledgedDuplicates acknowledgementsFor(UploadItem item) {
    asked.add(item.itemUuid);
    return acks;
  }

  @override
  void choose(UploadItem item, DuplicateGroup group) {}

  @override
  Set<DuplicateGroup> chosenFor(UploadItem item) => const {};
}

Map<String, dynamic> _ready(String uuid, {
  int index = 0,
  String state = 'review_ready',
  String? parent,
  String member = '',
  int version = 1,
}) => {
  ...itemJson(uuid,
      batchUuid: 'u-1', state: state, selectionIndex: index,
      reviewVersion: version),
  'parent_item_uuid': parent,
  'member_order_key': member,
};

void main() {
  late UploadHarness h;
  late _Review transport;
  late _Decisions decisions;
  late UploadReview review;

  setUp(() async {
    transport = _Review();
    h = await UploadHarness.create(review: transport);
    h.feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
      fromCache: false,
    );
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    h.api.openPuts.single.complete(state: 'review_ready', batchUuid: 'u-1');
    await h.pump();
    decisions = _Decisions();
    review = UploadReview(
      api: h.api,
      intents: h.store,
      binding: h.binding,
      manager: h.manager,
      decisions: decisions,
    );
  });
  tearDown(() => h.dispose());

  /// Serves [items] in pages of [size], with opaque cursors.
  void pages(List<Map<String, dynamic>> items, {int size = 100}) {
    h.api.onListItems = (batch, after) async {
      final start = after == null ? 0 : int.parse(after);
      final end = (start + size).clamp(0, items.length);
      return UploadItemPage.fromJson({
        'items': items.sublist(start, end),
        'next_after': end < items.length ? '$end' : null,
      });
    };
  }

  group('snapshot', () {
    test('every page is read; only ready items, in server order', () async {
      final items = [
        for (var i = 0; i < 250; i++)
          _ready('i-$i',
              index: i, state: i % 5 == 0 ? 'validating' : 'review_ready'),
      ];
      pages(items);

      final snap = await review.snapshot('u-1');

      expect(
        [for (final i in snap) i.itemUuid],
        [for (var i = 0; i < 250; i++) if (i % 5 != 0) 'i-$i'],
      );
      expect(h.api.calls.where((c) => c.startsWith('listItems')),
          hasLength(3));
    });

    test('Refresh keeps the items already held, whatever their state, and '
        'adds the newly ready ones in server order', () async {
      pages([
        _ready('a', index: 0, state: 'imported'),
        _ready('b', index: 1, state: 'review_ready'),
        _ready('c', index: 2, state: 'cancelled'),
        _ready('d', index: 3, state: 'validating'),
      ]);

      final snap = await review.snapshot('u-1', keep: {'a', 'c'});

      expect([for (final i in snap) i.itemUuid], ['a', 'b', 'c']);
      expect(snap.first.rawState, 'imported');
    });

    test('the ready files of a local archive get a local intent', () async {
      pages([
        _ready('u-2', index: 0, state: 'expanded'),
        _ready('c-1', parent: 'u-2', member: 'd/01.flac'),
        _ready('c-2', parent: 'u-2', member: 'd/02.flac', state: 'validating'),
      ]);

      final snap = await review.snapshot('u-1');

      expect([for (final i in snap) i.itemUuid], ['c-1']);
      final states = await h.states();
      expect(states['c-1'], 'review_ready');
      expect(states['c-2'], 'validating');
    });

    test('a cursor the server already gave ends the read: each page is read '
        'once', () async {
      var reads = 0;
      h.api.onListItems = (batch, after) async {
        // Without the guard the read would never end; fail instead.
        if (++reads > 10) throw StateError('the same page read for ever');
        return UploadItemPage.fromJson({
          'items': [
            after == null
                ? _ready('a', index: 0)
                : _ready('b', index: 1),
          ],
          'next_after': 'x',
        });
      };

      final snap = await review.snapshot('u-1');

      expect([for (final i in snap) i.itemUuid], ['a', 'b']);
      expect(reads, 2);
    });

    test('a refused page is the caller\'s error', () async {
      h.api.onListItems = (_, _) async =>
          throw apiError(404, 'upload_batch_not_found', retryable: false);
      await expectLater(review.snapshot('u-1'), throwsA(anything));
    });

    test('item() reads the authoritative item', () async {
      h.api.onGetItem = (item) async => UploadItem.fromJson(
          _ready(item, version: 4));
      final item = await review.item('u-2');
      expect(item.reviewVersion, 4);
    });
  });

  group('drafts', () {
    test('a saved draft comes back with values, explicit nulls and untouched '
        'fields told apart', () async {
      final edit = const MetadataEdit.empty()
          .set('title', 'New title')
          .set('genre', null)
          .set('year', 1999);

      await review.saveDraft('u-2', edit);
      final back = await review.draftOf('u-2');

      expect(back, edit);
      expect(back.isTouched('genre'), isTrue);
      expect(back.values['genre'], isNull);
      expect(back.isTouched('artist'), isFalse);
    });

    test('each item keeps its own draft', () async {
      await h.store.adoptChildren(h.token, [
        UploadItem.fromJson(_ready('c-1', parent: 'u-2', member: 'x.flac')),
      ]);
      await review.saveDraft('u-2', const MetadataEdit.empty().set('title', 'A'));
      await review.saveDraft('c-1', const MetadataEdit.empty().set('title', null));

      expect((await review.draftOf('u-2')).values['title'], 'A');
      final other = await review.draftOf('c-1');
      expect(other.isTouched('title'), isTrue);
      expect(other.values['title'], isNull);
    });

    test('no draft, or an unreadable one, is no edits; unknown keys are '
        'dropped', () async {
      expect(await review.draftOf('u-2'), const MetadataEdit.empty());
      await h.db.customStatement(
          "UPDATE upload_intents SET draft_json = 'not json' "
          "WHERE item_uuid = 'u-2'");
      expect(await review.draftOf('u-2'), const MetadataEdit.empty());
      await h.db.customStatement(
          "UPDATE upload_intents SET draft_json = "
          "'{\"v\":1,\"edits\":{\"title\":\"T\",\"path\":\"/x\"}}' "
          "WHERE item_uuid = 'u-2'");
      expect(await review.draftOf('u-2'),
          const MetadataEdit.empty().set('title', 'T'));
    });

    test('saving a draft sends nothing and leaves the item state alone',
        () async {
      final callsBefore = h.api.calls.length;
      await review.saveDraft('u-2', const MetadataEdit.empty().set('title', 'X'));
      await h.pump();
      expect(h.api.calls.length, callsBefore);
      expect(transport.sent, isEmpty);
      expect((await h.states())['u-2'], 'review_ready');
    });
  });

  group('submit', () {
    UploadItem ready({int version = 3}) =>
        UploadItem.fromJson(_ready('u-2', version: version));

    test('Confirm sends the edits and the write-tags choice at the item\'s '
        'review version', () async {
      final edit = const MetadataEdit.empty()
          .set('title', 'New')
          .set('album', null);

      await review.confirm(ready(), edit, writeTags: true);
      await h.pump();

      final (kind, item, body) = transport.sent.single;
      expect(kind, ReviewActionKind.commit);
      expect(item, 'u-2');
      expect(body['base_review_version'], 3);
      expect(body['edits'], {'album': null, 'title': 'New'});
      expect(body['write_tags'], isTrue);
      expect(body['acknowledged_duplicates'],
          {'library_tracks': [], 'staged_items': []});
      expect(body['operation_uuid'], isA<String>());
    });

    test('Skip sends empty edits and write_tags false, whatever the draft '
        'holds', () async {
      await review.saveDraft('u-2', const MetadataEdit.empty().set('title', 'X'));

      await review.skip(ready());
      await h.pump();

      final body = transport.sent.single.$3;
      expect(body['edits'], <String, Object?>{});
      expect(body['write_tags'], isFalse);
      expect(body['base_review_version'], 3);
    });

    test('the acknowledged duplicates come from the duplicate decisions',
        () async {
      decisions.acks = AcknowledgedDuplicates(
        libraryTracks: {for (var i = 7; i >= 1; i--) 't-$i'},
        stagedItems: {'s-1'},
      );

      await review.confirm(ready(), const MetadataEdit.empty(),
          writeTags: false);
      await h.pump();

      expect(decisions.asked, ['u-2']);
      expect(transport.sent.single.$3['acknowledged_duplicates'], {
        'library_tracks': [for (var i = 1; i <= 7; i++) 't-$i'],
        'staged_items': ['s-1'],
      });
    });

    // 7B.2d S1: the real decisions, through the real commit body: the
    // full list of exact matches, however many the banner displays.
    test('Import as separate track puts all seven exact matches of the '
        'report in the commit body', () async {
      final real = UploadDuplicateDecisions();
      final withRealDecisions = UploadReview(
        api: h.api,
        intents: h.store,
        binding: h.binding,
        manager: h.manager,
        decisions: real,
      );
      final item = UploadItem.fromJson({
        ..._ready('u-2', version: 3),
        'duplicate_check': duplicateCheckJson(matches: [
          for (var i = 7; i >= 1; i--) libraryMatchJson('t-$i'),
          libraryMatchJson('fp-1', kind: 'fingerprint', score: 0.9),
        ]),
      });
      real.choose(item, DuplicateGroup.library);

      await withRealDecisions.confirm(item, const MetadataEdit.empty(),
          writeTags: false);
      await h.pump();

      expect(transport.sent.single.$3['acknowledged_duplicates'], {
        'library_tracks': [for (var i = 1; i <= 7; i++) 't-$i'],
        'staged_items': [],
      });
    });

    test('Cancel this item cancels it on the server', () async {
      await review.cancel('u-2');
      await h.pump();
      expect(h.api.calls, contains('cancelItem u-2'));
    });
  });

  test('the default duplicate decisions acknowledge nothing (7B.2d fills '
      'them)', () {
    expect(
        UploadDuplicateDecisions()
            .acknowledgementsFor(UploadItem.fromJson(_ready('u-2')))
            .isEmpty,
        isTrue);
  });

  // 7B.2d S6: the duplicate inputs reach the model. Spec §7: Use existing
  // track / Don't import = resolve-duplicate (terminal `duplicate`) at the
  // item's review version; Import as separate / Import both are recorded
  // in the one decisions store; Back to review "calls retry, which
  // refreshes the report"; a `duplicate_conflict` item is still in the
  // review (it needs a decision), so it is part of the snapshot.
  group('duplicates', () {
    test('resolve-duplicate sends the chosen library track at the item\'s '
        'review version', () async {
      await review.resolveDuplicate(
          UploadItem.fromJson(_ready('u-2', version: 3)), 't-9');
      await h.pump();

      final (kind, item, body) = transport.sent.single;
      expect(kind, ReviewActionKind.resolveDuplicate);
      expect(item, 'u-2');
      expect(body['expected_review_version'], 3);
      expect(body['existing_track_uuid'], 't-9');
      expect(body['operation_uuid'], isA<String>());
    });

    test('a duplicate choice is recorded in the decisions store', () {
      final real = UploadDuplicateDecisions();
      final withReal = UploadReview(
        api: h.api,
        intents: h.store,
        binding: h.binding,
        manager: h.manager,
        decisions: real,
      );
      final item = UploadItem.fromJson(_ready('u-2', version: 2));

      withReal.chooseDuplicates(item, DuplicateGroup.staged);

      expect(real.chosenFor(item), {DuplicateGroup.staged});
      expect(withReal.chosenDuplicates(item), {DuplicateGroup.staged});
    });

    test('Back to review retries the item at its current version', () async {
      h.api.onGetItem = (item) async => UploadItem.fromJson(
          _ready(item, state: 'duplicate_conflict', version: 4));
      int? sentVersion;
      h.api.onRetry = (item, version) async {
        sentVersion = version;
        return UploadItem.fromJson(
            _ready(item, state: 'validating', version: version + 1));
      };

      final outcome = await review.backToReview('u-2');

      expect(outcome, RetryOutcome.accepted);
      expect(sentVersion, 4);
      expect((await h.states())['u-2'], 'validating');
    });

    test('a duplicate_conflict item is part of the snapshot', () async {
      pages([
        _ready('a', index: 0),
        _ready('b', index: 1, state: 'duplicate_conflict'),
        _ready('c', index: 2, state: 'imported'),
      ]);
      final snap = await review.snapshot('u-1');
      expect([for (final i in snap) i.itemUuid], ['a', 'b']);
    });
  });

  // Review r1 #8: a fresh item read is the newer truth for an item the
  // client still holds as ready (expired or cancelled elsewhere; 7A.3c
  // expiry): the local mirror takes it, so the review shows it as no longer
  // reviewable. An item whose submit is in flight is not overwritten.
  group('r1 #8 a fresh read updates the local mirror of a ready item', () {
    test('a ready item that expired on the server is mirrored as expired',
        () async {
      h.api.onGetItem = (item) async => UploadItem.fromJson(
          _ready(item, state: 'expired'));
      final item = await review.item('u-2');
      expect(item.rawState, 'expired');
      expect((await h.states())['u-2'], 'expired');
    });

    test('a submitted item is left alone by a read that still says ready',
        () async {
      await h.store.update(h.token, ['u-2'],
          lastState: const Value('review_submitted'));
      h.api.onGetItem = (item) async => UploadItem.fromJson(_ready(item));
      await review.item('u-2');
      expect((await h.states())['u-2'], 'review_submitted');
    });
  });

  // 7-R1-21: every fresh read of an item mirrors an ended or changed server
  // state over a local `review_ready` or `duplicate_conflict`, wherever the
  // review reads it (navigation, Refresh / start through the snapshot).
  group('7-R1-21 an item that ended on the server', () {
    Future<Map<String, Object?>> row() async => (await h.intents())
        .firstWhere((r) => r['item_uuid'] == 'u-2');

    test('a duplicate_conflict item read as expired is mirrored', () async {
      await h.store.update(h.token, ['u-2'],
          lastState: const Value('duplicate_conflict'));
      h.api.onGetItem = (item) async =>
          UploadItem.fromJson(_ready(item, state: 'expired'));
      await review.item('u-2');
      expect((await row())['last_state'], 'expired');
    });

    test('Refresh (snapshot with keep) mirrors a kept item that expired',
        () async {
      pages([_ready('u-2', state: 'expired')]);
      final snap = await review.snapshot('u-1', keep: {'u-2'});
      expect([for (final i in snap) i.itemUuid], ['u-2']);
      expect((await row())['last_state'], 'expired');
    });

    test('the snapshot mirrors a duplicate_conflict item cancelled '
        'elsewhere', () async {
      await h.store.update(h.token, ['u-2'],
          lastState: const Value('duplicate_conflict'));
      pages([_ready('u-2', state: 'cancelled')]);
      await review.snapshot('u-1');
      expect((await row())['last_state'], 'cancelled');
    });

    test('the snapshot mirrors an item imported elsewhere', () async {
      pages([_ready('u-2', state: 'imported')]);
      await review.snapshot('u-1', keep: {'u-2'});
      expect((await row())['last_state'], 'imported');
    });

    test('a read that still says ready keeps the local refusal words',
        () async {
      await h.store.update(h.token, ['u-2'],
          lastErrorCode: const Value('tag_write_unsupported'));
      h.api.onGetItem = (item) async => UploadItem.fromJson(_ready(item));
      await review.item('u-2');
      pages([_ready('u-2')]);
      await review.snapshot('u-1');
      final r = await row();
      expect(r['last_state'], 'review_ready');
      expect(r['last_error_code'], 'tag_write_unsupported');
    });

    test('an item being submitted is never overwritten by the snapshot',
        () async {
      await h.store.update(h.token, ['u-2'],
          lastState: const Value('review_submitted'));
      pages([_ready('u-2', state: 'expired')]);
      await review.snapshot('u-1', keep: {'u-2'});
      expect((await row())['last_state'], 'review_submitted');
    });
  });

  // Review (7-fix-r1-fe) R-2: a read is not ordered against local writes, so
  // it never puts one reviewable state over the other (a read taken before a
  // Back to review / a local conflict would undo it). Only an ended state is
  // mirrored over a reviewable one.
  group('R-2 no reviewable state is mirrored over the other', () {
    Future<String?> state() async => (await h.intents())
        .firstWhere((r) => r['item_uuid'] == 'u-2')['last_state'] as String?;

    test('a late read of duplicate_conflict does not undo a Back to review',
        () async {
      h.api.onGetItem = (item) async =>
          UploadItem.fromJson(_ready(item, state: 'duplicate_conflict'));
      await review.item('u-2');
      pages([_ready('u-2', state: 'duplicate_conflict')]);
      await review.snapshot('u-1');
      expect(await state(), 'review_ready');
    });

    test('a late read of review_ready does not undo a conflict', () async {
      await h.store.update(h.token, ['u-2'],
          lastState: const Value('duplicate_conflict'));
      h.api.onGetItem = (item) async => UploadItem.fromJson(_ready(item));
      await review.item('u-2');
      pages([_ready('u-2')]);
      await review.snapshot('u-1');
      expect(await state(), 'duplicate_conflict');
    });
  });
}
