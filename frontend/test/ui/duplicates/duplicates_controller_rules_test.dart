// 8B.3 review r1 (`phase-8/8B.3-review.md`): regression tests for the
// confirmed findings in the controller.
//  * #1 (major): the review's Refresh adopts the server's newer revision, but
//    the copy's lines (format, bitrate, ...) are the row's: a review whose
//    selection no longer matches the row as tapped must not be confirmable.
//  * #2 (major): spec §4 "The job UI must show partial success and each
//    reason": the page shows the outcome of a copy's deletion job.
//  * #3: while one copy's deletion is pending or done, the other copy of the
//    same pair cannot be deleted too (it may be the last copy).
//  * #4: a finished sync while a review is open drops it (the list is about
//    to change; the review must be started again from the new list).
//  * #5: setAside says whether it acted (the page shows Undo only then).
//  * #7: a failed Undo after a chip change leaves the other chip's list
//    alone.
//  * #8: a pair set aside is not brought back by a page that was asked for
//    before the server answered.
//  * #9: the confirmation tells two copies apart by a short id.
//  * #10: a second Delete tap while a review is open starts nothing (it
//    must not dispose the review an open sheet is showing).
//  * nit: Play on the paused copy resumes it.
import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';

import '../../helpers/delete_jobs_harness.dart';
import '../../helpers/duplicate_fixtures.dart';
import 'duplicates_test_support.dart';

class _PreviewModel extends PreviewPlayer {
  @override
  PreviewState build() => const PreviewState();

  void show(PreviewSource? source, PreviewStatus status) =>
      state = PreviewState(source: source, status: status);
}

void main() {
  late DupHarness h;

  setUp(() {
    h = DupHarness();
    h.pages['open']![null] = dupPage([
      dupPair(
        'a1',
        'b1',
        trackA: dupTrack('a1', revision: 3),
        trackB: dupTrack('b1', revision: 7, codec: 'mp3'),
      ),
      dupPair('a2', 'b2', band: 'strong'),
    ]);
    h.api.onDismissPair = (a, b) async => dupStatus(a, b, 'dismissed');
    h.api.onRestorePair = (a, b) async => dupStatus(a, b, 'open');
  });

  tearDown(() => h.dispose());

  group('Delete this copy', () {
    late DeleteJobsHarness jobs;

    setUp(() async {
      jobs = await DeleteJobsHarness.create();
      await jobs.verify();
    });
    tearDown(() async => jobs.dispose());

    List<Override> manager() => [
      deleteJobsManagerProvider.overrideWithValue(jobs.manager),
    ];

    Future<DeletionReviewControls> started(String uuid) async {
      final review = h.dup.startDeleteCopy(h.row('a1|b1'), uuid)!;
      await jobs.pump();
      expect(review.canConfirm, isTrue);
      return review;
    }

    test('#1 Refresh to the server revision makes the review unconfirmable '
        'and says the pair changed', () async {
      await h.open(extra: manager());
      // The server's copy moved on: the preview says conflict.
      jobs.api.onPreview = (targets) async => DeletionPreviewDto.fromJson({
        'targets': [previewTargetJson('b1', 7, revision: 9, conflict: true)],
      });
      final review = h.dup.startDeleteCopy(h.row('a1|b1'), 'b1')!;
      await jobs.pump();
      expect(review.canConfirm, isFalse);
      jobs.api.onPreview = (targets) async => DeletionPreviewDto.fromJson({
        'targets': [previewTargetJson('b1', targets.single.baseRevision)],
      });
      await review.refreshTarget('b1');
      await jobs.pump();
      expect(review.canConfirm, isFalse);
      expect(review.preview, isNull);
      expect(jobs.api.createBodies, isEmpty);
      expect(h.dup.message, 'This pair changed while you were reviewing it. '
          'Nothing was deleted.');
      h.dup.endDeleteCopy(review);
    });

    // U33-B-01: a sync that changed nothing (every resume, every macOS
    // window refocus) leaves an open review exactly as it was.
    test('#4 a sync that changed nothing keeps the open review', () async {
      await h.open(extra: manager());
      final review = await started('b1');
      h.sync.runOnce();
      await pumpEventQueue();
      await jobs.pump();
      expect(review.canConfirm, isTrue);
      expect(review.preview, isNotNull);
      expect(h.dup.message, isNull);
      expect(h.keys(), contains('a1|b1'));
      h.dup.endDeleteCopy(review);
    });

    test('#4 a sync that deleted a copy of the pair drops the open review',
        () async {
      await h.open(extra: manager());
      final review = await started('b1');
      h.sync.runOnce(deleted: {'a1'});
      await pumpEventQueue();
      // The list is reloading; "Review again" must not bring it back.
      await review.requestPreview();
      await jobs.pump();
      expect(review.canConfirm, isFalse);
      expect(jobs.api.createBodies, isEmpty);
      h.dup.endDeleteCopy(review);
    });

    test('#2 the outcome of the copy\'s deletion is shown on its pair',
        () async {
      await h.open(extra: manager());
      final row = h.row('a1|b1');
      expect(h.dup.deleteStatus(row), isNull);
      final review = await started('b1');
      expect(await review.confirm(review.preview!, confirmedCount: 1), isTrue);
      h.dup.endDeleteCopy(review);
      await jobs.pump();
      expect(h.dup.deleteStatus(row), isNotNull);
      final op = jobs.manager.jobs.value.keys.single;
      jobs.api.serverJobs[op] = deletionJobJson(op, [
        deletionItemJson('b1', baseRevision: 7, status: 'conflict',
            error: 'conflict'),
      ], status: 'failed');
      jobs.timers.fire();
      await jobs.pump();
      await pumpEventQueue();
      expect(
        h.dup.deleteStatus(row),
        'Not deleted: the track changed after you selected it',
      );
    });

    test('#3 while one copy is being deleted, neither copy of the pair can '
        'be deleted again; another pair still can', () async {
      await h.open(extra: manager());
      final review = await started('b1');
      expect(await review.confirm(review.preview!, confirmedCount: 1), isTrue);
      h.dup.endDeleteCopy(review);
      await jobs.pump();
      expect(h.dup.deleteBlocked(h.row('a1|b1')), isTrue);
      expect(h.dup.startDeleteCopy(h.row('a1|b1'), 'a1'), isNull);
      expect(h.dup.deleteBlocked(h.row('a2|b2')), isFalse);
      // Deleted: still blocked (the other copy may be the last one).
      final op = jobs.manager.jobs.value.keys.single;
      jobs.api.serverJobs[op] = deletionJobJson(op, [
        deletionItemJson('b1', baseRevision: 7, status: 'deleted', tombstoneRevision: 50),
      ], status: 'succeeded');
      jobs.timers.fire();
      await jobs.pump();
      await pumpEventQueue();
      expect(h.dup.deleteBlocked(h.row('a1|b1')), isTrue);
      expect(h.dup.deleteStatus(h.row('a1|b1')), 'Deleted');
    });

    test('#3 a copy being deleted also blocks the other pairs it is in',
        () async {
      h.pages['open']![null] = dupPage([
        dupPair('a1', 'b1', trackB: dupTrack('b1', revision: 7)),
        dupPair('b1', 'c1', band: 'strong', trackA: dupTrack('b1', revision: 7)),
        dupPair('d1', 'e1', band: 'possible', score: 0.6),
      ]);
      await h.open(extra: manager());
      final review = h.dup.startDeleteCopy(h.row('a1|b1'), 'b1')!;
      await jobs.pump();
      expect(await review.confirm(review.preview!, confirmedCount: 1), isTrue);
      h.dup.endDeleteCopy(review);
      await jobs.pump();
      expect(h.dup.deleteBlocked(h.row('b1|c1')), isTrue);
      expect(h.dup.startDeleteCopy(h.row('b1|c1'), 'c1'), isNull);
      expect(h.dup.deleteStatus(h.row('b1|c1')), isNotNull);
      expect(h.dup.deleteBlocked(h.row('d1|e1')), isFalse);
    });

    test('#3 a deletion that ended without deleting unblocks the pair',
        () async {
      await h.open(extra: manager());
      final review = await started('b1');
      expect(await review.confirm(review.preview!, confirmedCount: 1), isTrue);
      h.dup.endDeleteCopy(review);
      await jobs.pump();
      final op = jobs.manager.jobs.value.keys.single;
      jobs.api.serverJobs[op] = deletionJobJson(op, [
        deletionItemJson('b1', baseRevision: 7, status: 'busy', error: 'busy'),
      ], status: 'failed');
      jobs.timers.fire();
      await jobs.pump();
      await pumpEventQueue();
      expect(h.dup.deleteBlocked(h.row('a1|b1')), isFalse);
    });

    test('#10 a second Delete while a review is open starts nothing and '
        'leaves the open review intact', () async {
      await h.open(extra: manager());
      final review = await started('b1');
      expect(h.dup.startDeleteCopy(h.row('a2|b2'), 'a2'), isNull);
      await jobs.pump();
      expect(review.canConfirm, isTrue);
      expect(jobs.api.callsOf('preview'), ['preview b1']);
      h.dup.endDeleteCopy(review);
      expect(h.dup.startDeleteCopy(h.row('a2|b2'), 'a2'), isNotNull);
    });

    test('re-check R1: a deletion started elsewhere (Manage library, an '
        'earlier visit) blocks the pairs of that copy too', () async {
      await h.open(extra: manager());
      await jobs.submitAll([('b1', 7)]);
      await jobs.pump();
      await pumpEventQueue();
      expect(h.dup.deleteBlocked(h.row('a1|b1')), isTrue);
      expect(h.dup.startDeleteCopy(h.row('a1|b1'), 'a1'), isNull);
      expect(h.dup.deleteStatus(h.row('a1|b1')), isNotNull);
      expect(h.dup.deleteBlocked(h.row('a2|b2')), isFalse);
    });

    test('re-check R2: an outcome the app does not recognise keeps the pair '
        'blocked (unknown is not "not deleted")', () async {
      // 'someday' is deliberately a status this app does not know (a later
      // server's). The job is finished ('failed': what the server derives
      // when no target was deleted), so the item's outcome decides.
      await h.open(extra: manager());
      final op = await jobs.submitAll([('b1', 7)]);
      await jobs.pump();
      jobs.api.serverJobs[op] = deletionJobJson(op, [
        deletionItemJson('b1', baseRevision: 7, status: 'someday'),
      ], status: 'failed');
      jobs.timers.fire();
      await jobs.pump();
      await pumpEventQueue();
      expect(h.dup.deleteBlocked(h.row('a1|b1')), isTrue);
    });

    test('#9 each copy is named with a short id', () async {
      h.pages['open']![null] = dupPage([
        dupPair('0123456789ab', 'fedcba987654'),
      ]);
      await h.open(extra: manager());
      final row = h.dup.pairs.single;
      expect(row.a.identityLines.last, 'ID 01234567');
      expect(row.b.identityLines.last, 'ID fedcba98');
    });
  });

  group('Not duplicates', () {
    test('#5 setAside says whether it acted', () async {
      await h.open();
      final stale = h.row('a2|b2');
      expect(h.dup.setAside(h.row('a1|b1')), isTrue);
      h.pages['open']![null] = dupPage([dupPair('a3', 'b3')]);
      await h.dup.refresh();
      await pumpEventQueue();
      expect(h.dup.setAside(stale), isFalse);
    });

    test('#7 a failed Undo after a chip change leaves the other list alone',
        () async {
      await h.open();
      final row = h.row('a2|b2');
      h.dup.setAside(row);
      await pumpEventQueue();
      h.pages['dismissed']![null] = dupPage([
        dupPair('a2', 'b2', band: 'strong', status: 'dismissed'),
      ]);
      h.dup.setFilter(DuplicatesFilter.dismissed);
      await pumpEventQueue();
      expect(h.keys(), ['a2|b2']);
      h.api.onRestorePair = (a, b) async =>
          throw apiError(500, 'internal', retryable: true);
      h.dup.undo(row);
      await pumpEventQueue();
      // The restore failed: the pair is still dismissed, and listed here.
      expect(h.keys(), ['a2|b2']);
    });

    test('#8 a page asked for before the dismissal landed does not bring the '
        'pair back', () async {
      await h.open();
      final held = Completer<DuplicatePairStatusDto>();
      h.api.onDismissPair = (a, b) => held.future;
      h.dup.setAside(h.row('a2|b2'));
      // The server still lists it until the dismissal lands.
      await h.dup.refresh();
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1']);
      held.complete(dupStatus('a2', 'b2', 'dismissed'));
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1']);
    });
  });

  test('nit: Play on the paused copy resumes it', () async {
    late _PreviewModel model;
    await h.open(
      extra: [previewPlayerProvider.overrideWith(() => model = _PreviewModel())],
    );
    h.container.listen(previewPlayerProvider, (_, _) {});
    model.show(const LibraryTrackPreview('a1'), PreviewStatus.paused);
    await pumpEventQueue();
    await h.dup.togglePlay('a1');
    await h.dup.togglePlay('b1');
    expect(h.preview.calls, ['resume', 'playLibraryTrack b1']);
  });
}
