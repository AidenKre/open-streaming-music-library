// Phase 7B.2d S8/S9: the duplicate UX on the review page (view; SC-26: it
// renders the review controller's state and the model's banners, and sends
// every input to `UploadReviewControls` or to `PreviewControls`). Spec §7
// Duplicate UX (user decisions 2026-10-29):
//  * batch summary + coverage footnotes, from `duplicate_check` only;
//  * exact library banner "This audio is already in your library": the
//    existing track next to the staged file's values, Play existing / Play
//    this file through the preview controller, Use existing track /
//    Import as separate track, Confirm and Skip disabled until one is
//    picked;
//  * fingerprint banner "Possibly the same song as …" / "Very likely the
//    same recording …", advisory, with Don't import;
//  * staged banners "Same audio as x.flac in this upload" (Import both) and
//    "Sounds like x.mp3 in this upload" (advisory);
//  * at most five matches per banner, "+N more" opens the full list;
//  * `duplicate_conflict`: the new matching tracks, Use existing track or
//    Back to review.
// Never "No duplicates" without full coverage; a null report (not checked
// yet) is not an empty one. A gone track is shown as unavailable, never
// hidden and never playable. An item no longer reviewable shows no
// duplicate action.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/uploads/upload_duplicate_decisions.dart';
import 'package:frontend/services/uploads/upload_duplicate_summary.dart';
import 'package:frontend/ui/preview_controller.dart';
import 'package:frontend/ui/uploads/upload_review_controller.dart';
import 'package:frontend/ui/uploads/upload_review_page.dart';

import '../../helpers/duplicate_check_fixtures.dart';
import '../browse_harness.dart';
import '../fake_upload_review_controls.dart';

class _Preview implements PreviewControls {
  final calls = <String>[];
  @override
  Future<void> playStaged(String itemUuid) async =>
      calls.add('playStaged $itemUuid');
  @override
  Future<void> playLibraryTrack(String trackUuid) async =>
      calls.add('playLibrary $trackUuid');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> close() async => calls.add('close');
}

class _FixedPreview extends PreviewPlayer {
  _FixedPreview(this._state);
  final PreviewState _state;
  @override
  PreviewState build() => _state;
}

void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late FakeUploadReviewControls fake;
  late _Preview preview;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
    fake = FakeUploadReviewControls();
    preview = _Preview();
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, {PreviewState? previewState}) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness.wrap(
      const UploadReviewPage(batchUuid: 'b-1', startAt: 'a'),
      appInfo: defaultAppInfo(),
      overrides: [
        uploadReviewControllerFactoryProvider.overrideWithValue(() => fake),
        previewControlsProvider.overrideWithValue(preview),
        if (previewState != null)
          previewPlayerProvider.overrideWith(() => _FixedPreview(previewState)),
      ],
    ));
    await tester.pump();
  }

  VoidCallback? onPressed(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(find.ancestor(
          of: find.text(label),
          matching: find.bySubtype<ButtonStyleButton>())).onPressed;

  Future<void> tapText(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await tester.pump();
  }

  List<String> sent() =>
      [for (final c in fake.calls) if (!c.startsWith('start')) c];

  final exact = duplicateCheckJson(matches: [
    libraryMatchJson('t-1',
        title: 'Airbag',
        artist: 'Radiohead',
        album: 'OK Computer',
        codec: 'flac',
        bitrateKbps: 920,
        durationS: 287),
  ]);

  group('batch summary', () {
    testWidgets('the summary line and every footnote', (tester) async {
      fake.duplicateSummary = DuplicateSummary.of([
        reviewItem('a', check: exact),
        reviewItem('b', check: duplicateCheckJson(
            exact: coverageJson(pending: 3),
            fingerprint: coverageJson(subject: 'unavailable'))),
      ]);
      fake.show(fakeReviewView('a', check: exact));
      await pump(tester);
      expect(find.text('1 of 2 files may already be in your library'),
          findsOneWidget);
      expect(find.text('Only exact copies are detected on this server'),
          findsOneWidget);
      expect(find.text('3 library tracks not yet scanned'), findsOneWidget);
      expect(find.textContaining('No duplicates'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('"No duplicates found" only for a fully covered snapshot',
        (tester) async {
      fake.duplicateSummary =
          DuplicateSummary.of([reviewItem('a', check: duplicateCheckJson())]);
      fake.show(fakeReviewView('a', check: duplicateCheckJson()));
      await pump(tester);
      // The summary and the item's own line.
      expect(find.text('No duplicates found'), findsNWidgets(2));
      await teardownTree(tester);
    });
  });

  group('exact library match', () {
    testWidgets('the banner, the existing track next to this file, and '
        'Confirm and Skip off until a choice', (tester) async {
      fake.show(fakeReviewView('a', check: exact, detected: {
        'v': 1,
        'codec': 'mp3',
        'bitrate_kbps': 320.0,
        'duration_s': 287.0,
        'tags': {},
      }));
      await pump(tester);
      expect(find.text('This audio is already in your library'),
          findsOneWidget);
      expect(find.text('Airbag — Radiohead'), findsOneWidget);
      expect(find.text('OK Computer · FLAC · 920 kbps · 4:47'),
          findsOneWidget);
      expect(find.text('This file: MP3 · 320 kbps · 4:47'), findsOneWidget);
      expect(onPressed(tester, 'Confirm and import'), isNull);
      expect(onPressed(tester, 'Skip edits and import'), isNull);

      await tapText(tester, 'Import as separate track');
      await tapText(tester, 'Use existing track');
      expect(sent(), ['choose library', 'useExisting']);
      await teardownTree(tester);
    });

    testWidgets('after Import as separate track: Confirm and Skip work and '
        'the choice is shown', (tester) async {
      fake.show(fakeReviewView('a', check: exact,
          chosen: {DuplicateGroup.library}));
      await pump(tester);
      expect(onPressed(tester, 'Confirm and import'), isNotNull);
      expect(onPressed(tester, 'Skip edits and import'), isNotNull);
      expect(find.text('It will be imported as a separate track.'),
          findsOneWidget);
      expect(find.text('Import as separate track'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('Play existing and Play this file go through the preview '
        'controller', (tester) async {
      fake.show(fakeReviewView('a', check: exact));
      await pump(tester);
      await tapText(tester, 'Play existing');
      await tapText(tester, 'Play this file');
      expect(preview.calls, ['playLibrary t-1', 'playStaged a']);
      await teardownTree(tester);
    });

    testWidgets('the existing track that is playing can be paused',
        (tester) async {
      fake.show(fakeReviewView('a', check: exact));
      await pump(tester,
          previewState: const PreviewState(
              source: LibraryTrackPreview('t-1'),
              status: PreviewStatus.playing));
      await tapText(tester, 'Pause existing');
      expect(preview.calls, ['pause']);
      await teardownTree(tester);
    });

    testWidgets('five rows, "+3 more" opens the full list', (tester) async {
      fake.show(fakeReviewView('a', check: duplicateCheckJson(matches: [
        for (var i = 1; i <= 8; i++) libraryMatchJson('t-$i'),
      ])));
      await pump(tester);
      expect(find.text('Title t-5 — Artist t-5'), findsOneWidget);
      expect(find.text('Title t-6 — Artist t-6'), findsNothing);
      await tapText(tester, '+3 more');
      for (var i = 1; i <= 8; i++) {
        expect(find.text('Title t-$i — Artist t-$i'), findsOneWidget);
      }
      expect(find.text('+3 more'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a gone track is listed as unavailable and cannot be played',
        (tester) async {
      fake.show(fakeReviewView('a', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-gone', available: false),
      ])));
      await pump(tester);
      expect(find.text('A track that is no longer in your library'),
          findsOneWidget);
      expect(find.text('Play existing'), findsNothing);
      expect(onPressed(tester, 'Use existing track'), isNull);
      expect(onPressed(tester, 'Import as separate track'), isNotNull);
      await teardownTree(tester);
    });
  });

  group('fingerprint library match', () {
    testWidgets("advisory: Confirm works; Don't import goes to the "
        'controller', (tester) async {
      fake.show(fakeReviewView('a', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-1', kind: 'fingerprint', band: 'possible',
            score: 0.8, title: 'Title', artist: 'Artist', durationS: 252),
      ])));
      await pump(tester);
      expect(find.text('Possibly the same song as Title — Artist '
          '(FLAC, 4:12)'), findsOneWidget);
      expect(onPressed(tester, 'Confirm and import'), isNotNull);
      expect(onPressed(tester, 'Skip edits and import'), isNotNull);
      expect(find.text('Use existing track'), findsNothing);
      await tapText(tester, "Don't import");
      expect(sent(), ['dontImport']);
      await teardownTree(tester);
    });
  });

  group('the item\'s own coverage', () {
    testWidgets('not checked yet is never worded as no duplicates',
        (tester) async {
      fake.show(fakeReviewView('a'));
      await pump(tester);
      expect(find.text('Not checked for duplicates yet'), findsOneWidget);
      expect(find.textContaining('No duplicates'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('partial coverage: no "No duplicates" claim; the reason '
        'in words', (tester) async {
      fake.show(fakeReviewView('a', check: duplicateCheckJson(
          fingerprint: coverageJson(subject: 'too_short'))));
      await pump(tester);
      expect(find.text('No matches among what could be compared'),
          findsOneWidget);
      expect(find.text('Too short or quiet to compare by sound'),
          findsOneWidget);
      expect(find.textContaining('No duplicates'), findsNothing);
      await teardownTree(tester);
    });
  });

  // 7B.2d S9: staged banners, the duplicate_conflict view, and items whose
  // duplicate actions are off (no longer reviewable, offline, busy).
  group('staged matches', () {
    testWidgets('exact: "Same audio as x.flac in this upload"; Import both; '
        'Confirm and Skip off until then', (tester) async {
      fake.show(fakeReviewView('a', check: duplicateCheckJson(matches: [
        stagedMatchJson('x', filename: 'x.flac', batchUuid: 'b-1'),
      ])));
      await pump(tester);
      expect(find.text('Same audio as x.flac in this upload'),
          findsOneWidget);
      expect(onPressed(tester, 'Confirm and import'), isNull);
      expect(onPressed(tester, 'Skip edits and import'), isNull);
      expect(find.text('Play existing'), findsNothing);
      await tapText(tester, 'Import both');
      expect(sent(), ['choose staged']);
      await teardownTree(tester);
    });

    testWidgets('after Import both: Confirm works and the choice is shown',
        (tester) async {
      fake.show(fakeReviewView('a',
          check: duplicateCheckJson(matches: [stagedMatchJson('x')]),
          chosen: {DuplicateGroup.staged}));
      await pump(tester);
      expect(find.text('Both files will be imported.'), findsOneWidget);
      expect(find.text('Import both'), findsNothing);
      expect(onPressed(tester, 'Confirm and import'), isNotNull);
      await teardownTree(tester);
    });

    testWidgets('fingerprint: "Sounds like x.mp3 in this upload", advisory',
        (tester) async {
      fake.show(fakeReviewView('a', check: duplicateCheckJson(matches: [
        stagedMatchJson('x', kind: 'fingerprint', score: 0.8,
            filename: 'x.mp3', batchUuid: 'b-1'),
      ])));
      await pump(tester);
      expect(find.text('Sounds like x.mp3 in this upload'), findsOneWidget);
      expect(find.text('Import both'), findsNothing);
      expect(onPressed(tester, 'Confirm and import'), isNotNull);
      expect(onPressed(tester, 'Cancel this item'), isNotNull);
      await teardownTree(tester);
    });
  });

  group('duplicate_conflict', () {
    final conflicts = [
      libraryMatchJson('t-new', title: 'New', artist: 'Band'),
    ];

    testWidgets('the new matching track with Use existing track and Back to '
        'review; nothing else to send', (tester) async {
      fake.show(fakeReviewView('a', state: 'duplicate_conflict',
          check: exact, conflicts: conflicts));
      await pump(tester);
      expect(find.text('Needs a decision'), findsOneWidget);
      expect(find.text('This audio was added to your library after your '
          'review'), findsOneWidget);
      expect(find.text('New — Band'), findsOneWidget);
      expect(find.text('Import as separate track'), findsNothing);
      expect(find.text('This audio is already in your library'),
          findsNothing);
      expect(onPressed(tester, 'Confirm and import'), isNull);
      expect(onPressed(tester, 'Skip edits and import'), isNull);

      await tapText(tester, 'Play existing');
      expect(preview.calls, ['playLibrary t-new']);
      await tapText(tester, 'Use existing track');
      await tapText(tester, 'Back to review');
      expect(sent(), ['useExisting', 'backToReview']);
      await teardownTree(tester);
    });

    testWidgets('offline: shown, nothing can be sent or played',
        (tester) async {
      fake.show(fakeReviewView('a', state: 'duplicate_conflict',
          online: false, conflicts: conflicts));
      await pump(tester);
      expect(find.text('New — Band'), findsOneWidget);
      expect(onPressed(tester, 'Use existing track'), isNull);
      expect(onPressed(tester, 'Back to review'), isNull);
      expect(onPressed(tester, 'Play existing'), isNull);
      await teardownTree(tester);
    });
  });

  group('duplicate actions that are off', () {
    testWidgets('an item that expired while its banner was shown is no '
        'longer reviewable: no banner, no action', (tester) async {
      fake.show(fakeReviewView('a', check: exact));
      await pump(tester);
      expect(find.text('Use existing track'), findsOneWidget);

      fake.show(fakeReviewView('a', state: 'expired', check: exact));
      await tester.pump();
      expect(find.text('Expired'), findsOneWidget);
      expect(find.text('This audio is already in your library'),
          findsNothing);
      expect(find.text('Use existing track'), findsNothing);
      expect(find.text('Import as separate track'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('offline: the banner stays, its actions are off',
        (tester) async {
      fake.show(fakeReviewView('a', check: exact, online: false));
      await pump(tester);
      expect(find.text('This audio is already in your library'),
          findsOneWidget);
      expect(onPressed(tester, 'Use existing track'), isNull);
      expect(onPressed(tester, 'Import as separate track'), isNull);
      expect(onPressed(tester, 'Play existing'), isNull);
      expect(onPressed(tester, 'Play this file'), isNull);
      await teardownTree(tester);
    });

    testWidgets('while a request is being sent, Use existing and Don\'t '
        'import are off', (tester) async {
      fake.busy = true;
      fake.show(fakeReviewView('a', check: duplicateCheckJson(matches: [
        libraryMatchJson('t-1'),
        libraryMatchJson('t-fp', kind: 'fingerprint', score: 0.9),
      ])));
      await pump(tester);
      expect(onPressed(tester, 'Use existing track'), isNull);
      expect(onPressed(tester, "Don't import"), isNull);
      expect(onPressed(tester, 'Import as separate track'), isNull);
      await teardownTree(tester);
    });
  });

  // 7B.2d review r1 #1: an item closed as a duplicate (Use existing track,
  // Don't import) was not imported; the page says it is already in the
  // library and still offers View track for that existing track.
  testWidgets('r1 #1 an item closed as a duplicate is not called imported',
      (tester) async {
    fake.lastImported =
        const ReviewImported('a.flac', null, alreadyInLibrary: true);
    fake.show(fakeReviewView('b'));
    await pump(tester);
    expect(find.text('“a.flac” is already in your library'), findsOneWidget);
    expect(find.textContaining('was imported'), findsNothing);
    await teardownTree(tester);
  });

  // 7B.2d review r1 #2: an existing track still playing after the item was
  // sent (its rows are gone) can still be paused from the page's preview
  // control.
  testWidgets('r1 #2 a playing existing track can be paused after the item '
      'was sent', (tester) async {
    fake.show(fakeReviewView('a', state: 'review_submitted', check: exact));
    await pump(tester,
        previewState: const PreviewState(
            source: LibraryTrackPreview('t-1'),
            status: PreviewStatus.playing));
    expect(find.text('Pause existing'), findsNothing);
    expect(onPressed(tester, 'Pause preview'), isNotNull);
    await tapText(tester, 'Pause preview');
    expect(preview.calls, ['pause']);
    await teardownTree(tester);
  });

  // 7B.2d review r1 #7: Play this file pauses while this file plays.
  testWidgets('r1 #7 Play this file turns into Pause this file while it '
      'plays', (tester) async {
    fake.show(fakeReviewView('a', check: exact));
    await pump(tester,
        previewState: const PreviewState(
            source: StagedUploadPreview('a'), status: PreviewStatus.playing));
    await tapText(tester, 'Pause this file');
    expect(preview.calls, ['pause']);
    await teardownTree(tester);
  });

  // 7B.2d review r1 #8: a new review version starts with the list folded.
  testWidgets('r1 #8 a new review version folds the "+N more" list again',
      (tester) async {
    final eight = duplicateCheckJson(matches: [
      for (var i = 1; i <= 8; i++) libraryMatchJson('t-$i'),
    ]);
    fake.show(fakeReviewView('a', version: 1, check: eight));
    await pump(tester);
    await tapText(tester, '+3 more');
    expect(find.text('+3 more'), findsNothing);
    fake.show(fakeReviewView('a', version: 2, check: eight));
    await tester.pump();
    expect(find.text('+3 more'), findsOneWidget);
    await teardownTree(tester);
  });

  // 7-R1-36: a preview that is still loading can always be stopped, from
  // every control that would show Pause while it plays.
  group('7-R1-36 a loading preview can be stopped', () {
    testWidgets('this item, no longer previewable (sent): Pause preview',
        (tester) async {
      fake.show(fakeReviewView('a', state: 'review_submitted', check: exact));
      await pump(tester,
          previewState: const PreviewState(
              source: StagedUploadPreview('a'),
              status: PreviewStatus.loading));
      expect(onPressed(tester, 'Pause preview'), isNotNull);
      await tapText(tester, 'Pause preview');
      expect(preview.calls, ['pause']);
      await teardownTree(tester);
    });

    testWidgets('Play this file while it loads: Pause this file',
        (tester) async {
      fake.show(fakeReviewView('a', check: exact));
      await pump(tester,
          previewState: const PreviewState(
              source: StagedUploadPreview('a'),
              status: PreviewStatus.loading));
      await tapText(tester, 'Pause this file');
      expect(preview.calls, ['pause']);
      await teardownTree(tester);
    });

    testWidgets('an existing track while it loads: Pause existing',
        (tester) async {
      fake.show(fakeReviewView('a', check: exact));
      await pump(tester,
          previewState: const PreviewState(
              source: LibraryTrackPreview('t-1'),
              status: PreviewStatus.loading));
      await tapText(tester, 'Pause existing');
      expect(preview.calls, ['pause']);
      await teardownTree(tester);
    });
  });
}
