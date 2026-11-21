// Phase 8B.1b S6: submitting a confirmed deletion (spec §4 paras 3–4;
// SC-14; plan row 8B.1b; coordinator rule "the model must be incapable of
// sending the wrong one").
//  * Only a confirmable preview with the matching typed count can be
//    submitted; anything else writes and sends nothing.
//  * The body is frozen at confirmation: the ordered targets with the
//    revision each was confirmed at, and the confirmed count, under one new
//    operation UUID, persisted (kind `track_deletion`, the binding token)
//    before anything is sent, and sent exactly as stored.
//  * One confirmation is one operation: submitting the same preview again
//    returns the same operation and sends nothing new.
//  * The server's acceptance carries the per-target items; a refusal (a
//    4xx other than 401/408/429, whatever `retryable` says) is final and
//    the request is never sent again.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/operations/durable_submission.dart';

import '../../helpers/delete_jobs_harness.dart';

void main() {
  late DeleteJobsHarness h;
  setUp(() async {
    h = await DeleteJobsHarness.create();
    await h.verify();
  });
  tearDown(() => h.dispose());

  test('a confirmed preview is frozen, persisted, sent once exactly as '
      'stored, and accepted with its items in order', () async {
    final preview = await h.preview([('a', 7), ('b', 3)]);
    final op = await h.manager.submit(preview, confirmedCount: 2);
    await h.pump();

    expect(op, 'op-1');
    const frozen =
        '{"operation_uuid":"op-1",'
        '"targets":[{"uuid_id":"a","base_revision":7},'
        '{"uuid_id":"b","base_revision":3}],'
        '"confirmed_count":2}';
    final row = (await h.submissions()).single;
    expect(row['operation_uuid'], 'op-1');
    expect(row['kind'], 'track_deletion');
    expect(row['local_binding_id'], h.token);
    expect(row['frozen_body_json'], frozen);
    expect(row['state'], 'accepted');

    expect(h.api.callsOf('createJob'), ['createJob op-1']);
    expect(h.api.createBodies.single, frozen);

    final job = h.job('op-1')!;
    expect(job.phase, DeleteJobPhase.accepted);
    expect(job.targets.map((t) => (t.uuidId, t.baseRevision)), [
      ('a', 7),
      ('b', 3),
    ]);
    expect(job.items.map((i) => i.uuid), ['a', 'b']);
    expect(job.items.map((i) => i.status), everyElement(DeleteItemStatus.pending));
  });

  test('a missing-master target is submitted like any confirmable one',
      () async {
    h.api.onPreview = (targets) async => DeletionPreviewDto.fromJson({
      'targets': [previewTargetJson('a', 4, missingMaster: true)],
    });
    final op = await h.submitAll([('a', 4)]);
    await h.pump();
    expect(op, 'op-1');
    expect(h.api.callsOf('createJob'), ['createJob op-1']);
  });

  test('while the answer is outstanding the job is submitting', () async {
    final answer = Completer<DeletionJobDto>();
    h.api.onCreateJob = (_) => answer.future;
    await h.submitAll([('a', 1)]);
    await h.pump();

    expect(h.job('op-1')!.phase, DeleteJobPhase.submitting);
    expect(h.job('op-1')!.items, isEmpty);

    answer.complete(DeletionJobDto.fromJson(
      deletionJobJson('op-1', [deletionItemJson('a')]),
    ));
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
  });

  test('the same confirmation submitted twice is one operation, sent once',
      () async {
    final preview = await h.preview([('a', 1)]);
    final first = await h.manager.submit(preview, confirmedCount: 1);
    final second = await h.manager.submit(preview, confirmedCount: 1);
    await h.pump();
    final third = await h.manager.submit(preview, confirmedCount: 1);
    await h.pump();

    expect([first, second, third], ['op-1', 'op-1', 'op-1']);
    expect(await h.submissions(), hasLength(1));
    expect(h.api.callsOf('createJob'), ['createJob op-1']);
  });

  test('a new preview of the same tracks is a new, deliberate operation',
      () async {
    final first = await h.submitAll([('a', 1)]);
    // 8B.1c: once the first is answered (a new preview while it still
    // awaits its answer is refused: delete_jobs_awaiting_test.dart).
    await h.pump();
    final second = await h.submitAll([('a', 1)]);
    await h.pump();
    expect([first, second], ['op-1', 'op-2']);
  });

  group('refused before anything is written or sent', () {
    test('a preview that is not confirmable', () async {
      h.api.onPreview = (targets) async => DeletionPreviewDto.fromJson({
        'targets': [
          previewTargetJson('a', 1),
          previewTargetJson('b', 1, busy: true),
        ],
      });
      final preview = await h.preview([('a', 1), ('b', 1)]);
      await expectLater(
        h.manager.submit(preview, confirmedCount: 2),
        throwsA(isA<DeletionNotConfirmable>()),
      );
      await h.pump();
      expect(await h.submissions(), isEmpty);
      expect(h.api.callsOf('createJob'), isEmpty);
      expect(h.manager.jobs.value, isEmpty);
    });

    test('an unknown revision, even though the server said no conflict',
        () async {
      final preview = await h.preview([('a', null)]);
      await expectLater(
        h.manager.submit(preview, confirmedCount: 1),
        throwsA(isA<DeletionNotConfirmable>()),
      );
      expect(await h.submissions(), isEmpty);
    });

    test('a typed count that is not the preview count', () async {
      final preview = await h.preview([('a', 1), ('b', 2), ('c', 3)]);
      for (final count in [0, 2, 4]) {
        await expectLater(
          h.manager.submit(preview, confirmedCount: count),
          throwsA(isA<DeletionNotConfirmable>()),
          reason: '$count',
        );
      }
      await h.pump();
      expect(await h.submissions(), isEmpty);
      expect(h.api.callsOf('createJob'), isEmpty);
    });

    test('the switch turned off, or only a cached block, since the preview',
        () async {
      final preview = await h.preview([('a', 1)]);
      for (final feature in const [
        AdvertisedFeature(
          LibraryToolsFeature(version: 1, serverDelete: false, duplicateReview: false),
          fromCache: false,
        ),
        AdvertisedFeature(
          LibraryToolsFeature(version: 1, serverDelete: true, duplicateReview: false),
          fromCache: true,
        ),
        null,
      ]) {
        h.feature = feature;
        await expectLater(
          h.manager.submit(preview, confirmedCount: 1),
          throwsA(isA<DeleteJobsUnavailable>()),
          reason: '$feature',
        );
      }
      await h.pump();
      expect(await h.submissions(), isEmpty);
      expect(h.api.callsOf('createJob'), isEmpty);
    });
  });

  // A stored request this app cannot read back (a damaged row) does not
  // stop the pass: its job shows with no known tracks, it is sent as
  // stored (the server's answer settles it), and the rows after it are
  // sent too.
  test('a stored request that cannot be read is sent as stored and does not '
      'stop the other submissions', () async {
    final store = DurableSubmission(db: h.db, binding: h.binding, clock: h.clock);
    const damaged = '{"operation_uuid":"op-bad","targets":[{"uuid_id":7}],'
        '"confirmed_count":1}';
    await store.prepare(
      kind: 'track_deletion',
      operationUuid: 'op-bad',
      frozenBodyJson: damaged,
      bindingToken: h.token,
    );
    h.clock.advance(const Duration(milliseconds: 10));
    await store.prepare(
      kind: 'track_deletion',
      operationUuid: 'op-good',
      frozenBodyJson:
          '{"operation_uuid":"op-good","targets":[{"uuid_id":"a",'
          '"base_revision":1}],"confirmed_count":1}',
      bindingToken: h.token,
    );
    await h.manager.quiesce();
    final accept = h.api.onCreateJob;
    h.api.onCreateJob = (body) async => body == damaged
        ? throw apiError(422, 'invalid', retryable: false)
        : accept(body);
    h.manager = h.build();
    h.manager.request('coldStart');
    await h.pump();

    expect(h.api.createBodies, contains(damaged));
    expect(h.job('op-bad')!.phase, DeleteJobPhase.rejected);
    expect(h.job('op-bad')!.targets, isEmpty);
    expect(h.job('op-good')!.phase, DeleteJobPhase.accepted);
    expect(h.job('op-good')!.targets.single.uuidId, 'a');
  });

  // Deletion history orders a job the server has not dated by when this
  // device submitted it: the time stored with the submission.
  group('the time this device submitted the job', () {
    test('a job being sent carries it', () async {
      h.clock.advance(const Duration(milliseconds: 123));
      final answer = Completer<DeletionJobDto>();
      h.api.onCreateJob = (_) => answer.future;
      await h.submitAll([('a', 1)]);
      await h.pump();
      expect(h.job('op-1')!.phase, DeleteJobPhase.submitting);
      expect(h.job('op-1')!.submittedAtMs, 9123);
      answer.complete(DeletionJobDto.fromJson(
        deletionJobJson('op-1', [deletionItemJson('a')]),
      ));
      await h.pump();
    });

    test('a refused job keeps it', () async {
      h.clock.advance(const Duration(milliseconds: 50));
      h.api.onCreateJob =
          (_) async => throw apiError(409, 'operation_conflict');
      await h.submitAll([('a', 1)]);
      h.clock.advance(const Duration(seconds: 5));
      await h.pump();
      expect(h.job('op-1')!.phase, DeleteJobPhase.rejected);
      expect(h.job('op-1')!.submittedAtMs, 9050);
    });

    test('a job whose answer was lost keeps it', () async {
      h.clock.advance(const Duration(milliseconds: 70));
      final store = h.api.onCreateJob;
      h.api.onCreateJob = (body) async {
        await store(body);
        throw TimeoutException('lost');
      };
      await h.submitAll([('a', 1)]);
      h.clock.advance(const Duration(seconds: 5));
      await h.pump();
      expect(h.job('op-1')!.phase, DeleteJobPhase.unconfirmed);
      expect(h.job('op-1')!.submittedAtMs, 9070);
    });

    test('an accepted job whose receipt could not be read keeps it',
        () async {
      h.clock.advance(const Duration(milliseconds: 80));
      h.api.onCreateJob =
          (_) async => throw const DeletionReceiptUnreadable();
      h.api.onGetJob = (_) async => throw const FormatException('unreadable');
      await h.submitAll([('a', 1)]);
      h.clock.advance(const Duration(seconds: 5));
      await h.pump();
      expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
      expect(h.job('op-1')!.createdAt, isNull);
      expect(h.job('op-1')!.submittedAtMs, 9080);
    });

    test('after a relaunch, a stored submission being sent again carries '
        'the time it was stored at', () async {
      h.clock.advance(const Duration(milliseconds: 300));
      await DurableSubmission(db: h.db, binding: h.binding, clock: h.clock)
          .prepare(
            kind: 'track_deletion',
            operationUuid: 'op-old',
            frozenBodyJson:
                '{"operation_uuid":"op-old","targets":[{"uuid_id":"a",'
                '"base_revision":1}],"confirmed_count":1}',
            bindingToken: h.token,
          );
      await h.manager.quiesce();
      h.clock.advance(const Duration(seconds: 60));
      final answer = Completer<DeletionJobDto>();
      h.api.onCreateJob = (_) => answer.future;
      h.manager = h.build();
      h.manager.request('coldStart');
      await h.pump();
      expect(h.job('op-old')!.phase, DeleteJobPhase.submitting);
      expect(h.job('op-old')!.submittedAtMs, 9300);
      answer.complete(DeletionJobDto.fromJson(
        deletionJobJson('op-old', [deletionItemJson('a')]),
      ));
      await h.pump();
    });

    test('after a relaunch, a stored submission refused then keeps the time '
        'it was stored at', () async {
      h.clock.advance(const Duration(milliseconds: 400));
      await DurableSubmission(db: h.db, binding: h.binding, clock: h.clock)
          .prepare(
            kind: 'track_deletion',
            operationUuid: 'op-old',
            frozenBodyJson:
                '{"operation_uuid":"op-old","targets":[{"uuid_id":"a",'
                '"base_revision":1}],"confirmed_count":1}',
            bindingToken: h.token,
          );
      await h.manager.quiesce();
      h.clock.advance(const Duration(seconds: 60));
      h.api.onCreateJob =
          (_) async => throw apiError(409, 'operation_conflict');
      h.manager = h.build();
      h.manager.request('coldStart');
      await h.pump();
      expect(h.job('op-old')!.phase, DeleteJobPhase.rejected);
      expect(h.job('op-old')!.submittedAtMs, 9400);
    });
  });

  group('a refusal is final', () {
    for (final (status, code, retryable) in [
      (403, 'library_delete_disabled', false),
      (409, 'operation_conflict', false),
      (422, 'validation_failed', null),
      (409, 'operation_conflict', true),
    ]) {
      test('$status $code (retryable: $retryable): rejected, never resent',
          () async {
        h.api.onCreateJob = (_) async =>
            throw apiError(status, code, retryable: retryable);
        await h.submitAll([('a', 1)]);
        await h.pump();

        final job = h.job('op-1')!;
        expect(job.phase, DeleteJobPhase.rejected);
        expect(job.rejectionCode, code);
        final row = (await h.submissions()).single;
        expect(row['state'], 'rejected');
        expect(row['error_code'], code);

        h.timers.fire();
        h.manager.request('again', bypassBackoff: true);
        await h.pump();
        expect(h.api.callsOf('createJob'), ['createJob op-1']);
        expect(h.api.callsOf('getJob'), isEmpty);
      });
    }
  });

  test('the frozen body survives as stored text: a resend is byte-identical',
      () async {
    var first = true;
    h.api.onCreateJob = (body) async {
      if (first) {
        first = false;
        throw apiError(503, 'unavailable', retryable: true);
      }
      final m = jsonDecode(body) as Map<String, dynamic>;
      return DeletionJobDto.fromJson(deletionJobJson(
        m['operation_uuid'] as String,
        [deletionItemJson('a')],
      ));
    };
    await h.submitAll([('a', 1)]);
    await h.pump();
    h.timers.fire();
    await h.pump();

    expect(h.api.createBodies, hasLength(2));
    expect(h.api.createBodies[1], h.api.createBodies[0]);
    expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
  });
}
