// 8B.3 S6: the review sheet and its confirmation can name a copy by more
// than its title (Possible duplicates' "Delete this copy").
//  * Brief: "It names the copy unmistakably in the confirmation (the
//    differing fields, the file's format and bitrate, where it is a known
//    value)." Two copies of a pair usually share title, artist and album.
//  * The lines belong to one target: they are shown only beside the target
//    whose uuid they were given for.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';
import 'package:frontend/ui/manage_library/deletion_review_sheet.dart';

import '../../helpers/fake_library_tools_api.dart';
import '../browse_harness.dart' show teardownTree;
import 'fake_manage_library_controls.dart';

DeletionPreview _preview(String uuid) => DeletionPreview.fromServer(
  [DeletionCandidate(uuid, 1)],
  DeletionPreviewDto.fromJson({
    'targets': [previewTargetJson(uuid, 1)],
  }),
);

void main() {
  late FakeDeletionReviewControls fake;

  setUp(() => fake = FakeDeletionReviewControls());
  tearDown(() => fake.dispose());

  Future<void> open(
    WidgetTester tester,
    String uuid, {
    Map<String, List<String>> details = const {},
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    fake.stage = ReviewStage.ready;
    fake.preview = _preview(uuid);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showDeletionReview(context, fake, details: details),
              child: const Text('open review'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open review'));
    await tester.pumpAndSettle();
  }

  Finder inDialog(String text) => find.descendant(
    of: find.byKey(const Key('deletion-confirmation')),
    matching: find.text(text),
  );

  Finder inTarget(String uuid, String text) => find.descendant(
    of: find.byKey(Key('review-target-$uuid')),
    matching: find.text(text),
  );

  testWidgets('the copy is named by its lines in the sheet and in the '
      'confirmation', (tester) async {
    await open(
      tester,
      'b1',
      details: {
        'b1': ['Format: MP3', 'Bitrate: 320 kbps'],
      },
    );
    expect(inTarget('b1', 'Format: MP3'), findsOne);
    expect(inTarget('b1', 'Bitrate: 320 kbps'), findsOne);
    await tester.tap(find.byKey(const Key('confirm-deletion')));
    await tester.pumpAndSettle();
    expect(inDialog('Format: MP3'), findsOne);
    expect(inDialog('Bitrate: 320 kbps'), findsOne);
    await tester.tap(find.byKey(const Key('cancel-deletion')));
    await tester.pumpAndSettle();
    await teardownTree(tester);
  });

  testWidgets('lines given for another uuid are never shown', (tester) async {
    await open(
      tester,
      'b1',
      details: {
        'a1': ['Format: FLAC'],
      },
    );
    expect(find.text('Format: FLAC'), findsNothing);
    await tester.tap(find.byKey(const Key('confirm-deletion')));
    await tester.pumpAndSettle();
    expect(find.text('Format: FLAC'), findsNothing);
    await tester.tap(find.byKey(const Key('cancel-deletion')));
    await tester.pumpAndSettle();
    await teardownTree(tester);
  });

  testWidgets('without lines the sheet reads as before', (tester) async {
    await open(tester, 'b1');
    expect(find.textContaining('Format:'), findsNothing);
    await teardownTree(tester);
  });
}
