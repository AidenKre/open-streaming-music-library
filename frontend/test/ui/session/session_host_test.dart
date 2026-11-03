import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:drift/native.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/conversions_page.dart';
import 'package:frontend/ui/downloading_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/settings_page.dart';

import 'package:frontend/ui/session_controller.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';

/// SC-08: session-level destinations are pushed above the shell by the
/// session host, from anywhere below it (including nested tab navigators).
void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.init('');
    initCoverArtCache(CoverArtCacheManager.noop());
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext nested;
    await tester.pumpWidget(
      harness.wrap(
        SessionHost(
          // A nested navigator stands in for a shell tab.
          root: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) {
                nested = context;
                return const Scaffold(body: Text('shell'));
              },
            ),
          ),
        ),
      ),
    );
    return nested;
  }

  for (final (dest, page) in [
    (SessionDestination.settings, SettingsPage),
    (SessionDestination.downloadProgress, DownloadingPage),
    (SessionDestination.conversions, ConversionsPage),
  ]) {
    testWidgets('openSession($dest) covers the shell, back returns', (
      tester,
    ) async {
      final ctx = await pumpHost(tester);
      openSession(ctx, dest);
      await tester.pumpAndSettle();
      expect(find.byType(page), findsOneWidget);
      // The shell's tab navigator did not get the route: it sits above it.
      expect(find.text('shell', skipOffstage: false), findsOneWidget);
      expect(find.text('shell'), findsNothing);
      // System back pops the session destination first.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(page), findsNothing);
      expect(find.text('shell'), findsOneWidget);
      await teardownTree(tester);
    });
  }

  // 4A.4 back dispatch (phase-4 §4): Escape follows system back's order.
  testWidgets('Escape pops session routes in order, then stops at the shell', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    openSession(ctx, SessionDestination.settings);
    await tester.pumpAndSettle();
    openSession(ctx, SessionDestination.conversions);
    await tester.pumpAndSettle();
    expect(find.byType(ConversionsPage), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ConversionsPage), findsNothing);
    expect(find.byType(SettingsPage), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.text('shell'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('shell'), findsOneWidget);
    await teardownTree(tester);
  });

  // Audit 4A(c) #4/M11: a non-route overlay (menu anchor, autocomplete)
  // dismisses itself on Escape; the host must not pop the page instead.
  testWidgets('Escape goes to an enabled DismissIntent near the focus, not '
      'to back', (tester) async {
    final ctx = await pumpHost(tester);
    var dismissed = 0;
    unawaited(
      Navigator.of(ctx).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: Actions(
              actions: {
                DismissIntent: CallbackAction<DismissIntent>(
                  onInvoke: (_) => dismissed++,
                ),
              },
              child: const Focus(autofocus: true, child: Text('overlay owner')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(dismissed, 1);
    expect(find.text('overlay owner'), findsOneWidget, reason: 'not popped');
    await teardownTree(tester);
  });

  // Re-audit 4A #2: in a field, Escape first lets the field's own chain
  // act (Autocomplete options, a dialog) before leaving the field.
  testWidgets('Escape hides Autocomplete options, then leaves the field',
      (tester) async {
    final ctx = await pumpHost(tester);
    unawaited(
      Navigator.of(ctx).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: Autocomplete<String>(
              optionsBuilder: (v) =>
                  ['alpha', 'albatross'].where((o) => o.startsWith(v.text)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'al');
    await tester.pumpAndSettle();
    expect(find.text('albatross'), findsOneWidget, reason: 'options open');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('albatross'), findsNothing, reason: 'options hidden');
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>(),
      isNotNull,
      reason: 'field keeps focus',
    );
    expect(
      find.byType(Autocomplete<String>),
      findsOneWidget,
      reason: 'not popped',
    );
    // Once the suggestions are gone, Escape must leave the field rather
    // than being swallowed forever by the autocomplete ancestor.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final stillEditing = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>();
    await teardownTree(tester);
    expect(stillEditing, isNull, reason: 'second Escape leaves the field');
  });

  testWidgets('Escape in a field inside a dialog closes the dialog at once', (
    tester,
  ) async {
    final ctx = await pumpHost(tester);
    unawaited(
      showDialog<void>(
        context: ctx,
        useRootNavigator: false,
        builder: (_) => const AlertDialog(content: TextField(autofocus: true)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('shell'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('mounting the host activates the session once', (tester) async {
    final fake = FakeSessionControls();
    await tester.pumpWidget(
      harness.wrap(
        const SessionHost(root: Text('shell')),
        overrides: [sessionControlsProvider.overrideWithValue(fake)],
      ),
    );
    await tester.pump();
    // Rebuilds don't re-activate (no network work per rebuild).
    await tester.pumpWidget(
      harness.wrap(
        const SessionHost(root: Text('shell again')),
        overrides: [sessionControlsProvider.overrideWithValue(fake)],
      ),
    );
    await tester.pump();
    expect(fake.calls, ['activated']);
    await teardownTree(tester);
  });
}
