// Possible duplicates: "Delete this copy" stays blocked while the server
// holds an unfinished deletion of the other copy that this app run did not
// make (accepted before a relaunch, or started on another device). The
// server keeps listing the pair until the deletion actually runs, so only
// the server's job list tells the app the other copy is on its way out.
import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';

import '../../helpers/delete_jobs_harness.dart';
import '../../helpers/duplicate_fixtures.dart';
import 'duplicates_test_support.dart';

DeletionJobSummaryDto _summary(String op, String status) =>
    DeletionJobSummaryDto(
      operationUuid: op,
      createdAt: 1762800000,
      status: status,
      itemCount: 1,
      stateCounts: {status == 'succeeded' ? 'deleted' : status: 1},
    );

void main() {
  late DupHarness h;
  late DeleteJobsHarness jobs;

  setUp(() async {
    h = DupHarness();
    h.pages['open']![null] = dupPage([
      dupPair(
        'a1',
        'b1',
        trackA: dupTrack('a1', revision: 3),
        trackB: dupTrack('b1', revision: 7),
      ),
      dupPair('a2', 'b2', band: 'strong'),
    ]);
    jobs = await DeleteJobsHarness.create();
    await jobs.verify();
  });

  tearDown(() async {
    h.dispose();
    await jobs.dispose();
  });

  List<Override> manager() => [
    deleteJobsManagerProvider.overrideWithValue(jobs.manager),
  ];

  /// The server holds a pending deletion of copy a1 (made elsewhere), on the
  /// second page of its job list behind a finished job.
  void serverHoldsPendingDeletionOfA1() {
    jobs.api.serverJobs['op-old'] = deletionJobJson('op-old', [
      deletionItemJson('x9', baseRevision: 2, status: 'deleted'),
    ], status: 'succeeded');
    jobs.api.serverJobs['op-elsewhere'] = deletionJobJson('op-elsewhere', [
      deletionItemJson('a1', baseRevision: 3),
    ]);
    jobs.api.onListJobs = (after, limit) async => switch (after) {
      null => DeletionJobPageDto(
        jobs: [_summary('op-old', 'succeeded')],
        nextAfter: 'c1',
      ),
      _ => DeletionJobPageDto(
        jobs: [_summary('op-elsewhere', 'pending')],
        nextAfter: null,
      ),
    };
  }

  test('a pending deletion of one copy that this run did not make blocks '
      'Delete on the other copy', () async {
    serverHoldsPendingDeletionOfA1();
    await h.open(extra: manager());
    await jobs.pump();
    expect(h.dup.deleteBlocked(h.row('a1|b1')), isTrue);
    expect(h.dup.startDeleteCopy(h.row('a1|b1'), 'b1'), isNull);
    expect(h.dup.deleteStatus(h.row('a1|b1')), 'Waiting to be deleted');
    // Another pair is not concerned.
    expect(h.dup.deleteBlocked(h.row('a2|b2')), isFalse);
  });

  test('Delete is not offered until the server has said which deletions '
      'are unfinished', () async {
    serverHoldsPendingDeletionOfA1();
    final held = Completer<void>();
    final list = jobs.api.onListJobs;
    jobs.api.onListJobs = (after, limit) async {
      await held.future;
      return list(after, limit);
    };
    await h.open(extra: manager());
    await jobs.pump();
    expect(h.dup.deleteBlocked(h.row('a2|b2')), isTrue);
    expect(h.dup.startDeleteCopy(h.row('a1|b1'), 'b1'), isNull);
    held.complete();
    await jobs.pump();
    await pumpEventQueue();
    expect(h.dup.deleteBlocked(h.row('a1|b1')), isTrue);
    expect(h.dup.deleteBlocked(h.row('a2|b2')), isFalse);
  });

  // The session's deletion jobs cannot be read at all (their manager cannot
  // be built): whether a copy is already on its way out is unknown, so
  // Delete stays blocked, as when the server's list could not be read.
  test('when the deletion jobs cannot be read at all, Delete is not '
      'offered', () async {
    await h.open(extra: [
      deleteJobsManagerProvider.overrideWith(
        (ref) => throw StateError('the scope is closed'),
      ),
    ]);
    expect(h.dup.canDeleteCopy, isTrue);
    expect(h.dup.deleteBlocked(h.row('a2|b2')), isTrue);
    expect(h.dup.startDeleteCopy(h.row('a2|b2'), 'b2'), isNull);
    expect(h.dup.deleteStatus(h.row('a2|b2')), isNull);
  });

  test('a finished deletion elsewhere does not block anything', () async {
    jobs.api.serverJobs['op-old'] = deletionJobJson('op-old', [
      deletionItemJson('a1', baseRevision: 3, status: 'conflict',
          error: 'conflict'),
    ], status: 'failed');
    jobs.api.onListJobs = (after, limit) async => DeletionJobPageDto(
      jobs: [_summary('op-old', 'failed')],
      nextAfter: null,
    );
    await h.open(extra: manager());
    await jobs.pump();
    expect(h.dup.deleteBlocked(h.row('a1|b1')), isFalse);
    expect(jobs.api.callsOf('getJob'), isEmpty);
  });
}
