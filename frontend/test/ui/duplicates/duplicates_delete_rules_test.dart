// Refactor APP-DUP (guide A.9): the rules that decide, on the Possible
// duplicates page, when "Delete this copy" is blocked (the other copy may be
// the last one), what a pair's deletion status says, and when an open review
// no longer matches the pair as tapped. Table tests written against the
// controller's public answers (deleteBlocked, deleteStatus, the dropped
// review), before the rules move to the model; the move leaves this file
// unchanged.
//
// The jobs are the app's own job values, set directly on a stand-in for the
// delete-jobs manager, so each row reaches exactly one branch. Rows the
// server never produces are marked "defensive". The server-driven forms of
// the main rows are in duplicates_controller_rules_test.dart.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';
import 'package:frontend/ui/selection/track_selection_controller.dart';

import '../../helpers/duplicate_fixtures.dart';
import '../fake_track_selection_controls.dart';
import '../manage_library/fake_manage_library_controls.dart';
import 'duplicates_test_support.dart';

/// Only the manager's job map: what the page's rules read.
class _JobsOnly implements DeleteJobsManager {
  final store = ValueNotifier<Map<String, DeleteJob>>(const {});

  @override
  ValueListenable<Map<String, DeleteJob>> get jobs => store;

  /// The server holds no unfinished deletion beyond [store].
  @override
  Future<bool> loadUnfinished() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DeleteJobItem _item(String uuid, DeleteItemStatus status, {String? error}) =>
    DeleteJobItem(
      uuid: uuid,
      baseRevision: 7,
      status: status,
      rawStatus: status.name,
      errorCode: error,
      tombstoneRevision: null,
      details: const [],
    );

DeleteJob _job(
  String op,
  DeleteJobPhase phase,
  List<String> targets, {
  List<DeleteJobItem> items = const [],
  String? rejectionCode,
}) => DeleteJob(
  operationUuid: op,
  phase: phase,
  targets: [
    for (final t in targets) DeletionTargetDto(uuidId: t, baseRevision: 7),
  ],
  items: items,
  rejectionCode: rejectionCode,
);

void main() {
  late DupHarness h;
  late _JobsOnly manager;
  late List<FakeDeletionReviewControls> reviews;
  late List<FakeTrackSelectionControls> selections;

  setUp(() {
    h = DupHarness();
    h.pages['open']![null] = dupPage([
      dupPair(
        'a1',
        'b1',
        trackA: dupTrack('a1', revision: 3),
        trackB: dupTrack('b1', revision: 7),
      ),
      dupPair('b1', 'c1', band: 'strong', trackA: dupTrack('b1', revision: 7)),
      dupPair('a2', 'b2', band: 'possible', score: 0.6),
    ]);
    manager = _JobsOnly();
    reviews = [];
    selections = [];
  });

  tearDown(() => h.dispose());

  List<Override> overrides() => [
    deleteJobsManagerProvider.overrideWithValue(manager),
    deletionReviewControllerFactoryProvider.overrideWithValue(
      (TrackSelectionControls _) {
        final r = FakeDeletionReviewControls();
        reviews.add(r);
        return r;
      },
    ),
    trackSelectionControllerFactoryProvider.overrideWithValue(() {
      final s = FakeTrackSelectionControls();
      selections.add(s);
      return s;
    }),
  ];

  void setJobs(List<DeleteJob> jobs) =>
      manager.store.value = {for (final j in jobs) j.operationUuid: j};

  bool blocked(String key) => h.dup.deleteBlocked(h.row(key));
  String? status(String key) => h.dup.deleteStatus(h.row(key));

  group('deleteBlocked: a job that deletes a copy of the pair', () {
    // (row name, jobs, blocked for a1|b1)
    final rows = <(String, List<DeleteJob>, bool)>[
      ('no job', [], false),
      ('a job on other tracks only', [
        _job('op', DeleteJobPhase.running, ['x9']),
      ], false),
      ('submitting (not yet answered)', [
        _job('op', DeleteJobPhase.submitting, ['b1']),
      ], true),
      ('unconfirmed (answer lost)', [
        _job('op', DeleteJobPhase.unconfirmed, ['b1']),
      ], true),
      ('accepted, the copy pending', [
        _job('op', DeleteJobPhase.accepted, ['b1'],
            items: [_item('b1', DeleteItemStatus.pending)]),
      ], true),
      ('accepted with no items yet (an unreadable receipt)', [
        _job('op', DeleteJobPhase.accepted, ['b1']),
      ], true),
      ('running, the copy running', [
        _job('op', DeleteJobPhase.running, ['b1'],
            items: [_item('b1', DeleteItemStatus.running)]),
      ], true),
      ('running, the copy already refused (conflict) while another target '
          'still runs: the job is not finished', [
        _job('op', DeleteJobPhase.running, ['b1', 'x9'], items: [
          _item('b1', DeleteItemStatus.conflict, error: 'conflict'),
          _item('x9', DeleteItemStatus.running),
        ]),
      ], true),
      ('rejected by the server', [
        _job('op', DeleteJobPhase.rejected, ['b1'],
            rejectionCode: 'track_pending_deletion'),
      ], false),
      ('completed: the copy deleted', [
        _job('op', DeleteJobPhase.completed, ['b1'],
            items: [_item('b1', DeleteItemStatus.deleted)]),
      ], true),
      ('completed: the copy already deleted', [
        _job('op', DeleteJobPhase.completed, ['b1'],
            items: [_item('b1', DeleteItemStatus.alreadyDeleted)]),
      ], true),
      ('partial: the copy deleted, another target not', [
        _job('op', DeleteJobPhase.partial, ['b1', 'x9'], items: [
          _item('b1', DeleteItemStatus.deleted),
          _item('x9', DeleteItemStatus.conflict, error: 'conflict'),
        ]),
      ], true),
      ('failed: the copy not deleted (conflict)', [
        _job('op', DeleteJobPhase.failed, ['b1'],
            items: [_item('b1', DeleteItemStatus.conflict, error: 'conflict')]),
      ], false),
      ('failed: the copy not deleted (busy)', [
        _job('op', DeleteJobPhase.failed, ['b1'],
            items: [_item('b1', DeleteItemStatus.busy, error: 'busy')]),
      ], false),
      ('failed: the copy not deleted (failed, not_found)', [
        _job('op', DeleteJobPhase.failed, ['b1'], items: [
          _item('b1', DeleteItemStatus.failed, error: 'not_found'),
        ]),
      ], false),
      ('partial: the copy not deleted (conflict), another target deleted', [
        _job('op', DeleteJobPhase.partial, ['b1', 'x9'], items: [
          _item('b1', DeleteItemStatus.conflict, error: 'conflict'),
          _item('x9', DeleteItemStatus.deleted),
        ]),
      ], false),
      ('failed: an outcome this app does not know', [
        _job('op', DeleteJobPhase.failed, ['b1'],
            items: [_item('b1', DeleteItemStatus.unrecognized)]),
      ], true),
      ('defensive: finished with no outcome for the copy', [
        _job('op', DeleteJobPhase.failed, ['b1'],
            items: [_item('x9', DeleteItemStatus.conflict, error: 'conflict')]),
      ], true),
      ('the other member (a1) being deleted blocks too', [
        _job('op', DeleteJobPhase.running, ['a1']),
      ], true),
      ('both copies in one job: one deleted, one not', [
        _job('op', DeleteJobPhase.partial, ['a1', 'b1'], items: [
          _item('a1', DeleteItemStatus.conflict, error: 'conflict'),
          _item('b1', DeleteItemStatus.deleted),
        ]),
      ], true),
      ('both copies in one job: neither deleted', [
        _job('op', DeleteJobPhase.failed, ['a1', 'b1'], items: [
          _item('a1', DeleteItemStatus.conflict, error: 'conflict'),
          _item('b1', DeleteItemStatus.busy, error: 'busy'),
        ]),
      ], false),
      ('two jobs: an old one that freed the copy, a newer one running', [
        _job('op-1', DeleteJobPhase.failed, ['b1'],
            items: [_item('b1', DeleteItemStatus.busy, error: 'busy')]),
        _job('op-2', DeleteJobPhase.running, ['b1']),
      ], true),
      ('two jobs: an old one running, a newer one rejected', [
        _job('op-1', DeleteJobPhase.running, ['b1']),
        _job('op-2', DeleteJobPhase.rejected, ['b1']),
      ], true),
      ('two jobs, both freed the copy', [
        _job('op-1', DeleteJobPhase.rejected, ['b1']),
        _job('op-2', DeleteJobPhase.failed, ['a1'],
            items: [_item('a1', DeleteItemStatus.conflict, error: 'conflict')]),
      ], false),
    ];

    for (final (name, jobs, expected) in rows) {
      test('$name: ${expected ? 'blocked' : 'not blocked'}', () async {
        await h.open(extra: overrides());
        setJobs(jobs);
        expect(blocked('a1|b1'), expected);
        // Delete is offered exactly when it is not blocked.
        final review = h.dup.startDeleteCopy(h.row('a1|b1'), 'a1');
        expect(review == null, expected);
        if (review != null) h.dup.endDeleteCopy(review);
        // An unrelated pair is never blocked by these jobs.
        expect(blocked('a2|b2'), isFalse);
      });
    }

    test('a copy being deleted blocks every pair it is in, and only those',
        () async {
      await h.open(extra: overrides());
      setJobs([_job('op', DeleteJobPhase.running, ['b1'])]);
      expect(blocked('a1|b1'), isTrue);
      expect(blocked('b1|c1'), isTrue);
      expect(blocked('a2|b2'), isFalse);
      setJobs([_job('op', DeleteJobPhase.running, ['a1'])]);
      expect(blocked('a1|b1'), isTrue);
      expect(blocked('b1|c1'), isFalse);
    });

    test('jobs started elsewhere count as soon as the manager knows them',
        () async {
      await h.open(extra: overrides());
      expect(blocked('a1|b1'), isFalse);
      var notified = 0;
      h.dup.addListener(() => notified++);
      setJobs([_job('op', DeleteJobPhase.submitting, ['b1'])]);
      expect(notified, greaterThan(0));
      expect(blocked('a1|b1'), isTrue);
    });
  });

  group('deleteBlocked: a deletion submitted here', () {
    Future<void> submit(String key, String uuid, {String? op = 'op-x'}) async {
      final review = h.dup.startDeleteCopy(h.row(key), uuid)!;
      (review as FakeDeletionReviewControls).submittedOperation = op;
      h.dup.endDeleteCopy(review);
    }

    test('blocks before the manager lists its job: the pair, and every pair '
        'of the copy being deleted', () async {
      await h.open(extra: overrides());
      await submit('a1|b1', 'b1');
      expect(blocked('a1|b1'), isTrue);
      expect(blocked('b1|c1'), isTrue);
      expect(blocked('a2|b2'), isFalse);
      // No job yet: nothing to say about it.
      expect(status('a1|b1'), isNull);
    });

    test('deleting the other member leaves the pairs of the kept copy free',
        () async {
      await h.open(extra: overrides());
      await submit('a1|b1', 'a1');
      expect(blocked('a1|b1'), isTrue);
      expect(blocked('b1|c1'), isFalse);
    });

    test('once the manager lists the job, the job decides', () async {
      await h.open(extra: overrides());
      await submit('a1|b1', 'b1');
      setJobs([_job('op-x', DeleteJobPhase.rejected, ['b1'])]);
      expect(blocked('a1|b1'), isFalse);
      setJobs([_job('op-x', DeleteJobPhase.running, ['b1'])]);
      expect(blocked('a1|b1'), isTrue);
    });

    test('a review closed without confirming blocks nothing', () async {
      await h.open(extra: overrides());
      await submit('a1|b1', 'b1', op: null);
      expect(blocked('a1|b1'), isFalse);
      expect(blocked('b1|c1'), isFalse);
    });
  });

  group('deleteStatus', () {
    // (row name, jobs, status of a1|b1)
    final rows = <(String, List<DeleteJob>, String?)>[
      ('no job', [], null),
      ('a job on other tracks only', [
        _job('op', DeleteJobPhase.running, ['x9']),
      ], null),
      ('submitting', [
        _job('op', DeleteJobPhase.submitting, ['b1']),
      ], 'Sending to the server'),
      ('unconfirmed', [
        _job('op', DeleteJobPhase.unconfirmed, ['b1']),
      ], 'Checking with the server: the answer was lost. It will not be sent '
          'again until the answer is known.'),
      ('accepted with no items yet', [
        _job('op', DeleteJobPhase.accepted, ['b1']),
      ], 'Accepted by the server'),
      ('accepted, the copy pending: the copy\'s outcome', [
        _job('op', DeleteJobPhase.accepted, ['b1'],
            items: [_item('b1', DeleteItemStatus.pending)]),
      ], 'Waiting to be deleted'),
      ('running, the copy running', [
        _job('op', DeleteJobPhase.running, ['b1'],
            items: [_item('b1', DeleteItemStatus.running)]),
      ], 'Deleting'),
      ('rejected, a known code', [
        _job('op', DeleteJobPhase.rejected, ['b1'],
            rejectionCode: 'track_pending_deletion'),
      ], 'A track in this request is already being deleted. Nothing was '
          'deleted.'),
      ('rejected, no code', [
        _job('op', DeleteJobPhase.rejected, ['b1']),
      ], 'The server refused this request. Nothing was deleted.'),
      ('completed, the copy deleted', [
        _job('op', DeleteJobPhase.completed, ['b1'],
            items: [_item('b1', DeleteItemStatus.deleted)]),
      ], 'Deleted'),
      ('failed, the copy refused (conflict)', [
        _job('op', DeleteJobPhase.failed, ['b1'],
            items: [_item('b1', DeleteItemStatus.conflict, error: 'conflict')]),
      ], 'Not deleted: the track changed after you selected it'),
      ('failed, an outcome this app does not know', [
        _job('op', DeleteJobPhase.failed, ['b1'],
            items: [_item('b1', DeleteItemStatus.unrecognized)]),
      ], 'Status unknown'),
      ('defensive: finished with outcomes for other targets only: the job', [
        _job('op', DeleteJobPhase.partial, ['b1', 'x9'],
            items: [_item('x9', DeleteItemStatus.deleted)]),
      ], 'Some tracks were not deleted'),
      ('both copies in one job: the first outcome in the job\'s order', [
        _job('op', DeleteJobPhase.partial, ['b1', 'a1'], items: [
          _item('b1', DeleteItemStatus.busy, error: 'busy'),
          _item('a1', DeleteItemStatus.deleted),
        ]),
      ], 'Not deleted: the server was working on it'),
      ('two jobs: the newest decides', [
        _job('op-1', DeleteJobPhase.failed, ['b1'],
            items: [_item('b1', DeleteItemStatus.busy, error: 'busy')]),
        _job('op-2', DeleteJobPhase.submitting, ['a1']),
      ], 'Sending to the server'),
    ];

    for (final (name, jobs, expected) in rows) {
      test('$name: ${expected ?? 'none'}', () async {
        await h.open(extra: overrides());
        setJobs(jobs);
        expect(status('a1|b1'), expected);
        expect(status('a2|b2'), isNull);
      });
    }
  });

  // An open review is for the pair as tapped: when no listed pair is that
  // pair at the same revisions and status, its selection is cleared (it
  // can't be confirmed) and the page says the pair changed.
  group('an open review and the pair as tapped', () {
    const changed =
        'This pair changed while you were reviewing it. Nothing was deleted.';

    Future<FakeTrackSelectionControls> started() async {
      await h.open(extra: overrides());
      expect(h.dup.startDeleteCopy(h.row('a1|b1'), 'b1'), isNotNull);
      final sel = selections.single;
      expect(sel.count, 1);
      return sel;
    }

    Future<void> reload(List<DuplicatePairDto> pairs) async {
      h.pages['open']![null] = dupPage(pairs);
      await h.dup.refresh();
      await pumpEventQueue();
    }

    final rows = <(String, List<DuplicatePairDto>, bool)>[
      ('the same pair at the same revisions', [
        dupPair('a1', 'b1',
            trackA: dupTrack('a1', revision: 3),
            trackB: dupTrack('b1', revision: 7)),
      ], true),
      ('the same pair with other fields changed (not compared)', [
        dupPair('a1', 'b1',
            band: 'strong',
            trackA: dupTrack('a1', revision: 3, codec: 'mp3'),
            trackB: dupTrack('b1', revision: 7, title: 'Other')),
      ], true),
      ('the tapped copy at a newer revision', [
        dupPair('a1', 'b1',
            trackA: dupTrack('a1', revision: 3),
            trackB: dupTrack('b1', revision: 8)),
      ], false),
      ('the other copy at a newer revision', [
        dupPair('a1', 'b1',
            trackA: dupTrack('a1', revision: 4),
            trackB: dupTrack('b1', revision: 7)),
      ], false),
      ('defensive: the same pair listed with another status', [
        dupPair('a1', 'b1',
            status: 'dismissed',
            trackA: dupTrack('a1', revision: 3),
            trackB: dupTrack('b1', revision: 7)),
      ], false),
      ('the pair gone; another pair at the same revisions is listed', [
        dupPair('a9', 'b1',
            trackA: dupTrack('a9', revision: 3),
            trackB: dupTrack('b1', revision: 7)),
        dupPair('a1', 'b9',
            trackA: dupTrack('a1', revision: 3),
            trackB: dupTrack('b9', revision: 7)),
      ], false),
    ];

    for (final (name, pairs, kept) in rows) {
      test('$name: ${kept ? 'the review stays' : 'the review is dropped'}',
          () async {
        final sel = await started();
        await reload(pairs);
        expect(sel.count, kept ? 1 : 0);
        expect(h.dup.message, kept ? isNull : changed);
      });
    }
  });
}
