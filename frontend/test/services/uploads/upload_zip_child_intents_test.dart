// Phase 7B.2c S4: the files of an unpacked ZIP become local upload intents
// (7A.2d: children are ordinary items with `parent_item_uuid`, listed after
// their parent, `validating` as soon as the manifest exists; "a review_ready
// child is reviewed and committed like any item"). A child is adopted when
// the status poll lists it under a parent this sign-in uploaded (and by the
// review flow, through the same store method), so its review draft, its
// commit (DurableSubmission) and its status live where every other item's
// do. A child has no source on this device: it is never transferred (the
// server refuses a PUT to a child). The Uploads page lists children under
// their archive, not as rows of their own.
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

Map<String, dynamic> _child(
  String uuid, {
  String parent = 'u-2',
  String batch = 'u-1',
  String state = 'validating',
  String name = 'disc1/01.flac',
}) => {
  ...itemJson(uuid, batchUuid: batch, state: state, filename: name),
  'parent_item_uuid': parent,
  'member_order_key': name,
  'kind': 'audio',
};

UploadIntentRecord _record(String uuid, {String? parent, String state =
    'review_ready'}) => UploadIntentRecord(
  itemUuid: uuid,
  batchUuid: 'b-1',
  parentItemUuid: parent,
  selectionIndex: 0,
  displayName: uuid,
  lastState: state,
  lastErrorCode: null,
  lastErrorMessage: null,
  operationUuid: null,
  transferOperationUuid: null,
  reviewGeneration: null,
  draftJson: null,
  localBindingId: 'bind-1',
  createdAtMs: 0,
  updatedAtMs: 0,
  expectedLength: null,
  expectedSha256: null,
  descriptor: null,
);

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
    await h.manager.addFiles([await h.file('album.zip', 'zip-bytes')]);
    await h.pump();
    h.api.openPuts.single.complete(state: 'validating', batchUuid: 'u-1');
    await h.pump();
  });
  tearDown(() => h.dispose());

  void serverLists(List<Map<String, dynamic>> items) {
    h.api.onListItems = (batch, after) async =>
        UploadItemPage.fromJson({'items': items, 'next_after': null});
  }

  Future<void> poll() async {
    visible.value = true;
    await h.pump();
    h.timers.fire(UploadManager.pollInterval);
    await h.pump();
  }

  Future<List<Map<String, Object?>>> rows() async => [
    for (final r in await h.db
        .customSelect(
          'SELECT item_uuid, parent_item_uuid, batch_uuid, display_name, '
          'last_state, source_descriptor_json, local_binding_id '
          'FROM upload_intents ORDER BY item_uuid',
        )
        .get())
      r.data,
  ];

  test('the poll adopts the children listed under a local archive, with '
      'their parent, name and state, and no source', () async {
    serverLists([
      itemJson('u-2', batchUuid: 'u-1', state: 'expanded'),
      _child('c-1', name: 'disc1/01.flac'),
      _child('c-2', name: 'disc1/02.flac', state: 'review_ready'),
    ]);

    await poll();

    final all = {for (final r in await rows()) r['item_uuid']: r};
    expect(all.keys, containsAll(['u-2', 'c-1', 'c-2']));
    expect(all['u-2']!['last_state'], 'expanded');
    expect(all['c-1']!['parent_item_uuid'], 'u-2');
    expect(all['c-1']!['batch_uuid'], 'u-1');
    expect(all['c-1']!['display_name'], 'disc1/01.flac');
    expect(all['c-1']!['last_state'], 'validating');
    expect(all['c-1']!['source_descriptor_json'], isNull);
    expect(all['c-1']!['local_binding_id'], h.token);
    expect(all['c-2']!['last_state'], 'review_ready');
  });

  test('an adopted child is polled like any item: its new state is stored',
      () async {
    serverLists([
      itemJson('u-2', batchUuid: 'u-1', state: 'expanded'),
      _child('c-1'),
    ]);
    await poll();

    serverLists([
      itemJson('u-2', batchUuid: 'u-1', state: 'expanded'),
      _child('c-1', state: 'review_ready'),
    ]);
    h.timers.fire(UploadManager.pollInterval);
    await h.pump();

    expect((await h.states())['c-1'], 'review_ready');
  });

  test('adopting again never overwrites a child that is already tracked',
      () async {
    final child = UploadItem.fromJson(_child('c-1', state: 'review_ready'));
    await h.store.adoptChildren(h.token, [child]);
    await h.store.update(h.token, ['c-1'],
        lastState: const Value('review_submitted'));

    await h.store.adoptChildren(h.token, [child]);

    expect((await h.states())['c-1'], 'review_submitted');
  });

  test('items whose parent is not a local upload, and top-level items '
      'without an intent, are not adopted', () async {
    serverLists([
      itemJson('u-2', batchUuid: 'u-1', state: 'expanded'),
      _child('c-9', parent: 'someone-elses-archive'),
      itemJson('x-1', batchUuid: 'u-1', state: 'review_ready'),
    ]);

    await poll();

    final ids = {for (final r in await rows()) r['item_uuid']};
    expect(ids, isNot(contains('c-9')));
    expect(ids, isNot(contains('x-1')));
  });

  test('a child is never transferred, even in a state a transfer starts '
      'from', () async {
    await h.store.adoptChildren(
        h.token, [UploadItem.fromJson(_child('c-1', state: 'allocated'))]);
    final putsBefore = h.api.openPuts.length;
    final openedBefore = h.opened.length;

    h.manager.request('test', bypassBackoff: true);
    await h.pump();

    expect(h.api.openPuts.length, putsBefore);
    expect(h.opened.length, openedBefore);
    expect(h.api.calls.where((c) => c.startsWith('putContent c-1')), isEmpty);
    // Not even a status query or a reselect: the child stays as it was.
    expect(h.api.calls.where((c) => c.endsWith(' c-1')), isEmpty);
    expect((await h.states())['c-1'], 'allocated');
  });

  test('the Uploads page lists an archive once, not its children', () {
    final overview = UploadsOverview.of(
      intents: [
        _record('zip', state: 'expanded'),
        _record('c-1', parent: 'zip'),
        _record('c-2', parent: 'zip', state: 'imported'),
      ],
      progress: const {},
      availability: UploadsAvailability.available,
    );
    expect([for (final r in overview.rows) r.itemUuid], ['zip']);
    expect(overview.counts.total, 1);
    expect(overview.counts.readyForReview, 0);
  });
}
