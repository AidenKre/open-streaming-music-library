// Phase 7 review r1, 7-R1-22 (coordinator decision: fix it). Spec §7:
// "Reopening/restarting reconstructs server work", and a reset "does not
// delete server-staged items". When the Uploads page is entered, the
// manager reads the user's batches and items from the server (every page)
// and adopts the items this device doesn't know as local intents without a
// source: they can be reviewed, committed and cancelled through the
// existing paths. Nothing is adopted on a cached feature block, before the
// binding is verified, or from another server instance. Known rows are left
// to their own paths, except that an ended state is mirrored over a local
// `review_ready` / `duplicate_conflict` (7-R1-21).
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value, Variable;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_review_transport.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

class _Transport implements UploadReviewTransport {
  final sent = <(ReviewActionKind, String)>[];

  @override
  Future<Map<String, dynamic>> send(
    ReviewActionKind kind,
    String itemUuid,
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) async {
    sent.add((kind, itemUuid));
    final body = jsonDecode(frozenBodyJson) as Map<String, dynamic>;
    return itemJson(itemUuid,
        batchUuid: 'b-9',
        state: 'committing',
        reviewVersion: body['base_review_version'] as int? ?? 1);
  }
}

Map<String, dynamic> _remote(String uuid,
        {String state = 'review_ready', int index = 0, int version = 1}) =>
    itemJson(uuid,
        batchUuid: 'b-9',
        state: state,
        selectionIndex: index,
        filename: '$uuid.flac',
        expectedBytes: 3,
        expectedSha256:
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        reviewVersion: version);

void main() {
  late UploadHarness h;
  late ValueNotifier<bool> visible;
  late _Transport transport;

  const live = AdvertisedFeature(
    UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
    fromCache: false,
  );

  setUp(() async {
    visible = ValueNotifier(false);
    transport = _Transport();
    h = await UploadHarness.create(visible: visible, review: transport);
    h.feature = live;
  });
  tearDown(() => h.dispose());

  /// The server holds batch b-9 with [items] (one page each, unless paged).
  void server(List<Map<String, dynamic>> items) {
    h.api.onListBatches = (after) async => UploadBatchPage.fromJson({
      'batches': [batchJson('b-9', itemCount: items.length)],
      'next_after': null,
    });
    h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
      'items': batch == 'b-9' ? items : <Object>[],
      'next_after': null,
    });
  }

  Future<void> enter() async {
    visible.value = true;
    await h.pump();
  }

  Future<Map<String, Object?>?> row(String uuid) async {
    final rows = await h.db
        .customSelect(
          'SELECT * FROM upload_intents WHERE item_uuid = ?',
          variables: [Variable.withString(uuid)],
        )
        .get();
    return rows.isEmpty ? null : rows.single.data;
  }

  test('entering the page adopts a server item this device does not know, '
      'without a source', () async {
    await h.verify();
    server([_remote('x')]);
    await enter();

    final r = await row('x');
    expect(r, isNotNull);
    expect(r!['batch_uuid'], 'b-9');
    expect(r['display_name'], 'x.flac');
    expect(r['last_state'], 'review_ready');
    expect(r['parent_item_uuid'], isNull);
    expect(r['source_descriptor_json'], isNull);
    expect(r['local_binding_id'], h.token);
  });

  test('finished server work (imported, already in the library, cancelled, '
      'expired) is not adopted: nothing is left to do with it', () async {
    await h.verify();
    server([
      _remote('done', state: 'imported'),
      _remote('dup', state: 'duplicate'),
      _remote('gone', state: 'cancelled'),
      _remote('old', state: 'expired'),
      _remote('bad', state: 'failed'),
      _remote('zip', state: 'expanded'),
    ]);
    await enter();

    for (final uuid in ['done', 'dup', 'gone', 'old']) {
      expect(await row(uuid), isNull, reason: uuid);
    }
    for (final uuid in ['bad', 'zip']) {
      expect(await row(uuid), isNotNull, reason: uuid);
    }
  });

  test('every page of batches and of items is read', () async {
    await h.verify();
    final batchAfters = <String?>[];
    final itemAfters = <String, List<String?>>{};
    h.api.onListBatches = (after) async {
      batchAfters.add(after);
      return UploadBatchPage.fromJson({
        'batches': [batchJson(after == null ? 'b-8' : 'b-9')],
        'next_after': after == null ? 'bc-2' : null,
      });
    };
    h.api.onListItems = (batch, after) async {
      (itemAfters[batch] ??= []).add(after);
      final first = after == null;
      return UploadItemPage.fromJson({
        'items': [
          {
            ..._remote('$batch-${first ? 1 : 2}'),
            'batch_uuid': batch,
          },
        ],
        'next_after': first ? 'ic-2' : null,
      });
    };
    await enter();

    expect(batchAfters, [null, 'bc-2']);
    expect(itemAfters['b-8'], [null, 'ic-2']);
    expect(itemAfters['b-9'], [null, 'ic-2']);
    for (final uuid in ['b-8-1', 'b-8-2', 'b-9-1', 'b-9-2']) {
      expect(await row(uuid), isNotNull, reason: uuid);
    }
  });

  // 7-R2-23: a server that echoes its cursor would hold the single-flight
  // pass forever; the listing stops on a repeated cursor, as the ZIP
  // children's does. (The fakes end the echo after 10 calls so a missing
  // guard fails on the call count instead of hanging.)
  test('7-R2-23 the batch listing stops on a repeated cursor', () async {
    await h.verify();
    final batchAfters = <String?>[];
    h.api.onListBatches = (after) async {
      batchAfters.add(after);
      return UploadBatchPage.fromJson({
        'batches': [batchJson('b-9')],
        'next_after': batchAfters.length < 10 ? 'bc-same' : null,
      });
    };
    h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
      'items': [_remote('x')],
      'next_after': null,
    });
    await enter();

    expect(batchAfters, [null, 'bc-same']);
    expect(await row('x'), isNotNull);
  });

  test('7-R2-23 the item listing stops on a repeated cursor', () async {
    await h.verify();
    final itemAfters = <String?>[];
    h.api.onListBatches = (after) async => UploadBatchPage.fromJson({
      'batches': [batchJson('b-9')],
      'next_after': null,
    });
    h.api.onListItems = (batch, after) async {
      itemAfters.add(after);
      return UploadItemPage.fromJson({
        'items': [_remote(after == null ? 'x' : 'y')],
        'next_after': itemAfters.length < 10 ? 'ic-same' : null,
      });
    };
    await enter();

    expect(itemAfters, [null, 'ic-same']);
    expect(await row('x'), isNotNull);
    expect(await row('y'), isNotNull);
  });

  test('a cached feature block adopts nothing and lists nothing', () async {
    h.feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
      fromCache: true,
    );
    await h.verify();
    server([_remote('x')]);
    await enter();

    expect(h.api.calls.where((c) => c.startsWith('list')), isEmpty);
    expect(await row('x'), isNull);
  });

  test('nothing is listed before the binding is verified; afterwards the '
      'item is adopted', () async {
    server([_remote('x')]);
    await enter();
    expect(h.api.calls, isEmpty);
    expect(await row('x'), isNull);

    await h.verify();
    await h.pump();
    expect(await row('x'), isNotNull);
  });

  test('an answer from another server instance adopts nothing', () async {
    await h.verify();
    h.api.onListBatches = (after) async => UploadBatchPage.fromJson({
      'batches': [batchJson('b-9')],
      'next_after': null,
    });
    h.api.onListItems = (batch, after) async =>
        throw ServerInstanceChangedException(
            boundInstanceId: 'inst-1', servedBy: 'inst-2');
    await enter();

    expect(await row('x'), isNull);
    expect(await h.intents(), isEmpty);
  });

  test('the batches are listed once per page entry, not on every poll',
      () async {
    await h.verify();
    server([_remote('x')]);
    await enter();
    int lists() => h.api.calls.where((c) => c == 'listBatches').length;
    expect(lists(), 1);

    h.timers.fire(UploadManager.pollInterval);
    await h.pump();
    expect(lists(), 1);

    visible.value = false;
    await h.pump();
    await enter();
    expect(lists(), 2);
  });

  // Review (7-fix-r1-fe) R-5: a page entry during a listing gets its own
  // listing.
  test('R-5 re-entering while a listing runs lists again afterwards',
      () async {
    await h.verify();
    server([_remote('x')]);
    final hold = Completer<void>();
    final list = h.api.onListBatches;
    h.api.onListBatches = (after) async {
      await hold.future;
      return list(after);
    };
    // The listing is held: let the events run without waiting for idle.
    visible.value = true;
    await pumpEventQueue();
    visible.value = false;
    await pumpEventQueue();
    visible.value = true;
    await pumpEventQueue();
    h.api.onListBatches = list;
    hold.complete();
    await h.pump();
    h.timers.fire(UploadManager.pollInterval);
    await h.pump();

    expect(h.api.calls.where((c) => c == 'listBatches'), hasLength(2));
  });

  test('an adopted batch is never allocated', () async {
    await h.verify();
    server([_remote('x')]);
    await enter();
    h.manager.request('again', bypassBackoff: true);
    await h.pump();

    expect(h.api.calls.where((c) => c.startsWith('allocate')), isEmpty);
    expect((await row('x'))!['last_state'], 'review_ready');
  });

  test('an adopted ready item can be committed', () async {
    await h.verify();
    server([_remote('x')]);
    await enter();

    await h.manager.submitReviewAction('x', ReviewActionKind.commit,
        reviewVersion: 1,
        body: {'base_review_version': 1, 'edits': {}, 'write_tags': false});
    await h.pump();

    expect(transport.sent, [(ReviewActionKind.commit, 'x')]);
    expect((await row('x'))!['last_state'], 'committing');
  });

  test('an adopted item can be cancelled: the DELETE is sent', () async {
    await h.verify();
    server([_remote('x')]);
    await enter();

    await h.manager.cancel('x');
    await h.pump();

    expect(h.api.calls, contains('cancelItem x'));
    expect((await row('x'))!['last_state'], 'cancelled');
  });

  test('a known item keeps its own row; an ended state is mirrored over a '
      'ready one', () async {
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    h.api.openPuts.single.complete(state: 'review_ready', batchUuid: 'u-1');
    await h.pump();
    final before = await row('u-2');
    expect(before!['last_state'], 'review_ready');

    h.api.onListBatches = (after) async => UploadBatchPage.fromJson({
      'batches': [batchJson('u-1')],
      'next_after': null,
    });
    h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
      'items': [itemJson('u-2', batchUuid: 'u-1', state: 'expired')],
      'next_after': null,
    });
    await enter();

    final after = await row('u-2');
    expect(after!['last_state'], 'expired');
    expect(after['source_descriptor_json'], before['source_descriptor_json']);
    expect(after['expected_sha256'], before['expected_sha256']);
  });

  // A7-01 (pre-merge review): a failed or unpacked row of this device follows
  // what the server says about it when the page opens (DEV-7-23 point 4), so
  // a retry, cancel or expiry done elsewhere is shown here. A row the server
  // still calls failed, or one whose file the server is still waiting for,
  // stays failed with its Retry.
  group('a failed or unpacked row follows the server on page entry', () {
    /// This device's file u-2 (batch u-1) ends in [localState]; a failed one
    /// carries a retryable error code.
    Future<void> local(String localState) async {
      await h.verify();
      await h.manager.addFiles([await h.file('a.flac', 'abc')]);
      await h.pump();
      h.api.openPuts.single.complete(state: localState, batchUuid: 'u-1');
      await h.pump();
      if (localState == 'failed') {
        await h.store.update(
          h.token,
          ['u-2'],
          lastErrorCode: const Value('probe_timeout'),
        );
      }
      expect((await row('u-2'))!['last_state'], localState);
    }

    /// The server lists u-2 in [state].
    void listed(String state, {Map<String, dynamic>? error}) {
      h.api.onListBatches = (after) async => UploadBatchPage.fromJson({
        'batches': [batchJson('u-1')],
        'next_after': null,
      });
      h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
        'items': [
          itemJson('u-2', batchUuid: 'u-1', state: state, error: error),
        ],
        'next_after': null,
      });
    }

    Future<UploadRow> overviewRow() async => UploadsOverview.of(
      intents: await h.store.forBinding(h.token),
      progress: const {},
      availability: UploadsAvailability.available,
      retryable: h.manager.retryable.value,
    ).rows.single;

    for (final state in ['imported', 'duplicate', 'cancelled', 'expired']) {
      test('a failed row that ended elsewhere ($state) takes that state and '
          'no longer offers Retry', () async {
        await local('failed');
        expect((await overviewRow()).offersRetry, isTrue);
        listed(state);
        await enter();

        final after = await row('u-2');
        expect(after!['last_state'], state);
        expect(after['last_error_code'], isNull);
        expect((await overviewRow()).offersRetry, isFalse);
        expect((await overviewRow()).needsAttention, isFalse);
      });
    }

    test('a failed row retried elsewhere and now ready takes the review '
        'state', () async {
      await local('failed');
      listed('review_ready');
      await enter();

      expect((await row('u-2'))!['last_state'], 'review_ready');
      expect((await overviewRow()).offersReviewTags, isTrue);
      expect((await overviewRow()).offersRetry, isFalse);
    });

    test('a row the server still calls failed stays failed with Retry',
        () async {
      await local('failed');
      listed('failed', error: {
        'code': 'probe_timeout',
        'message': 'probe_timeout',
        'retryable': true,
      });
      await enter();

      final after = await row('u-2');
      expect(after!['last_state'], 'failed');
      expect(after['last_error_code'], 'probe_timeout');
      expect((await overviewRow()).offersRetry, isTrue);
    });

    for (final state in ['allocated', 'receiving']) {
      test('a failed row whose file the server is still waiting for ($state) '
          'stays failed with Retry', () async {
        await local('failed');
        listed(state);
        await enter();

        expect((await row('u-2'))!['last_state'], 'failed');
        expect((await row('u-2'))!['last_error_code'], 'probe_timeout');
        expect((await overviewRow()).offersRetry, isTrue);
      });
    }

    test('an unpacked archive cancelled elsewhere takes the cancelled state',
        () async {
      await local('expanded');
      listed('cancelled');
      await enter();

      expect((await row('u-2'))!['last_state'], 'cancelled');
      expect((await overviewRow()).offersChildren, isFalse);
    });

    // The server lists no batch u-1: it forgot it (retention).
    void forgotten() {
      h.api.onListBatches = (after) async =>
          UploadBatchPage.fromJson({'batches': [], 'next_after': null});
      h.api.onGetBatch = (batch) async =>
          throw apiError(404, 'upload_batch_not_found', retryable: false);
    }

    const forgottenText =
        'The server no longer has a record of this upload. Check your '
        "library, and add the file again if it isn't there.";

    test('a failed row whose batch the server forgot ends as expired, '
        'without Retry', () async {
      await local('failed');
      forgotten();
      await enter();

      expect(h.api.calls, contains('getBatch u-1'));
      final after = await row('u-2');
      expect(after!['last_state'], 'expired');
      expect(after['last_error_code'], 'upload_batch_not_found');
      final shown = await overviewRow();
      expect(shown.statusText, 'Expired');
      expect(shown.detailText, forgottenText);
      expect(shown.offersRetry, isFalse);
    });

    // An unpacked archive is finished on the server: its row stays as it is
    // (what it should show once its file list is gone is not decided).
    test('an unpacked archive whose batch the server forgot keeps its state, '
        'and its batch is not read', () async {
      await local('expanded');
      forgotten();
      await enter();

      expect(h.api.calls.where((c) => c.startsWith('getBatch')), isEmpty);
      final after = await row('u-2');
      expect(after!['last_state'], 'expanded');
      expect(after['last_error_code'], isNull);
    });

    test('a batch missing from the listing that the server still has, or '
        'whose read fails, leaves the row as it is', () async {
      await local('failed');
      forgotten();
      h.api.onGetBatch = (batch) async =>
          UploadBatch.fromJson(batchJson(batch));
      await enter();
      expect((await row('u-2'))!['last_state'], 'failed');

      h.api.onGetBatch = (batch) async =>
          throw apiError(503, 'server_busy', retryable: true);
      visible.value = false;
      await enter();
      expect((await row('u-2'))!['last_state'], 'failed');
      expect((await row('u-2'))!['last_error_code'], 'probe_timeout');
      // The failed check does not fail the listing: it is not listed again
      // until the next page entry.
      final listings = h.api.calls.where((c) => c == 'listBatches').length;
      h.manager.request('again', bypassBackoff: true);
      await h.pump();
      expect(h.api.calls.where((c) => c == 'listBatches'), hasLength(listings));
    });

    test('a listed batch is not read again on its own', () async {
      await local('failed');
      listed('failed');
      await enter();
      expect(h.api.calls.where((c) => c.startsWith('getBatch')), isEmpty);
    });
  });

  // 7-R2-02: a sign-out rotates the binding and keeps the rows; a sign-in as
  // the same user on the same server keeps the store. A row of the earlier
  // sign-in is dead (never shown, resumed or sent). An item the server lists
  // for the signed-in user is always represented by a row of the current
  // binding: the dead row gives way and the item is adopted afresh, without
  // anything the dead row held (source, digest, operations, draft).
  // Sign-off s7-app-texts follow-up (owner 2026-11-17): while Uploads is
  // open, the poll also reads the batches of rows waiting for another
  // device, and the manager publishes which uploads another device is
  // sending (UploadArrivals over its own reads and its clock).
  group('whether another device is sending', () {
    void poll() => h.timers.fire(UploadManager.pollInterval);

    test('a waiting row whose upload starts arriving: sent, at the next poll',
        () async {
      await h.verify();
      server([_remote('x', state: 'allocated', version: 0)]);
      await enter();
      h.manager.request('again', bypassBackoff: true);
      await h.pump();
      expect((await row('x'))!['last_state'], 'on_other_device');
      expect(h.manager.otherDeviceSending.value, isEmpty,
          reason: 'nothing of it is arriving');

      server([_remote('x', state: 'receiving', version: 0)]);
      poll();
      await h.pump();
      expect(h.manager.otherDeviceSending.value, {'b-9'});
      expect((await row('x'))!['last_state'], 'on_other_device',
          reason: 'the stored state is the mirror rule\'s, unchanged');
    });

    test('another file of the upload arriving counts for the waiting one',
        () async {
      await h.verify();
      server([
        _remote('x', state: 'allocated', version: 0),
        _remote('y', state: 'receiving', index: 1, version: 0),
      ]);
      await enter();
      expect(h.manager.otherDeviceSending.value, {'b-9'});
    });

    // Review #1: the poll that reads a waiting row's batch also applies the
    // mirror rule, so a file that arrived is never told to be added again.
    test('a waiting row whose file arrived takes the server state at the '
        'next poll', () async {
      await h.verify();
      server([_remote('x', state: 'allocated', version: 0)]);
      await enter();
      h.manager.request('again', bypassBackoff: true);
      await h.pump();
      expect((await row('x'))!['last_state'], 'on_other_device');
      server([_remote('x', state: 'review_ready')]);
      poll();
      await h.pump();
      expect((await row('x'))!['last_state'], 'review_ready');
    });

    // Review #8: a batch the server forgot ends its waiting rows, like the
    // others, instead of being read every 5 s.
    test('a waiting row of a batch the server forgot ends as expired',
        () async {
      await h.verify();
      server([_remote('x', state: 'allocated', version: 0)]);
      await enter();
      h.manager.request('again', bypassBackoff: true);
      await h.pump();
      expect((await row('x'))!['last_state'], 'on_other_device');
      h.api.onListItems = (batch, after) async =>
          throw apiError(404, 'upload_batch_not_found', retryable: false);
      poll();
      await h.pump();
      expect((await row('x'))!['last_state'], 'expired');
      expect((await row('x'))!['last_error_code'], 'upload_batch_not_found');
    });

    // Review #2: a change seen against a read from before a long absence is
    // not dated now.
    test('reopening the page long after: a change since is not "being sent"',
        () async {
      await h.verify();
      server([
        _remote('x', state: 'allocated', version: 0),
        _remote('y', state: 'allocated', index: 1, version: 0),
      ]);
      await enter();
      visible.value = false;
      await h.pump();
      h.clock.advance(const Duration(minutes: 20));
      server([
        _remote('x', state: 'allocated', version: 0),
        _remote('y', state: 'validating', index: 1, version: 0),
      ]);
      await enter();
      expect(h.manager.otherDeviceSending.value, isEmpty);
    });

    // Review #3: with no pass running (offline here; also a backoff), the
    // open page's poll tick still lets time end "being sent".
    test('time alone ends it at the next tick, even with no pass', () async {
      await h.verify();
      server([
        _remote('x', state: 'allocated', version: 0),
        _remote('y', state: 'receiving', index: 1, version: 0),
      ]);
      await enter();
      expect(h.manager.otherDeviceSending.value, {'b-9'});
      h.offline = true;
      h.clock.advance(const Duration(seconds: 61));
      poll();
      await h.pump();
      expect(h.manager.otherDeviceSending.value, isEmpty);
    });

    test('when nothing arrives for a minute, it is no longer sent, at the '
        'next poll, with no server change', () async {
      await h.verify();
      server([
        _remote('x', state: 'allocated', version: 0),
        _remote('y', state: 'receiving', index: 1, version: 0),
      ]);
      await enter();
      expect(h.manager.otherDeviceSending.value, {'b-9'});

      // The sender stopped: the server ended the transfer.
      server([
        _remote('x', state: 'allocated', version: 0),
        _remote('y', state: 'allocated', index: 1, version: 0),
      ]);
      h.clock.advance(const Duration(seconds: 5));
      poll();
      await h.pump();
      expect(h.manager.otherDeviceSending.value, {'b-9'},
          reason: 'within the minute');

      h.clock.advance(const Duration(seconds: 56));
      poll();
      await h.pump();
      expect(h.manager.otherDeviceSending.value, isEmpty);
    });
  });

  group('7-R2-02 after a sign-out and a sign-in as the same user', () {
    /// Picks a.flac (u-2 in batch u-1) and brings it to review_ready with a
    /// draft, then signs out (quiesce, rotate) and signs in again (a new
    /// manager on the new token). Returns the new token.
    Future<String> pickThenSignOutAndIn() async {
      await h.verify();
      await h.manager.addFiles([await h.file('a.flac', 'abc')]);
      await h.pump();
      h.api.openPuts.single.complete(state: 'review_ready', batchUuid: 'u-1');
      await h.pump();
      await h.store.update(h.token, ['u-2'],
          draftJson: const Value('{"title":"Mine"}'));
      expect((await row('u-2'))!['last_state'], 'review_ready');
      expect((await row('u-2'))!['expected_sha256'], isNotNull);

      visible.value = false;
      await h.pump();
      await h.manager.quiesce();
      final rotated = await h.binding.rotate();
      await h.verify();
      h.manager = h.build();
      h.api.onListBatches = (after) async => UploadBatchPage.fromJson({
        'batches': [batchJson('u-1')],
        'next_after': null,
      });
      h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
        'items': batch == 'u-1'
            ? [
                itemJson('u-2',
                    batchUuid: 'u-1',
                    state: 'review_ready',
                    filename: 'a.flac',
                    expectedBytes: 3,
                    reviewVersion: 1),
              ]
            : <Object>[],
        'next_after': null,
      });
      return rotated!.localBindingId;
    }

    // Sign-off s7-app-texts follow-up: the device that added the file lost
    // its record; nobody sends the bytes, so it is not "being sent".
    test('a file this device added and lost the record of, still waiting '
        'for its bytes: waiting here, and nobody is sending it', () async {
      await pickThenSignOutAndIn();
      h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
        'items': batch == 'u-1'
            ? [
                itemJson('u-2',
                    batchUuid: 'u-1',
                    state: 'allocated',
                    filename: 'a.flac',
                    expectedBytes: 3),
              ]
            : <Object>[],
        'next_after': null,
      });
      await enter();
      h.manager.request('again', bypassBackoff: true);
      await h.pump();
      expect((await row('u-2'))!['last_state'], 'on_other_device');
      h.timers.fire(UploadManager.pollInterval);
      await h.pump();
      expect(h.manager.otherDeviceSending.value, isEmpty);
    });

    test('entering Uploads shows the server item again, under the current '
        'binding, without anything of the earlier sign-in', () async {
      final current = await pickThenSignOutAndIn();
      expect(current, isNot(h.token));
      await enter();

      final r = await row('u-2');
      expect(r, isNotNull);
      expect(r!['local_binding_id'], current);
      expect(r['last_state'], 'review_ready');
      expect(r['display_name'], 'a.flac');
      expect(r['source_descriptor_json'], isNull);
      expect(r['expected_sha256'], isNull);
      expect(r['operation_uuid'], isNull);
      expect(r['transfer_operation_uuid'], isNull);
      expect(r['draft_json'], isNull);
      expect([for (final i in await h.store.forBinding(current)) i.itemUuid],
          ['u-2']);
      expect(h.api.puts, hasLength(1), reason: 'nothing is sent again');
    });

    test('Review tags can commit it', () async {
      await pickThenSignOutAndIn();
      await enter();

      await h.manager.submitReviewAction('u-2', ReviewActionKind.commit,
          reviewVersion: 1,
          body: {'base_review_version': 1, 'edits': {}, 'write_tags': false});
      await h.pump();

      expect(transport.sent, [(ReviewActionKind.commit, 'u-2')]);
      expect((await row('u-2'))!['last_state'], 'committing');
    });

    test('Cancel sends the DELETE', () async {
      await pickThenSignOutAndIn();
      await enter();

      await h.manager.cancel('u-2');
      await h.pump();

      expect(h.api.calls, contains('cancelItem u-2'));
      expect((await row('u-2'))!['last_state'], 'cancelled');
    });

    test('a cached feature block after the sign-in changes nothing',
        () async {
      await pickThenSignOutAndIn();
      h.feature = const AdvertisedFeature(
        UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
        fromCache: true,
      );
      final before = await row('u-2');
      await enter();

      expect(h.api.calls.where((c) => c == 'listBatches'), isEmpty);
      expect(await row('u-2'), before);
    });
  });

  // 7-R1-22: an adopted item the server still needs bytes for is never
  // transferred from this device: it waits for the device it came from
  // (local state `on_other_device`), with Cancel as the only action.
  group('an adopted item that still needs its bytes', () {
    test('is never transferred and waits for the other device', () async {
      await h.verify();
      server([_remote('x', state: 'allocated', version: 0)]);
      await enter();
      h.manager.request('again', bypassBackoff: true);
      await h.pump();

      expect(h.api.puts, isEmpty);
      expect(h.opened, isEmpty);
      expect((await row('x'))!['last_state'], 'on_other_device');
    });

    test('an interrupted transfer from elsewhere (back to allocated) is not '
        'taken over', () async {
      await h.verify();
      server([_remote('x', state: 'receiving', version: 0)]);
      await enter();
      expect((await row('x'))!['last_state'], 'receiving');

      h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
        'items': [
          _remote('x', state: 'allocated', version: 0)
            ..['error'] = {'code': 'upload_interrupted', 'retryable': true},
        ],
        'next_after': null,
      });
      h.timers.fire(UploadManager.pollInterval);
      await h.pump();
      h.manager.request('again', bypassBackoff: true);
      await h.pump();

      expect(h.api.puts, isEmpty);
      expect((await row('x'))!['last_state'], 'on_other_device');
    });

    test('Cancel sends the DELETE', () async {
      await h.verify();
      server([_remote('x', state: 'allocated', version: 0)]);
      await enter();
      await h.manager.cancel('x');
      await h.pump();

      expect(h.api.calls, contains('cancelItem x'));
      expect((await row('x'))!['last_state'], 'cancelled');
    });

    test('once the other device sent it, the next page entry shows it',
        () async {
      await h.verify();
      server([_remote('x', state: 'allocated', version: 0)]);
      await enter();
      expect((await row('x'))!['last_state'], 'on_other_device');

      visible.value = false;
      await h.pump();
      server([_remote('x')]);
      await enter();
      expect((await row('x'))!['last_state'], 'review_ready');
    });

    test('a retry the server answers with allocated waits for the other '
        'device too', () async {
      await h.verify();
      server([
        _remote('x', state: 'failed')
          ..['error'] = {'code': 'upload_source_missing', 'retryable': true},
      ]);
      await enter();
      h.api.onGetItem = (item) async => UploadItem.fromJson(
          _remote(item, state: 'failed'));
      h.api.onRetry = (item, version) async => UploadItem.fromJson(
          _remote(item, state: 'allocated', version: version + 1));

      expect(await h.manager.retry('x'), RetryOutcome.accepted);
      await h.pump();

      expect(h.api.puts, isEmpty);
      expect((await row('x'))!['last_state'], 'on_other_device');
    });

    // 7-R2-03: adopted as on_other_device at once, not only after a
    // transfer pass (which a pending transfer wait skips).
    test('is stored as waiting for the other device the moment it is '
        'adopted, even while a transfer wait is pending', () async {
      await h.verify();
      await h.manager.addFiles([await h.file('a.flac', 'abc')]);
      await h.pump();
      h.api.openPuts.single.fail(
          apiError(503, 'upload_slots_busy', retryable: true, retryAfterS: 30));
      await h.pump();
      expect((await row('u-2'))!['last_error_code'], 'upload_slots_busy');

      server([_remote('x', state: 'allocated', version: 0)]);
      await enter();

      expect((await row('x'))!['last_state'], 'on_other_device');
      final loss = UploadLossReporter(intents: h.store, binding: h.binding);
      expect(await loss.pendingLossSummary(), '1 upload not yet sent');
    });

    test('an interrupted transfer from elsewhere is adopted as waiting for '
        'the other device too', () async {
      await h.verify();
      await h.manager.addFiles([await h.file('a.flac', 'abc')]);
      await h.pump();
      h.api.openPuts.single.fail(
          apiError(503, 'upload_slots_busy', retryable: true, retryAfterS: 30));
      await h.pump();

      server([_remote('x', state: 'transferring', version: 0)]);
      await enter();

      expect((await row('x'))!['last_state'], 'on_other_device');
    });

    test('an adopted row the poll moves back to allocated is not counted '
        'as an unsent upload of this device', () async {
      await h.verify();
      await h.manager.addFiles([await h.file('a.flac', 'abc')]);
      await h.pump();
      h.api.openPuts.single.fail(
          apiError(503, 'upload_slots_busy', retryable: true, retryAfterS: 30));
      await h.pump();
      server([_remote('x', state: 'receiving', version: 0)]);
      await enter();
      expect((await row('x'))!['last_state'], 'receiving');

      // The other device's transfer was cut: a server read stores allocated
      // (as the status poll does) before any pass converts it.
      await h.store.update(h.token, ['x'], lastState: const Value('allocated'));
      expect((await row('x'))!['last_state'], 'allocated');

      final loss = UploadLossReporter(intents: h.store, binding: h.binding);
      expect(await loss.pendingLossSummary(), '1 upload not yet sent');
    });

    test('is not counted as an unsent upload of this device', () async {
      await h.verify();
      server([_remote('x', state: 'allocated', version: 0)]);
      await enter();
      final loss = UploadLossReporter(intents: h.store, binding: h.binding);
      expect(await loss.pendingLossSummary(), isNull);
    });
  });

  // TR-UPLOAD-03: the server's per-item `retryable` flag of every listed
  // item is kept (in memory, per item) for the Uploads page's Retry.
  test('TR-UPLOAD-03 the listing keeps each item\'s retryable flag', () async {
    await h.verify();
    server([
      {
        ..._remote('zip', state: 'failed'),
        'error': {'code': 'user_staged_quota_exceeded', 'retryable': true},
      },
      {
        ..._remote('bad', state: 'failed'),
        'error': {'code': 'probe_timeout', 'retryable': false},
      },
      {
        ..._remote('old', state: 'failed'),
        'error': {'code': 'probe_timeout'},
      },
    ]);
    await enter();
    expect(h.manager.retryable.value, {'zip': true, 'bad': false});
  });

  // Review r1 of 7-fix-r3-fe (rev-1 #4): the flag is kept only for an item the
  // server holds as failed (the server also flags `allocated` items after a
  // dead transfer; those are not retried through Retry).
  test('TR-UPLOAD-03 r1 a flag on an item that is not failed on the server '
      'is not kept', () async {
    await h.verify();
    server([
      {
        ..._remote('alloc', state: 'allocated'),
        'error': {'code': 'upload_interrupted', 'retryable': true},
      },
      {
        ..._remote('bad', state: 'failed'),
        'error': {'code': 'probe_timeout', 'retryable': true},
      },
    ]);
    await enter();
    expect(h.manager.retryable.value, {'bad': true});
  });
}
