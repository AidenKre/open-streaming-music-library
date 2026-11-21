// SC-01 rule 1 (blocked: different server): a persistent banner offers
// Reset (keep the URL, bind to the server there) or Disconnect, each behind
// a confirmation that names what will be lost (SC-15).
import 'dart:async';

import 'package:frontend/services/session_service.dart' show ServerBlockedReason;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/logout_losses.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/widgets/server_blocked_banner.dart';

import '../browse_harness.dart' show teardownTree;
import '../fake_session_controls.dart';

void main() {
  Future<FakeSessionControls> pump(
    WidgetTester tester, {
    bool blocked = true,
  }) async {
    final fake = FakeSessionControls()
      ..serverBlocked = blocked
          ? ServerBlockedReason.differentServer
          : ServerBlockedReason.none
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
    fake.setBlocked(ServerBlockedReason.differentServer);
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

  // One sheet per tap. A second tap on either button while the
  // losses are read does nothing; once the sheet is closed, a tap asks
  // again.
  for (final (first, second) in [
    ('Reset', 'Reset'),
    ('Disconnect', 'Disconnect'),
    ('Reset', 'Disconnect'),
  ]) {
    testWidgets('$first, then $second while the losses are read: one sheet',
        (tester) async {
      final fake = await pump(tester);
      final gate = Completer<List<String>>();
      fake.lossSummariesGate = gate;
      await tester.tap(find.widgetWithText(TextButton, first));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, second));
      await tester.pump();
      gate.complete(['2 unsent metadata edits']);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(fake.lossSummaryReads, 1);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(fake.calls, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, second));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget,
          reason: 'the guard is released once the sheet closes');
      await teardownTree(tester);
    });
  }

  // Phase M §7.7 (M-U24): a 401 signed the session out. The banner says so;
  // its action is Log in, which performs logout first (user decision), so
  // the rebuilt scope opens at Log in with the local data kept.
  group('signed out', () {
    Future<FakeSessionControls> pumpSignedOut(WidgetTester tester) async {
      final fake = await pump(tester, blocked: false);
      fake.setBlocked(ServerBlockedReason.signedOut);
      await tester.pump();
      return fake;
    }

    testWidgets('says signed out and offers Log in, not Reset/Disconnect',
        (tester) async {
      await pumpSignedOut(tester);
      expect(find.textContaining('Signed out'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Log in'), findsOneWidget);
      expect(find.textContaining('Different server'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Reset'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Disconnect'), findsNothing);
    });

    testWidgets("the banner's Log in performs logout", (tester) async {
      final fake = await pumpSignedOut(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Log in'));
      await tester.pumpAndSettle();
      // Round 3: a log-out that keeps the unsent changes.
      expect(fake.calls, ['logout keep']);
    });

    // signoff-8-logout-warning round 3 (user 2026-11-14): after an ended
    // session there is nothing to choose, so no sheet: Log in logs out
    // keeping the unsent uploads and deletions for the same user's next
    // login (where they continue).
    testWidgets('with unsent changes: no sheet; they are kept', (tester) async {
      final fake = await pumpSignedOut(tester);
      fake.logoutLosses = const LogoutLosses(
        unsentUploads: 2,
        reviewDrafts: 1,
        unsentReviews: 0,
        unsentCancels: 1,
        unsentDeletions: 1,
        unconfirmedDeletions: 3,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Log in'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(fake.calls, ['logout keep']);
      await teardownTree(tester);
    });

    testWidgets('different server wins: its banner, not the signed-out one',
        (tester) async {
      final fake = await pumpSignedOut(tester);
      fake.setBlocked(ServerBlockedReason.differentServer);
      await tester.pump();
      expect(find.textContaining('Different server'), findsOneWidget);
      expect(find.textContaining('Signed out'), findsNothing);
    });
  });
}
