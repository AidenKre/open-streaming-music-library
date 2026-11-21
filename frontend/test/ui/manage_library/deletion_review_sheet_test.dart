// Phase 8 spec §4 para 3, §6 paras 1-3, review 8-V01 (8B.1c, S8): the
// deletion review sheet and its confirmation render what
// DeletionReviewControls says and forward every input to it (SC-26).
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';
import 'package:frontend/services/deletion/deletion_text.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';
import 'package:frontend/ui/manage_library/deletion_review_sheet.dart';

import '../../helpers/fake_library_tools_api.dart';
import '../../helpers/run_once_track_sync.dart';
import '../browse_harness.dart' show teardownTree;
import '../fake_track_selection_controls.dart';
import 'fake_manage_library_controls.dart';

const _confirmButton = Key('confirm-deletion');
const _dialog = Key('deletion-confirmation');
const _typed = Key('typed-count');
const _permanently = Key('confirm-delete-permanently');
const _cancel = Key('cancel-deletion');

/// A preview over [specs]: uuid -> JSON from `previewTargetJson`, with the
/// candidates' base revisions (null: unknown).
DeletionPreview previewOf(
  List<({String uuid, int? base, Map<String, dynamic> json})> specs,
) => DeletionPreview.fromServer([
  for (final s in specs) DeletionCandidate(s.uuid, s.base),
], DeletionPreviewDto.fromJson({'targets': [for (final s in specs) s.json]}));

({String uuid, int? base, Map<String, dynamic> json}) ready(String uuid) =>
    (uuid: uuid, base: 1, json: previewTargetJson(uuid, 1));

DeletionPreview readyPreview(List<String> uuids) =>
    previewOf([for (final u in uuids) ready(u)]);

void main() {
  late FakeDeletionReviewControls fake;
  bool? result;

  setUp(() {
    fake = FakeDeletionReviewControls();
    result = null;
  });
  tearDown(() => fake.dispose());

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(800, 1600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await showDeletionReview(context, fake),
              child: const Text('open review'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open review'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> openReady(
    WidgetTester tester,
    DeletionPreview preview, {
    Size size = const Size(800, 1600),
  }) async {
    fake.stage = ReviewStage.ready;
    fake.preview = preview;
    await open(tester, size: size);
    await tester.pumpAndSettle();
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(_confirmButton));
    await tester.tap(find.byKey(_confirmButton));
    await tester.pumpAndSettle();
  }

  String dialogText(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(of: find.byKey(_dialog), matching: find.byType(Text)),
      )
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join('\n');

  bool? enabled(WidgetTester tester, Key key) =>
      tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed != null;

  Finder target(String uuid) => find.byKey(Key('review-target-$uuid'));

  group('stages', () {
    testWidgets('previewing shows a progress indicator', (tester) async {
      fake.stage = ReviewStage.previewing;
      await open(tester);
      expect(
        find.descendant(
          of: find.byType(DeletionReviewSheet),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOne,
      );
      expect(find.byKey(_confirmButton), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('failed shows the message', (tester) async {
      fake.stage = ReviewStage.failed;
      fake.message = couldNotReachServerText();
      await open(tester);
      await tester.pumpAndSettle();
      expect(find.text(couldNotReachServerText()), findsOne);
      await teardownTree(tester);
    });

    testWidgets('follows the controller from previewing to ready', (
      tester,
    ) async {
      fake.stage = ReviewStage.previewing;
      await open(tester);
      fake.stage = ReviewStage.ready;
      fake.preview = readyPreview(['a']);
      fake.notify();
      await tester.pumpAndSettle();
      expect(target('a'), findsOne);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await teardownTree(tester);
    });
  });

  group('per-target verdicts', () {
    final cases = <PreviewVerdict, ({int? base, Map<String, dynamic> json})>{
      PreviewVerdict.unknownTrack: (
        base: 1,
        json: previewTargetJson('a', 1, unknown: true),
      ),
      PreviewVerdict.alreadyDeleted: (
        base: 1,
        json: previewTargetJson('a', 1, alreadyDeleted: true),
      ),
      PreviewVerdict.revisionUnknown: (
        base: null,
        json: previewTargetJson('a', 0, revision: 5),
      ),
      PreviewVerdict.conflict: (
        base: 1,
        json: previewTargetJson('a', 1, revision: 2, conflict: true),
      ),
      PreviewVerdict.busy: (base: 1, json: previewTargetJson('a', 1, busy: true)),
      PreviewVerdict.missingMaster: (
        base: 1,
        json: previewTargetJson('a', 1, missingMaster: true),
      ),
      PreviewVerdict.fileStatusUnknown: (
        base: 1,
        json: previewTargetJson('a', 1, fileUnchecked: true),
      ),
      PreviewVerdict.ready: (base: 1, json: previewTargetJson('a', 1)),
    };

    for (final e in cases.entries) {
      testWidgets('${e.key.name} shows its words, and Refresh only if it can', (
        tester,
      ) async {
        final preview = previewOf([(uuid: 'a', base: e.value.base, json: e.value.json)]);
        expect(preview.targets.single.verdict, e.key, reason: 'fixture');
        await openReady(tester, preview);

        expect(
          find.descendant(
            of: target('a'),
            matching: find.text(previewVerdictText(e.key)),
          ),
          findsOne,
        );
        final title = preview.targets.single.title;
        expect(
          find.descendant(
            of: target('a'),
            matching: find.text(title ?? 'Unknown track'),
          ),
          findsOne,
        );
        final refreshable =
            e.key == PreviewVerdict.conflict ||
            e.key == PreviewVerdict.revisionUnknown;
        expect(find.byKey(const Key('refresh-a')), refreshable ? findsOne : findsNothing);
        expect(find.byKey(const Key('remove-a')), findsOne);
        await teardownTree(tester);
      });
    }

    testWidgets('a file the server could not check gets its own line instead '
        'of "Ready to delete." (sign-off OPEN-8-07 row 2)', (tester) async {
      final preview = previewOf([
        (uuid: 'a', base: 1, json: previewTargetJson('a', 1, fileUnchecked: true)),
        ready('b'),
      ]);
      await openReady(tester, preview);

      expect(
        find.descendant(
          of: target('a'),
          matching: find.text(
            "The server can't check this file, so it may refuse to delete it.",
          ),
        ),
        findsOne,
      );
      expect(
        find.descendant(of: target('a'), matching: find.text('Ready to delete.')),
        findsNothing,
      );
      expect(
        find.descendant(of: target('b'), matching: find.text('Ready to delete.')),
        findsOne,
      );
      await teardownTree(tester);
    });

    testWidgets('a known artist is shown with the title', (tester) async {
      await openReady(tester, readyPreview(['a']));
      expect(
        find.descendant(of: target('a'), matching: find.text('Title a')),
        findsOne,
      );
      expect(
        find.descendant(of: target('a'), matching: find.textContaining('Artist')),
        findsWidgets,
      );
      await teardownTree(tester);
    });

    testWidgets('Refresh and Remove forward the target', (tester) async {
      final preview = previewOf([
        ready('b'),
        (
          uuid: 'a',
          base: 1,
          json: previewTargetJson('a', 1, revision: 2, conflict: true),
        ),
      ]);
      await openReady(tester, preview);
      await tester.tap(find.byKey(const Key('refresh-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('remove-b')));
      await tester.pumpAndSettle();
      expect(fake.calls, ['refreshTarget a', 'removeTarget b']);
      await teardownTree(tester);
    });
  });

  group('confirm button', () {
    testWidgets('is labelled with the count', (tester) async {
      await openReady(tester, readyPreview(['a', 'b']));
      expect(find.text('Delete 2 tracks…'), findsOne);
      expect(enabled(tester, _confirmButton), isTrue);
      await teardownTree(tester);
    });

    testWidgets('is labelled for one track', (tester) async {
      await openReady(tester, readyPreview(['a']));
      expect(find.text('Delete 1 track…'), findsOne);
      await teardownTree(tester);
    });

    testWidgets('is disabled with the reason when it cannot be confirmed', (
      tester,
    ) async {
      fake.canConfirm = false;
      fake.blockedReason = notConfirmableText(needsRefresh: false);
      await openReady(tester, readyPreview(['a']));
      expect(find.text(notConfirmableText(needsRefresh: false)), findsOne);
      expect(enabled(tester, _confirmButton), isFalse);
      await teardownTree(tester);
    });

    testWidgets('shows the controller message beside a ready preview', (
      tester,
    ) async {
      fake.message = awaitingAnswerText();
      await openReady(tester, readyPreview(['a']));
      expect(find.text(awaitingAnswerText()), findsOne);
      await teardownTree(tester);
    });
  });

  group('confirmation dialog', () {
    testWidgets('for several tracks has the exact title and every warning', (
      tester,
    ) async {
      final preview = previewOf([
        ready('a'),
        (uuid: 'b', base: 1, json: previewTargetJson('b', 1, missingMaster: true)),
      ]);
      await openReady(tester, preview);
      await openDialog(tester);

      expect(find.byKey(_dialog), findsOne);
      expect(
        find.descendant(
          of: find.byKey(_dialog),
          matching: find.text('Delete 2 tracks from the server permanently'),
        ),
        findsOne,
      );
      final text = dialogText(tester);
      expect(text, contains('Title a'));
      expect(text, contains('Title b'));
      // A device playing a downloaded copy reads nothing from the
      // server; it keeps its copy until its next sync applies the deletion.
      final lines = text.split('\n');
      expect(
        lines,
        contains(
          'This removes these tracks from the server. Each device removes '
          'its downloads of these tracks when it next syncs.',
        ),
      );
      expect(
        lines,
        contains(
          'This is different from removing a download from this device only.',
        ),
      );
      expect(
        lines,
        contains(
          'Tracks streaming on any device will stop at the next buffer refill.',
        ),
      );
      expect(lines, contains("This can't be undone."));
      expect(text, isNot(contains('downloads synced to your devices')));
      expect(text, isNot(contains('currently playing')));
      expect(text, contains('Remove missing-file catalog entry'));
      expect(find.byKey(_cancel), findsOne);
      expect(fake.calls, isEmpty, reason: 'opening the dialog sends nothing');
      await teardownTree(tester);
    });

    // A missing-file entry has no master file: the sentence about what is
    // removed must hold for it too.
    testWidgets(
      'a confirmation of missing-file entries only does not promise to remove '
      'master files',
      (tester) async {
        final preview = previewOf([
          (
            uuid: 'a',
            base: 1,
            json: previewTargetJson('a', 1, missingMaster: true),
          ),
          (
            uuid: 'b',
            base: 1,
            json: previewTargetJson('b', 1, missingMaster: true),
          ),
        ]);
        fake.canConfirm = true;
        await openReady(tester, preview);
        await openDialog(tester);
        final text = dialogText(tester);
        expect(text, contains('Remove missing-file catalog entry'));
        expect(text, isNot(contains('master files')));
        expect(
          text.split('\n'),
          contains(
            'This removes these tracks from the server. Each device removes '
            'its downloads of these tracks when it next syncs.',
          ),
        );
        expect(
          text.split('\n'),
          contains(
            'Tracks streaming on any device will stop at the next buffer '
            'refill.',
          ),
        );
        await teardownTree(tester);
      },
    );

    testWidgets('lists an unknown title as Unknown track', (tester) async {
      final preview = previewOf([
        (uuid: 'a', base: 1, json: {...previewTargetJson('a', 1), 'title': null}),
      ]);
      fake.canConfirm = true;
      await openReady(tester, preview);
      await openDialog(tester);
      expect(dialogText(tester), contains('Unknown track'));
      await teardownTree(tester);
    });

    // An empty title is not a blank line, in the review or in the
    // confirmation.
    testWidgets('lists an empty title as Unknown track', (tester) async {
      final preview = previewOf([
        (uuid: 'a', base: 1, json: {...previewTargetJson('a', 1), 'title': ''}),
      ]);
      fake.canConfirm = true;
      await openReady(tester, preview);
      expect(
        find.descendant(of: target('a'), matching: find.text('Unknown track')),
        findsOne,
      );
      await openDialog(tester);
      expect(dialogText(tester).split('\n'), contains('Unknown track'));
      expect(dialogText(tester).split('\n'), isNot(contains('')));
      await teardownTree(tester);
    });

    testWidgets('does not name a missing file for a ready track only', (
      tester,
    ) async {
      await openReady(tester, readyPreview(['a', 'b']));
      await openDialog(tester);
      expect(dialogText(tester), isNot(contains('Remove missing-file catalog entry')));
      await teardownTree(tester);
    });

    testWidgets('for one track has the singular title and no count field', (
      tester,
    ) async {
      await openReady(tester, readyPreview(['a']));
      await openDialog(tester);
      expect(
        find.descendant(
          of: find.byKey(_dialog),
          matching: find.text('Delete 1 track from the server permanently'),
        ),
        findsOne,
      );
      expect(find.byKey(_typed), findsNothing);
      expect(find.text('Delete 1 tracks from the server permanently'), findsNothing);
      expect(enabled(tester, _permanently), isTrue);
      await teardownTree(tester);
    });

    testWidgets('the typed count gates the confirm button', (tester) async {
      await openReady(tester, readyPreview(['a', 'b']));
      await openDialog(tester);
      expect(find.text('Type 2 to confirm'), findsOne);
      expect(enabled(tester, _permanently), isFalse, reason: 'empty');

      await tester.enterText(find.byKey(_typed), '3');
      await tester.pump();
      expect(enabled(tester, _permanently), isFalse, reason: '3');

      await tester.enterText(find.byKey(_typed), '2');
      await tester.pump();
      expect(enabled(tester, _permanently), isTrue, reason: '2');

      await tester.enterText(find.byKey(_typed), '');
      await tester.pump();
      expect(enabled(tester, _permanently), isFalse, reason: 'cleared');
      expect(fake.calls, isEmpty);
      await teardownTree(tester);
    });

    testWidgets('Cancel closes the dialog and sends no job', (tester) async {
      await openReady(tester, readyPreview(['a', 'b']));
      await openDialog(tester);
      await tester.enterText(find.byKey(_typed), '2');
      await tester.pump();
      await tester.tap(find.byKey(_cancel));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byType(DeletionReviewSheet), findsOne);
      expect(fake.calls.where((c) => c.startsWith('confirm')), isEmpty);
      expect(fake.confirmedShown, isNull);
      expect(result, isNull, reason: 'the review is still open');
      await teardownTree(tester);
    });

    // DR-B-01: only Cancel or the confirm button closes it (PopScope with
    // canPop false): Escape and the system back action leave it open.
    testWidgets('Escape and the back action leave the dialog open', (
      tester,
    ) async {
      await openReady(tester, readyPreview(['a', 'b']));
      await openDialog(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOne, reason: 'Escape');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOne, reason: 'back');
      expect(find.byType(DeletionReviewSheet), findsOne);
      expect(fake.calls.where((c) => c.startsWith('confirm')), isEmpty);
      expect(result, isNull);
      await teardownTree(tester);
    });

    testWidgets('confirming hands over the shown preview and the count', (
      tester,
    ) async {
      final preview = readyPreview(['a', 'b']);
      await openReady(tester, preview);
      await openDialog(tester);
      await tester.enterText(find.byKey(_typed), '2');
      await tester.pump();
      await tester.tap(find.byKey(_permanently));
      await tester.pumpAndSettle();

      expect(fake.calls, ['confirm 2']);
      expect(identical(fake.confirmedShown, preview), isTrue);
      expect(fake.confirmedCount, 2);
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byType(DeletionReviewSheet), findsNothing);
      expect(result, isTrue);
      await teardownTree(tester);
    });

    testWidgets('one track is confirmed without typing', (tester) async {
      final preview = readyPreview(['a']);
      await openReady(tester, preview);
      await openDialog(tester);
      await tester.tap(find.byKey(_permanently));
      await tester.pumpAndSettle();
      expect(fake.calls, ['confirm 1']);
      expect(identical(fake.confirmedShown, preview), isTrue);
      expect(result, isTrue);
      await teardownTree(tester);
    });

    testWidgets('confirms the preview that was shown, not a newer one', (
      tester,
    ) async {
      final shown = readyPreview(['a', 'b']);
      await openReady(tester, shown);
      await openDialog(tester);
      fake.preview = readyPreview(['a', 'b', 'c']);
      fake.notify();
      await tester.pump();
      await tester.enterText(find.byKey(_typed), '2');
      await tester.pump();
      await tester.tap(find.byKey(_permanently));
      await tester.pumpAndSettle();
      expect(fake.calls, ['confirm 2']);
      expect(identical(fake.confirmedShown, shown), isTrue);
      await teardownTree(tester);
    });

    testWidgets('a refused confirm keeps the sheet and says why', (
      tester,
    ) async {
      fake.confirmResult = false;
      fake.messageAfterConfirm = reviewOutOfDateText();
      await openReady(tester, readyPreview(['a']));
      await openDialog(tester);
      await tester.tap(find.byKey(_permanently));
      await tester.pumpAndSettle();
      expect(fake.calls, ['confirm 1']);
      expect(find.byKey(_dialog), findsNothing);
      expect(find.byType(DeletionReviewSheet), findsOne);
      expect(find.text(reviewOutOfDateText()), findsOne);
      expect(result, isNull);
      await teardownTree(tester);
    });

    testWidgets('a submit after the switch was turned off explains itself', (
      tester,
    ) async {
      fake.confirmResult = false;
      fake.messageAfterConfirm = confirmUnavailableText(
        DeleteJobsUnavailableReason.switchedOff,
      );
      await openReady(tester, readyPreview(['a']));
      await openDialog(tester);
      await tester.tap(find.byKey(_permanently));
      await tester.pumpAndSettle();
      expect(
        find.text(
          confirmUnavailableText(DeleteJobsUnavailableReason.switchedOff),
        ),
        findsOne,
      );
      expect(find.byType(DeletionReviewSheet), findsOne);
      await teardownTree(tester);
    });

    testWidgets('a 403 library_delete_disabled explains itself', (
      tester,
    ) async {
      fake.confirmResult = false;
      fake.messageAfterConfirm = deletionErrorText('library_delete_disabled');
      await openReady(tester, readyPreview(['a']));
      await openDialog(tester);
      await tester.tap(find.byKey(_permanently));
      await tester.pumpAndSettle();
      expect(find.text(deletionErrorText('library_delete_disabled')), findsOne);
      await teardownTree(tester);
    });
  });

  group('8-V01 narrow screen, large text, long names', () {
    testWidgets('sheet and dialog render and stay reachable', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final longTitle = 'An extremely long track title ' * 12;
      final preview = previewOf([
        (
          uuid: 'a',
          base: 1,
          json: {...previewTargetJson('a', 1), 'title': longTitle},
        ),
        (
          uuid: 'b',
          base: 1,
          json: {
            ...previewTargetJson('b', 1, missingMaster: true),
            'title': longTitle,
          },
        ),
      ]);
      await openReady(tester, preview, size: const Size(320, 640));
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.byKey(_confirmButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_confirmButton));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(_dialog), findsOne);

      await tester.ensureVisible(find.byKey(_typed));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(_typed), '2');
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.byKey(_cancel));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_cancel));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      expect(fake.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await teardownTree(tester);
    });
  });

  group('review r1', () {
    // R1-1: while the deletion is being handed over, the dialog cannot be
    // dismissed (a dismissal would look like Cancel while it is sent).
    testWidgets('the confirmation cannot be dismissed by tapping outside',
        (tester) async {
      await openReady(tester, readyPreview(['a']));
      await openDialog(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsOneWidget);
      expect(fake.calls, isEmpty);
      await tester.tap(find.byKey(_cancel));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      await teardownTree(tester);
    });

    // R1-4: look-alike copies show their album, and no ID, in the review
    // or in the confirmation (owner, 2026-11-17: "We should never reveal
    // track ids to users.").
    testWidgets('look-alike targets show their album and no ID in the '
        'review and in the confirmation', (tester) async {
      Map<String, dynamic> twin(String uuid) => {
        ...previewTargetJson(uuid, 1),
        'title': 'Same',
        'artist': 'Artist',
        'album': 'Record',
      };
      const a = 'aaaa1111-0000-4000-8000-000000000001';
      const b = 'bbbb2222-0000-4000-8000-000000000002';
      await openReady(
        tester,
        previewOf([
          (uuid: a, base: 1, json: twin(a)),
          (uuid: b, base: 1, json: twin(b)),
          ready('c'),
        ]),
      );
      for (final u in [a, b]) {
        expect(
          find.descendant(of: target(u), matching: find.textContaining('Record')),
          findsWidgets,
        );
        expect(
          find.descendant(of: target(u), matching: find.text('Same')),
          findsOneWidget,
        );
      }
      expect(find.textContaining('ID '), findsNothing);
      expect(find.textContaining('aaaa1111'), findsNothing);
      expect(find.textContaining('bbbb2222'), findsNothing);
      await openDialog(tester);
      final text = dialogText(tester);
      expect(text, isNot(contains('ID ')));
      expect(text, isNot(contains('aaaa1111')));
      expect(text, isNot(contains('bbbb2222')));
      expect(text, contains('Record'));
      expect('Same'.allMatches(text).length, 2);
      await teardownTree(tester);
    });

    // R1 nit: after a review goes out of date or fails, it can be asked
    // again from the sheet.
    for (final stage in [ReviewStage.idle, ReviewStage.failed]) {
      testWidgets('Review again from ${stage.name}', (tester) async {
        fake.stage = stage;
        fake.message = reviewOutOfDateText();
        await open(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Review again'));
        await tester.pump();
        expect(fake.calls, ['requestPreview']);
        await teardownTree(tester);
      });
    }
  });

  testWidgets('a review that empties while its confirmation is open closes '
      'both, and nothing is confirmed', (tester) async {
    // As in the app: the sheet opens on a nested navigator (the session
    // navigator, SessionHost), the confirmation on the root one.
    fake.stage = ReviewStage.ready;
    fake.preview = readyPreview(['a']);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    result = await showDeletionReview(context, fake),
                child: const Text('open review'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open review'));
    await tester.pumpAndSettle();
    await openDialog(tester);
    expect(find.byKey(_dialog), findsOneWidget);
    fake
      ..stage = ReviewStage.idle
      ..preview = null
      ..nothingToReview = true
      ..notify();
    await tester.pumpAndSettle();
    expect(find.byKey(_dialog), findsNothing);
    expect(find.byType(DeletionReviewSheet), findsNothing);
    expect(find.text('open review'), findsOneWidget);
    expect(result, isFalse);
    expect(fake.calls, isEmpty);
    await teardownTree(tester);
  });

  testWidgets('on one navigator too, a review that empties under its '
      'confirmation closes both', (tester) async {
    await openReady(tester, readyPreview(['a']));
    await openDialog(tester);
    fake
      ..stage = ReviewStage.idle
      ..preview = null
      ..nothingToReview = true
      ..notify();
    await tester.pumpAndSettle();
    expect(find.byKey(_dialog), findsNothing);
    expect(find.byType(DeletionReviewSheet), findsNothing);
    expect(find.text('open review'), findsOneWidget);
    expect(result, isFalse);
    expect(fake.calls, isEmpty);
    await teardownTree(tester);
  });

  testWidgets('removing the last target closes the sheet', (tester) async {
    final c = ProviderContainer(
      overrides: [
        deleteJobsManagerProvider.overrideWithValue(_PreviewOnly()),
        trackSyncProvider.overrideWith(RunOnceTrackSync.new),
      ],
    );
    addTearDown(c.dispose);
    c.listen(trackSyncProvider, (_, _) {});
    final sel = FakeTrackSelectionControls()..select('a', baseRevision: 1);
    addTearDown(sel.dispose);
    final review = c.read(deletionReviewControllerFactoryProvider)(sel);
    addTearDown(review.dispose);
    await review.requestPreview();
    expect(review.stage, ReviewStage.ready);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await showDeletionReview(context, review),
              child: const Text('open review'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open review'));
    await tester.pumpAndSettle();
    expect(target('a'), findsOneWidget);

    await tester.tap(find.byKey(const Key('remove-a')));
    await tester.pumpAndSettle();
    expect(find.byType(DeletionReviewSheet), findsNothing);
    expect(find.byKey(const Key('review-again')), findsNothing);
    expect(result, isFalse);
    await teardownTree(tester);
  });
}

/// A delete-jobs model that only answers previews: every target is live at
/// the revision sent.
class _PreviewOnly implements DeleteJobsManager {
  final _jobs = ValueNotifier<Map<String, DeleteJob>>(const {});

  @override
  ValueListenable<Map<String, DeleteJob>> get jobs => _jobs;

  @override
  bool awaitingAnswer(Iterable<String> uuids) => false;

  @override
  Future<DeletionPreview> preview(List<DeletionCandidate> candidates) async =>
      DeletionPreview.fromServer(
        candidates,
        DeletionPreviewDto.fromJson({
          'targets': [
            for (final c in candidates)
              previewTargetJson(c.uuid, c.baseRevision ?? 0),
          ],
        }),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
