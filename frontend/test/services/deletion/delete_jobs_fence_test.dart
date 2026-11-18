// Phase 8B.1b S9: the binding fence, reset quiesce and relaunch recovery
// (SC-01 rule 4, SC-15, SC-14 "status-first recovery"; plan exit "a late
// response after a reset is a no-op"; review 8-A03 unit half: "No old job
// crosses to the new server; SC-01 fence makes the late write a no-op";
// plan §4 check "reset and user switch mid-poll produce a fenced no-op").
//  * A response that arrives after the reset's fence changes nothing: no
//    row, no job state, no sync request, no further request.
//  * A user switch (the binding token rotates) in the middle of a poll is
//    the same fenced no-op.
//  * After quiesce nothing is sent; preview and submit are unavailable; a
//    pass waiting at the gate ends.
//  * A relaunch resumes the binding's unresolved submissions status-first
//    under their own operation UUID; another binding's rows are never sent.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/dead_sign_in_records.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/operations/durable_submission.dart';

import '../../helpers/delete_jobs_harness.dart';

const _frozenOld =
    '{"operation_uuid":"op-old","targets":[{"uuid_id":"a",'
    '"base_revision":1}],"confirmed_count":1}';

void main() {
  late DeleteJobsHarness h;
  setUp(() async {
    h = await DeleteJobsHarness.create();
    await h.verify();
  });
  tearDown(() => h.dispose());

  Future<void> prepareOld(String token, {String state = 'prepared'}) async {
    await DurableSubmission(db: h.db, binding: h.binding, clock: h.clock)
        .prepare(
          kind: 'track_deletion',
          operationUuid: 'op-old',
          frozenBodyJson: _frozenOld,
          bindingToken: token,
        );
    if (state != 'prepared') {
      await h.db.customStatement(
        "UPDATE durable_submissions SET state = '$state' "
        "WHERE operation_uuid = 'op-old'",
      );
    }
  }

  // signoff-8-logout-warning round 3: after a log-out that kept the unsent
  // records and the same user's login took them over, a deletion continues
  // under the new token: one never sent is sent once, as frozen (its base
  // revisions let the server refuse a stale one); one the server may have
  // received is resolved by its own operation id first, never sent twice.
  group('taken over after the same user signs in again', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> takeOver() async {
      await h.manager.quiesce();
      final records = DeadSignInRecords(db: h.db, binding: h.binding);
      await records.keepForNextLogin(h.token); // the session-ended log-out
      await h.binding.rotate();
      final token = (await h.binding.current())!.localBindingId;
      await records.takeOver(token);
      h.gate.gate.stop();
      await h.verify();
      h.manager = h.build();
      h.manager.request('coldStart');
      await h.pump();
    }

    test('a deletion never sent is sent once, as stored', () async {
      await prepareOld(h.token);
      await takeOver();
      expect(h.api.callsOf('createJob'), ['createJob op-old']);
      expect(h.api.createBodies.single, _frozenOld);
      expect(h.job('op-old')!.phase, DeleteJobPhase.accepted);
    });

    test('one the server already received is recognised by its id, not sent '
        'again', () async {
      await prepareOld(h.token, state: 'sent');
      h.api.serverJobs['op-old'] = deletionJobJson('op-old', [
        deletionItemJson('a'),
      ]);
      await takeOver();
      expect(h.api.callsOf('createJob'), isEmpty);
      expect(h.api.calls.first, 'getJob op-old');
      expect((await h.submissions()).single['state'], 'accepted');
    });
  });

  group('a reset in the middle (exit proof; 8-A03)', () {
    test('a late acceptance after the fence is a no-op', () async {
      final hold = Completer<DeletionJobDto>();
      h.api.onCreateJob = (_) => hold.future;
      await h.submitAll([('a', 1)]);
      await h.pump();
      final rowBefore = (await h.submissions()).single;

      await h.binding.fence(); // SC-15 step 1
      hold.complete(DeletionJobDto.fromJson(deletionJobJson('op-1', [
        deletionItemJson('a', status: 'deleted', tombstoneRevision: 5),
      ], status: 'succeeded')));
      await h.pump();

      expect((await h.submissions()).single, rowBefore);
      expect(h.job('op-1')!.phase, DeleteJobPhase.submitting);
      expect(h.job('op-1')!.items, isEmpty);
      expect(h.syncRequests, 0);
      h.timers.fire();
      await h.pump();
      expect(h.api.calls, ['preview a', 'createJob op-1']);
    });

    test('a late poll answer after the fence is a no-op', () async {
      await h.submitAll([('a', 1)]);
      await h.pump();
      final hold = Completer<DeletionJobDto>();
      h.api.onGetJob = (_) => hold.future;
      h.timers.fire();
      await h.pump();

      await h.binding.fence();
      hold.complete(DeletionJobDto.fromJson(deletionJobJson('op-1', [
        deletionItemJson('a', status: 'deleted', tombstoneRevision: 5),
      ], status: 'succeeded')));
      await h.pump();

      expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
      expect(h.syncRequests, 0);
    });

    test('quiesce after the fence ends the pass; nothing more is sent',
        () async {
      final hold = Completer<DeletionJobDto>();
      h.api.onCreateJob = (_) => hold.future;
      await h.submitAll([('a', 1)]);
      await h.pump();

      await h.binding.fence();
      await h.manager.quiesce().timeout(const Duration(seconds: 5));
      hold.complete(DeletionJobDto.fromJson(
        deletionJobJson('op-1', [deletionItemJson('a')]),
      ));
      await h.pump();

      expect(h.syncRequests, 0);
      expect(h.manager.isClosed, isTrue);
      h.manager.request('networkRecovered', bypassBackoff: true);
      h.timers.fire();
      await h.pump();
      expect(h.api.calls, ['preview a', 'createJob op-1']);
    });
  });

  test('a same-user log-out (the token rotates) in the middle of a poll is '
      'a fenced no-op', () async {
    await h.submitAll([('a', 1)]);
    await h.pump();
    final hold = Completer<DeletionJobDto>();
    h.api.onGetJob = (_) => hold.future;
    h.timers.fire();
    await h.pump();

    await h.binding.rotate();
    hold.complete(DeletionJobDto.fromJson(deletionJobJson('op-1', [
      deletionItemJson('a', status: 'deleted', tombstoneRevision: 5),
    ], status: 'succeeded')));
    await h.pump();

    expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
    expect(h.syncRequests, 0);
  });

  group('quiesce', () {
    test('ends a pass waiting at an unverified gate; nothing is sent',
        () async {
      await prepareOld(h.token);
      final fresh = await DeleteJobsHarness.create();
      addTearDown(fresh.dispose);
      // `fresh` never verifies its gate.
      fresh.manager.request('coldStart');
      await fresh.pump();
      await fresh.manager.quiesce().timeout(const Duration(seconds: 5));
      expect(fresh.api.calls, isEmpty);
    });

    test('is idempotent; preview and submit are then unavailable', () async {
      final preview = await h.preview([('a', 1)]);
      await h.manager.quiesce();
      await h.manager.quiesce();

      await expectLater(
        h.manager.submit(preview, confirmedCount: 1),
        throwsA(isA<DeleteJobsUnavailable>().having(
          (e) => e.reason,
          'reason',
          DeleteJobsUnavailableReason.closed,
        )),
      );
      await expectLater(
        h.preview([('a', 1)]),
        throwsA(isA<DeleteJobsUnavailable>()),
      );
      expect(await h.submissions(), isEmpty);
      expect(h.api.calls, ['preview a']);
    });
  });

  group('relaunch recovery', () {
    test('an unconfirmed submission is resolved by its own UUID: accepted, '
        'never sent twice', () async {
      await prepareOld(h.token, state: 'ambiguous');
      h.api.serverJobs['op-old'] = deletionJobJson('op-old', [
        deletionItemJson('a'),
      ]);
      await h.manager.quiesce();
      h.manager = h.build();
      h.manager.request('coldStart');
      await h.pump();

      expect(h.api.callsOf('createJob'), isEmpty);
      expect(h.api.calls.first, 'getJob op-old');
      expect((await h.submissions()).single['state'], 'accepted');
      final job = h.job('op-old')!;
      expect(job.phase, DeleteJobPhase.accepted);
      expect(job.targets.single.uuidId, 'a');
    });

    test('a submission frozen but never sent is sent once, as stored',
        () async {
      await prepareOld(h.token);
      await h.manager.quiesce();
      h.manager = h.build();
      h.manager.request('coldStart');
      await h.pump();

      expect(h.api.callsOf('createJob'), ['createJob op-old']);
      expect(h.api.createBodies.single, _frozenOld);
      expect(h.job('op-old')!.phase, DeleteJobPhase.accepted);
    });

    test('an earlier sign-in\'s rows are never sent (a same-user log-out '
        'rotates the token)', () async {
      await prepareOld(h.token);
      await h.binding.rotate();
      await h.manager.quiesce();
      h.manager = h.build();
      h.manager.request('coldStart');
      await h.pump();
      h.timers.fire();
      await h.pump();

      expect(h.api.calls, isEmpty);
      expect((await h.submissions()).single['state'], 'prepared');
      expect(h.job('op-old'), isNull);
    });
  });
}
