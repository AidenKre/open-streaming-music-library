// Phase 8B.1b review r1 (phase-8/8B.1b-review.md), regression tests:
//  * R1-1: one job whose answer can't be read never stops the other jobs
//    from being polled, and a sync owed by a deletion applied earlier in a
//    pass that then fails is still requested.
//  * R1-2: a preview is only submittable to the manager (scope) that
//    produced it, under the binding it was produced under; a hand-built
//    preview the server never answered is refused. Nothing is written.
//  * R1-3: a preview while the binding gate is not verified answers
//    "unavailable" at once instead of waiting forever; nothing is sent.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';

import '../../helpers/delete_jobs_harness.dart';

void main() {
  late DeleteJobsHarness h;
  setUp(() async => h = await DeleteJobsHarness.create());
  tearDown(() => h.dispose());

  group('R1-1 polling survives one unreadable job', () {
    test('a malformed answer for one job; the next job is still polled',
        () async {
      await h.verify();
      await h.submitAll([('a', 1)]);
      await h.submitAll([('b', 1)]);
      await h.pump();

      h.api.serverJobs['op-2'] = deletionJobJson('op-2', [
        deletionItemJson('b', status: 'deleted', tombstoneRevision: 7),
      ], status: 'succeeded');
      final getJob = h.api.onGetJob;
      h.api.onGetJob = (op) async {
        if (op == 'op-1') throw const FormatException('items must be a list');
        return getJob(op);
      };
      h.timers.fire();
      await h.pump();

      expect(h.job('op-2')!.phase, DeleteJobPhase.completed);
      expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
      expect(h.syncRequests, 1);
    });

    test('a sync owed before an unexpected failure in the same pass is still '
        'requested', () async {
      await h.verify();
      await h.submitAll([('a', 1)]);
      await h.submitAll([('b', 1)]);
      await h.pump();

      h.api.serverJobs['op-1'] = deletionJobJson('op-1', [
        deletionItemJson('a', status: 'deleted', tombstoneRevision: 7),
      ], status: 'succeeded');
      final getJob = h.api.onGetJob;
      h.api.onGetJob = (op) async {
        if (op == 'op-2') throw StateError('unexpected');
        return getJob(op);
      };
      h.timers.fire();
      await h.pump();
      h.api.onGetJob = getJob;
      h.timers.fire();
      await h.pump();

      expect(h.job('op-1')!.phase, DeleteJobPhase.completed);
      expect(h.syncRequests, 1);
    });
  });

  group('R1-2 a preview belongs to the scope that produced it', () {
    test('a preview from an earlier scope is refused by the new one',
        () async {
      await h.verify();
      final preview = await h.preview([('a', 1)]);
      await h.manager.quiesce();
      await h.binding.rotate(); // a user switch: the new scope's binding
      h.manager = h.build();

      await expectLater(
        h.manager.submit(preview, confirmedCount: 1),
        throwsA(isA<DeletionNotConfirmable>()),
      );
      await h.pump();
      expect(await h.submissions(), isEmpty);
      expect(h.api.callsOf('createJob'), isEmpty);
    });

    test('a preview produced before the binding changed is refused', () async {
      await h.verify();
      final preview = await h.preview([('a', 1)]);
      await h.binding.rotate();

      await expectLater(
        h.manager.submit(preview, confirmedCount: 1),
        throwsA(isA<DeletionNotConfirmable>()),
      );
      expect(await h.submissions(), isEmpty);
    });

    test('a hand-built preview the server never answered is refused, even '
        'one that claims to be ready', () async {
      await h.verify();
      for (final base in [3, null]) {
        final forged = DeletionPreview([
          PreviewedTarget(
            uuid: 'a',
            baseRevision: base,
            serverRevision: 3,
            title: null,
            artist: null,
            album: null,
            masterExists: true,
            masterSize: 1,
            verdict: PreviewVerdict.ready,
          ),
        ]);
        await expectLater(
          h.manager.submit(forged, confirmedCount: 1),
          throwsA(isA<DeletionNotConfirmable>()),
          reason: '$base',
        );
      }
      expect(await h.submissions(), isEmpty);
    });
  });

  test('R1-3 a preview while the gate is not verified is unavailable at once',
      () async {
    // The gate never verifies (no connection, or blocked: another server).
    await expectLater(
      h.preview([('a', 1)]).timeout(const Duration(seconds: 5)),
      throwsA(isA<DeleteJobsUnavailable>().having(
        (e) => e.reason,
        'reason',
        DeleteJobsUnavailableReason.notConnected,
      )),
    );
    expect(h.api.calls, isEmpty);
  });
}
