// V-FIX-P7-01 (TR-UPLOAD-06 residue): work the user started is followed to
// its end whatever page is open. A commit is answered 202 `committing`; the
// import itself ends seconds later on the server, and only a status read
// stores `imported` (which fires the import sync). So while one of this
// device's own commits is `committing`, the manager keeps polling those
// batches even with Uploads closed: the same poll and cadence, only those
// batches, stopping at a terminal state, offline, on a 401 or another
// server, and at the latest `followLimit` after the commit was sent.
// A `validating` row is not followed while hidden ("not visible: no poll"
// in upload_manager_polling_test): its ends (review_ready, failed,
// expanded) need the user on the Uploads page, whose entry reads at once.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_review_transport.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

/// Answers every commit `committing` (a fresh 202).
class _Review implements UploadReviewTransport {
  @override
  Future<Map<String, dynamic>> send(
    ReviewActionKind kind,
    String itemUuid,
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) async =>
      itemJson(itemUuid, batchUuid: 'u-1', state: 'committing',
          reviewVersion: 1);
}

const _body = {
  'base_review_version': 1,
  'edits': <String, Object?>{},
  'write_tags': false,
  'acknowledged_duplicates': {'library_tracks': [], 'staged_items': []},
};

void main() {
  late UploadHarness h;
  late ValueNotifier<bool> visible;
  late int committedAtMs;

  setUp(() async {
    visible = ValueNotifier(false);
    h = await UploadHarness.create(visible: visible, review: _Review());
    h.feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
      fromCache: false,
    );
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    h.api.openPuts.single.complete(state: 'review_ready', batchUuid: 'u-1');
    await h.pump();
    expect((await h.states())['u-2'], 'review_ready');

    // The user confirms on the open page, then leaves it.
    visible.value = true;
    await h.pump();
    committedAtMs = h.clock.nowUtcMs();
    await h.manager.submitReviewAction('u-2', ReviewActionKind.commit,
        reviewVersion: 1, body: _body);
    await h.pump();
    expect((await h.states())['u-2'], 'committing');
    visible.value = false;
    await h.pump();
    h.api.calls.clear();
  });
  tearDown(() => h.dispose());

  int lists([String batch = 'u-1']) =>
      h.api.calls.where((c) => c == 'listItems $batch').length;

  List<ManualTimer> pollTimers() => [
    for (final t in h.timers.active)
      if (t.duration == UploadManager.pollInterval) t,
  ];

  void advanceTo(int ms) =>
      h.clock.advance(Duration(milliseconds: ms - h.clock.nowUtcMs()));

  Future<void> poll() async {
    h.timers.fire(UploadManager.pollInterval);
    await h.pump();
  }

  void serverSays(String state) {
    h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
      'items': [
        if (batch == 'u-1') itemJson('u-2', batchUuid: batch, state: state),
      ],
      'next_after': null,
    });
  }

  test('a commit that ends after Uploads closed is still read: imported '
      'is stored', () async {
    serverSays('imported');
    await poll();
    expect(lists(), greaterThanOrEqualTo(1));
    expect((await h.states())['u-2'], 'imported');
  });

  test('the follow stops at the terminal state', () async {
    serverSays('imported');
    await poll();
    expect((await h.states())['u-2'], 'imported');
    final before = lists();

    await poll();
    await poll();
    expect(lists(), before);
    expect(pollTimers(), isEmpty);
  });

  test('a commit still running is read on every tick', () async {
    serverSays('committing');
    await poll();
    await poll();
    expect(lists(), 2);
    expect(pollTimers(), hasLength(1));
  });

  test('while hidden, only the batches of own commits are read', () async {
    h.clock.advance(const Duration(minutes: 1));
    await h.manager.addFiles([await h.file('b.flac', 'abcd')]);
    await h.pump();
    final other = (await h.intents())
        .singleWhere((r) => r['item_uuid'] != 'u-2');
    final batch = other['batch_uuid']! as String;
    h.api.openPuts.single.complete(state: 'validating', batchUuid: batch);
    await h.pump();
    expect((await h.states())[other['item_uuid']], 'validating');

    serverSays('committing');
    await poll();
    await poll();
    expect(lists(), 2);
    expect(lists(batch), 0);
  });

  test('a commit that never ends is followed for at most followLimit after '
      'it was sent', () async {
    serverSays('committing');
    advanceTo(committedAtMs +
        UploadManager.followLimit.inMilliseconds -
        const Duration(minutes: 1).inMilliseconds);
    await poll();
    expect(lists(), 1);

    advanceTo(committedAtMs +
        UploadManager.followLimit.inMilliseconds +
        const Duration(seconds: 1).inMilliseconds);
    await poll();
    await poll();
    expect(lists(), 1);
    expect(pollTimers(), isEmpty);
    expect((await h.states())['u-2'], 'committing');
  });

  test('offline: no request and the follow stops; a recovered network '
      'picks it up again', () async {
    serverSays('imported');
    h.offline = true;
    await poll();
    expect(lists(), 0);
    expect(pollTimers(), isEmpty);

    h.offline = false;
    h.manager.request('networkRecovered', bypassBackoff: true);
    await h.pump();
    await poll();
    expect((await h.states())['u-2'], 'imported');
  });

  test('a 401 stops the follow', () async {
    h.api.onListItems = (batch, after) async =>
        throw apiError(401, 'unauthorized');
    await poll();
    expect(lists(), 1);

    await poll();
    await poll();
    expect(lists(), 1);
    expect(pollTimers(), isEmpty);
  });

  test('another server answering: the row stays committing and the follow '
      'stops', () async {
    h.api.onListItems = (batch, after) async =>
        throw ServerInstanceChangedException(
            boundInstanceId: 'inst-1', servedBy: 'inst-2');
    await poll();
    expect(lists(), 1);
    expect((await h.states())['u-2'], 'committing');

    await poll();
    await poll();
    expect(lists(), 1);
  });

  test('a commit left committing by an earlier run is followed after a '
      'relaunch', () async {
    await h.manager.quiesce();
    h.manager = h.build();
    h.manager.request('coldStart');
    await h.pump();

    serverSays('imported');
    await poll();
    expect((await h.states())['u-2'], 'imported');
  });

  test('back on the page: one poll timer, the page poll as before',
      () async {
    serverSays('committing');
    await poll();
    visible.value = true;
    await h.pump();
    expect(pollTimers(), hasLength(1));
  });

  // Review r1 (7-fix-r4-fe rev-1 #1): a follow read still running when the
  // manager quiesces arms no timer afterwards.
  test('rev #1 a quiesce during a follow read leaves no poll timer',
      () async {
    final held = Completer<UploadItemPage>();
    h.api.onListItems = (batch, after) => held.future;
    h.timers.fire(UploadManager.pollInterval);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(lists(), 1);
    final quiesced = h.manager.quiesce();
    held.complete(UploadItemPage.fromJson({
      'items': [itemJson('u-2', batchUuid: 'u-1', state: 'committing')],
      'next_after': null,
    }));
    await quiesced;
    await h.pump();
    expect(pollTimers(), isEmpty);
  });

  // Review r1 (rev-1 #2): a 401 anywhere (here a transfer) parks the manager;
  // the hidden follow stops then too instead of waking every tick.
  test('rev #2 a 401 on a transfer stops the follow', () async {
    await h.manager.addFiles([await h.file('b.flac', 'abcd')]);
    await h.pump();
    h.api.openPuts.single.fail(apiError(401, 'unauthorized'));
    await h.pump();
    serverSays('committing');
    await poll();
    await poll();
    expect(pollTimers(), isEmpty);
  });

  test('a commit sent long after the start opens its own window', () async {
    serverSays('imported');
    await poll();
    expect((await h.states())['u-2'], 'imported');

    // Past the start's window: a new commit, confirmed with Uploads hidden.
    h.clock.advance(UploadManager.followLimit + const Duration(minutes: 1));
    await h.manager.addFiles([await h.file('b.flac', 'abcd')]);
    await h.pump();
    final b = (await h.intents()).singleWhere((r) => r['item_uuid'] != 'u-2');
    final item = b['item_uuid']! as String;
    final batch = b['batch_uuid']! as String;
    h.api.openPuts.single.complete(state: 'review_ready', batchUuid: batch);
    await h.pump();
    await h.manager.submitReviewAction(item, ReviewActionKind.commit,
        reviewVersion: 1, body: _body);
    await h.pump();
    expect((await h.states())[item], 'committing');

    h.api.onListItems = (bt, after) async => UploadItemPage.fromJson({
      'items': [
        if (bt == batch) itemJson(item, batchUuid: bt, state: 'imported'),
      ],
      'next_after': null,
    });
    await poll();
    expect((await h.states())[item], 'imported');
  });
}
