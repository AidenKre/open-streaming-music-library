import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
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
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
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
