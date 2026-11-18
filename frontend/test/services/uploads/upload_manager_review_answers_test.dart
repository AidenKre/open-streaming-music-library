// Phase 7B.2c S3: how the upload manager settles a review action's answer
// (spec §4 commit; 7A.3a: 422 `tag_write_unsupported` (retryable: a changed
// choice may succeed) and 409 `upload_review_version_conflict` are refused
// before acceptance, with no receipt; SC-14: a new operation id only for a
// deliberately changed request).
//  * A refusal (4xx other than 401/408/429) ends the operation whatever its
//    `retryable` says: the same body would be refused again, so it is never
//    resent (no loop).
//  * After a refused operation, the next submit at the same review version
//    gets a new operation id (the refused one has no receipt), so a changed
//    choice (write tags off) is not a SubmissionConflict.
//  * A submit marks the item `review_submitted` with no error before the
//    send, so the review flow can tell its outcome from an older error.
//  * A refusal's own code is what the item shows.
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/uploads/upload_review_transport.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

class _Review implements UploadReviewTransport {
  final sent = <Map<String, dynamic>>[];
  Future<Map<String, dynamic>> Function(String item) answer = (item) async =>
      itemJson(item, state: 'committing', reviewVersion: 1);

  @override
  Future<Map<String, dynamic>> send(
    ReviewActionKind kind,
    String itemUuid,
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) {
    sent.add(jsonDecode(frozenBodyJson) as Map<String, dynamic>);
    final reply = answer(itemUuid);
    if (abortTrigger == null) return reply;
    // Like the real transport: an abort (quiesce) ends a held answer.
    return Future.any([
      reply,
      abortTrigger.then<Map<String, dynamic>>(
          (_) => throw const UploadTransferAborted()),
    ]);
  }
}

Map<String, dynamic> _body({bool writeTags = false, int version = 1}) => {
  'base_review_version': version,
  'edits': <String, Object?>{},
  'write_tags': writeTags,
  'acknowledged_duplicates': {'library_tracks': [], 'staged_items': []},
};

void main() {
  late UploadHarness h;
  late _Review review;

  setUp(() async {
    review = _Review();
    h = await UploadHarness.create(review: review);
    h.feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
      fromCache: false,
    );
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    h.api.openPuts.single.complete(state: 'review_ready');
    await h.pump();
    h.api.onGetItem = (item) async => UploadItem.fromJson(
        itemJson(item, state: 'review_ready', reviewVersion: 1));
  });
  tearDown(() => h.dispose());

  Future<Map<String, Object?>> intent() async => (await h.db
          .customSelect(
            "SELECT operation_uuid, last_state, last_error_code "
            "FROM upload_intents WHERE item_uuid = 'u-2'",
          )
          .getSingle())
      .data;

  Future<void> submit(Map<String, dynamic> body, {int version = 1}) =>
      h.manager.submitReviewAction('u-2', ReviewActionKind.commit,
          reviewVersion: version, body: body);

  /// Lets queued work run without waiting for the runner to go idle (a held
  /// answer keeps a pass running).
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Lets every backoff and poll timer fire once more.
  Future<void> laterPasses() async {
    for (var i = 0; i < 3; i++) {
      h.clock.advance(const Duration(minutes: 5));
      h.timers.fire();
      await h.pump();
    }
  }

  test('422 tag_write_unsupported (retryable) is a refusal: the item is '
      'reviewable with the code and the body is never resent', () async {
    review.answer = (_) async =>
        throw apiError(422, 'tag_write_unsupported', retryable: true);

    await submit(_body(writeTags: true));
    await h.pump();
    await laterPasses();

    expect(review.sent, hasLength(1));
    final row = await intent();
    expect(row['last_state'], 'review_ready');
    expect(row['last_error_code'], 'tag_write_unsupported');
    final sub = (await h.submissions())
        .firstWhere((s) => s['operation_uuid'] == row['operation_uuid']);
    expect(sub['state'], 'rejected');
  });

  test('after a refusal, a changed choice at the same version goes out under '
      'a new operation id', () async {
    review.answer = (_) async =>
        throw apiError(422, 'tag_write_unsupported', retryable: true);
    await submit(_body(writeTags: true));
    await h.pump();
    final refused = (await intent())['operation_uuid'];

    review.answer = (item) async =>
        itemJson(item, state: 'committing', reviewVersion: 1);
    await submit(_body(writeTags: false));
    await h.pump();

    expect(review.sent, hasLength(2));
    expect(review.sent[1]['operation_uuid'], isNot(refused));
    expect(review.sent[1]['write_tags'], isFalse);
    expect((await intent())['last_state'], 'committing');
  });

  test('a stale version (409) leaves the item reviewable with that code, '
      'even when the item still carries an older error', () async {
    h.api.onGetItem = (item) async => UploadItem.fromJson(itemJson(item,
        state: 'review_ready',
        reviewVersion: 2,
        error: {'code': 'upload_commit_failed', 'retryable': true}));
    review.answer = (_) async => throw apiError(
        409, 'upload_review_version_conflict', retryable: false);

    await submit(_body());
    await h.pump();
    await laterPasses();

    expect(review.sent, hasLength(1));
    final row = await intent();
    expect(row['last_state'], 'review_ready');
    expect(row['last_error_code'], 'upload_review_version_conflict');
  });

  test('a submit marks the item review_submitted with no error before the '
      'answer arrives', () async {
    await h.store.update(h.token, ['u-2'],
        lastErrorCode: const Value('upload_commit_failed'));
    final answer = Completer<Map<String, dynamic>>();
    review.answer = (_) => answer.future;

    await submit(_body());
    await settle();

    final row = await intent();
    expect(row['last_state'], 'review_submitted');
    expect(row['last_error_code'], isNull);

    answer.complete(itemJson('u-2', state: 'committing', reviewVersion: 1));
    await h.pump();
    expect((await intent())['last_state'], 'committing');
  });

  test('a lost answer keeps the item review_submitted until its status '
      'settles it', () async {
    review.answer = (_) async =>
        throw NetworkException('lost', attemptsMade: 1);
    await submit(_body());
    await h.pump();
    expect((await intent())['last_state'], 'review_submitted');

    h.api.onGetItem = (item) async => UploadItem.fromJson(
        itemJson(item, state: 'committing', reviewVersion: 1));
    await laterPasses();
    expect((await intent())['last_state'], 'committing');
    expect(review.sent, hasLength(1));
  });

  test('a server error (5xx) is not a refusal: status first, then the same '
      'operation is resent', () async {
    var n = 0;
    review.answer = (item) async {
      if (n++ == 0) throw apiError(500, 'internal', retryable: true);
      return itemJson(item, state: 'committing', reviewVersion: 1);
    };
    await submit(_body());
    await h.pump();
    await laterPasses();

    expect(review.sent, hasLength(2));
    expect(review.sent[1]['operation_uuid'], review.sent[0]['operation_uuid']);
    expect((await intent())['last_state'], 'committing');
  });

  test('a changed body under the same version while the first one is still '
      'unsettled is a conflict, and nothing new is sent', () async {
    final answer = Completer<Map<String, dynamic>>();
    review.answer = (_) => answer.future;
    await submit(_body());
    await settle();

    await expectLater(
      submit(_body(writeTags: true)),
      throwsA(isA<SubmissionConflict>()),
    );
    answer.complete(itemJson('u-2', state: 'committing', reviewVersion: 1));
    await h.pump();
    expect(review.sent, hasLength(1));
  });

  test('a submit for a state other than review_ready does not overwrite it',
      () async {
    await h.store.update(h.token, ['u-2'],
        lastState: const Value('committing'));
    final answer = Completer<Map<String, dynamic>>();
    review.answer = (_) => answer.future;

    await submit(_body());
    await settle();

    expect((await intent())['last_state'], 'committing');
    answer.complete(itemJson('u-2', state: 'committing', reviewVersion: 1));
    await h.pump();
  });

  // Review r1 #1: after an accepted commit failed on the server (item back
  // to review_ready at a new version), a Confirm still carrying the old
  // version must not reuse the settled operation: it goes out (and the
  // server answers), so the item never stays "Sending".
  test('r1 #1 a settled operation is never reused: an old-version Confirm '
      'goes out and the item does not stay review_submitted', () async {
    await submit(_body());
    await h.pump();
    expect((await intent())['last_state'], 'committing');
    // The commit failed on the server: review_ready at version 2.
    await h.store.update(h.token, ['u-2'],
        lastState: const Value('review_ready'),
        lastErrorCode: const Value('upload_commit_failed'));
    h.api.onGetItem = (item) async => UploadItem.fromJson(
        itemJson(item, state: 'review_ready', reviewVersion: 2));
    review.answer = (_) async => throw apiError(
        409, 'upload_review_version_conflict', retryable: false);

    await submit(_body()); // still version 1
    await h.pump();

    expect(review.sent, hasLength(2));
    expect(review.sent[1]['operation_uuid'],
        isNot(review.sent[0]['operation_uuid']));
    final row = await intent();
    expect(row['last_state'], 'review_ready');
    expect(row['last_error_code'], 'upload_review_version_conflict');
  });

  // Review r1 #2: a refusal whose follow-up item read fails still leaves the
  // item reviewable (with the refusal's code), never review_submitted.
  test('r1 #2 a refusal whose follow-up read fails leaves the item '
      'reviewable with the refusal code', () async {
    review.answer = (_) async =>
        throw apiError(422, 'tag_write_unsupported', retryable: true);
    h.api.onGetItem = (_) async =>
        throw NetworkException('lost', attemptsMade: 1);

    await submit(_body(writeTags: true));
    await h.pump();

    final row = await intent();
    expect(row['last_state'], 'review_ready');
    expect(row['last_error_code'], 'tag_write_unsupported');
  });

  // Review r1 #3: a 4xx on the status query (after a lost answer) is not a
  // refusal of the commit: the operation stays unsettled and is resolved by
  // a later status read.
  test('r1 #3 a 4xx on the status query does not settle the operation as '
      'refused', () async {
    review.answer = (_) async =>
        throw NetworkException('lost', attemptsMade: 1);
    await submit(_body());
    await h.pump();

    h.api.onGetItem = (_) async =>
        throw apiError(403, 'forbidden', retryable: false);
    await laterPasses();
    var row = await intent();
    final sub = (await h.submissions())
        .firstWhere((s) => s['operation_uuid'] == row['operation_uuid']);
    expect(sub['state'], isNot('rejected'));
    expect(row['last_state'], 'review_submitted');

    h.api.onGetItem = (item) async => UploadItem.fromJson(
        itemJson(item, state: 'committing', reviewVersion: 1));
    await laterPasses();
    row = await intent();
    expect(row['last_state'], 'committing');
    expect(review.sent, hasLength(1));
  });

  // 7B.2d review r1 #3: a resolve-duplicate sent from `duplicate_conflict`
  // (Use existing track in the conflict view) whose answer is lost. The
  // item still reading `duplicate_conflict` (or `review_ready`) at the same
  // version proves the resolve was NOT acted on (only `duplicate` does), so
  // the same operation is sent again; for a commit, `duplicate_conflict`
  // still proves the commit was acted on.
  group('r1 (7B.2d) #3 a lost resolve answer from duplicate_conflict', () {
    Map<String, dynamic> resolveBody() => {
      'expected_review_version': 1,
      'existing_track_uuid': 't-1',
    };

    Future<void> fromConflict() async {
      await h.store.update(h.token, ['u-2'],
          lastState: const Value('duplicate_conflict'));
    }

    for (final still in ['duplicate_conflict', 'review_ready']) {
      test('the item still reads $still: the same operation is sent again',
          () async {
        await fromConflict();
        var n = 0;
        review.answer = (item) async {
          if (n++ == 0) throw NetworkException('lost', attemptsMade: 1);
          return itemJson(item, state: 'duplicate', reviewVersion: 1);
        };
        h.api.onGetItem = (item) async => UploadItem.fromJson(
            itemJson(item, state: still, reviewVersion: 1));

        await h.manager.submitReviewAction(
            'u-2', ReviewActionKind.resolveDuplicate,
            reviewVersion: 1, body: resolveBody());
        await h.pump();
        await laterPasses();

        expect(review.sent, hasLength(2));
        expect(review.sent[1]['operation_uuid'],
            review.sent[0]['operation_uuid']);
        expect((await intent())['last_state'], 'duplicate');
      });
    }

    test('the item reads duplicate: accepted, not sent again', () async {
      await fromConflict();
      review.answer = (_) async =>
          throw NetworkException('lost', attemptsMade: 1);
      h.api.onGetItem = (item) async => UploadItem.fromJson(
          itemJson(item, state: 'duplicate', reviewVersion: 1));

      await h.manager.submitReviewAction(
          'u-2', ReviewActionKind.resolveDuplicate,
          reviewVersion: 1, body: resolveBody());
      await h.pump();
      await laterPasses();

      expect(review.sent, hasLength(1));
      expect((await intent())['last_state'], 'duplicate');
    });

    test('guard: a lost commit answer whose item reads duplicate_conflict '
        'was acted on (not sent again)', () async {
      review.answer = (_) async =>
          throw NetworkException('lost', attemptsMade: 1);
      h.api.onGetItem = (item) async => UploadItem.fromJson(
          itemJson(item, state: 'duplicate_conflict', reviewVersion: 1));

      await submit(_body());
      await h.pump();
      await laterPasses();

      expect(review.sent, hasLength(1));
      expect((await intent())['last_state'], 'duplicate_conflict');
    });
  });
}
