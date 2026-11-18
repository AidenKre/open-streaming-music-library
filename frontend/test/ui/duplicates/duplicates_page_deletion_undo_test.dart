// 8B.3 review r1 (`phase-8/8B.3-review.md`): page halves of the findings.
//  * #2: the outcome of a copy's deletion job is shown on its pair.
//  * #3: while a copy of the pair is being (or was) deleted, neither copy
//    offers "Delete this copy".
//  * #5: Undo is offered only when the row was actually set aside.
//  * #6: the Undo snackbar belongs to the page: it does not outlive it.
//  * #9: each copy shows its short id (as the confirmation names it).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';
import 'package:frontend/ui/duplicates/duplicates_page.dart';

import '../../helpers/duplicate_fixtures.dart';
import '../browse_harness.dart' show teardownTree;
import 'fake_duplicates_controls.dart';

void main() {
  late FakeDuplicatesControls fake;
  final pair = pairView(dupPair('0123456789ab', 'fedcba987654'));
  const key = '0123456789ab|fedcba987654';

  setUp(() {
    fake = FakeDuplicatesControls()..pairs = [pair];
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          duplicatesControllerFactoryProvider.overrideWithValue(() => fake),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const DuplicatesPage()),
                ),
                child: const Text('open duplicates'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open duplicates'));
    await tester.pumpAndSettle();
  }

  Finder inRow(Finder f) =>
      find.descendant(of: find.byKey(const Key('pair-$key')), matching: f);

  testWidgets('#2 #3 a pair with a deletion shows its outcome and no Delete',
      (tester) async {
    fake.canDeleteCopy = true;
    fake.deleteStatuses[key] = 'Not deleted: the server was working on it';
    fake.blocked.add(key);
    await open(tester);
    expect(inRow(find.text('Not deleted: the server was working on it')), findsOne);
    expect(find.text('Delete this copy'), findsNothing);
    fake.blocked.clear();
    fake.notify();
    await tester.pump();
    expect(find.text('Delete this copy'), findsNWidgets(2));
    await teardownTree(tester);
  });

  testWidgets('#5 no Undo when the row was not set aside', (tester) async {
    fake.setAsideResult = false;
    await open(tester);
    await tester.tap(find.byKey(const Key('aside-$key')));
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('#6 the Undo snackbar does not outlive the page', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('aside-$key')));
    await tester.pump();
    expect(find.text('Marked as not duplicates'), findsOne);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Marked as not duplicates'), findsNothing);
    expect(find.text('Undo'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('#9 each copy shows its short id', (tester) async {
    await open(tester);
    expect(inRow(find.text('ID 01234567')), findsOne);
    expect(inRow(find.text('ID fedcba98')), findsOne);
    await teardownTree(tester);
  });
}
