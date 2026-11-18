// 8B.1c S3: while a submission's outcome is unknown (its answer is lost, or
// not yet back), nothing new can be submitted for those tracks (spec §4
// para 3 "disable repeated submission while response is ambiguous"; the
// model resolves the lost answer by asking the server, never by sending
// again). The refusal reads the durable submissions, so it also holds after
// a relaunch, before any pass has run. A refused submit writes nothing.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';

import '../../helpers/delete_jobs_harness.dart';

void main() {
  late DeleteJobsHarness h;
  setUp(() async {
    h = await DeleteJobsHarness.create();
    await h.verify();
  });
  tearDown(() => h.dispose());

  /// The server stores the job, then the answer is lost.
  void receivedButLost() {
    final store = h.api.onCreateJob;
    h.api.onCreateJob = (body) async {
      await store(body);
      throw TimeoutException('lost');
    };
  }

  Future<void> expectAwaitingRefusal(List<(String, int?)> candidates) async {
    final before = await h.submissions();
    final createsBefore = h.api.callsOf('createJob');
    final p = await h.preview(candidates);
    await expectLater(
      h.manager.submit(p, confirmedCount: p.count),
      throwsA(isA<DeletionAwaitingAnswer>()),
    );
    await h.pump();
    expect(await h.submissions(), before, reason: 'nothing written');
    expect(h.api.callsOf('createJob'), createsBefore, reason: 'nothing sent');
  }

  test('a lost answer: its tracks are awaiting, and a new preview that '
      'includes one of them is refused with nothing written or sent', () async {
    receivedButLost();
    await h.submitAll([('a', 1), ('b', 2)]);
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.unconfirmed);

    expect(h.manager.awaitingAnswer(const ['b']), isTrue);
    expect(h.manager.awaitingAnswer(const ['c', 'a']), isTrue);
    expect(h.manager.awaitingAnswer(const ['c']), isFalse);

    await expectAwaitingRefusal([('b', 2), ('c', 3)]);
  });

  test('other tracks can still be submitted meanwhile', () async {
    receivedButLost();
    await h.submitAll([('a', 1)]);
    await h.pump();
    expect(await h.submitAll([('c', 3)]), 'op-2');
  });

  test('a job still being sent (no answer yet) also blocks its tracks',
      () async {
    final answer = Completer<DeletionJobDto>();
    h.api.onCreateJob = (_) => answer.future;
    await h.submitAll([('a', 1)]);
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.submitting);
    expect(h.manager.awaitingAnswer(const ['a']), isTrue);

    await expectAwaitingRefusal([('a', 1)]);

    answer.complete(
      DeletionJobDto.fromJson(
        deletionJobJson('op-1', [deletionItemJson('a', baseRevision: 1)]),
      ),
    );
    await h.pump();
  });

  test('once the server answers (accepted), the tracks are no longer '
      'awaiting', () async {
    receivedButLost();
    await h.submitAll([('a', 1)]);
    await h.pump();
    h.timers.fire(); // the status query finds the job
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
    expect(h.manager.awaitingAnswer(const ['a']), isFalse);
  });

  test('after a relaunch, before any pass ran, the durable row still '
      'refuses', () async {
    receivedButLost();
    await h.submitAll([('a', 1)]);
    await h.pump();
    await h.manager.quiesce();
    h.manager = h.build(); // a relaunch over the same database
    expect(h.manager.jobs.value, isEmpty);

    await expectAwaitingRefusal([('a', 1)]);
  });

  test('two confirmations sharing a track, submitted at once: exactly one '
      'is accepted', () async {
    final p1 = await h.preview([('a', 1), ('b', 2)]);
    final p2 = await h.preview([('b', 2), ('c', 3)]);
    final results = await Future.wait([
      h.manager
          .submit(p1, confirmedCount: 2)
          .then<Object>((op) => op, onError: (Object e) => e),
      h.manager
          .submit(p2, confirmedCount: 2)
          .then<Object>((op) => op, onError: (Object e) => e),
    ]);
    expect(results.whereType<String>(), hasLength(1));
    expect(results.whereType<DeletionAwaitingAnswer>(), hasLength(1));
    await h.pump();
    expect(await h.submissions(), hasLength(1));
  });
}
