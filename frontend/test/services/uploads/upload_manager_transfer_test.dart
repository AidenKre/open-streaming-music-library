// 7B.1d S5: transfers (spec §7 para 2: "at most two transfers"; DEV-7-02:
// `min(2, limits.receives_per_user)`, unknown = one at a time, never
// unlimited). Each content PUT goes through DurableSubmission (kind
// `upload_content`, a local transfer operation id stored on the intent)
// and is preceded by a GET of the item's status, so a file the server
// already holds is never sent again and a refusal that would only arrive
// after the whole body is avoided where the status already shows it
// (7B.1c trap 4). A transfer's end releases its slot whatever the answer.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

AdvertisedFeature<UploadsFeature> _limits(int? receivesPerUser) =>
    AdvertisedFeature(
      UploadsFeature(
        version: 1,
        limits: UploadLimits(receivesPerUser: receivesPerUser),
      ),
      fromCache: false,
    );

void main() {
  late UploadHarness h;

  setUp(() async => h = await UploadHarness.create());
  tearDown(() => h.dispose());

  Future<void> addThree() async {
    await h.verify();
    await h.manager.addFiles([
      await h.file('a.flac', 'abc'),
      await h.file('b.flac', 'abcd'),
      await h.file('c.flac', 'abcde'),
    ]);
    await h.pump();
  }

  test('a third transfer waits for a slot and starts when one ends',
      () async {
    h.feature = _limits(2);
    await addThree();

    // Two slots race to the wire: the order between them is free; the
    // third file waits until one ends.
    expect({for (final p in h.api.openPuts) p.itemUuid}, {'u-2', 'u-3'});
    expect((await h.states())['u-4'], 'allocated');

    final first = h.api.openPuts.first;
    first.complete();
    await h.pump();

    expect({for (final p in h.api.openPuts) p.itemUuid},
        ({'u-2', 'u-3'}..remove(first.itemUuid))..add('u-4'));
    expect(h.api.puts, hasLength(3));
  });

  test('every PUT is preceded by a GET of that item, and carries the '
      'allocation digest and length', () async {
    h.feature = _limits(2);
    await addThree();
    h.api.openPuts.first.complete();
    await h.pump();

    for (final item in ['u-2', 'u-3', 'u-4']) {
      final put = h.api.calls.indexOf('putContent $item');
      expect(put, greaterThan(0));
      expect(h.api.calls.sublist(0, put), contains('getItem $item'));
    }
    final first = h.api.puts.firstWhere((p) => p.itemUuid == 'u-2');
    expect(first.expectedLength, 3);
    expect(first.expectedSha256,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });

  for (final (receives, expected) in [(1, 1), (null, 1), (5, 2), (2, 2)]) {
    test('receives_per_user $receives → $expected at once', () async {
      h.feature = _limits(receives);
      await addThree();
      expect(h.api.openPuts, hasLength(expected));
    });
  }

  test('a finished transfer stores the server state, its operation is '
      'accepted, and progress is reported while it runs', () async {
    h.feature = _limits(1);
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    final put = h.api.openPuts.single;
    put.onProgress!(2);
    expect(h.manager.progress.value, {'u-2': 2});
    expect((await h.states())['u-2'], 'transferring');

    put.complete(state: 'validating');
    await h.pump();

    final row = (await h.intents()).single;
    expect(row['last_state'], 'validating');
    expect(row['last_error_code'], isNull);
    final op = row['transfer_operation_uuid'];
    expect(op, isNotNull);
    final sub = (await h.submissions()).firstWhere(
      (s) => s['operation_uuid'] == op,
    );
    expect(sub['kind'], 'upload_content');
    expect(sub['state'], 'accepted');
    expect(h.manager.progress.value, isEmpty);
  });

  test('a permanent refusal releases the slot and the item shows the '
      "server's state", () async {
    h.feature = _limits(1);
    await h.verify();
    await h.manager.addFiles([
      await h.file('a.flac', 'abc'),
      await h.file('b.flac', 'abcd'),
    ]);
    await h.pump();
    expect([for (final p in h.api.openPuts) p.itemUuid], ['u-2']);

    h.api.onGetItem = (item) async => UploadItem.fromJson(
      item == 'u-2'
          ? itemJson(item, state: 'failed', error: {
              'code': 'upload_digest_mismatch',
              'retryable': false,
            })
          : itemJson(item),
    );
    h.api.openPuts.single.fail(
      apiError(422, 'upload_digest_mismatch', retryable: false),
    );
    await h.pump();

    final rows = {for (final r in await h.intents()) r['item_uuid']: r};
    expect(rows['u-2']!['last_state'], 'failed');
    expect(rows['u-2']!['last_error_code'], 'upload_digest_mismatch');
    expect([for (final p in h.api.openPuts) p.itemUuid], ['u-3']);
  });

  test('the server already holds the file: the status GET settles it and '
      'nothing is sent', () async {
    h.feature = _limits(1);
    h.api.onGetItem = (item) async =>
        UploadItem.fromJson(itemJson(item, state: 'review_ready'));
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    expect(h.api.puts, isEmpty);
    expect((await h.states())['u-2'], 'review_ready');
  });

  test('a cancelled or expired item is never sent', () async {
    h.feature = _limits(1);
    h.api.onGetItem = (item) async =>
        UploadItem.fromJson(itemJson(item, state: 'cancelled'));
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    expect(h.api.puts, isEmpty);
    expect((await h.states())['u-2'], 'cancelled');
  });

  test('a raised receives_per_user is used by the next pass', () async {
    h.feature = _limits(1);
    await addThree();
    expect(h.api.openPuts, hasLength(1));

    h.feature = _limits(2);
    h.manager.start();
    await h.pump();
    expect(h.api.openPuts, hasLength(2));
  });

  test('a transfer opens its source through the injected opener', () async {
    h.feature = _limits(1);
    final a = await h.file('a.flac', 'abc');
    await h.verify();
    await h.manager.addFiles([a]);
    await h.pump();
    expect(h.opened, [a.path]);
    expect(h.api.puts, hasLength(1));
  });
}
