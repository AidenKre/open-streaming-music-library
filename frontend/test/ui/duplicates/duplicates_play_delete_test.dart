// 8B.3 S5: Play through the preview player, and "Delete this copy".
//  * Spec §6: "Play either track through the shared preview/audition
//    player ... so the user's queue is untouched and no history click or
//    play is recorded. Offline, Play is disabled" (the preview player
//    streams only: O11).
//  * Spec §6: "Delete this copy appears only when server_delete is true. It
//    opens the standard single-track preview and destructive confirmation
//    for that UUID/revision (§4) and submits a normal delete job through
//    DurableSubmission." "A pair whose track revision changed since the list
//    loaded gets the normal preview conflict."
//  * Brief: it can only delete the copy whose button was tapped as that
//    pair looked when it was tapped; a pair that changed, was dismissed or
//    lost a member while the confirmation was open cannot be confirmed
//    without a new preview. The page never deletes anything by itself.
//  * 8B.1c hand-over: build a one-track selection at the pair's revision,
//    a review from deletionReviewControllerFactoryProvider, requestPreview().
import 'dart:convert';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';
import 'package:frontend/ui/selection/track_selection_controller.dart';

import '../../helpers/delete_jobs_harness.dart';
import '../../helpers/duplicate_fixtures.dart';
import '../fake_track_selection_controls.dart';
import 'duplicates_test_support.dart';

/// The preview model's observable state, set by the test.
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
  });

  tearDown(() => h.dispose());

  group('Play', () {
    late _PreviewModel model;
    List<Override> previewModel() => [
      previewPlayerProvider.overrideWith(() => model = _PreviewModel()),
    ];

    test('plays a copy through the preview controls', () async {
      await h.open(extra: previewModel());
      expect(h.dup.canPlay, isTrue);
      await h.dup.togglePlay('b1');
      expect(h.preview.calls, ['playLibraryTrack b1']);
    });

    // Sign-off OPEN-M-11 (E8 review): a failed server check is handled like
    // offline, as playback does since step D.
    test('the server check failed: Play is disabled and sends nothing',
        () async {
      await h.open(extra: [
        ...previewModel(),
        streamsUnavailableProvider.overrideWithValue(() => true),
      ]);
      expect(h.dup.canPlay, isFalse);
      await h.dup.togglePlay('b1');
      expect(h.preview.calls, isEmpty);
    });

    test('offline, Play is disabled and sends nothing', () async {
      await h.open(isOffline: true, extra: previewModel());
      expect(h.dup.canPlay, isFalse);
      await h.dup.togglePlay('b1');
      expect(h.preview.calls, isEmpty);
    });

    test('follows the preview player: which copy, its status, its message',
        () async {
      await h.open(extra: previewModel());
      h.container.listen(previewPlayerProvider, (_, _) {});
      model.show(const LibraryTrackPreview('a1'), PreviewStatus.playing);
      await pumpEventQueue();
      expect(h.dup.previewingUuid, 'a1');
      expect(h.dup.previewStatus, PreviewStatus.playing);
      expect(h.dup.previewMessage, isNull);
      model.show(const LibraryTrackPreview('a1'), PreviewStatus.failed);
      await pumpEventQueue();
      expect(h.dup.previewMessage, "Preview couldn't play");
      // Another surface's staged preview is not one of these copies.
      model.show(const StagedUploadPreview('i1'), PreviewStatus.playing);
      await pumpEventQueue();
      expect(h.dup.previewingUuid, isNull);
    });

    test('Play on the copy that is playing pauses it; another copy switches',
        () async {
      await h.open(extra: previewModel());
      h.container.listen(previewPlayerProvider, (_, _) {});
      model.show(const LibraryTrackPreview('a1'), PreviewStatus.playing);
      await pumpEventQueue();
      await h.dup.togglePlay('a1');
      await h.dup.togglePlay('b1');
      expect(h.preview.calls, ['pause', 'playLibraryTrack b1']);
    });

    test('leaving the page closes the preview', () async {
      await h.open(extra: previewModel());
      h.dup.leave();
      await pumpEventQueue();
      expect(h.preview.calls, ['close']);
    });
  });

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

    test('is offered only with a live switch that is on, online', () async {
      await h.open(extra: manager());
      expect(h.dup.canDeleteCopy, isTrue);
      h.dispose();

      h = DupHarness();
      await h.open(serverDelete: false, extra: manager());
      expect(h.dup.canDeleteCopy, isFalse);
      expect(h.dup.startDeleteCopy(h.dup.pairs.isEmpty ? _none : h.dup.pairs.first, 'x'), isNull);
      h.dispose();

      h = DupHarness();
      await h.open(fromCache: true, extra: manager());
      expect(h.dup.canDeleteCopy, isFalse);
      h.dispose();

      h = DupHarness();
      await h.open(isOffline: true, extra: manager());
      expect(h.dup.canDeleteCopy, isFalse);
    });

    test('with the switch off, nothing can start a deletion', () async {
      await h.open(serverDelete: false, extra: manager());
      h.pages['open']![null] = dupPage([dupPair('a1', 'b1')]);
      await h.dup.refresh();
      await pumpEventQueue();
      expect(h.dup.startDeleteCopy(h.row('a1|b1'), 'b1'), isNull);
      await jobs.pump();
      expect(jobs.api.calls, isEmpty);
    });

    test('previews exactly the tapped copy at the revision the row showed',
        () async {
      await h.open(extra: manager());
      final review = h.dup.startDeleteCopy(h.row('a1|b1'), 'b1')!;
      await jobs.pump();
      expect(jobs.api.calls, ['preview b1']);
      expect(jobs.api.previews.single, {
        'targets': [
          {'uuid_id': 'b1', 'base_revision': 7},
        ],
      });
      expect(review.stage, ReviewStage.ready);
      expect(review.canConfirm, isTrue);
      h.dup.endDeleteCopy(review);
    });

    // 8-R1-19: the tapped copy is selected by its uuid and the revision the
    // row showed, not through a TrackUI built with invented fields.
    test('selects the tapped copy by uuid and revision', () async {
      final fake = FakeTrackSelectionControls();
      await h.open(extra: [
        ...manager(),
        trackSelectionControllerFactoryProvider.overrideWithValue(() => fake),
      ]);
      final review = h.dup.startDeleteCopy(h.row('a1|b1'), 'b1')!;
      await jobs.pump();
      expect(fake.calls, ['select b1 7']);
      expect(
        [for (final e in fake.selection.entries) (e.uuid, e.baseRevision)],
        [('b1', 7)],
      );
      h.dup.endDeleteCopy(review);
    });

    test('confirming submits one job for that copy only', () async {
      await h.open(extra: manager());
      final review = h.dup.startDeleteCopy(h.row('a1|b1'), 'a1')!;
      await jobs.pump();
      expect(await review.confirm(review.preview!, confirmedCount: 1), isTrue);
      await jobs.pump();
      final body = jsonDecode(jobs.api.createBodies.single) as Map;
      expect(body['targets'], [
        {'uuid_id': 'a1', 'base_revision': 3},
      ]);
      expect(body['confirmed_count'], 1);
      h.dup.endDeleteCopy(review);
    });

    test('a uuid that is not a member of the pair starts nothing', () async {
      await h.open(extra: manager());
      expect(h.dup.startDeleteCopy(h.row('a1|b1'), 'a2'), isNull);
      await jobs.pump();
      expect(jobs.api.calls, isEmpty);
    });

    test('a row that is no longer listed starts nothing', () async {
      await h.open(extra: manager());
      final stale = h.row('a1|b1');
      h.pages['open']![null] = dupPage([dupPair('a2', 'b2', band: 'strong')]);
      await h.dup.refresh();
      await pumpEventQueue();
      expect(h.dup.startDeleteCopy(stale, 'b1'), isNull);
      await jobs.pump();
      expect(jobs.api.calls, isEmpty);
    });

    group('a review that is no longer the pair as tapped cannot be confirmed',
        () {
      Future<DeletionReviewControls> started() async {
        await h.open(extra: manager());
        final review = h.dup.startDeleteCopy(h.row('a1|b1'), 'b1')!;
        await jobs.pump();
        expect(review.canConfirm, isTrue);
        return review;
      }

      Future<void> expectStale(DeletionReviewControls review) async {
        final shown = review.preview;
        await jobs.pump();
        expect(review.canConfirm, isFalse);
        expect(review.preview, isNull);
        if (shown != null) {
          expect(await review.confirm(shown, confirmedCount: 1), isFalse);
        }
        await jobs.pump();
        expect(jobs.api.createBodies, isEmpty);
        h.dup.endDeleteCopy(review);
      }

      test('the list no longer has the pair', () async {
        final review = await started();
        h.pages['open']![null] = dupPage([dupPair('a2', 'b2', band: 'strong')]);
        await h.dup.refresh();
        await pumpEventQueue();
        await expectStale(review);
      });

      test('the other member changed', () async {
        final review = await started();
        h.pages['open']![null] = dupPage([
          dupPair(
            'a1',
            'b1',
            trackA: dupTrack('a1', revision: 4),
            trackB: dupTrack('b1', revision: 7, codec: 'mp3'),
          ),
        ]);
        await h.dup.refresh();
        await pumpEventQueue();
        await expectStale(review);
      });

      test('the pair was set aside', () async {
        final review = await started();
        h.api.onDismissPair = (a, b) async => dupStatus(a, b, 'dismissed');
        h.dup.setAside(h.row('a1|b1'));
        await pumpEventQueue();
        await expectStale(review);
      });

      test('the app went offline', () async {
        final review = await started();
        h.offline.set(true);
        await pumpEventQueue();
        await expectStale(review);
      });

      // Audit V-FIX-P89 U33-B-01(b): going offline drops the review (above)
      // but the pair did not change: never "This pair changed ...".
      test('going offline never says the pair changed', () async {
        final review = await started();
        h.offline.set(true);
        await pumpEventQueue();
        await jobs.pump();
        expect(review.canConfirm, isFalse);
        expect(h.dup.message, isNull);
        h.dup.endDeleteCopy(review);
      });

      test('a list without the pair still says it changed', () async {
        final review = await started();
        h.pages['open']![null] = dupPage([dupPair('a2', 'b2', band: 'strong')]);
        await h.dup.refresh();
        await pumpEventQueue();
        expect(h.dup.message, startsWith('This pair changed'));
        h.dup.endDeleteCopy(review);
      });

      test('a refresh that still lists the pair as it was keeps the review',
          () async {
        final review = await started();
        await h.dup.refresh();
        await pumpEventQueue();
        await jobs.pump();
        expect(review.canConfirm, isTrue);
        h.dup.endDeleteCopy(review);
      });
    });

    test('closing the sheet disposes the review', () async {
      await h.open(extra: manager());
      final review = h.dup.startDeleteCopy(h.row('a1|b1'), 'b1')!;
      await jobs.pump();
      h.dup.endDeleteCopy(review);
      expect(() => review.addListener(() {}), throwsFlutterError);
    });
  });
}

/// A placeholder row for the switch-off check when nothing is listed.
final _none = DuplicatePairView(
  pair: dupPair('x', 'y'),
  badge: '',
  isExact: true,
  a: DuplicateCopyView(track: dupTrack('x'), fields: const {}, identityLines: const []),
  b: DuplicateCopyView(track: dupTrack('y'), fields: const {}, identityLines: const []),
  differing: const {},
);
