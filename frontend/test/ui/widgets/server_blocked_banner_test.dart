// SC-01 rule 1 (blocked: different server): a persistent banner offers
// Reset (keep the URL, bind to the server there) or Disconnect, each behind
// a confirmation that names what will be lost (SC-15).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/widgets/server_blocked_banner.dart';

import '../fake_session_controls.dart';

void main() {
  Future<FakeSessionControls> pump(
    WidgetTester tester, {
    bool blocked = true,
  }) async {
    final fake = FakeSessionControls()
      ..serverBlocked = blocked
      ..lossSummaries = ['2 unsent metadata edits'];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionControlsProvider.overrideWithValue(fake)],
        child: const MaterialApp(
          home: Scaffold(body: Column(children: [ServerBlockedBanner()])),
        ),
      ),
    );
    await tester.pump();
    return fake;
  }

  testWidgets('hidden while the session is not blocked', (tester) async {
    await pump(tester, blocked: false);
    expect(find.textContaining('Different server'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Reset'), findsNothing);
  });

  testWidgets('appears when the controller reports the block', (tester) async {
    final fake = await pump(tester, blocked: false);
    fake.setBlocked(true);
    await tester.pump();
    expect(find.textContaining('Different server'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Reset'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Disconnect'), findsOneWidget);
  });

  testWidgets('Reset asks first, naming what will be lost; confirm resets',
      (tester) async {
    final fake = await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Reset'));
    await tester.pumpAndSettle();
    expect(find.text('Reset for this server?'), findsOneWidget);
    expect(find.textContaining('2 unsent metadata edits'), findsOneWidget);
    await tester.tap(find.text('Reset and reconnect'));
    await tester.pumpAndSettle();
    expect(fake.calls, ['resetBlockedServer']);
  });

  testWidgets('cancelling the Reset confirmation does nothing', (tester) async {
    final fake = await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Reset'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fake.calls, isEmpty);
    expect(find.textContaining('Different server'), findsOneWidget);
  });

  testWidgets('Disconnect asks first, naming what will be lost', (
    tester,
  ) async {
    final fake = await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Disconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Reset and disconnect?'), findsOneWidget);
    expect(find.textContaining('2 unsent metadata edits'), findsOneWidget);
    await tester.tap(find.text('Reset and disconnect'));
    await tester.pumpAndSettle();
    expect(fake.calls, ['disconnect']);
  });
}
