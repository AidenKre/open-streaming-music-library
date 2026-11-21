// Phase 8 spec §6 paras 2-3, review 8-V01 (8B.1c, S9): Deletion history shows
// jobs (partial results, each reason) and receipts, and forwards every input
// to ManageLibraryControls (SC-26).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/deletion_text.dart';
import 'package:frontend/ui/manage_library/delete_jobs_view.dart';
import 'package:frontend/ui/manage_library/manage_library_controller.dart';

import '../browse_harness.dart' show teardownTree;
import 'fake_manage_library_controls.dart';

void main() {
  late FakeManageLibraryControls fake;

  setUp(() => fake = FakeManageLibraryControls());
  tearDown(() {
    fake.fakeSelection.dispose();
    fake.fakeReview.dispose();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: DeleteJobsPage(controls: fake)),
    );
    await tester.pump();
  }

  Finder job(String op) => find.byKey(Key('job-$op'));
  Finder jobTarget(String op, String uuid) =>
      find.byKey(Key('job-target-$op-$uuid'));
  Finder receipt(String op) => find.byKey(Key('receipt-$op'));

  ReceiptView receiptView(String op, String status, int n) => ReceiptView(
    operationUuid: op,
    createdAt: 1000,
    statusText: status,
    itemCount: n,
  );

  testWidgets('has its title and loads receipts on open', (tester) async {
    await pumpPage(tester);
    expect(find.text('Deletion history'), findsOne);
    expect(fake.calls, ['loadReceipts']);
    await teardownTree(tester);
  });

  group('jobs', () {
    testWidgets('a partial job shows each target with its own reason', (
      tester,
    ) async {
      fake.jobs = [
        DeleteJobView(
          operationUuid: 'op1',
          phase: DeleteJobPhase.partial,
          phaseText: jobPhaseText(DeleteJobPhase.partial),
          targets: const [
            JobTargetView(
              uuid: 'a',
              title: 'First Song',
              artist: 'Artist',
              outcome: 'Deleted; storage cleanup pending',
              deleted: true,
            ),
            JobTargetView(
              uuid: 'b',
              title: 'Second Song',
              artist: 'Artist',
              outcome: 'Not deleted: the track changed after you selected it',
              deleted: false,
            ),
          ],
        ),
      ];
      await pumpPage(tester);
      expect(
        find.descendant(
          of: job('op1'),
          matching: find.text(jobPhaseText(DeleteJobPhase.partial)),
        ),
        findsOne,
      );
      expect(
        find.descendant(
          of: jobTarget('op1', 'a'),
          matching: find.text('First Song'),
        ),
        findsOne,
      );
      expect(
        find.descendant(
          of: jobTarget('op1', 'a'),
          matching: find.text('Deleted; storage cleanup pending'),
        ),
        findsOne,
      );
      expect(
        find.descendant(
          of: jobTarget('op1', 'b'),
          matching: find.text('Second Song'),
        ),
        findsOne,
      );
      expect(
        find.descendant(
          of: jobTarget('op1', 'b'),
          matching: find.text(
            'Not deleted: the track changed after you selected it',
          ),
        ),
        findsOne,
      );
      await teardownTree(tester);
    });

    testWidgets('an unknown title reads Unknown track, and no ID', (
      tester,
    ) async {
      fake.jobs = [
        DeleteJobView(
          operationUuid: 'op1',
          phase: DeleteJobPhase.completed,
          phaseText: jobPhaseText(DeleteJobPhase.completed),
          targets: const [
            JobTargetView(
              uuid: 'a',
              title: null,
              artist: null,
              outcome: 'Deleted',
              deleted: true,
            ),
          ],
        ),
      ];
      await pumpPage(tester);
      final row = jobTarget('op1', 'a');
      expect(
        find.descendant(of: row, matching: find.text('Unknown track')),
        findsOne,
      );
      expect(
        find.descendant(of: row, matching: find.textContaining('ID ')),
        findsNothing,
      );
      expect(find.descendant(of: row, matching: find.text('Deleted')), findsOne);
      await teardownTree(tester);
    });

    // An empty title is not a blank line.
    testWidgets('an empty title reads Unknown track', (tester) async {
      fake.jobs = [
        DeleteJobView(
          operationUuid: 'op1',
          phase: DeleteJobPhase.completed,
          phaseText: jobPhaseText(DeleteJobPhase.completed),
          targets: const [
            JobTargetView(
              uuid: 'a',
              title: '',
              artist: 'Artist',
              outcome: 'Deleted',
              deleted: true,
            ),
          ],
        ),
      ];
      await pumpPage(tester);
      final row = jobTarget('op1', 'a');
      expect(
        find.descendant(of: row, matching: find.text('Unknown track')),
        findsOne,
      );
      expect(find.descendant(of: row, matching: find.text('')), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a rejected job shows its refusal', (tester) async {
      final refusal = deletionErrorText('library_delete_disabled');
      fake.jobs = [
        DeleteJobView(
          operationUuid: 'op1',
          phase: DeleteJobPhase.rejected,
          phaseText: jobPhaseText(DeleteJobPhase.rejected),
          refusal: refusal,
          targets: const [
            JobTargetView(
              uuid: 'a',
              title: 'First Song',
              artist: null,
              outcome: 'The server refused the request',
              deleted: false,
            ),
          ],
        ),
      ];
      await pumpPage(tester);
      expect(
        find.descendant(of: job('op1'), matching: find.text(refusal)),
        findsOne,
      );
      expect(
        find.descendant(
          of: job('op1'),
          matching: find.text(jobPhaseText(DeleteJobPhase.rejected)),
        ),
        findsOne,
      );
      await teardownTree(tester);
    });

    testWidgets('an unconfirmed job says the answer is unknown', (tester) async {
      fake.jobs = [
        DeleteJobView(
          operationUuid: 'op1',
          phase: DeleteJobPhase.unconfirmed,
          phaseText: jobPhaseText(DeleteJobPhase.unconfirmed),
          targets: const [
            JobTargetView(
              uuid: 'a',
              title: 'First Song',
              artist: null,
              outcome: 'Checking',
              deleted: false,
            ),
          ],
        ),
      ];
      await pumpPage(tester);
      expect(
        find.descendant(
          of: job('op1'),
          matching: find.text(jobPhaseText(DeleteJobPhase.unconfirmed)),
        ),
        findsOne,
      );
      expect(find.text('Deleted'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a job without a refusal shows none', (tester) async {
      fake.jobs = [
        DeleteJobView(
          operationUuid: 'op1',
          phase: DeleteJobPhase.running,
          phaseText: jobPhaseText(DeleteJobPhase.running),
          targets: const [],
        ),
      ];
      await pumpPage(tester);
      expect(find.text(deletionErrorText('library_delete_disabled')), findsNothing);
      expect(find.text(deletionErrorText(null)), findsNothing);
      await teardownTree(tester);
    });
  });

  group('receipts', () {
    testWidgets('rows show status and track count; tap opens the receipt', (
      tester,
    ) async {
      fake.receiptsLoad = ReceiptsLoad.loaded;
      fake.receipts = [
        receiptView('r1', receiptStatusText('succeeded'), 2),
        receiptView('r2', receiptStatusText('failed'), 1),
      ];
      await pumpPage(tester);
      expect(
        find.descendant(
          of: receipt('r1'),
          matching: find.text(receiptStatusText('succeeded')),
        ),
        findsOne,
      );
      expect(
        find.descendant(of: receipt('r1'), matching: find.text('2 tracks')),
        findsOne,
      );
      expect(
        find.descendant(of: receipt('r2'), matching: find.text('1 track')),
        findsOne,
      );

      await tester.tap(receipt('r1'));
      await tester.pump();
      expect(fake.calls, ['loadReceipts', 'openReceipt r1']);
      await teardownTree(tester);
    });

    testWidgets('Load more appears only when there are more', (tester) async {
      fake.receiptsLoad = ReceiptsLoad.loaded;
      fake.receipts = [receiptView('r1', 'Finished', 2)];
      await pumpPage(tester);
      expect(find.text('Load more'), findsNothing);

      fake.hasMoreReceipts = true;
      fake.notify();
      await tester.pump();
      expect(find.text('Load more'), findsOne);
      await tester.tap(find.text('Load more'));
      await tester.pump();
      expect(fake.calls, ['loadReceipts', 'loadMoreReceipts']);
      await teardownTree(tester);
    });

    testWidgets('a failed first load says so and Retry loads again', (
      tester,
    ) async {
      fake.receiptsLoad = ReceiptsLoad.failed;
      await pumpPage(tester);
      expect(find.textContaining("Couldn't load"), findsOne);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      // B-06: Retry repeats the failed request (the controller knows which).
      expect(fake.calls, ['loadReceipts', 'retryReceipts']);
      await teardownTree(tester);
    });

    testWidgets('a failed later page keeps the rows and Retry repeats it', (
      tester,
    ) async {
      fake.receiptsLoad = ReceiptsLoad.failed;
      fake.receipts = [receiptView('r1', 'Finished', 2)];
      fake.hasMoreReceipts = true;
      await pumpPage(tester);
      expect(receipt('r1'), findsOne);
      expect(find.textContaining("Couldn't load"), findsOne);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(fake.calls, ['loadReceipts', 'retryReceipts']);
      await teardownTree(tester);
    });

    testWidgets('loading shows a progress indicator', (tester) async {
      fake.receiptsLoad = ReceiptsLoad.loading;
      await pumpPage(tester);
      expect(find.byType(CircularProgressIndicator), findsOne);
      expect(find.textContaining("Couldn't load"), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('no failure text and no spinner once loaded', (tester) async {
      fake.receiptsLoad = ReceiptsLoad.loaded;
      fake.receipts = [receiptView('r1', 'Finished', 2)];
      await pumpPage(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Retry'), findsNothing);
      await teardownTree(tester);
    });

    // 8-R1-22 / U33-B-02: offline or with the binding unverified the page
    // says so with Retry instead of spinning.
    testWidgets('needs a connection: says so, with Retry, no spinner', (
      tester,
    ) async {
      fake.receiptsLoad = ReceiptsLoad.needsConnection;
      await pumpPage(tester);
      expect(find.text('Deletion history needs a connection.'), findsOne);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('No deletions yet.'), findsNothing);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(fake.calls, ['loadReceipts', 'retryReceipts']);
      await teardownTree(tester);
    });

    // Refactor APP-DUP (section 6 #11): the controller's reason.
    testWidgets('needs a connection says the controller\'s reason', (
      tester,
    ) async {
      fake.receiptsLoad = ReceiptsLoad.needsConnection;
      fake.receiptsUnreachableText = 'Reason words.';
      await pumpPage(tester);
      expect(find.text('Reason words.'), findsOne);
      expect(find.text('Deletion history needs a connection.'), findsNothing);
      await teardownTree(tester);
    });

    // Where Retry cannot help (a different server, signed out),
    // the reason shows without a Retry.
    testWidgets('a reason Retry cannot help: the reason, no Retry', (
      tester,
    ) async {
      fake.receiptsLoad = ReceiptsLoad.needsConnection;
      fake.receiptsUnreachableText = 'Reason words.';
      fake.receiptsRetryHelps = false;
      await pumpPage(tester);
      expect(find.text('Reason words.'), findsOne);
      expect(find.text('Retry'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('loaded with nothing in it says so; never while loading, '
        'failed or disconnected', (tester) async {
      fake.receiptsLoad = ReceiptsLoad.loaded;
      await pumpPage(tester);
      expect(find.text('No deletions yet.'), findsOne);
      for (final state in [
        ReceiptsLoad.loading,
        ReceiptsLoad.failed,
        ReceiptsLoad.needsConnection,
        ReceiptsLoad.idle,
      ]) {
        fake.receiptsLoad = state;
        fake.notify();
        await tester.pump();
        expect(find.text('No deletions yet.'), findsNothing, reason: '$state');
      }
      await teardownTree(tester);
    });
  });
}
