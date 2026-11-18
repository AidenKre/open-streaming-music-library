// 7B.1d S14: the seam for review actions (spec §7 para 2: "Allocation, PUT
// content, commit and resolve-duplicate all go through the shared
// DurableSubmission helper"; §4 commit / resolve-duplicate; SC-14: a new
// operation id only for a deliberately changed request, e.g. a new review
// version). The transport is an interface (the HTTP transport by default,
// a fake in these tests); the manager freezes the
// request with one operation id per review version, sends it through the
// runner, and resolves a lost answer by the item's status first.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_review_transport.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

class _FakeReview implements UploadReviewTransport {
  final sent = <(ReviewActionKind, String, Map<String, dynamic>)>[];
  Future<Map<String, dynamic>> Function(String item) answer = (item) async =>
      itemJson(item, state: 'committing', reviewVersion: 1);

  @override
  Future<Map<String, dynamic>> send(
    ReviewActionKind kind,
    String itemUuid,
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) {
    sent.add((
      kind,
      itemUuid,
      jsonDecode(frozenBodyJson) as Map<String, dynamic>,
    ));
    return answer(itemUuid);
  }
}

void main() {
  late UploadHarness h;
  late _FakeReview review;

  setUp(() async {
    review = _FakeReview();
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
  });
  tearDown(() => h.dispose());

  Future<Map<String, Object?>> intent() async => (await h.db
          .customSelect(
            "SELECT operation_uuid, review_generation, last_state "
            "FROM upload_intents WHERE item_uuid = 'u-2'",
          )
          .getSingle())
      .data;

  test('a commit is frozen with an operation id for its review version and '
      'sent once', () async {
    await h.manager.submitReviewAction(
      'u-2',
      ReviewActionKind.commit,
      reviewVersion: 1,
      body: {'base_review_version': 1, 'edits': {}, 'write_tags': false},
    );
    await h.pump();

    expect(review.sent, hasLength(1));
    final (kind, item, body) = review.sent.single;
    expect(kind, ReviewActionKind.commit);
    expect(item, 'u-2');
    final row = await intent();
    expect(body['operation_uuid'], row['operation_uuid']);
    expect(body['base_review_version'], 1);
    expect(row['review_generation'], 1);
    expect(row['last_state'], 'committing');
    final sub = (await h.submissions())
        .firstWhere((s) => s['operation_uuid'] == row['operation_uuid']);
    expect(sub['kind'], 'upload_commit');
    expect(sub['state'], 'accepted');
  });

  test('a repeated tap of the same review version reuses the operation id; '
      'a new review version gets a new one', () async {
    review.answer = (_) async =>
        throw NetworkException('lost', attemptsMade: 1);
    final body = {'base_review_version': 1, 'edits': {}, 'write_tags': false};
    await h.manager.submitReviewAction('u-2', ReviewActionKind.commit,
        reviewVersion: 1, body: body);
    await h.pump();
    final first = (await intent())['operation_uuid'];

    h.api.onGetItem = (item) async =>
        UploadItem.fromJson(itemJson(item, state: 'review_ready',
            reviewVersion: 1));
    review.answer = (item) async =>
        itemJson(item, state: 'committing', reviewVersion: 1);
    await h.manager.submitReviewAction('u-2', ReviewActionKind.commit,
        reviewVersion: 1, body: body);
    await h.pump();
    expect((await intent())['operation_uuid'], first);
    expect(review.sent[1].$3['operation_uuid'], first);

    await h.manager.submitReviewAction('u-2', ReviewActionKind.commit,
        reviewVersion: 2,
        body: {'base_review_version': 2, 'edits': {}, 'write_tags': true});
    await h.pump();
    expect((await intent())['operation_uuid'], isNot(first));
    expect((await intent())['review_generation'], 2);
  });

  // 7-R1-29 (M18): the operation id is reused only for the same review
  // version, also while the old version's operation is still unresolved.
  test('a new review version mints a new operation id while the old one is '
      'still unresolved', () async {
    review.answer = (_) async =>
        throw NetworkException('lost', attemptsMade: 1);
    h.api.onGetItem = (_) async =>
        throw NetworkException('still lost', attemptsMade: 1);
    await h.manager.submitReviewAction('u-2', ReviewActionKind.commit,
        reviewVersion: 1,
        body: {'base_review_version': 1, 'edits': {}, 'write_tags': false});
    await h.pump();
    final first = (await intent())['operation_uuid'] as String;
    final old = (await h.submissions())
        .firstWhere((s) => s['operation_uuid'] == first);
    expect(old['state'], isIn(['sent', 'ambiguous']));

    await h.manager.submitReviewAction('u-2', ReviewActionKind.commit,
        reviewVersion: 2,
        body: {'base_review_version': 2, 'edits': {}, 'write_tags': true});
    final row = await intent();
    expect(row['operation_uuid'], isNot(first));
    expect(row['review_generation'], 2);
    final frozen = (await h.submissions())
        .where((s) => s['operation_uuid'] == row['operation_uuid']);
    expect(frozen, hasLength(1));
  });

  test('a lost answer the server acted on: the item status settles it and '
      'the action is not sent again', () async {
    review.answer = (_) async =>
        throw NetworkException('lost', attemptsMade: 1);
    await h.manager.submitReviewAction('u-2', ReviewActionKind.commit,
        reviewVersion: 1, body: {'base_review_version': 1});
    await h.pump();

    h.api.onGetItem = (item) async => UploadItem.fromJson(
        itemJson(item, state: 'imported', reviewVersion: 1));
    h.clock.advance(const Duration(minutes: 1));
    h.timers.fire();
    await h.pump();

    expect(review.sent, hasLength(1));
    expect((await intent())['last_state'], 'imported');
  });

  test('resolve-duplicate goes the same way under its own kind', () async {
    await h.manager.submitReviewAction('u-2', ReviewActionKind.resolveDuplicate,
        reviewVersion: 1,
        body: {'expected_review_version': 1, 'existing_track_uuid': 't-1'});
    await h.pump();
    expect(review.sent.single.$1, ReviewActionKind.resolveDuplicate);
    final op = (await intent())['operation_uuid'];
    final sub =
        (await h.submissions()).firstWhere((s) => s['operation_uuid'] == op);
    expect(sub['kind'], 'upload_resolve_duplicate');
  });

  // Refactor APP-UPLOAD (B.9): the "route unavailable" default is gone;
  // without a transport the manager sends through the uploads API.
  test('without a transport given, a review action goes to the uploads API',
      () async {
    final plain = await UploadHarness.create();
    addTearDown(plain.dispose);
    plain.feature = h.feature;
    await plain.verify();
    await plain.manager.addFiles([await plain.file('a.flac', 'abc')]);
    await plain.pump();
    plain.api.openPuts.single.complete(state: 'review_ready');
    await plain.pump();

    await plain.manager.submitReviewAction(
      'u-2',
      ReviewActionKind.commit,
      reviewVersion: 1,
      body: {'base_review_version': 1, 'edits': {}, 'write_tags': false},
    );
    await plain.pump();

    expect(plain.api.calls, contains('commit u-2'));
    expect(
      (await plain.states())['u-2'],
      'committing',
    );
  });
}
