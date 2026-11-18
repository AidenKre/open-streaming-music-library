// 7B.1d S10: server-status polling (spec §7 para 2 "server-status polling
// while visible/active"; SC-13: requests to the same runner, no bespoke
// loop). Polling runs only while the Uploads page says it is visible (a
// seam the page drives later; default not visible), while online, and
// while an item is in a state the server changes on its own; it reads the
// batch's item pages and stores each item's new state.
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
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
  late ValueNotifier<bool> visible;

  setUp(() async {
    visible = ValueNotifier(false);
    h = await UploadHarness.create(visible: visible);
    h.feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
      fromCache: false,
    );
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    h.api.openPuts.single.complete(state: 'validating', batchUuid: 'u-1');
    await h.pump();
  });
  tearDown(() => h.dispose());

  int lists() => h.api.calls.where((c) => c.startsWith('listItems')).length;

  void poll() => h.timers.fire(UploadManager.pollInterval);

  void serverSays(String state, {String? nextAfter}) {
    h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
      'items': [itemJson('u-2', batchUuid: batch, state: state)],
      'next_after': nextAfter,
    });
  }

  test('not visible: no poll', () async {
    serverSays('review_ready');
    poll();
    h.timers.fire();
    await h.pump();
    expect(lists(), 0);
    expect((await h.states())['u-2'], 'validating');
  });

  test('visible: the poll reads the batch and stores the new state; '
      'hidden again, it stops', () async {
    serverSays('validating');
    visible.value = true;
    await h.pump();
    poll();
    await h.pump();
    expect(lists(), greaterThanOrEqualTo(1));

    serverSays('review_ready');
    poll();
    await h.pump();
    expect((await h.states())['u-2'], 'review_ready');

    visible.value = false;
    await h.pump();
    final before = lists();
    poll();
    await h.pump();
    expect(lists(), before);
    expect(
      [for (final t in h.timers.active)
        if (t.duration == UploadManager.pollInterval) t],
      isEmpty,
    );
  });

  test('visible but offline: no poll', () async {
    h.offline = true;
    visible.value = true;
    await h.pump();
    poll();
    await h.pump();
    expect(lists(), 0);
  });

  test('nothing the server changes on its own: no poll', () async {
    serverSays('review_ready');
    visible.value = true;
    await h.pump();
    poll();
    await h.pump();
    expect((await h.states())['u-2'], 'review_ready');
    final before = lists();

    poll();
    await h.pump();
    expect(lists(), before);
  });

  // U31-A-08 / TR-UPLOAD-05: an unpacked archive (`expanded`) is ended
  // (spec §3); the server never changes it on its own, so its batch is not
  // polled again. Polling it for ever stalled every newer batch once the
  // server pruned the old one (30-day retention answers 404).
  test('U31-A-08 an unpacked archive is not polled again', () async {
    serverSays('expanded');
    visible.value = true;
    await h.pump();
    poll();
    await h.pump();
    expect((await h.states())['u-2'], 'expanded');
    final before = lists();

    poll();
    await h.pump();
    expect(lists(), before);
  });

  test('TR-UPLOAD-05 a pruned batch with an unpacked archive does not stop '
      'the poll of a newer batch', () async {
    serverSays('expanded');
    visible.value = true;
    await h.pump();
    poll();
    await h.pump();
    expect((await h.states())['u-2'], 'expanded');

    h.clock.advance(const Duration(minutes: 1));
    await h.manager.addFiles([await h.file('b.flac', 'abcd')]);
    await h.pump();
    final newer = (await h.intents())
        .singleWhere((r) => r['item_uuid'] != 'u-2');
    final item = newer['item_uuid']! as String;
    final batch = newer['batch_uuid']! as String;
    expect(batch, isNot('u-1'));
    h.api.openPuts.single.complete(state: 'validating', batchUuid: batch);
    await h.pump();
    expect((await h.states())[item], 'validating');

    h.api.onListItems = (b, after) async {
      if (b == 'u-1') {
        throw apiError(404, 'upload_batch_not_found', retryable: false);
      }
      return UploadItemPage.fromJson({
        'items': [itemJson(item, batchUuid: b, state: 'review_ready')],
        'next_after': null,
      });
    };
    poll();
    await h.pump();
    expect((await h.states())[item], 'review_ready');
  });

  // TR-UPLOAD-05 r4 (V-FIX-P7, DEV-r3fe-04): each batch's status read is
  // caught on its own. The server prunes a batch 30 days after its items
  // ended; its listing then answers 404 `upload_batch_not_found`. For this
  // binding's own row that means "ended and forgotten": the row ends as
  // `expired` (it is not polled again) and newer batches keep being read.
  group('TR-UPLOAD-05 r4 one batch\'s failed read', () {
    /// A newer batch with one `validating` row; returns its item and batch.
    Future<(String, String)> newerBatch() async {
      h.clock.advance(const Duration(minutes: 1));
      await h.manager.addFiles([await h.file('b.flac', 'abcd')]);
      await h.pump();
      final newer = (await h.intents())
          .singleWhere((r) => r['item_uuid'] != 'u-2');
      final item = newer['item_uuid']! as String;
      final batch = newer['batch_uuid']! as String;
      h.api.openPuts.single.complete(state: 'validating', batchUuid: batch);
      await h.pump();
      expect((await h.states())[item], 'validating');
      return (item, batch);
    }

    Future<String?> errorOf(String item) async => (await h.intents())
        .singleWhere((r) => r['item_uuid'] == item)['last_error_code']
        as String?;

    int listsOf(String batch) =>
        h.api.calls.where((c) => c == 'listItems $batch').length;

    UploadItemPage readyPage(String item, String batch) =>
        UploadItemPage.fromJson({
          'items': [itemJson(item, batchUuid: batch, state: 'review_ready')],
          'next_after': null,
        });

    test('a stale committing row in a pruned batch ends as expired, and the '
        'newer batch is still polled', () async {
      // Left committing when the page closed mid-commit, long ago.
      await h.store.update(h.token, ['u-2'],
          lastState: const Value('committing'));
      final (item, _) = await newerBatch();
      h.api.onListItems = (b, after) async {
        if (b == 'u-1') {
          throw apiError(404, 'upload_batch_not_found', retryable: false);
        }
        return readyPage(item, b);
      };
      visible.value = true;
      await h.pump();
      poll();
      await h.pump();

      expect((await h.states())[item], 'review_ready');
      expect((await h.states())['u-2'], 'expired');
      expect(await errorOf('u-2'), 'upload_batch_not_found');

      // Ended: the pruned batch is not read again.
      final before = listsOf('u-1');
      poll();
      await h.pump();
      expect(listsOf('u-1'), before);
    });

    test('another 404 (no upload_batch_not_found) is no proof the batch '
        'ended: the row stays, the newer batch is still polled', () async {
      final (item, _) = await newerBatch();
      h.api.onListItems = (b, after) async {
        if (b == 'u-1') throw ApiException(404, 'Not Found');
        return readyPage(item, b);
      };
      visible.value = true;
      await h.pump();
      poll();
      await h.pump();

      expect((await h.states())[item], 'review_ready');
      expect((await h.states())['u-2'], 'validating');
      expect(await errorOf('u-2'), isNull);
    });

    test('a transient failure of one batch: the row stays, the newer batch '
        'is still polled', () async {
      final (item, _) = await newerBatch();
      h.api.onListItems = (b, after) async {
        if (b == 'u-1') throw apiError(503, 'unavailable', retryable: true);
        return readyPage(item, b);
      };
      visible.value = true;
      await h.pump();
      poll();
      await h.pump();

      expect((await h.states())[item], 'review_ready');
      expect((await h.states())['u-2'], 'validating');
    });

    test('another server answering: nothing is written and no other batch '
        'is read in that pass', () async {
      final (item, batch) = await newerBatch();
      h.api.onListItems = (b, after) async {
        if (b == 'u-1') {
          throw ServerInstanceChangedException(
              boundInstanceId: 'inst-1', servedBy: 'inst-2');
        }
        return readyPage(item, b);
      };
      visible.value = true;
      await h.pump();
      poll();
      await h.pump();

      expect((await h.states())['u-2'], 'validating');
      expect((await h.states())[item], 'validating');
      expect(listsOf(batch), 0);
    });
  });

  test('TR-UPLOAD-03 the poll keeps the failed item\'s retryable flag',
      () async {
    h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
      'items': [
        {
          ...itemJson('u-2', batchUuid: batch, state: 'failed'),
          'error': {'code': 'insufficient_storage', 'retryable': true},
        },
      ],
      'next_after': null,
    });
    visible.value = true;
    await h.pump();
    poll();
    await h.pump();
    expect((await h.states())['u-2'], 'failed');
    expect(h.manager.retryable.value['u-2'], isTrue);
  });

  test('every page of the batch is read', () async {
    final afters = <String?>[];
    h.api.onListItems = (batch, after) async {
      afters.add(after);
      return UploadItemPage.fromJson({
        'items': [itemJson('u-2', batchUuid: batch, state: 'validating')],
        'next_after': after == null ? 'cursor-2' : null,
      });
    };
    visible.value = true;
    await h.pump();
    poll();
    await h.pump();
    expect(afters.take(2), [null, 'cursor-2']);
  });
}
