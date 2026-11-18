import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/library_sync_status.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/session_controller.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';

/// Audit 4A(a) M2 (phase-4 §4): the session host's initial sync has bounded
/// loading / error / Retry feedback on Home and Search.
void main() {
  late AppDatabase db;
  late BrowseHarness h;
  late FakeSessionControls session;

  setUpAll(() {
  });
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    h = await BrowseHarness.create(db);
    session = FakeSessionControls();
  });
  tearDown(() async {
    await h.dispose();
    await db.close();
  });

  for (final (name, page) in [
    ('Home', const HomePage() as Widget),
    ('Search', const SearchPage()),
  ]) {
    Future<void> pump(WidgetTester t, LibrarySyncStatus status) async {
      await t.pumpWidget(
        h.wrap(
          page,
          overrides: [
            librarySyncStatusProvider.overrideWithValue(status),
            sessionControlsProvider.overrideWithValue(session),
          ],
        ),
      );
      await t.pump();
    }

    testWidgets('$name: syncing shows bounded progress', (t) async {
      await pump(t, LibrarySyncStatus.syncing);
      expect(find.text('Syncing your library…'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      await teardownTree(t);
    });

    testWidgets('$name: failure shows Retry, which goes to the controller', (
      t,
    ) async {
      await pump(t, LibrarySyncStatus.failed);
      expect(find.text("Couldn't sync your library."), findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, 'Retry'));
      expect(session.calls, ['retrySync']);
      await teardownTree(t);
    });

    // Other-issues decision 3 (a): the decided text; Reset… in place of
    // Retry opens the existing "Reset and disconnect?" sheet. The app never
    // resets on its own: declining changes nothing.
    testWidgets('$name: a restored server shows its text and Reset…, which '
        'opens the reset sheet; Cancel changes nothing', (t) async {
      session.lossSummaries = const ['2 unsent history events'];
      await pump(t, LibrarySyncStatus.serverRestored);
      expect(
        find.text("The server's library looks restored from an older "
            "backup. This device can't sync with it until it is reset."),
        findsOneWidget,
      );
      expect(find.text("Couldn't sync your library."), findsNothing);
      expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
      await t.tap(find.widgetWithText(TextButton, 'Reset…'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Reset and disconnect?'), findsOneWidget);
      expect(find.textContaining('2 unsent history events'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Reset and disconnect?'), findsNothing);
      expect(session.calls, isEmpty);
      await teardownTree(t);
    });

    testWidgets('$name: a restored server: confirming the sheet disconnects',
        (t) async {
      await pump(t, LibrarySyncStatus.serverRestored);
      await t.tap(find.widgetWithText(TextButton, 'Reset…'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.widgetWithText(FilledButton, 'Reset and disconnect'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(session.calls, ['disconnect']);
      await teardownTree(t);
    });

    // Pre-merge review D4-06: a double tap on Reset… opens one sheet.
    testWidgets('$name: a double tap on Reset… opens one sheet', (t) async {
      session.lossSummariesGate = Completer<List<String>>();
      await pump(t, LibrarySyncStatus.serverRestored);
      await t.tap(find.widgetWithText(TextButton, 'Reset…'));
      await t.pump();
      await t.tap(find.widgetWithText(TextButton, 'Reset…'));
      await t.pump();
      session.lossSummariesGate!.complete(const []);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Reset and disconnect?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Reset and disconnect?'), findsNothing);
      // Usable again once the sheet closed.
      session.lossSummariesGate = null;
      await t.tap(find.widgetWithText(TextButton, 'Reset…'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Reset and disconnect?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await teardownTree(t);
    });

    testWidgets('$name: idle shows nothing', (t) async {
      await pump(t, LibrarySyncStatus.idle);
      expect(find.textContaining('sync your library'), findsNothing);
      expect(find.textContaining('Syncing'), findsNothing);
      await teardownTree(t);
    });
  }

  test('Home registers the status right after the search header', () {
    final order = HomeSectionIds.order;
    expect(
      order.indexOf(HomeSectionIds.syncStatus),
      order.indexOf(HomeSectionIds.search) + 1,
    );
  });
}
