import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/services/stale_downloads_provider.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/shell/app_shell.dart';
import 'package:frontend/ui/widgets/mini_player.dart';
import 'package:frontend/ui/widgets/stale_downloads_banner.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';

/// 4B.1 short viewport (phase-4 §8): the banner region is capped at 30% of
/// the body, scrolls, and says how many notifications it holds; the player
/// and navigation stay reachable; tiny windows scroll instead of overflow.
void main() {
  late AppDatabase db;
  late BrowseHarness h;

  setUpAll(() => ApiClient.init('http://localhost:8000'));

  setUp(() async {
    initCoverArtCache(CoverArtCacheManager.noop());
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(
        uuid: 'd1',
        title: 'Kept Song',
        artistId: 1,
        artist: 'Ann',
        albumId: 10,
        album: 'Air',
        downloaded: true,
      ),
    ]);
    h = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await db.close();
    await h.dispose();
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    required Size size,
    double textScale = 1,
    bool banners = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final track = await tester.runAsync(
      () => BrowseRepository(db).getTrack('d1'),
    );
    await tester.pumpWidget(
      h.wrap(
        const SessionHost(root: AppShell()),
        offline: banners,
        overrides: [
          sessionControlsProvider.overrideWithValue(FakeSessionControls()),
          if (banners) ...[
            pendingEditCountsProvider.overrideWith(
              (ref) => Stream.value((pending: 2, conflicted: 1, rejected: 0)),
            ),
            staleDownloadsProvider.overrideWith(
              (ref) => Stream.value([track!]),
            ),
          ],
        ],
      ),
    );
    h.audio.showTrack(track!);
    await tester.pumpAndSettle();
  }

  testWidgets('short window: banners capped at 30% with a count; player and '
      'navigation reachable; every banner action reachable', (tester) async {
    // 330 pt: the three banners (~108 pt) exceed the 99-pt cap.
    await pumpShell(tester, size: const Size(800, 330));
    expect(tester.takeException(), isNull);
    final region = find.byKey(AppShell.bannerRegionKey);
    expect(tester.getSize(region).height, lessThanOrEqualTo(330 * 0.3 + 0.5));
    expect(find.text('Notifications (3)'), findsOneWidget);
    expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
    expect(find.byType(MiniPlayer).hitTestable(), findsOneWidget);
    // The stale banner's Review is inside the region: scroll to it.
    final review = find.descendant(
      of: find.byType(StaleDownloadsBanner),
      matching: find.text('Review'),
    );
    await tester.scrollUntilVisible(
      review,
      20,
      scrollable: find.descendant(
        of: region,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(review);
    await tester.pumpAndSettle();
    expect(find.text('Downloads changed on the server'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('tall window: banners not capped, no notifications label', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(800, 1200));
    expect(find.textContaining('Notifications ('), findsNothing);
    expect(find.text('Review').hitTestable(), findsNWidgets(2));
    await teardownTree(tester);
  });

  testWidgets('Search remains usable with a landscape soft keyboard', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(800, 400), banners: false);
    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Search'),
    ));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final error = tester.takeException();
    final fieldIsReachable = find.byType(TextField).hitTestable().evaluate().length;
    final resultsHeight = tester.getSize(find.byType(SectionedFeedView)).height;
    await tester.enterText(find.byType(TextField), 'needle');
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    final query = tester.widget<TextField>(find.byType(TextField)).controller!.text;
    final navigationRestored = find.byType(NavigationBar).hitTestable().evaluate().isNotEmpty;
    await teardownTree(tester);
    expect(error, isNull);
    expect(fieldIsReachable, 1);
    expect(resultsHeight, greaterThan(0), reason: 'results retain a viewport');
    expect(query, 'needle');
    expect(navigationRestored, isTrue);
  });

  testWidgets('a snackbar fits while the short-window chrome is capped', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(800, 260), textScale: 2);
    ScaffoldMessenger.of(tester.element(find.byType(AppShell)))
        .showSnackBar(const SnackBar(content: Text('Saved')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final errors = <Object>[];
    Object? error;
    while ((error = tester.takeException()) != null) {
      errors.add(error!);
    }
    await teardownTree(tester);
    expect(errors, isEmpty);
  });

  testWidgets('tiny window at text scale 2: no overflow; navigation still '
      'reachable', (tester) async {
    await pumpShell(tester, size: const Size(800, 260), textScale: 2);
    expect(tester.takeException(), isNull);
    // The chrome stays inside the window (never extends above its top)...
    final stack = tester.getRect(find.byKey(AppShell.bottomStackKey));
    expect(stack.top, greaterThanOrEqualTo(0));
    expect(stack.bottom, lessThanOrEqualTo(260.5));
    // ... and every part of it can be reached.
    for (final part in [find.byType(NavigationBar), find.byType(MiniPlayer)]) {
      await tester.ensureVisible(part);
      await tester.pumpAndSettle();
      expect(part.hitTestable(), findsOneWidget);
    }
    await teardownTree(tester);
  });

  // Audit 4B(b) F1: the stack's limit and the 30% cap use the AVAILABLE
  // body height, so the top bar stays reachable even with every surface up.
  testWidgets('tiny window, all banners + player: the top bar stays '
      'reachable', (tester) async {
    await pumpShell(tester, size: const Size(800, 260), textScale: 2);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
    final bar = tester.getRect(find.byKey(AppShell.topBarKey));
    final stack = tester.getRect(find.byKey(AppShell.bottomStackKey));
    expect(stack.top, greaterThanOrEqualTo(bar.bottom - 0.5));
    final region = tester.getSize(find.byKey(AppShell.bannerRegionKey)).height;
    expect(region, lessThanOrEqualTo((260 - bar.height) * 0.3 + 0.5));
    await teardownTree(tester);
  });

  // Re-audit 4B #1: with a route pushed, its own AppBar (and back button)
  // stays reachable on a tiny window with every surface up.
  testWidgets('tiny window, route pushed: its back button stays reachable', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(800, 260), textScale: 2);
    final nav = tester.state<NavigatorState>(
      find
          .descendant(
            of: find.byType(AppShell),
            matching: find.byType(Navigator),
          )
          .first,
    );
    unawaited(
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(appBar: AppBar(title: const Text('Detail'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackButton).hitTestable(), findsOneWidget);
    final appBar = tester.getRect(find.byType(AppBar));
    final stack = tester.getRect(find.byKey(AppShell.bottomStackKey));
    expect(stack.top, greaterThanOrEqualTo(appBar.bottom - 0.5));
    await teardownTree(tester);
  });
}
