// Phase 8B.1b S8: receipt polling (spec §6 paras 4–5; SC-13; SC-03; plan
// exit "a cached block never starts the runner", "polling stops at
// terminal", "401 parks", "partial outcomes are surfaced per target").
//  * An accepted job is polled by its operation UUID (on the runner,
//    paced by the BackoffSchedule) until the server says it is finished;
//    then nothing more is requested for it.
//  * Every target's outcome is surfaced: status, the closed error code, the
//    tombstone revision and the details (missing master, storage cleanup
//    pending). A status this client does not know is kept, not coerced.
//  * The local phase reflects the server's receipt: accepted, running,
//    completed, partial, failed.
//  * When a target newly reaches `deleted` or `already_deleted`, one normal
//    `/changes` sync is requested (never a local removal).
//  * No network work starts on a cached or absent block, or offline.
//  * A 401 while polling parks the runner.
//  * `follow` polls a job known only from the receipt list.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/deletion/delete_job.dart';
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

  void serverSays(
    String op,
    String status,
    List<Map<String, dynamic>> items,
  ) => h.api.serverJobs[op] = deletionJobJson(op, items, status: status);

  // Sign-off OPEN-M-11 (E8): a poll whose token is withheld skips that job
  // for this pass; the other jobs are still polled, and it is polled again
  // later.
  test('a poll with the token withheld skips that job for this pass only',
      () async {
    await h.submitAll([('a', 1)]);
    await h.submitAll([('b', 2)]);
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
    expect(h.job('op-2')!.phase, DeleteJobPhase.accepted);

    final readable = h.api.onGetJob;
    h.api.onGetJob = (op) async => op == 'op-1'
        ? throw const TokenWithheldException()
        : readable(op);
    serverSays('op-2', 'running', [
      deletionItemJson('b', status: 'running', baseRevision: 2),
    ]);
    h.timers.fire();
    await h.pump();
    expect(h.job('op-2')!.phase, DeleteJobPhase.running,
        reason: 'the pass went on to op-2');
    expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
    expect(h.timers.active, isNotEmpty, reason: 'polled again later');

    h.api.onGetJob = readable;
    serverSays('op-1', 'running', [
      deletionItemJson('a', status: 'running'),
    ]);
    h.timers.fire();
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.running);
  });

  test('an accepted job is polled until it is finished, then never again',
      () async {
    await h.submitAll([('a', 1), ('b', 2)]);
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);

    serverSays('op-1', 'running', [
      deletionItemJson('a', status: 'running'),
      deletionItemJson('b', baseRevision: 2),
    ]);
    h.timers.fire();
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.running);
    expect(h.job('op-1')!.items.first.status, DeleteItemStatus.running);

    serverSays('op-1', 'succeeded', [
      deletionItemJson('a', status: 'deleted', tombstoneRevision: 50),
      deletionItemJson(
        'b',
        baseRevision: 2,
        status: 'already_deleted',
        tombstoneRevision: 31,
      ),
    ]);
    h.timers.fire();
    await h.pump();
    final job = h.job('op-1')!;
    expect(job.phase, DeleteJobPhase.completed);
    expect(job.items.map((i) => i.status), [
      DeleteItemStatus.deleted,
      DeleteItemStatus.alreadyDeleted,
    ]);
    expect(job.items.map((i) => i.tombstoneRevision), [50, 31]);
    expect(job.items.every((i) => i.isGone), isTrue);

    final polls = h.api.callsOf('getJob').length;
    expect(h.timers.active, isEmpty, reason: 'no retry scheduled');
    h.manager.request('appResume', bypassBackoff: true);
    await h.pump();
    expect(h.api.callsOf('getJob').length, polls,
        reason: 'a finished job is not polled again');
  });

  test('a partial result surfaces each target with its own reason', () async {
    await h.submitAll([('a', 1), ('b', 2), ('c', 3), ('d', 4)]);
    await h.pump();
    serverSays('op-1', 'partial', [
      deletionItemJson(
        'a',
        status: 'deleted',
        tombstoneRevision: 60,
        details: ['master_missing', 'storage_cleanup_pending'],
      ),
      deletionItemJson('b', baseRevision: 2, status: 'conflict', error: 'conflict'),
      deletionItemJson('c', baseRevision: 3, status: 'busy', error: 'busy'),
      deletionItemJson('d', baseRevision: 4, status: 'failed', error: 'path_rejected'),
    ]);
    h.timers.fire();
    await h.pump();

    final job = h.job('op-1')!;
    expect(job.phase, DeleteJobPhase.partial);
    final byUuid = {for (final i in job.items) i.uuid: i};
    expect(byUuid['a']!.status, DeleteItemStatus.deleted);
    expect(byUuid['a']!.masterMissing, isTrue);
    expect(byUuid['a']!.storageCleanupPending, isTrue);
    expect(byUuid['a']!.errorCode, isNull);
    expect(byUuid['b']!.status, DeleteItemStatus.conflict);
    expect(byUuid['b']!.errorCode, 'conflict');
    expect(byUuid['b']!.baseRevision, 2);
    expect(byUuid['b']!.isGone, isFalse);
    expect(byUuid['c']!.status, DeleteItemStatus.busy);
    expect(byUuid['d']!.status, DeleteItemStatus.failed);
    expect(byUuid['d']!.errorCode, 'path_rejected');
    expect(byUuid['d']!.tombstoneRevision, isNull);
  });

  test('a job where nothing was deleted is failed', () async {
    await h.submitAll([('a', 1)]);
    await h.pump();
    serverSays('op-1', 'failed', [
      deletionItemJson('a', status: 'failed', error: 'not_found'),
    ]);
    h.timers.fire();
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.failed);
    expect(h.syncRequests, 0, reason: 'nothing was deleted');
  });

  test('a status this client does not know is kept and keeps the job polled',
      () async {
    await h.submitAll([('a', 1)]);
    await h.pump();
    serverSays('op-1', 'archiving', [
      deletionItemJson('a', status: 'quarantined'),
    ]);
    h.timers.fire();
    await h.pump();
    final job = h.job('op-1')!;
    expect(job.phase.isTerminal, isFalse);
    expect(job.items.single.status, DeleteItemStatus.unrecognized);
    expect(job.items.single.rawStatus, 'quarantined');
    expect(h.timers.active, isNotEmpty, reason: 'still polled');
  });

  test('one /changes sync is requested when a target newly becomes deleted',
      () async {
    await h.submitAll([('a', 1), ('b', 2)]);
    await h.pump();
    expect(h.syncRequests, 0);

    serverSays('op-1', 'running', [
      deletionItemJson('a', status: 'deleted', tombstoneRevision: 9),
      deletionItemJson('b', baseRevision: 2, status: 'running'),
    ]);
    h.timers.fire();
    await h.pump();
    expect(h.syncRequests, 1);

    h.timers.fire(); // the same answer again: nothing new
    await h.pump();
    expect(h.syncRequests, 1);

    serverSays('op-1', 'succeeded', [
      deletionItemJson('a', status: 'deleted', tombstoneRevision: 9),
      deletionItemJson('b', baseRevision: 2, status: 'already_deleted', tombstoneRevision: 4),
    ]);
    h.timers.fire();
    await h.pump();
    expect(h.syncRequests, 2);
  });

  test('an acceptance that already carries a deletion requests a sync',
      () async {
    h.api.onCreateJob = (body) async {
      h.api.serverJobs['op-1'] = deletionJobJson('op-1', [
        deletionItemJson('a', status: 'already_deleted', tombstoneRevision: 3),
      ], status: 'succeeded');
      return h.api.onGetJob('op-1');
    };
    await h.submitAll([('a', 1)]);
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.completed);
    expect(h.syncRequests, 1);
  });

  // 8-fix-r1 8-R1-23: the server accepted the job (2xx) but its receipt
  // could not be read. The submission is settled as accepted (nothing is
  // resent, the tracks are not held as awaiting an answer), and the job is
  // read by its operation UUID until a status read can be parsed.
  test('an accepted job whose receipt is unreadable is accepted and read by '
      'status', () async {
    h.api.onCreateJob = (body) async => throw const DeletionReceiptUnreadable();
    final readable = h.api.onGetJob;
    h.api.onGetJob = (op) async => throw const FormatException('unreadable');
    await h.submitAll([('a', 1)]);
    await h.pump();

    expect((await h.submissions()).single['state'], 'accepted');
    final job = h.job('op-1')!;
    expect(job.phase, DeleteJobPhase.accepted);
    expect(job.items, isEmpty, reason: 'no outcome is known yet');
    expect(h.manager.awaitingAnswer(['a']), isFalse);
    expect(h.api.callsOf('getJob'), isNotEmpty, reason: 'read by status');
    expect(h.timers.active, isNotEmpty, reason: 'read again later');

    h.api.onGetJob = readable;
    serverSays('op-1', 'succeeded', [
      deletionItemJson('a', status: 'deleted', tombstoneRevision: 9),
    ]);
    h.timers.fire();
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.completed);
    expect(h.syncRequests, 1);
    expect(h.api.callsOf('createJob'), ['createJob op-1'],
        reason: 'never sent again');
  });

  // 8-fix-r1 TR-DELETE-02: the post-deletion sync is kept owed until one
  // actually ran (offline, no verified connection, a failed pull or a sync
  // already in flight answer false).
  test('a sync that did not run is asked for again until one runs', () async {
    h.syncSucceeds = false;
    h.api.onCreateJob = (body) async {
      h.api.serverJobs['op-1'] = deletionJobJson('op-1', [
        deletionItemJson('a', status: 'already_deleted', tombstoneRevision: 3),
      ], status: 'succeeded');
      return h.api.onGetJob('op-1');
    };
    await h.submitAll([('a', 1)]);
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.completed);
    expect(h.syncRequests, 1);
    expect(h.timers.active, isNotEmpty, reason: 'the owed sync is retried');

    h.timers.fire();
    await h.pump();
    expect(h.syncRequests, 2);

    h.syncSucceeds = true;
    h.timers.fire();
    await h.pump();
    expect(h.syncRequests, 3);
    expect(h.timers.active, isEmpty, reason: 'nothing owed any more');
    h.manager.request('appResume', bypassBackoff: true);
    await h.pump();
    expect(h.syncRequests, 3);
  });

  group('no network work without a live block, or offline', () {
    for (final (name, feature) in [
      ('a cached block', const AdvertisedFeature(
        LibraryToolsFeature(version: 1, serverDelete: true, duplicateReview: false),
        fromCache: true,
      )),
      ('no block', null),
    ]) {
      test('$name: polling and resuming send nothing', () async {
        await h.submitAll([('a', 1)]);
        await h.pump();
        final before = h.api.calls.length;
        h.feature = feature;

        h.manager.follow('op-9');
        h.manager.request('appResume', bypassBackoff: true);
        h.timers.fire();
        await h.pump();
        expect(h.api.calls.length, before);
      });
    }

    test('a relaunch with only the cached block never starts a pending '
        'submission', () async {
      // A previous run froze a confirmation and was killed before sending.
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
      h.feature = const AdvertisedFeature(
        LibraryToolsFeature(version: 1, serverDelete: true, duplicateReview: false),
        fromCache: true,
      );
      h.manager = h.build();
      h.manager.request('coldStart');
      await h.pump();
      h.timers.fire();
      await h.pump();

      expect(h.api.calls, isEmpty);
      expect((await h.submissions()).single['state'], 'prepared');
    });

    test('offline: nothing is sent; back online the job is polled', () async {
      await h.submitAll([('a', 1)]);
      await h.pump();
      final before = h.api.calls.length;
      h.offline = true;
      h.timers.fire();
      h.manager.request('poll');
      await h.pump();
      expect(h.api.calls.length, before);

      h.offline = false;
      h.manager.request('networkRecovered', bypassBackoff: true);
      await h.pump();
      expect(h.api.calls.length, greaterThan(before));
    });
  });

  test('a 401 while polling parks the runner', () async {
    await h.submitAll([('a', 1)]);
    await h.pump();
    h.api.onGetJob = (_) async =>
        throw apiError(401, 'auth_required', retryable: false);
    h.timers.fire();
    await h.pump();
    final sent = h.api.calls.length;
    expect(h.job('op-1')!.phase, DeleteJobPhase.accepted,
        reason: 'the job keeps its last known state');

    h.timers.fire();
    h.manager.request('networkRecovered', bypassBackoff: true);
    await h.pump();
    expect(h.api.calls.length, sent);
  });

  test('follow polls a job known only from the receipt list', () async {
    serverSays('op-x', 'running', [
      deletionItemJson('z', status: 'running'),
    ]);
    h.manager.follow('op-x');
    await h.pump();

    expect(h.api.callsOf('getJob'), ['getJob op-x']);
    final job = h.job('op-x')!;
    expect(job.phase, DeleteJobPhase.running);
    expect(job.createdAt, 1762800000);
    expect(job.items.single.uuid, 'z');
    expect(await h.submissions(), isEmpty, reason: 'following writes nothing');
  });

  test('opening the receipt of a finished job reads it once more and shows '
      'what the server says now', () async {
    await h.submitAll([('a', 1)]);
    await h.pump();
    serverSays('op-1', 'succeeded', [
      deletionItemJson(
        'a',
        status: 'deleted',
        tombstoneRevision: 50,
        details: ['master_missing', 'storage_cleanup_pending'],
      ),
    ]);
    h.timers.fire();
    await h.pump();
    expect(h.job('op-1')!.items.single.storageCleanupPending, isTrue);
    final polls = h.api.callsOf('getJob').length;

    // The server's clean-up finished.
    serverSays('op-1', 'succeeded', [
      deletionItemJson(
        'a',
        status: 'deleted',
        tombstoneRevision: 50,
        details: ['master_missing'],
      ),
    ]);
    h.manager.follow('op-1');
    await h.pump();
    expect(h.api.callsOf('getJob').length, polls + 1);
    final item = h.job('op-1')!.items.single;
    expect(item.storageCleanupPending, isFalse);
    expect(item.masterMissing, isTrue);

    // Read once: nothing more afterwards.
    h.timers.fire();
    h.manager.request('appResume', bypassBackoff: true);
    await h.pump();
    expect(h.api.callsOf('getJob').length, polls + 1);
  });
}
