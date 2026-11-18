// 7B.1d S8: per-file cancel (spec §7 para 2 "per-file cancellation"; §4
// DELETE: repeat succeeds; an accepted commit answers 409 and is never
// undone). A cancel is recorded at once (`cancelling`), stops the file's
// transfer (its slot goes to the next file), and the DELETE is sent by the
// runner behind the verified gate (plan §6: user actions go through the
// runner). A file not yet allocated is cancelled once the server knows it.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

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

  Future<String> state(String item) async => (await h.states())[item]!;

  Future<void> addTwoVerified() async {
    await h.verify();
    await h.manager.addFiles([
      await h.file('a.flac', 'abc'),
      await h.file('b.flac', 'abcd'),
    ]);
    await h.pump();
  }

  test('cancelling a transferring file stops its PUT, gives the slot to the '
      'next file and cancels it on the server', () async {
    await addTwoVerified();
    final put = h.api.openPuts.single;
    expect(put.itemUuid, 'u-2');

    await h.manager.cancel('u-2');
    await h.pump();

    expect(put.aborted, isTrue);
    expect(h.api.calls, contains('cancelItem u-2'));
    expect(await state('u-2'), 'cancelled');
    expect([for (final p in h.api.openPuts) p.itemUuid], ['u-3']);
  });

  test('cancelling a file waiting for a slot sends only the DELETE',
      () async {
    await addTwoVerified();
    await h.manager.cancel('u-3');
    await h.pump();

    expect(h.api.calls, contains('cancelItem u-3'));
    expect(await state('u-3'), 'cancelled');
    h.api.openPuts.single.complete();
    await h.pump();
    expect(h.api.puts.where((p) => p.itemUuid == 'u-3'), isEmpty);
  });

  test('a cancel is recorded at once, even before the gate verifies; the '
      'DELETE waits for it', () async {
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.manager.cancel('u-2');
    expect(await state('u-2'), UploadIntentState.cancelling);
    expect(h.api.calls, isEmpty);

    await h.verify();
    // Allocated first (the frozen batch includes it), then cancelled;
    // never transferred.
    expect(h.api.calls, containsAllInOrder(['allocate u-1', 'cancelItem u-2']));
    expect(h.api.puts, isEmpty);
    expect(await state('u-2'), 'cancelled');
  });

  test('a cancel the server refuses (already validated) shows the '
      "server's state", () async {
    await addTwoVerified();
    h.api.openPuts.single.complete(state: 'validating');
    await h.pump();
    h.api.onCancel = (item) async => throw apiError(
      409,
      'upload_item_not_cancellable',
      retryable: false,
    );
    h.api.onGetItem = (item) async =>
        UploadItem.fromJson(itemJson(item, state: 'validating'));

    await h.manager.cancel('u-2');
    await h.pump();

    expect(await state('u-2'), 'validating');
  });

  test('a DELETE that gets no answer is sent again by a later pass',
      () async {
    await addTwoVerified();
    var first = true;
    h.api.onCancel = (item) async {
      if (first) {
        first = false;
        throw NetworkException('lost', attemptsMade: 1);
      }
      return UploadItem.fromJson(itemJson(item, state: 'cancelled'));
    };
    await h.manager.cancel('u-3');
    await h.pump();
    expect(await state('u-3'), UploadIntentState.cancelling);

    h.clock.advance(const Duration(minutes: 1));
    h.timers.fire();
    await h.pump();
    expect(h.api.calls.where((c) => c == 'cancelItem u-3'), hasLength(2));
    expect(await state('u-3'), 'cancelled');
  });

  test('a file the server never knew (rejected allocation) is cancelled '
      'locally only', () async {
    h.api.onAllocate = (_) async =>
        throw apiError(413, 'upload_limit_exceeded', retryable: false);
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    expect(await state('u-2'), UploadIntentState.rejected);

    await h.manager.cancel('u-2');
    await h.pump();
    expect(await state('u-2'), 'cancelled');
    expect(h.api.calls.where((c) => c.startsWith('cancelItem')), isEmpty);
  });

  test('cancelling during a busy wait is not delayed by it', () async {
    await addTwoVerified();
    h.api.openPuts.single.fail(
      apiError(503, 'upload_slots_busy', retryable: true, retryAfterS: 30),
    );
    await h.pump();

    await h.manager.cancel('u-3');
    await h.pump();
    expect(h.api.calls, contains('cancelItem u-3'));
    // The busy wait still holds the transfers back.
    expect(h.api.puts, hasLength(1));
  });

  test('a cancel of a file whose allocation answer was lost waits for the '
      'allocation to settle before the DELETE', () async {
    var lost = true;
    final allocate = h.api.onAllocate;
    h.api.onAllocate = (body) async {
      if (lost) throw NetworkException('lost', attemptsMade: 1);
      return allocate(body);
    };
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    await h.manager.cancel('u-2');
    await h.pump();
    expect(h.api.calls.where((c) => c.startsWith('cancelItem')), isEmpty);

    lost = false;
    h.clock.advance(const Duration(minutes: 1));
    h.timers.fire();
    await h.pump();
    expect(h.api.calls, containsAllInOrder(['allocate u-1', 'cancelItem u-2']));
    expect(h.api.calls.indexOf('cancelItem u-2'),
        greaterThan(h.api.calls.lastIndexOf('allocate u-1')));
    expect(await state('u-2'), 'cancelled');
  });

  // 7-R1-UI-01 / backend 7-R1-16: the server now cancels a `failed` item
  // (DELETE answers 200 `cancelled`; it used to answer 409). The Uploads
  // page offers Cancel on it, and that Cancel ends with the item cancelled.
  test('a failed item is cancelled: the server answers 200 cancelled and the '
      'row says so', () async {
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    h.api.openPuts.single.complete(state: 'failed', batchUuid: 'u-1');
    await h.pump();
    expect(await state('u-2'), 'failed');

    Future<UploadRow> row() async => UploadsOverview.of(
      intents: await h.store.forBinding(h.token),
      progress: const {},
      availability: UploadsAvailability.available,
    ).rows.single;
    expect((await row()).canCancel, isTrue);

    var deletes = 0;
    h.api.onCancel = (item) async {
      deletes++;
      return UploadItem.fromJson(
          itemJson(item, batchUuid: 'u-1', state: 'cancelled'));
    };
    await h.manager.cancel('u-2');
    await h.pump();

    expect(deletes, 1);
    expect(await state('u-2'), 'cancelled');
    final after = await row();
    expect(after.statusText, 'Cancelled');
    expect(after.offersCancel, isFalse);
    expect(after.needsAttention, isFalse);
  });
}
