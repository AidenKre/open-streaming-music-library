// 7B.1d S11: a relaunch rebuilds from the intents and the server (spec §7
// para 3 "Reopening/restarting reconstructs server work"; SC-14 status
// first). A new manager over the same database resumes every unfinished
// intent of the current binding: an interrupted PUT asks for the item's
// status before anything is sent (a completed file is never sent again),
// an interrupted allocation asks for the batch first, and rows of an
// earlier sign-in (a rotated binding) are never sent.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';

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
  });
  tearDown(() => h.dispose());

  /// The app dies: the old manager is dropped without any clean-up, and a
  /// new one starts on the same database with a fresh fake server view.
  Future<void> relaunch() async {
    final api = FakeUploadsApi(gate: h.gate.gate)
      ..onGetItem = h.api.onGetItem
      ..onGetBatch = h.api.onGetBatch;
    h.api = api;
    h.manager = h.build();
    h.manager.start();
    await h.pump();
  }

  test('killed mid-transfer, the server finished the file: the relaunch '
      'asks first and sends nothing', () async {
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    expect(h.api.openPuts, hasLength(1));

    h.api.onGetItem = (item) async =>
        UploadItem.fromJson(itemJson(item, state: 'validating'));
    await relaunch();

    expect(h.api.calls, ['getItem u-2']);
    expect(h.api.puts, isEmpty);
    expect((await h.states())['u-2'], 'validating');
  });

  test('killed mid-transfer, the server never finished: the relaunch sends '
      'it again under the same operation id', () async {
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    final op = (await h.intents()).single['transfer_operation_uuid'];

    await relaunch();

    expect(h.api.calls.first, 'getItem u-2');
    expect(h.api.puts, hasLength(1));
    expect((await h.intents()).single['transfer_operation_uuid'], op);
  });

  test('killed during the allocation: the relaunch asks for the batch '
      'before sending it again', () async {
    h.api.onAllocate = (_) => Completer<AllocationResult>().future; // dies
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    // Verify without waiting on the old manager: its pass never ends.
    unawaited(h.gate.gate.startConnection('http://test'));
    await pumpEventQueue();
    h.gate.respond(h.instanceId);
    await pumpEventQueue();
    expect(h.api.calls, ['allocate u-1']);

    h.api.onGetBatch = (b) async => UploadBatch.fromJson(batchJson(b));
    await relaunch();

    expect(h.api.calls.first, 'getBatch u-1');
    expect(h.api.calls.where((c) => c.startsWith('allocate')), isEmpty);
  });

  test('a file that needs reselecting stays so; nothing is sent', () async {
    final a = await h.file('a.flac', 'abc');
    await h.manager.addFiles([a]);
    File(a.path).deleteSync();
    await h.verify();
    expect((await h.states())['u-2'], UploadIntentState.needsReselect);

    await relaunch();
    expect(h.api.puts, isEmpty);
    expect((await h.states())['u-2'], UploadIntentState.needsReselect);
  });

  test('rows of an earlier sign-in are never sent', () async {
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.manager.quiesce();
    await h.binding.rotate(); // logout, then a new sign-in

    await h.verify();
    await relaunch();

    expect(h.api.calls, isEmpty);
    expect((await h.states())['u-2'], 'allocating');
  });
}
