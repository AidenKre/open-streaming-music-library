// Phase 6B.3a (SC-10): NewActivityNotice is a view. Its copy and its
// onRefresh come from the surface (See all "History changed — Refresh",
// the Home rail's "New activity", Phase 7's "More items ready").
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/feed/new_activity_notice.dart';

import '../browse_harness.dart' show teardownTree;

void main() {
  Future<void> pump(WidgetTester tester, Widget notice,
      {double width = 400, double textScale = 1}) =>
      tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 600),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(width: width, child: notice),
            ),
          ),
        ),
      ));

  testWidgets('shows the surface copy and refreshes from its action',
      (tester) async {
    var refreshes = 0;
    await pump(
      tester,
      NewActivityNotice(
        message: 'History changed',
        actionLabel: 'Refresh',
        onRefresh: () => refreshes++,
      ),
    );
    expect(find.text('History changed'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('New activity'), findsNothing, reason: 'no built-in copy');

    await tester.tap(find.text('Refresh'));
    await tester.pump();
    expect(refreshes, 1);
    await teardownTree(tester);
  });

  testWidgets('different surfaces inject different copy', (tester) async {
    await pump(
      tester,
      NewActivityNotice(
        message: 'More items ready',
        actionLabel: 'Reload',
        onRefresh: () {},
      ),
    );
    expect(find.text('More items ready'), findsOneWidget);
    expect(find.text('Reload'), findsOneWidget);
    expect(find.text('Refresh'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('without an action label the whole notice is the button',
      (tester) async {
    var refreshes = 0;
    await pump(
      tester,
      NewActivityNotice(message: 'New activity', onRefresh: () => refreshes++),
    );
    await tester.tap(find.text('New activity'));
    await tester.pump();
    expect(refreshes, 1);
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.bySemanticsLabel('New activity')),
      isSemantics(isButton: true, hasTapAction: true, isLiveRegion: true),
    );
    handle.dispose();
    await teardownTree(tester);
  });

  testWidgets('is announced as a live region with a labelled button',
      (tester) async {
    final handle = tester.ensureSemantics();
    var refreshes = 0;
    await pump(
      tester,
      NewActivityNotice(
        message: 'New activity',
        actionLabel: 'Refresh',
        onRefresh: () => refreshes++,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel(RegExp('New activity'))),
      isSemantics(isLiveRegion: true),
    );
    final button = find.bySemanticsLabel('Refresh');
    expect(
      tester.getSemantics(button),
      isSemantics(isButton: true, hasTapAction: true),
    );
    tester.semantics.tap(find.semantics.byLabel('Refresh'));
    await tester.pump();
    expect(refreshes, 1);
    handle.dispose();
    await teardownTree(tester);
  });

  testWidgets('fits a narrow window at text scale 2', (tester) async {
    await pump(
      tester,
      NewActivityNotice(
        message: 'New listening activity',
        actionLabel: 'Refresh',
        onRefresh: () {},
      ),
      width: 280,
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Refresh'), findsOneWidget);
    await teardownTree(tester);
  });
}
