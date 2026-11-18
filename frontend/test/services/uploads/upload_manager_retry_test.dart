// Phase 7B.2c S6: retrying a failed item (spec §4 `POST …/retry
// {expected_review_version}`; 7A.2c: a retryable `failed` item goes back to
// `validating`, or to `allocated` when the server no longer has its source,
// with `review_version + 1`; anything else answers 409
// `upload_item_not_retryable`; a stale version 409
// `upload_review_version_conflict`). The manager reads the item's current
// version first (the status is authoritative), sends the retry once, and
// stores the answer. Back to `allocated` means the bytes go again: a fresh
// transfer id (7B.1d hand-over) and a pass. A stale retry never revives an
// item the server ended (7-L15). Another server's answer leaves the row
// exactly as it was (SC-01).
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_manager.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

void main() {
  late UploadHarness h;

  setUp(() async {
    h = await UploadHarness.create();
    h.feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
      fromCache: false,
    );
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    h.api.openPuts.single.complete(state: 'failed', batchUuid: 'u-1');
    await h.pump();
    await h.store.update(h.token, ['u-2'],
        lastErrorCode: const Value('probe_timeout'));
  });
  tearDown(() => h.dispose());

  void serverItem(String state, {int version = 3, String? code}) {
    h.api.onGetItem = (item) async => UploadItem.fromJson(itemJson(item,
        batchUuid: 'u-1',
        state: state,
        reviewVersion: version,
        error: code == null ? null : {'code': code, 'retryable': true}));
  }

  Future<Map<String, Object?>> row() async => (await h.db
          .customSelect(
            "SELECT last_state, last_error_code, transfer_operation_uuid "
            "FROM upload_intents WHERE item_uuid = 'u-2'",
          )
          .getSingle())
      .data;

  List<String> retries() =>
      [for (final c in h.api.calls) if (c.startsWith('retry')) c];

  test('a retryable failure is retried at the current version and the item '
      'goes back to checking', () async {
    serverItem('failed', version: 3, code: 'probe_timeout');
    int? sentVersion;
    h.api.onRetry = (item, version) async {
      sentVersion = version;
      return UploadItem.fromJson(itemJson(item,
          batchUuid: 'u-1', state: 'validating', reviewVersion: version + 1));
    };

    final outcome = await h.manager.retry('u-2');
    await h.pump();

    expect(outcome, RetryOutcome.accepted);
    expect(sentVersion, 3);
    expect(retries(), hasLength(1));
    final r = await row();
    expect(r['last_state'], 'validating');
    expect(r['last_error_code'], isNull);
  });

  test('a retry the server answers with allocated sends the file again under '
      'a fresh transfer id', () async {
    serverItem('failed', code: 'upload_source_missing');
    final before = (await row())['transfer_operation_uuid'];
    final putsBefore = h.api.openPuts.length;
    h.api.onRetry = (item, version) async {
      // From now on the server's status says the item waits for its bytes.
      serverItem('allocated', version: version + 1);
      return UploadItem.fromJson(itemJson(item,
          batchUuid: 'u-1', state: 'allocated', reviewVersion: version + 1));
    };

    await h.manager.retry('u-2');
    await h.pump();

    final r = await row();
    expect(r['transfer_operation_uuid'], isNotNull);
    expect(r['transfer_operation_uuid'], isNot(before));
    expect(h.api.openPuts.length, putsBefore + 1);
  });

  test('a stale retry never revives an item the server ended: the row '
      'mirrors the server and nothing else is sent', () async {
    serverItem('expired', version: 3);
    h.api.onRetry = (_, _) async => throw apiError(
        409, 'upload_item_not_retryable', retryable: false);

    final outcome = await h.manager.retry('u-2');
    await h.pump();

    expect(outcome, RetryOutcome.notRetryable);
    expect(retries(), hasLength(1));
    expect((await row())['last_state'], 'expired');
  });

  test('a version that moved meanwhile: the row takes the server state and '
      'the user is told it changed', () async {
    var gets = 0;
    h.api.onGetItem = (item) async => UploadItem.fromJson(itemJson(item,
        batchUuid: 'u-1',
        state: gets++ == 0 ? 'failed' : 'validating',
        reviewVersion: gets == 1 ? 3 : 4));
    h.api.onRetry = (_, _) async => throw apiError(
        409, 'upload_review_version_conflict', retryable: false);

    final outcome = await h.manager.retry('u-2');
    await h.pump();

    expect(outcome, RetryOutcome.changed);
    expect(retries(), hasLength(1));
    expect((await row())['last_state'], 'validating');
  });

  test("another server's answer leaves the row exactly as it was", () async {
    serverItem('failed', code: 'probe_timeout');
    h.api.onRetry = (_, _) async {
      // As the real UploadsApi does: report to the gate, then rethrow.
      final e = ServerInstanceChangedException(
        boundInstanceId: 'inst-1',
        servedBy: 'inst-2',
      );
      h.gate.gate.reportDifferentInstance(h.gate.gate.verifiedConnection!, e);
      throw e;
    };
    final before = await row();

    await expectLater(
      h.manager.retry('u-2'),
      throwsA(isA<ServerInstanceChangedException>()),
    );
    await h.pump();

    expect(await row(), before);
  });

  test('a lost answer is an error for the user; the row is unchanged',
      () async {
    serverItem('failed', code: 'probe_timeout');
    h.api.onRetry = (_, _) async =>
        throw NetworkException('lost', attemptsMade: 1);
    final before = await row();

    await expectLater(
      h.manager.retry('u-2'),
      throwsA(isA<NetworkException>()),
    );
    expect(await row(), before);
  });

  test('offline, nothing is sent', () async {
    final callsBefore = h.api.calls.length;
    h.offline = true;
    await expectLater(
      h.manager.retry('u-2'),
      throwsA(isA<UploadsUnavailable>()),
    );
    expect(retries(), isEmpty);
    expect(h.api.calls.length, callsBefore);
  });
}
