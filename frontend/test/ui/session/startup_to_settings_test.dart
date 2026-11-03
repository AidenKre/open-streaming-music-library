import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/main.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/login_page.dart';
import 'package:frontend/ui/settings_page.dart';
import 'package:frontend/ui/startup_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../browse_harness.dart';

class _Service extends SessionService {
  _Service(super.ref);
  LocalResetException? failure;
  int resets = 0;
  @override
  Future<SessionStart> resumeSavedSession() async =>
      const SessionStart(SessionStartKind.online);
  @override
  Future<LocalResetException?> resetLocalData() async {
    resets++;
    return failure;
  }
}

/// Real StartupGate -> session host -> AppShell -> top-bar Settings ->
/// Disconnect (spec §4: not only a globally overridden harness).
void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late _Service service;

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

  Future<void> pumpLiveApp(WidgetTester tester) async {
    await tester.pumpWidget(
      harness.wrap(
        const StartupGate(),
        overrides: [
          sessionServiceProvider.overrideWith((ref) => service = _Service(ref)),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppShell), findsOneWidget);
  }

  Future<void> openSettingsAndConfirmDisconnect(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Settings').hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    final list = find.byType(Scrollable).last;
    for (var i = 0; i < 5; i++) {
      await tester.drag(list, const Offset(0, -400));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Reset and disconnect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('Disconnect from session Settings ends the session and its '
      'routes', (tester) async {
    await pumpLiveApp(tester);
    await openSettingsAndConfirmDisconnect(tester);
    expect(service.resets, 1);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.byType(AppShell), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('a failed reset is shown honestly before leaving', (
    tester,
  ) async {
    await pumpLiveApp(tester);
    service.failure = LocalResetException([]);
    await openSettingsAndConfirmDisconnect(tester);
    expect(find.text('Reset incomplete'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LoginPage), findsOneWidget);
    await teardownTree(tester);
  });

  // Audit 4B(b) F5: a sheet on the session navigator closes with the
  // session (no stranded modal over the login page).
  testWidgets('disconnect with a card menu sheet open ends the sheet too', (
    tester,
  ) async {
    await seedLibrary(db, const [
      SeedTrack(
        uuid: 'u1',
        title: 'Song',
        artistId: 1,
        artist: 'Ann',
        albumId: 2,
        album: 'Air',
      ),
    ]);
    await pumpLiveApp(tester);
    await tester.tap(find.text('Artists').hitTestable());
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Ann').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Play Next'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StartupGate)),
    );
    unawaited(container.read(sessionControlsProvider).disconnect());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('Play Next'), findsNothing);
    expect(service.resets, 1);
    await teardownTree(tester);
  });

  // 4A.4: the tab detail is now reached from Home's Artists entry point
  // (was the Artists tab root); Escape follows the same dispatch (phase-4
  // §4). Both inputs run the whole sequence.
  for (final (name, back) in [
    ('system back', (WidgetTester t) => t.binding.handlePopRoute()),
    ('Escape', (WidgetTester t) => t.sendKeyEvent(LogicalKeyboardKey.escape)),
  ]) {
    testWidgets('$name: session route, then tab detail, then stays at the '
        'shell root', (tester) async {
      await seedLibrary(db, const [
        SeedTrack(
          uuid: 'u1',
          title: 'Song',
          artistId: 1,
          artist: 'Ann',
          albumId: 2,
          album: 'Air',
        ),
      ]);
      await pumpLiveApp(tester);
      Future<void> goBack() async {
        await back(tester);
        await tester.pumpAndSettle();
      }

      // Session destination stack: Settings -> Conversions.
      await tester.tap(find.byTooltip('Settings').hitTestable().first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Conversions'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Conversions'));
      await tester.pumpAndSettle();
      await goBack();
      expect(
        find.byType(SettingsPage),
        findsOneWidget,
        reason: 'back -> Settings',
      );
      await goBack();
      expect(find.byType(SettingsPage), findsNothing, reason: 'back -> shell');
      // Tab routes: Home -> Artists browse -> artist detail.
      await tester.tap(find.text('Artists').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ann').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('Air').hitTestable(), findsOneWidget);
      await goBack();
      expect(
        find.text('Air').hitTestable(),
        findsNothing,
        reason: 'back -> Artists browse',
      );
      expect(find.text('Ann').hitTestable(), findsOneWidget);
      await goBack();
      expect(find.byType(HomePage), findsOneWidget, reason: 'back -> Home');
      // At the shell root, back leaves the shell in place.
      await goBack();
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(HomePage), findsOneWidget);
      await teardownTree(tester);
    });
  }
}
