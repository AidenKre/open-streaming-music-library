// 7B.1d S9: the transfer stall watchdog (7B.1c trap 3: `putStream` has no
// timeout of its own). A PUT whose progress hasn't moved for the stall
// timeout (time from the SC-20 clock, checked by an injected timer) is
// aborted; the next try asks for the item's status first and resends under
// the same transfer operation id (never a fresh one after a timeout).
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

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
  });
  tearDown(() => h.dispose());

  void check() => h.timers.fire(UploadManager.stallCheckInterval);

  test('no progress for the stall timeout aborts the PUT; the retry reuses '
      'the operation id after a status GET', () async {
    final op = (await h.intents()).single['transfer_operation_uuid'];
    final put = h.api.openPuts.single;

    h.clock.advance(UploadManager.stallTimeout - const Duration(seconds: 1));
    check();
    await h.pump();
    expect(put.aborted, isFalse);

    h.clock.advance(const Duration(seconds: 1));
    check();
    await h.pump();
    expect(put.aborted, isTrue);

    h.clock.advance(const Duration(minutes: 5));
    h.timers.fire();
    await h.pump();
    expect(h.api.puts, hasLength(2));
    expect((await h.intents()).single['transfer_operation_uuid'], op);
    final calls = h.api.calls;
    expect(
      calls.sublist(calls.indexOf('putContent u-2') + 1,
          calls.lastIndexOf('putContent u-2')),
      contains('getItem u-2'),
    );
  });

  // A7-03 (pre-merge review): during the wait after a stall no byte moves;
  // the row says the upload was interrupted, not "Uploading".
  test('a stalled transfer reads interrupted, not uploading, while it waits',
      () async {
    final put = h.api.openPuts.single;
    h.clock.advance(UploadManager.stallTimeout);
    check();
    await h.pump();
    expect(put.aborted, isTrue);

    final intent = (await h.intents()).single;
    expect(intent['last_state'], 'allocated');
    expect(intent['last_error_code'], 'upload_interrupted');
    final row = UploadsOverview.of(
      intents: await h.store.forBinding(h.token),
      progress: h.manager.progress.value,
      availability: UploadsAvailability.available,
    ).rows.single;
    expect(row.statusText, 'Queued');
    expect(row.detailText, 'The upload was interrupted. It will start again.');
    expect(row.sending, isFalse);
  });

  test('progress keeps a slow transfer alive', () async {
    final put = h.api.openPuts.single;
    for (var i = 1; i <= 3; i++) {
      h.clock.advance(UploadManager.stallTimeout - const Duration(seconds: 1));
      put.onProgress!(i);
      check();
      await h.pump();
    }
    expect(put.aborted, isFalse);
  });

  test('the watchdog stops with its transfer', () async {
    h.api.openPuts.single.complete();
    await h.pump();
    expect(
      [for (final t in h.timers.active)
        if (t.duration == UploadManager.stallCheckInterval) t],
      isEmpty,
    );
  });
}
