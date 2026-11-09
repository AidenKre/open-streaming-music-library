import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/browse/browse_pages.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/shell/app_shell.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';
import 'package:frontend/ui/widgets/mini_player.dart';
import 'package:frontend/ui/widgets/offline_banner.dart';
import 'package:frontend/ui/widgets/pending_edits_banner.dart';
import 'package:frontend/ui/widgets/server_blocked_banner.dart';
import 'package:frontend/ui/widgets/stale_downloads_banner.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';

/// 4B.1 (phase-4 §8): a full-height shell body with overlay chrome whose
/// MEASURED size every nested surface gets as insets.
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
        artist: 'Downloaded Artist',
        albumId: 10,
        album: 'Kept Album',
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
    FakeSessionControls? session,
  }) async {
    await tester.pumpWidget(
      h.wrap(
        const SessionHost(root: AppShell()),
        overrides: [
          sessionControlsProvider.overrideWithValue(
            session ?? FakeSessionControls(),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  EdgeInsets homeInsets(WidgetTester tester) => ShellChromeInsets.of(
    tester.element(find.byType(HomePage, skipOffstage: false)),
  );
  double heightOf(WidgetTester tester, Finder f) => tester.getSize(f).height;

  testWidgets('content runs the full height under the chrome', (tester) async {
    await pumpShell(tester);
    expect(
      heightOf(tester, find.byType(IndexedStack)),
      heightOf(tester, find.byType(AppShell)),
    );
    await teardownTree(tester);
  });

  testWidgets('Home gets the measured top bar and bottom stack as insets', (
    tester,
  ) async {
    await pumpShell(tester);
    final insets = homeInsets(tester);
    expect(insets.top, heightOf(tester, find.byKey(AppShell.topBarKey)));
    expect(
      insets.bottom,
      heightOf(tester, find.byKey(AppShell.bottomStackKey)),
    );
    expect(insets.bottom, greaterThan(0));
    await teardownTree(tester);
  });

  testWidgets('the mini player appearing grows the bottom inset by its '
      'laid-out height', (tester) async {
    await pumpShell(tester);
    final before = homeInsets(tester).bottom;
    final track = await tester.runAsync(
      () => BrowseRepository(db).getTrack('d1'),
    );
    h.audio.showTrack(track!);
    await tester.pumpAndSettle();
    expect(
      homeInsets(tester).bottom,
      closeTo(before + heightOf(tester, find.byType(MiniPlayer)), 0.01),
    );
    expect(
      homeInsets(tester).bottom,
      heightOf(tester, find.byKey(AppShell.bottomStackKey)),
    );
    await teardownTree(tester);
  });

  // 4B.1b, updated by audit 4B(b) F4: the floating bar hides under a pushed
  // route, but the root keeps its top inset (it is covered anyway) so it
  // does not jump when it reappears.
  testWidgets('the bar hides under a pushed route; the root keeps its top '
      'inset', (tester) async {
    await pumpShell(tester);
    final top = homeInsets(tester).top;
    expect(top, greaterThan(0));
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistsBrowsePage), findsOneWidget);
    expect(find.byKey(AppShell.topBarKey), findsNothing);
    expect(homeInsets(tester).top, top);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(AppShell.topBarKey), findsOneWidget);
    expect(homeInsets(tester).top, top);
    await teardownTree(tester);
  });

  testWidgets('a soft keyboard hides the bottom stack (bottom inset 0)', (
    tester,
  ) async {
    await pumpShell(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(find.byKey(AppShell.bottomStackKey), findsNothing);
    expect(homeInsets(tester).bottom, 0);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.byKey(AppShell.bottomStackKey), findsOneWidget);
    expect(homeInsets(tester).bottom, greaterThan(0));
    await teardownTree(tester);
  });

  testWidgets('bottom stack order: pending, stale, offline, player, tabs', (
    tester,
  ) async {
    await pumpShell(tester);
    h.offline.set(true);
    final track = await tester.runAsync(
      () => BrowseRepository(db).getTrack('d1'),
    );
    h.audio.showTrack(track!);
    await tester.pumpAndSettle();
    // 4B.1d: banners sit in their own (cappable) region now, so check the
    // on-screen order rather than one Column's children.
    final stack = find.byKey(AppShell.bottomStackKey);
    double top(Type t) => tester
        .getTopLeft(find.descendant(of: stack, matching: find.byType(t)))
        .dy;
    expect(
      top(PendingEditsBanner),
      lessThanOrEqualTo(top(StaleDownloadsBanner)),
    );
    expect(top(StaleDownloadsBanner), lessThanOrEqualTo(top(OfflineBanner)));
    expect(top(OfflineBanner), lessThan(top(MiniPlayer)));
    expect(top(MiniPlayer), lessThan(top(NavigationBar)));
    await teardownTree(tester);
  });

  // SC-01 rule 1: blocked behaves as offline, but says why and offers the
  // way out instead of the generic offline banner.
  testWidgets('a blocked session shows its banner instead of the offline one',
      (tester) async {
    final session = FakeSessionControls()..serverBlocked = true;
    await pumpShell(tester, session: session);
    h.offline.set(true);
    await tester.pumpAndSettle();
    final stack = find.byKey(AppShell.bottomStackKey);
    expect(
      find.descendant(of: stack, matching: find.byType(ServerBlockedBanner)),
      findsOneWidget,
    );
    expect(find.textContaining('Different server'), findsOneWidget);
    expect(find.byType(OfflineBanner), findsNothing);

    session.setBlocked(false);
    await tester.pumpAndSettle();
    expect(find.textContaining('Different server'), findsNothing);
    expect(find.byType(OfflineBanner), findsOneWidget);
    await teardownTree(tester);
  });
}
