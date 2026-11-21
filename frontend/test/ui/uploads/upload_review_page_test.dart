// Phase 7B.2c S11: the review page (view; SC-26: renders the controller's
// state, sends every input to `UploadReviewControls` or the preview
// controller). Spec §7 para 4: header `1/X`, MetadataForm keyed by
// (item_uuid, review_generation) with that item's draft (field initial
// values must not leak from the prior item), preview control, Previous,
// `Skip edits and import`, `Confirm and import` (confirmation shows the
// tag-write mode), `Cancel this item`; `More items ready — Refresh`
// (NewActivityNotice); `View track` only once the UUID resolves, through
// `openTrackInfo`. The write-tags toggle is disabled when the server says
// the file can't take tags; unknown support is worded as unknown and left
// to the server's check (null ≠ false).
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/library_tools_pages.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/ui/feed/new_activity_notice.dart';
import 'package:frontend/ui/get_info_page.dart';
import 'package:frontend/ui/preview_controller.dart';
import 'package:frontend/ui/uploads/upload_review_controller.dart';
import 'package:frontend/ui/uploads/upload_review_page.dart';

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

/// A preview player that only reports a fixed state.
class _PlayingPreview extends PreviewPlayer {
  _PlayingPreview(this._state);
  final PreviewState _state;
  @override
  PreviewState build() => _state;
}

const _track = TrackUI(
  uuidId: 't-1',
  createdAt: 0,
  lastUpdated: 0,
  title: 'Imported song',
  artist: 'Artist',
  duration: 120,
  bitrateKbps: 320,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

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

  Future<void> pump(WidgetTester tester, {String? startAt = 'a'}) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness.wrap(
      UploadReviewPage(batchUuid: 'b-1', startAt: startAt),
      appInfo: defaultAppInfo(),
      overrides: [
        uploadReviewControllerFactoryProvider.overrideWithValue(() => fake),
        previewControlsProvider.overrideWithValue(preview),
      ],
    ));
    await tester.pump();
  }

  Finder titleField() => find.descendant(
      of: find.byKey(const ValueKey('field_title')),
      matching: find.byType(EditableText));

  String titleText(WidgetTester tester) =>
      tester.widget<EditableText>(titleField()).controller.text;

  testWidgets('it starts the review of the batch at the item asked for',
      (tester) async {
    await pump(tester, startAt: 'b');
    expect(fake.calls, contains('start b-1 b'));
    await teardownTree(tester);
  });

  testWidgets('header 1/X, the file, its status and its error in words',
      (tester) async {
    fake.show(
      fakeReviewView('b', code: 'upload_review_version_conflict'),
      position: 1,
      total: 3,
    );
    await pump(tester);
    expect(find.text('2/3'), findsOneWidget);
    expect(find.text('b.flac'), findsOneWidget);
    expect(find.text('Ready for review'), findsOneWidget);
    expect(
        find.text('This file changed on the server since you opened it. '
            'Check it and confirm again.'),
        findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('the form shows the detected tags with the draft over them; '
      'typing goes to the controller', (tester) async {
    fake.show(fakeReviewView('a'),
        detected: {'title': 'Detected A', 'artist': 'Someone'},
        edit: const MetadataEdit.empty().set('artist', 'Edited'));
    await pump(tester);
    expect(titleText(tester), 'Detected A');
    expect(find.text('Edited'), findsOneWidget);

    await tester.enterText(titleField(), 'Typed');
    await tester.pump();
    expect(fake.calls.last, contains('title: Typed'));
    await teardownTree(tester);
  });

  testWidgets('no field value leaks from one item to the next; a cleared '
      'field stays empty when the user comes back', (tester) async {
    fake.show(fakeReviewView('a'),
        detected: {'title': 'Title A'},
        edit: const MetadataEdit.empty().set('title', 'Edited A'));
    await pump(tester);
    expect(titleText(tester), 'Edited A');

    fake.show(fakeReviewView('b'), detected: {'title': 'Title B'});
    await tester.pump();
    expect(titleText(tester), 'Title B');

    fake.show(fakeReviewView('a'),
        detected: {'title': 'Title A'},
        edit: const MetadataEdit.empty().set('title', null));
    await tester.pump();
    expect(titleText(tester), '');
    await teardownTree(tester);
  });

  testWidgets('a new review version of the same item rebuilds the form',
      (tester) async {
    fake.show(fakeReviewView('a', version: 1), detected: {'title': 'Old'});
    await pump(tester);
    expect(titleText(tester), 'Old');
    fake.show(fakeReviewView('a', version: 2), detected: {'title': 'New'});
    await tester.pump();
    expect(titleText(tester), 'New');
    await teardownTree(tester);
  });

  testWidgets('Previous, Next, Skip edits and import, Cancel this item go to '
      'the controller', (tester) async {
    fake.show(fakeReviewView('b'),
        position: 1, total: 3, canPrevious: true, canNext: true);
    await pump(tester);
    await tester.tap(find.text('Previous'));
    await tester.tap(find.text('Next'));
    await tester.tap(find.text('Skip edits and import'));
    await tester.tap(find.text('Cancel this item'));
    await tester.pump();
    expect(fake.calls.where((c) => !c.startsWith('start')),
        ['previous', 'next', 'skip', 'cancel']);
    await teardownTree(tester);
  });

  testWidgets('Previous and Next are off at the ends', (tester) async {
    fake.show(fakeReviewView('a'), total: 1);
    await pump(tester);
    for (final label in ['Previous', 'Next']) {
      final b = tester.widget<ButtonStyleButton>(find.ancestor(
          of: find.text(label), matching: find.bySubtype<ButtonStyleButton>()));
      expect(b.onPressed, isNull, reason: label);
    }
    await teardownTree(tester);
  });

  testWidgets('Confirm opens a sheet with the tag-write choice, off by '
      'default', (tester) async {
    fake.show(fakeReviewView('a'));
    await pump(tester);
    await tester.tap(find.text('Confirm and import'));
    await tester.pumpAndSettle();
    expect(find.text('Write these tags into the imported file'),
        findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse);
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(fake.calls.last, 'confirm false');
    expect(fake.confirmTargets, [('a', 1)]);
    await teardownTree(tester);
  });

  testWidgets('turning tag writing on is sent with the confirmation',
      (tester) async {
    fake.show(fakeReviewView('a'));
    await pump(tester);
    await tester.tap(find.text('Confirm and import'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(fake.calls.last, 'confirm true');
    await teardownTree(tester);
  });

  testWidgets('7-R1-01 the sheet confirms the item and version it was '
      'opened for, even after the review moved on', (tester) async {
    fake.show(fakeReviewView('a', version: 3));
    await pump(tester);
    await tester.tap(find.text('Confirm and import'));
    await tester.pumpAndSettle();
    fake.show(fakeReviewView('b', version: 1));
    await tester.pump();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(fake.confirmTargets, [('a', 3)]);
    expect(find.text('Write these tags into the imported file'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('closing the sheet without Import sends nothing',
      (tester) async {
    fake.show(fakeReviewView('a'));
    await pump(tester);
    await tester.tap(find.text('Confirm and import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(fake.calls.where((c) => c.startsWith('confirm')), isEmpty);
    await teardownTree(tester);
  });

  testWidgets('a file that cannot take tags: the toggle is off and disabled, '
      'and says why', (tester) async {
    fake.show(fakeReviewView('a', tagWrite: false));
    await pump(tester);
    await tester.tap(find.text('Confirm and import'));
    await tester.pumpAndSettle();
    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.value, isFalse);
    expect(toggle.onChanged, isNull);
    expect(find.text("This file type can't take written tags."),
        findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('unknown tag-write support is not treated as known: the toggle '
      'works and the server checks', (tester) async {
    fake.show(fakeReviewView('a', tagWrite: null));
    await pump(tester);
    await tester.tap(find.text('Confirm and import'));
    await tester.pumpAndSettle();
    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.onChanged, isNotNull);
    expect(
        find.text("It isn't known yet whether this file can take written "
            'tags. The server checks when you import.'),
        findsOneWidget);
    expect(find.text("This file type can't take written tags."), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('while a submit is being sent, Confirm and Skip are off',
      (tester) async {
    fake.show(fakeReviewView('a'));
    fake.busy = true;
    await pump(tester);
    for (final label in ['Confirm and import', 'Skip edits and import']) {
      final b = tester.widget<ButtonStyleButton>(find.ancestor(
          of: find.text(label), matching: find.bySubtype<ButtonStyleButton>()));
      expect(b.onPressed, isNull, reason: label);
    }
    await teardownTree(tester);
  });

  // Refactor APP-UPLOAD, section 6 #4 (owner 2026-11-17): Cancel waits for a
  // review submit like Confirm and Skip, and shows it: the button is off.
  testWidgets('while a submit is being sent, Cancel this item is off; it is '
      'on again when the submit ended', (tester) async {
    fake.show(fakeReviewView('a'));
    fake.busy = true;
    await pump(tester);
    ButtonStyleButton cancel() => tester.widget<ButtonStyleButton>(
        find.ancestor(
            of: find.text('Cancel this item'),
            matching: find.bySubtype<ButtonStyleButton>()));
    expect(cancel().onPressed, isNull);
    await tester.tap(find.text('Cancel this item'));
    await tester.pump();
    expect(fake.calls, isNot(contains('cancel')));

    fake.busy = false;
    fake.changed();
    await tester.pump();
    expect(cancel().onPressed, isNotNull);
    await teardownTree(tester);
  });

  testWidgets('an item being imported offers no action', (tester) async {
    fake.show(fakeReviewView('a', state: 'committing'));
    await pump(tester);
    expect(find.text('Importing'), findsOneWidget);
    for (final label in [
      'Confirm and import',
      'Skip edits and import',
      'Cancel this item',
    ]) {
      final f = find.ancestor(
          of: find.text(label), matching: find.bySubtype<ButtonStyleButton>());
      if (f.evaluate().isEmpty) continue;
      expect(tester.widget<ButtonStyleButton>(f).onPressed, isNull,
          reason: label);
    }
    await teardownTree(tester);
  });

  testWidgets('new ready items: More items ready — Refresh', (tester) async {
    fake.show(fakeReviewView('a'), total: 2);
    fake.moreItemsReady = true;
    await pump(tester);
    expect(find.byType(NewActivityNotice), findsOneWidget);
    expect(find.text('More items ready'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    await tester.pump();
    expect(fake.calls.last, 'refresh');
    await teardownTree(tester);
  });

  testWidgets('View track appears only once the track resolves and opens '
      'its Get info', (tester) async {
    fake.show(fakeReviewView('b'), position: 1, total: 2);
    fake.lastImported = const ReviewImported('a.flac', null);
    await pump(tester);
    expect(find.textContaining('a.flac'), findsWidgets);
    expect(find.text('View track'), findsNothing);

    fake.lastImported = const ReviewImported('a.flac', _track);
    fake.changed();
    await tester.pump();
    await tester.tap(find.text('View track'));
    await tester.pumpAndSettle();
    expect(find.byType(GetInfoPage), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('an imported item shown again offers View track for itself',
      (tester) async {
    fake.show(fakeReviewView('a', state: 'imported', result: 't-1'));
    fake.currentTrack = _track;
    await pump(tester);
    expect(find.text('Imported'), findsOneWidget);
    expect(find.text('View track'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('the preview plays the staged file through the preview '
      'controller', (tester) async {
    fake.show(fakeReviewView('a'));
    await pump(tester);
    await tester.tap(find.text('Play preview'));
    await tester.pump();
    expect(preview.calls, ['playStaged a']);
    await teardownTree(tester);
  });

  testWidgets('offline: preview and import are off, the draft stays '
      'editable', (tester) async {
    fake.show(fakeReviewView('a', online: false), detected: {'title': 'T'});
    await pump(tester);
    for (final label in [
      'Play preview',
      'Confirm and import',
      'Skip edits and import',
      'Cancel this item',
    ]) {
      final b = tester.widget<ButtonStyleButton>(find.ancestor(
          of: find.text(label), matching: find.bySubtype<ButtonStyleButton>()));
      expect(b.onPressed, isNull, reason: label);
    }
    await tester.enterText(titleField(), 'Offline edit');
    await tester.pump();
    expect(fake.calls.last, contains('Offline edit'));
    await teardownTree(tester);
  });

  testWidgets('loading, a failed load with Try again, and nothing to review',
      (tester) async {
    fake.load = ReviewLoad.loading;
    await pump(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    fake.load = ReviewLoad.failed;
    fake.changed();
    await tester.pump();
    expect(find.text("Couldn't load the files to review."), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(fake.calls.where((c) => c.startsWith('start')), hasLength(2));

    fake.load = ReviewLoad.ready;
    fake.total = 0;
    fake.current = null;
    fake.changed();
    await tester.pump();
    expect(find.text('Nothing to review right now.'), findsOneWidget);
    await teardownTree(tester);
  });

  // A failed load names its reason; Try again only where it helps.
  for (final (reason, retry, text) in <(LibraryToolsUnreachable?, bool, String)>[
    (
      LibraryToolsUnreachable.needsConnection,
      true,
      'The files to review need a connection.',
    ),
    (
      LibraryToolsUnreachable.differentServer,
      false,
      'The files to review are not available: a different server answers '
          'at this address.',
    ),
    (
      LibraryToolsUnreachable.signedOut,
      false,
      'The files to review are not available: you are signed out.',
    ),
    (null, true, "Couldn't load the files to review."),
  ]) {
    testWidgets('a failed load: ${reason?.name ?? 'other failure'}',
        (tester) async {
      fake.load = ReviewLoad.failed;
      fake.loadUnreachable = reason;
      fake.loadRetryHelps = retry;
      await pump(tester);
      expect(find.text(text), findsOneWidget);
      for (final other in [
        'The files to review need a connection.',
        "Couldn't load the files to review.",
      ]) {
        if (other != text) expect(find.text(other), findsNothing);
      }
      expect(find.text('Try again'), retry ? findsOneWidget : findsNothing);
      if (retry) {
        await tester.tap(find.text('Try again'));
        await tester.pump();
        expect(fake.calls.where((c) => c.startsWith('start')), hasLength(2));
      }
      await teardownTree(tester);
    });
  }

  testWidgets('a notice is shown and can be dismissed', (tester) async {
    fake.show(fakeReviewView('a'));
    fake.notice = 'This file is already being imported.';
    await pump(tester);
    expect(find.text('This file is already being imported.'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(fake.calls.last, 'dismissNotice');
    await teardownTree(tester);
  });

  testWidgets('leaving the page disposes its controller', (tester) async {
    fake.show(fakeReviewView('a'));
    await pump(tester);
    await teardownTree(tester);
    expect(fake.disposed, isTrue);
  });

  testWidgets('narrow window, large text: no overflow', (tester) async {
    fake.show(fakeReviewView('a-very-long-file-name-that-goes-on-and-on'),
        position: 9, total: 120, canPrevious: true, canNext: true);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester);
    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await teardownTree(tester);
  });

  // Review r1 #9: while this item's preview plays, Pause stays reachable
  // even when the item can no longer be previewed (after Confirm, offline).
  testWidgets('r1 #9 Pause preview stays available while this item plays',
      (tester) async {
    fake.show(fakeReviewView('a', state: 'review_submitted'));
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness.wrap(
      const UploadReviewPage(batchUuid: 'b-1', startAt: 'a'),
      appInfo: defaultAppInfo(),
      overrides: [
        uploadReviewControllerFactoryProvider.overrideWithValue(() => fake),
        previewControlsProvider.overrideWithValue(preview),
        previewPlayerProvider.overrideWith(() => _PlayingPreview(
            const PreviewState(
                source: StagedUploadPreview('a'),
                status: PreviewStatus.playing))),
      ],
    ));
    await tester.pump();

    await tester.tap(find.text('Pause preview'));
    await tester.pump();
    expect(preview.calls, ['pause']);
    await teardownTree(tester);
  });
}
