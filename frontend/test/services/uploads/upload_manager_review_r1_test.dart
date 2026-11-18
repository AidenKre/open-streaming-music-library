// 7B.1d review r1 (7B.1d-review.md) regression tests, one group per
// finding. Each fails on 7ce67a1.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

AdvertisedFeature<UploadsFeature> _limits(int receives) => AdvertisedFeature(
  UploadsFeature(
    version: 1,
    limits: UploadLimits(receivesPerUser: receives),
  ),
  fromCache: false,
);

void main() {
  late UploadHarness h;

  setUp(() async => h = await UploadHarness.create());
  tearDown(() => h.dispose());

  Future<Map<String, Object?>> row(String item) async =>
      (await h.intents()).firstWhere((r) => r['item_uuid'] == item);

  int count(String call) => h.api.calls.where((c) => c == call).length;

  test('#1 a cancel made while the allocation is in flight survives its '
      'answer: the file is cancelled on the server and never sent',
      () async {
    h.feature = _limits(1);
    final answer = Completer<AllocationResult>();
    final allocate = h.api.onAllocate;
    h.api.onAllocate = (body) async {
      await answer.future;
      return allocate(body);
    };
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await pumpEventQueue();
    expect(h.api.calls, ['allocate u-1']);

    await h.manager.cancel('u-2');
    answer.complete(await allocate(h.api.allocations.single));
    await h.pump();

    expect(h.api.puts, isEmpty);
    expect(count('cancelItem u-2'), 1);
    expect((await row('u-2'))['last_state'], 'cancelled');
    expect(h.api.calls.length, lessThan(10), reason: '${h.api.calls}');
  });

  test('#1 a poll answer read before a cancel does not overwrite it',
      () async {
    await h.dispose();
    final visible = ValueNotifier(false);
    h = await UploadHarness.create(visible: visible);
    h.feature = _limits(1);
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    h.api.openPuts.single.complete(state: 'validating', batchUuid: 'u-1');
    await h.pump();

    final page = Completer<UploadItemPage>();
    h.api.onListItems = (batch, after) => page.future;
    visible.value = true; // requests a poll
    await pumpEventQueue();
    expect(h.api.calls.last, 'listItems u-1');

    h.api.onCancel = (item) async => throw apiError(
      409,
      'upload_item_not_cancellable',
      retryable: false,
    );
    await h.manager.cancel('u-2');
    expect((await row('u-2'))['last_state'], UploadIntentState.cancelling);
    page.complete(UploadItemPage.fromJson({
      'items': [itemJson('u-2', batchUuid: 'u-1', state: 'review_ready')],
      'next_after': null,
    }));
    await pumpEventQueue();
    // The poll's answer, read before the cancel, must not replace it.
    expect((await row('u-2'))['last_state'], UploadIntentState.cancelling);
  });

  test('#2 a lost answer for a file the server stored, then the source is '
      'deleted: the status settles it, no reselect', () async {
    h.feature = _limits(1);
    final a = await h.file('a.flac', 'abc');
    await h.verify();
    await h.manager.addFiles([a]);
    await h.pump();
    h.api.openPuts.single.fail(NetworkException('lost', attemptsMade: 1));
    await h.pump();
    File(a.path).deleteSync();
    h.api.onGetItem = (item) async =>
        UploadItem.fromJson(itemJson(item, state: 'validating'));

    h.clock.advance(const Duration(minutes: 1));
    h.timers.fire();
    await h.pump();

    expect((await row('u-2'))['last_state'], 'validating');
    expect(h.api.puts, hasLength(1));
  });

  test('#3 a permanent refusal that leaves the item allocated ends in a '
      'local failure, with no request loop', () async {
    h.feature = _limits(1);
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    h.api.openPuts.single.fail(
      apiError(422, 'upload_length_mismatch', retryable: false),
    );
    await h.pump();
    await h.pump();

    final r = await row('u-2');
    expect(r['last_state'], 'failed');
    expect(r['last_error_code'], 'upload_length_mismatch');
    expect(count('getItem u-2'), lessThan(4), reason: '${h.api.calls}');
    expect(h.api.puts, hasLength(1));
  });

  test('#3 a refusal whose follow-up GET fails also ends in a local failure '
      'without a loop', () async {
    h.feature = _limits(1);
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    h.api.onGetItem = (item) async =>
        throw apiError(404, 'upload_item_not_found', retryable: false);
    h.api.openPuts.single.fail(
      apiError(422, 'upload_digest_mismatch', retryable: false),
    );
    await h.pump();
    await h.pump();

    final r = await row('u-2');
    expect(r['last_state'], 'failed');
    expect(r['last_error_code'], 'upload_digest_mismatch');
    expect(count('getItem u-2'), lessThan(4), reason: '${h.api.calls}');
  });

  test('#4 a success on the other slot does not cut a busy wait short',
      () async {
    h.feature = _limits(2);
    await h.verify();
    await h.manager.addFiles([
      await h.file('a.flac', 'abc'),
      await h.file('b.flac', 'abcd'),
    ]);
    await h.pump();
    // Two slots race to the wire: which PUT the fake sees first is not
    // the manager's to fix, so the busy file is whichever one answers busy.
    final [busy, other] = h.api.openPuts;
    busy.fail(
        apiError(503, 'upload_slots_busy', retryable: true, retryAfterS: 30));
    await h.pump();
    other.complete();
    await h.pump();

    h.manager.request('appResume', bypassBackoff: true);
    await h.pump();
    expect(h.api.puts, hasLength(2),
        reason: 'no file is sent again before retry_after');

    h.clock.advance(const Duration(seconds: 30));
    h.timers.fire();
    await h.pump();
    expect(h.api.puts, hasLength(3));
    expect(h.api.puts.last.itemUuid, busy.itemUuid);
  });

  test('#5 a different-server answer to the pre-PUT status GET leaves the '
      'intent exactly as before the pass', () async {
    h.feature = _limits(1);
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    h.api.openPuts.single.fail(
      apiError(503, 'upload_slots_busy', retryable: true, retryAfterS: 5),
    );
    await h.pump();
    final before = await row('u-2');
    expect(before['last_error_code'], 'upload_slots_busy');

    h.api.onGetItem = (item) async {
      final e = ServerInstanceChangedException(
        boundInstanceId: 'inst-1',
        servedBy: 'inst-2',
      );
      h.gate.gate.reportDifferentInstance(h.gate.gate.verifiedConnection!, e);
      throw e;
    };
    h.clock.advance(const Duration(seconds: 5));
    h.timers.fire();
    await h.pump();

    expect(count('getItem u-2'), greaterThanOrEqualTo(1));
    final after = await row('u-2');
    expect(after['last_state'], before['last_state']);
    expect(after['last_error_code'], before['last_error_code']);
    expect(after['transfer_operation_uuid'], before['transfer_operation_uuid']);
  });

  test('#6 a different-server answer on one slot stops the other PUT',
      () async {
    h.feature = _limits(2);
    await h.verify();
    await h.manager.addFiles([
      await h.file('a.flac', 'abc'),
      await h.file('b.flac', 'abcd'),
    ]);
    await h.pump();
    final [a, b] = h.api.openPuts;
    final e = ServerInstanceChangedException(
      boundInstanceId: 'inst-1',
      servedBy: 'inst-2',
    );
    h.gate.gate.reportDifferentInstance(h.gate.gate.verifiedConnection!, e);
    a.fail(e);
    await h.pump();

    expect(b.aborted, isTrue);
  });

  test('#7 quiesce waits for running transfers to settle; nothing is sent '
      'or written after it returns', () async {
    h.feature = _limits(1);
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    final put = h.api.openPuts.single;
    put.onProgress!(1);
    expect(h.manager.progress.value, {'u-2': 1});
    // The aborted PUT's follow-up work must finish inside quiesce.
    await h.manager.quiesce();
    expect(h.manager.progress.value, isEmpty,
        reason: 'the transfer settled before quiesce returned');
    final calls = h.api.calls.length;
    final rows = await h.intents();
    await h.pump();
    expect(put.aborted, isTrue);
    expect(h.api.calls.length, calls);
    expect(await h.intents(), rows);
  });
}
