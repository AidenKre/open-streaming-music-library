// 8-fix-r4-fe (refactor audit V-F903-FE item 1, FE78-A-01 = FE78-B-01):
// DEV-8-11 says "The duplicates list keeps your place; every sync re-reads
// the header counts and keeps the old header while it does". A quiet
// re-read that fails must keep that promise too:
//  * a failed read (5xx) keeps the header shown before; it never turns into
//    "Couldn't load the scan status";
//  * a read refused as not connected (the binding was re-checked while the
//    sync ran: an app resume, a macOS window refocus) keeps the header, and
//    once the binding verifies the list is not reloaded: the place, the
//    cursor and an open review on a later page stay, with no "This pair
//    changed" message (SC-25: a failed load never claims a change);
//  * a later successful quiet re-read updates the header.
// A load the user starts keeps its behaviour: a failed first load still
// says it failed (see duplicates_controller_test.dart).
import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';

import '../../helpers/delete_jobs_harness.dart';
import '../../helpers/duplicate_fixtures.dart';
import 'duplicates_test_support.dart';

void main() {
  late DupHarness h;
  late DeleteJobsHarness jobs;

  setUp(() async {
    h = DupHarness();
    h.pages['open']![null] = dupPage(
      [dupPair('a1', 'b1'), dupPair('a2', 'b2')],
      next: 'c1',
    );
    h.pages['open']!['c1'] = dupPage([dupPair('a3', 'b3', band: 'strong')]);
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

  /// The page opened, page 2 loaded, and a review open on a page-2 copy.
  Future<DeletionReviewControls> openOnPage2() async {
    await h.open(extra: manager());
    await h.dup.loadMore();
    await pumpEventQueue();
    expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
    expect(h.dup.header!.scanLine, 'Checked 10 of 10 tracks');
    final review = h.dup.startDeleteCopy(h.row('a3|b3'), 'b3')!;
    await jobs.pump();
    expect(review.canConfirm, isTrue);
    return review;
  }

  void expectPlaceKept(DeletionReviewControls review) {
    expect(h.dup.header, isNotNull);
    expect(h.dup.header!.scanLine, 'Checked 10 of 10 tracks');
    expect(h.dup.summaryLoad, DuplicatesLoad.loaded);
    expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
    expect(h.dup.listLoad, DuplicatesLoad.loaded);
    expect(h.dup.hasMore, isFalse, reason: 'the cursor is not reset');
    expect(h.api.callsOf('listDuplicates'), [
      'listDuplicates open null',
      'listDuplicates open c1',
    ]);
    expect(review.canConfirm, isTrue, reason: 'the review stays open');
    expect(review.preview, isNotNull);
    expect(h.dup.message, isNull, reason: 'nothing changed');
  }

  test('a failed quiet re-read keeps the header, the place and the review; '
      'a later one updates the header', () async {
    final review = await openOnPage2();
    h.api.onDuplicateSummary = () async =>
        throw apiError(503, 'unavailable', retryable: true);
    h.sync.runOnce();
    await pumpEventQueue();
    await jobs.pump();
    expect(h.api.callsOf('duplicateSummary'), hasLength(2));
    expectPlaceKept(review);

    h.api.onDuplicateSummary = () async =>
        dupSummary(total: 12, exactPending: 1);
    h.sync.runOnce();
    await pumpEventQueue();
    await jobs.pump();
    expect(h.dup.header!.scanLine, 'Checked 11 of 12 tracks');
    expect(h.dup.summaryLoad, DuplicatesLoad.loaded);
    expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
    expect(review.canConfirm, isTrue);
    expect(h.dup.message, isNull);
    h.dup.endDeleteCopy(review);
  });

  test('a quiet re-read refused as not connected keeps the header; once the '
      'binding verifies the list is not reloaded and the review stays',
      () async {
    final review = await openOnPage2();
    // A resume cleared the verification while the sync was running.
    h.api.bindingVerified = false;
    h.sync.runOnce();
    await pumpEventQueue();
    await jobs.pump();
    expectPlaceKept(review);

    // The counts may have changed meanwhile: the summary alone is read
    // again once verified, still quietly.
    h.summary = dupSummary(total: 12, exactPending: 1);
    h.api.bindingVerified = true;
    await pumpEventQueue();
    await jobs.pump();
    expect(h.dup.header!.scanLine, 'Checked 11 of 12 tracks');
    expect(h.dup.summaryLoad, DuplicatesLoad.loaded);
    expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
    expect(h.dup.hasMore, isFalse);
    expect(h.api.callsOf('listDuplicates'), [
      'listDuplicates open null',
      'listDuplicates open c1',
    ]);
    expect(review.canConfirm, isTrue);
    expect(h.dup.message, isNull);
    h.dup.endDeleteCopy(review);
  });

  // Review of this piece (major): a header that is not on show (a user's
  // reload is in flight and the page shows its spinner) is not kept by a
  // failed quiet read that supersedes that reload; the page must not stay
  // on the spinner.
  test('a quiet re-read failing while a reload is in flight ends the '
      'spinner with the failure', () async {
    final review = await openOnPage2();
    h.dup.endDeleteCopy(review);
    final held = Completer<DuplicateSummaryDto>();
    h.api.onDuplicateSummary = () => held.future;
    unawaited(h.dup.refresh());
    await pumpEventQueue();
    expect(h.dup.summaryLoad, DuplicatesLoad.loading);
    h.api.onDuplicateSummary = () async =>
        throw apiError(503, 'unavailable', retryable: true);
    h.sync.runOnce();
    await pumpEventQueue();
    held.complete(dupSummary());
    await pumpEventQueue();
    expect(h.dup.summaryLoad, DuplicatesLoad.failed);
    expect(h.dup.header, isNull);
  });

  // Without a header shown there is nothing to keep: a quiet read that is
  // refused says so, and verification reads the summary again, but the
  // loaded list (and its place) is still not reloaded.
  test('with no header yet, a refused quiet re-read says it needs a '
      'connection and reloads only the summary once verified', () async {
    h.api.onDuplicateSummary = () async =>
        throw apiError(500, 'internal', retryable: true);
    await h.open(extra: manager());
    await h.dup.loadMore();
    await pumpEventQueue();
    expect(h.dup.summaryLoad, DuplicatesLoad.failed);
    h.api.onDuplicateSummary = () async => h.summary;
    h.api.bindingVerified = false;
    h.sync.runOnce();
    await pumpEventQueue();
    expect(h.dup.header, isNull);
    expect(h.dup.summaryLoad, DuplicatesLoad.needsConnection);
    h.api.bindingVerified = true;
    await pumpEventQueue();
    expect(h.dup.summaryLoad, DuplicatesLoad.loaded);
    expect(h.dup.header!.scanLine, 'Checked 10 of 10 tracks');
    expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
    expect(h.api.callsOf('listDuplicates'), [
      'listDuplicates open null',
      'listDuplicates open c1',
    ]);
  });
}
