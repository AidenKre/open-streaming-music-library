// 8B.1c S4/S5: the deletion review controller over the real delete-jobs
// model (DeleteJobsHarness: in-memory database, fake server).
//  * Spec §4 para 3: the preview distinguishes unknown / tombstone / missing
//    master / conflict / busy, "refresh/remove before confirming"; "Cancel
//    sends no job"; "Freeze request body/operation UUID before submitting;
//    disable repeated submission while response is ambiguous".
//  * Spec §6 para 3: "Do not silently update selected base revisions after
//    sync; preview shows those conflicts for refresh."
//  * A preview is confirmable only while it is the preview of exactly the
//    current selection: a selection change or a finished sync makes it
//    stale. What is sent is exactly what the confirmation showed.
//  * 8-V01: the switch turned off between preview and confirm is refused
//    cleanly and explained.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';
import 'package:frontend/services/deletion/deletion_text.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';
import 'package:frontend/ui/selection/track_selection_controller.dart';

import '../../helpers/delete_jobs_harness.dart';
import '../../helpers/run_once_track_sync.dart';

TrackUI _track(String uuid, {int? revision}) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  revision: revision,
  title: uuid,
  duration: 60,
  bitrateKbps: 320,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

void main() {
  late DeleteJobsHarness h;
  late ProviderContainer c;
  late TrackSelectionControls sel;
  late DeletionReviewControls review;

  setUp(() async {
    h = await DeleteJobsHarness.create();
    await h.verify();
    c = ProviderContainer(
      overrides: [
        deleteJobsManagerProvider.overrideWithValue(h.manager),
        trackSyncProvider.overrideWith(RunOnceTrackSync.new),
      ],
    );
    c.listen(trackSyncProvider, (_, _) {});
    await c.read(trackSyncProvider.future);
    sel = c.read(trackSelectionControllerFactoryProvider)();
    review = c.read(deletionReviewControllerFactoryProvider)(sel);
  });

  tearDown(() async {
    review.dispose();
    sel.dispose();
    c.dispose();
    await h.dispose();
  });

  void select(String uuid, int? revision) =>
      sel.toggle(_track(uuid, revision: revision));

  List<(String, int?)> selected() => [
    for (final e in sel.selection.entries) (e.uuid, e.baseRevision),
  ];

  /// What the server answers to the next previews: per uuid, its current
  /// revision and flags (default: live at the base sent).
  void serverSays(
    Map<String, Map<String, dynamic> Function(int base)> byUuid,
  ) {
    h.api.onPreview = (targets) async => DeletionPreviewDto.fromJson({
      'targets': [
        for (final t in targets)
          (byUuid[t.uuidId] ??
              (base) => previewTargetJson(t.uuidId, base))(t.baseRevision),
      ],
    });
  }

  Future<DeletionPreview> previewed() async {
    await review.requestPreview();
    await h.pump();
    expect(review.stage, ReviewStage.ready);
    return review.preview!;
  }

  group('preview', () {
    test('previews exactly the selection, in order', () async {
      select('a', 1);
      select('b', 2);
      final p = await previewed();
      expect(p.targets.map((t) => (t.uuid, t.baseRevision)), [
        ('a', 1),
        ('b', 2),
      ]);
      expect(h.api.calls, ['preview a,b']);
      expect(review.canConfirm, isTrue);
      expect(review.blockedReason, isNull);
    });

    test('a file the server could not check can still be confirmed: the '
        'server decides (sign-off OPEN-8-07 row 2)', () async {
      select('a', 1);
      select('b', 2);
      serverSays({'a': (base) => previewTargetJson('a', base, fileUnchecked: true)});
      final p = await previewed();
      expect(p.targets.first.verdict, PreviewVerdict.fileStatusUnknown);
      expect(review.canConfirm, isTrue);
      expect(review.blockedReason, isNull);
    });

    test('an empty selection sends nothing', () async {
      await review.requestPreview();
      await h.pump();
      expect(h.api.calls, isEmpty);
      expect(review.stage, ReviewStage.idle);
      expect(review.preview, isNull);
    });

    test('more than 100 tracks sends nothing and says to split', () async {
      for (var i = 0; i < 101; i++) {
        select('t$i', 1);
      }
      await review.requestPreview();
      await h.pump();
      expect(h.api.calls, isEmpty);
      expect(review.preview, isNull);
      expect(review.message, contains('100'));
    });

    test('a selection change makes the preview stale, and re-selecting the '
        'same tracks does not bring it back', () async {
      select('a', 1);
      select('b', 2);
      await previewed();
      sel.toggle(_track('b'));
      expect(review.preview, isNull);
      expect(review.stage, ReviewStage.idle);
      expect(review.canConfirm, isFalse);
      select('b', 2); // the same pairs, in the same order, again
      expect(review.preview, isNull);
      expect(review.canConfirm, isFalse);
    });

    test('an answer for a selection that changed meanwhile is dropped',
        () async {
      final answer = Completer<DeletionPreviewDto>();
      h.api.onPreview = (_) => answer.future;
      select('a', 1);
      final pending = review.requestPreview();
      await h.pump();
      expect(review.stage, ReviewStage.previewing);
      select('b', 2);
      answer.complete(
        DeletionPreviewDto.fromJson({
          'targets': [previewTargetJson('a', 1)],
        }),
      );
      await pending;
      await h.pump();
      expect(review.preview, isNull);
      expect(review.canConfirm, isFalse);
    });

    // U33-B-01: only a sync that touched the selection makes the preview
    // stale; a no-op sync (every resume, every macOS refocus) or one that
    // touched other tracks changes nothing on screen.
    test('a sync that changed nothing keeps the ready preview and its '
        'confirmation', () async {
      select('a', 1);
      final shown = await previewed();
      (c.read(trackSyncProvider.notifier) as RunOnceTrackSync).runOnce();
      await h.pump();
      expect(review.stage, ReviewStage.ready);
      expect(review.preview, same(shown));
      expect(review.message, isNull);
      expect(review.canConfirm, isTrue);
      expect(await review.confirm(shown, confirmedCount: 1), isTrue);
      await h.pump();
      expect(await h.submissions(), hasLength(1));
    });

    test('a sync that deleted other tracks keeps the preview', () async {
      select('a', 1);
      final shown = await previewed();
      (c.read(trackSyncProvider.notifier) as RunOnceTrackSync).runOnce(deleted: {'z'});
      await h.pump();
      expect(review.preview, same(shown));
      expect(review.message, isNull);
    });

    test('a finished sync that deleted a selected track makes the preview '
        'stale and says so', () async {
      select('a', 1);
      await previewed();
      (c.read(trackSyncProvider.notifier) as RunOnceTrackSync).runOnce(deleted: {'a'});
      await h.pump();
      expect(review.preview, isNull);
      expect(review.canConfirm, isFalse);
      expect(review.message, isNotNull);
      // The selection itself is untouched (never silently refreshed).
      expect(selected(), [('a', 1)]);
    });

    test('a 403 because the switch was turned off explains itself', () async {
      h.api.onPreview = (_) async =>
          throw apiError(403, 'library_delete_disabled', retryable: false);
      select('a', 1);
      await review.requestPreview();
      await h.pump();
      expect(review.stage, ReviewStage.failed);
      expect(review.preview, isNull);
      expect(review.message, deletionErrorText('library_delete_disabled'));
    });

    test('the switch known to be off: nothing sent, the reason shown',
        () async {
      h.feature = const AdvertisedFeature(
        LibraryToolsFeature(
          version: 1,
          serverDelete: false,
          duplicateReview: false,
        ),
        fromCache: false,
      );
      select('a', 1);
      await review.requestPreview();
      await h.pump();
      expect(h.api.calls, isEmpty);
      expect(review.stage, ReviewStage.failed);
      expect(
        review.message,
        unavailableText(DeleteJobsUnavailableReason.switchedOff),
      );
    });

    test('a network failure: no preview, a plain message', () async {
      h.api.onPreview = (_) async =>
          throw NetworkException('down', attemptsMade: 1);
      select('a', 1);
      await review.requestPreview();
      await h.pump();
      expect(review.stage, ReviewStage.failed);
      expect(review.preview, isNull);
      expect(review.message, isNotNull);
      expect(review.message, isNot(contains('down')));
    });
  });

  group('refresh and remove', () {
    test('Refresh of a conflict takes the server revision in place and '
        'previews again', () async {
      serverSays({'a': (base) => previewTargetJson('a', base, revision: 5)});
      select('a', 1);
      select('b', 2);
      await review.requestPreview();
      await h.pump();
      expect(review.preview!.targets.first.verdict, PreviewVerdict.conflict);
      expect(review.canConfirm, isFalse);
      expect(review.blockedReason, isNotNull);

      await review.refreshTarget('a');
      await h.pump();
      expect(selected(), [('a', 5), ('b', 2)]);
      expect(h.api.previews.last['targets'], [
        {'uuid_id': 'a', 'base_revision': 5},
        {'uuid_id': 'b', 'base_revision': 2},
      ]);
      expect(review.stage, ReviewStage.ready);
      expect(review.canConfirm, isTrue);
    });

    test('an unknown revision is never confirmable until Refresh supplies '
        'it', () async {
      serverSays({'a': (base) => previewTargetJson('a', base, revision: 9)});
      select('a', null);
      await review.requestPreview();
      await h.pump();
      expect(
        review.preview!.targets.single.verdict,
        PreviewVerdict.revisionUnknown,
      );
      expect(review.canConfirm, isFalse);
      expect(review.blockedReason!.toLowerCase(), contains('refresh'));

      await review.refreshTarget('a');
      await h.pump();
      expect(selected(), [('a', 9)]);
      expect(review.canConfirm, isTrue);
    });

    test('Refresh of a ready target changes nothing and sends nothing',
        () async {
      select('a', 1);
      await previewed();
      await review.refreshTarget('a');
      await h.pump();
      expect(selected(), [('a', 1)]);
      expect(h.api.callsOf('preview'), hasLength(1));
    });

    test('Remove drops the track and previews the rest', () async {
      serverSays({'b': (base) => previewTargetJson('b', base, busy: true)});
      select('a', 1);
      select('b', 2);
      await review.requestPreview();
      await h.pump();
      expect(review.canConfirm, isFalse);

      await review.removeTarget('b');
      await h.pump();
      expect(selected(), [('a', 1)]);
      expect(h.api.calls.last, 'preview a');
      expect(review.canConfirm, isTrue);
    });

    test('removing the last track leaves nothing to preview', () async {
      select('a', 1);
      await previewed();
      await review.removeTarget('a');
      await h.pump();
      expect(selected(), isEmpty);
      expect(review.preview, isNull);
      expect(h.api.callsOf('preview'), hasLength(1));
    });
  });

  group('confirm', () {
    test('sends exactly the shown targets, revisions and count, then clears '
        'the selection', () async {
      select('b', 2);
      select('a', 1);
      final p = await previewed();

      expect(await review.confirm(p, confirmedCount: 2), isTrue);
      await h.pump();
      expect(review.stage, ReviewStage.submitted);
      expect(review.submittedOperation, 'op-1');
      final body = jsonDecode(h.api.createBodies.single) as Map;
      expect(body['targets'], [
        {'uuid_id': 'b', 'base_revision': 2},
        {'uuid_id': 'a', 'base_revision': 1},
      ]);
      expect(body['confirmed_count'], 2);
      expect(sel.selection.isEmpty, isTrue);
      expect(h.job('op-1'), isNotNull);
    });

    test('a preview that is no longer the current one sends nothing',
        () async {
      select('a', 1);
      final old = await previewed();
      await review.requestPreview(); // a newer preview of the same selection
      await h.pump();
      expect(identical(old, review.preview), isFalse);
      expect(await review.confirm(old, confirmedCount: 1), isFalse);
      await h.pump();
      expect(await h.submissions(), isEmpty);
      expect(h.api.callsOf('createJob'), isEmpty);
      expect(review.message, isNotNull);
    });

    test('the selection changed while the confirmation was open: nothing '
        'sent', () async {
      select('a', 1);
      select('b', 2);
      final shown = await previewed();
      sel.deselect('b');
      expect(await review.confirm(shown, confirmedCount: 2), isFalse);
      expect(await review.confirm(shown, confirmedCount: 1), isFalse);
      await h.pump();
      expect(await h.submissions(), isEmpty);
      expect(selected(), [('a', 1)]);
    });

    test('a sync that deleted the track finished while the confirmation was '
        'open: nothing sent',
        () async {
      select('a', 1);
      final shown = await previewed();
      (c.read(trackSyncProvider.notifier) as RunOnceTrackSync).runOnce(deleted: {'a'});
      await h.pump();
      expect(await review.confirm(shown, confirmedCount: 1), isFalse);
      await h.pump();
      expect(await h.submissions(), isEmpty);
    });

    test('a second tap while the first is being handed over sends nothing '
        'more', () async {
      select('a', 1);
      final shown = await previewed();
      final results = await Future.wait([
        review.confirm(shown, confirmedCount: 1),
        review.confirm(shown, confirmedCount: 1),
      ]);
      await h.pump();
      expect(results.where((r) => r), hasLength(1));
      expect(await h.submissions(), hasLength(1));
      expect(h.api.callsOf('createJob'), ['createJob op-1']);
    });

    test('a count that is not the preview\'s is refused with nothing written',
        () async {
      select('a', 1);
      select('b', 2);
      final shown = await previewed();
      expect(await review.confirm(shown, confirmedCount: 3), isFalse);
      await h.pump();
      expect(await h.submissions(), isEmpty);
      expect(selected(), [('a', 1), ('b', 2)]);
    });

    test('a not-confirmable preview is refused with nothing written',
        () async {
      serverSays({'a': (base) => previewTargetJson('a', base, busy: true)});
      select('a', 1);
      await review.requestPreview();
      await h.pump();
      expect(await review.confirm(review.preview!, confirmedCount: 1), isFalse);
      await h.pump();
      expect(await h.submissions(), isEmpty);
    });

    test('while an earlier deletion of a track awaits its answer, it cannot '
        'be confirmed again, and the page is told why', () async {
      final store = h.api.onCreateJob;
      h.api.onCreateJob = (body) async {
        await store(body);
        throw TimeoutException('lost');
      };
      select('a', 1);
      expect(
        await review.confirm(await previewed(), confirmedCount: 1),
        isTrue,
      );
      await h.pump();
      expect(h.job('op-1')!.phase, DeleteJobPhase.unconfirmed);

      select('a', 1);
      final again = await previewed();
      expect(review.canConfirm, isFalse);
      expect(review.blockedReason, isNotNull);
      expect(await review.confirm(again, confirmedCount: 1), isFalse);
      await h.pump();
      expect(await h.submissions(), hasLength(1));
      expect(h.api.callsOf('createJob'), ['createJob op-1']);
    });

    // Sign-off s7-app-texts, Phase 8 tail: handing a deletion over fails
    // only on a local fault (its database rows), of unknown cause, so the
    // text says what happened and offers no "Try again."
    test('a local fault while handing the deletion over: nothing sent, the '
        'review stays ready, and the text says so', () async {
      select('a', 1);
      final shown = await previewed();
      await h.db.customStatement('DROP TABLE durable_submissions');
      expect(await review.confirm(shown, confirmedCount: 1), isFalse);
      await h.pump();
      expect(review.stage, ReviewStage.ready);
      expect(review.message,
          "This device couldn't start the deletion. Nothing was sent.");
      expect(h.api.callsOf('createJob'), isEmpty);
    });

    test('8-V01: the switch turned off between preview and confirm is '
        'refused and explained', () async {
      select('a', 1);
      final shown = await previewed();
      h.feature = const AdvertisedFeature(
        LibraryToolsFeature(
          version: 1,
          serverDelete: false,
          duplicateReview: false,
        ),
        fromCache: false,
      );
      expect(await review.confirm(shown, confirmedCount: 1), isFalse);
      await h.pump();
      expect(await h.submissions(), isEmpty);
      expect(
        review.message,
        contains(unavailableText(DeleteJobsUnavailableReason.switchedOff)),
      );
      expect(selected(), [('a', 1)]);
    });
  });

  test('review r1-3: when the awaited answer arrives, the block lifts and '
      'the page is notified', () async {
    final store = h.api.onCreateJob;
    h.api.onCreateJob = (body) async {
      await store(body);
      throw TimeoutException('lost');
    };
    select('a', 1);
    expect(await review.confirm(await previewed(), confirmedCount: 1), isTrue);
    await h.pump();
    h.api.onCreateJob = store;
    select('a', 1);
    await previewed();
    expect(review.blockedReason, isNotNull);
    var notified = 0;
    review.addListener(() => notified++);

    h.timers.fire(); // the status query finds the job: accepted
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
    expect(notified, greaterThan(0));
    expect(review.blockedReason, isNull);
    expect(review.canConfirm, isTrue);
  });

  test('after dispose, input sends nothing', () async {
    select('a', 1);
    review.dispose();
    await review.requestPreview();
    await h.pump();
    expect(h.api.calls, isEmpty);
    // tearDown disposes again: dispose is idempotent.
  });
}
