// Possible duplicates: what the person sees when the open deletion review
// can no longer go on. The review's Refresh adopts the server's newer
// revision of the tapped copy, so the review is dropped (the copy's lines
// are the row's, no longer the server's); the sheet then has nothing left
// to review: it closes, and the page's message says why.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';
import 'package:frontend/ui/duplicates/duplicates_page.dart';
import 'package:frontend/ui/manage_library/deletion_review_sheet.dart';

import '../../helpers/delete_jobs_harness.dart';
import '../../helpers/duplicate_fixtures.dart';
import '../browse_harness.dart' show teardownTree;
import 'duplicates_test_support.dart';

void main() {
  testWidgets('Refresh to a changed copy closes the review; the page says '
      'the pair changed', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = DupHarness();
    h.pages['open']![null] = dupPage([
      dupPair(
        'a1',
        'b1',
        trackA: dupTrack('a1', revision: 3),
        trackB: dupTrack('b1', revision: 7),
      ),
    ]);
    late DeleteJobsHarness jobs;
    await tester.runAsync(() async {
      jobs = await DeleteJobsHarness.create();
      await jobs.verify();
      await h.open(
        extra: [deleteJobsManagerProvider.overrideWithValue(jobs.manager)],
      );
      await jobs.pump();
    });
    // The server's copy moved on: the preview says conflict.
    jobs.api.onPreview = (targets) async => DeletionPreviewDto.fromJson({
      'targets': [previewTargetJson('b1', 7, revision: 9, conflict: true)],
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: ProviderScope(
          overrides: [
            duplicatesControllerFactoryProvider.overrideWithValue(() => h.dup),
          ],
          child: const MaterialApp(home: DuplicatesPage()),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('delete-b1')));
    await tester.pump();
    await tester.runAsync(() => jobs.pump());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('refresh-b1')), findsOneWidget);

    jobs.api.onPreview = (targets) async => DeletionPreviewDto.fromJson({
      'targets': [previewTargetJson('b1', targets.single.baseRevision)],
    });
    await tester.tap(find.byKey(const Key('refresh-b1')));
    await tester.pump();
    await tester.runAsync(() => jobs.pump());
    await tester.pumpAndSettle();

    expect(find.byType(DeletionReviewSheet), findsNothing);
    expect(find.byKey(const Key('review-again')), findsNothing);
    expect(
      find.text(
        'This pair changed while you were reviewing it. Nothing was deleted.',
      ),
      findsOneWidget,
    );
    expect(jobs.api.createBodies, isEmpty);

    await teardownTree(tester);
    await tester.runAsync(() async {
      h.dispose();
      await jobs.dispose();
    });
  });
}
