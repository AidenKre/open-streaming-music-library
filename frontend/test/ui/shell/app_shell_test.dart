import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/browse/browse_pages.dart';
import 'package:frontend/ui/browse_controller.dart';
import 'package:frontend/ui/feed/feed_header.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/widgets/full_player.dart';
import 'package:frontend/ui/widgets/mini_player.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/shell/app_shell.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/track_card.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';

class _CountingBrowse implements BrowseControls {
  int refreshes = 0;
  @override
  Future<void> refreshLibrary() async => refreshes++;
}

/// 4B: the shell's bar is the floating top bar (AppShell.topBarKey), not an
/// AppBar; browse and detail routes still own real AppBars.
Finder shellBar(String title) => find.descendant(
  of: find.byKey(AppShell.topBarKey),
  matching: find.text(title),
);

/// A text field has focus (its node's context sits inside an EditableText).
bool textFocused() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>() !=
    null;

/// 4A.4: the two-tab shell (phase-4 §3.7–3.8, §4).
void main() {
  late AppDatabase db;
  late BrowseHarness h;
  late _CountingBrowse browse;

  setUpAll(() {
    ApiClient.init('http://localhost:8000');
  });

  setUp(() async {
    initCoverArtCache(CoverArtCacheManager.noop());
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, [
      const SeedTrack(
        uuid: 'd1',
        title: 'Kept Song',
        artistId: 1,
        artist: 'Downloaded Artist',
        albumId: 10,
        album: 'Kept Album',
        downloaded: true,
      ),
      const SeedTrack(
        uuid: 's1',
        title: 'Remote Song',
        artistId: 2,
        artist: 'Streaming Artist',
        albumId: 20,
        album: 'Remote Album',
      ),
    ]);
    h = await BrowseHarness.create(db);
    browse = _CountingBrowse();
  });

  tearDown(() async {
    await db.close();
    await h.dispose();
  });

  Future<void> pumpShell(WidgetTester tester) async {
    // As in the app: the shell is the session host's root (back/Escape
    // dispatch starts there).
    await tester.pumpWidget(
      h.wrap(
        const SessionHost(root: AppShell()),
        overrides: [
          browseControlsProvider.overrideWithValue(browse),
          sessionControlsProvider.overrideWithValue(FakeSessionControls()),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder navBar() => find.byType(NavigationBar);

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: navBar(), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  // skipOffstage: false — Search's root stays mounted (offstage) on Home.
  TextField searchField(WidgetTester tester) => tester.widget<TextField>(
    find.descendant(
      of: find.byType(SearchPage, skipOffstage: false),
      matching: find.byType(TextField, skipOffstage: false),
      skipOffstage: false,
    ),
  );

  bool searchFocused(WidgetTester tester) =>
      searchField(tester).focusNode!.hasFocus;

  Future<void> typeSearch(WidgetTester tester, String q) async {
    await tester.enterText(
      find.descendant(
        of: find.byType(SearchPage),
        matching: find.byType(TextField),
      ),
      q,
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  testWidgets('Home is first; two tabs; one shell top bar with the actions', (
    tester,
  ) async {
    await pumpShell(tester);
    final destinations = tester
        .widget<NavigationBar>(navBar())
        .destinations
        .cast<NavigationDestination>()
        .map((d) => d.label)
        .toList();
    expect(destinations, ['Home', 'Search']);
    expect(find.byType(HomePage), findsOneWidget);
    // 4B: one floating shell bar (was one AppBar); no AppBar at a root.
    expect(find.byKey(AppShell.topBarKey), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byTooltip('Downloads'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.text('Artists'), findsOneWidget, reason: 'entry point');
    expect(browse.refreshes, 0, reason: 'the session host syncs, not tabs');
    await teardownTree(tester);
  });

  testWidgets('a browse route from Home owns the only AppBar; back returns '
      'Home with the shell bar', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistsBrowsePage), findsOneWidget);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byKey(AppShell.topBarKey), findsNothing, reason: '4B: hidden');
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget, reason: 'stays');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistsBrowsePage), findsNothing);
    expect(find.byKey(AppShell.topBarKey), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byTooltip('Settings'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('system back pops the active tab\'s route, and at a root '
      'leaves the shell in place', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kept Album'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Kept Album'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlbumsBrowsePage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byType(HomePage), findsOneWidget);
    await teardownTree(tester);
  });

  // Audit 4A(a) M1: back must never exit the app from a tab detail (stale
  // nested-navigator notifications) nor at the app root (existing policy).
  testWidgets('system back never exits the app: tab detail after a tab '
      'switch, and at the root', (tester) async {
    final platformCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpShell(tester);
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    await tapTab(tester, 'Search');
    await typeSearch(tester, 'Streaming');
    await tester.tap(find.text('Streaming Artist').first);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute(); // Search detail -> Search root
    await tester.pumpAndSettle();
    await tapTab(tester, 'Home');
    expect(find.byType(ArtistsBrowsePage), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ArtistsBrowsePage), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
    await tester.binding.handlePopRoute(); // at the root
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    expect(platformCalls, isNot(contains('SystemNavigator.pop')));
    await teardownTree(tester);
  });

  // Audit 4A(a) M3: a menu sheet on a tab root is not a route "above the
  // root"; the shell bar stays.
  testWidgets('a card menu sheet on the Search root keeps the shell bar', (
    tester,
  ) async {
    await pumpShell(tester);
    await tapTab(tester, 'Search');
    await typeSearch(tester, 'Streaming');
    await tester.longPress(find.text('Streaming Artist').first);
    await tester.pumpAndSettle();
    expect(find.text('Play Next'), findsOneWidget, reason: 'sheet open');
    expect(shellBar('Search'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    await teardownTree(tester);
  });

  // Re-audit 4A #1, updated for 4B (audit 4B(a) M1): a card menu now opens
  // above the whole shell, so its barrier covers the tab bar — a sheet can
  // no longer be left open on a hidden tab — and closing it does not put
  // the focus back in the field underneath.
  testWidgets('a card menu sheet covers the tab bar; closing it does not '
      'focus the Search field', (tester) async {
    await pumpShell(tester);
    await tapTab(tester, 'Search');
    await typeSearch(tester, 'Streaming');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.longPress(find.text('Streaming Artist').first);
    await tester.pumpAndSettle();
    expect(find.text('Play Next'), findsOneWidget);
    expect(find.byType(NavigationBar).hitTestable(), findsNothing);
    await tester.tapAt(const Offset(10, 10)); // the barrier
    await tester.pumpAndSettle();
    expect(find.text('Play Next'), findsNothing);
    expect(searchFocused(tester), isFalse);
    await teardownTree(tester);
  });

  // Re-audit 4A #6: Home's search header also updates the bar in the
  // very first frame (it pops Search's routes and switches tab).
  testWidgets('Home\'s search header shows the Search bar in the same frame', (
    tester,
  ) async {
    await pumpShell(tester);
    await tapTab(tester, 'Search');
    await typeSearch(tester, 'Streaming');
    await tester.tap(find.text('Streaming Artist').first);
    await tester.pumpAndSettle();
    await tapTab(tester, 'Home');
    await tester.tap(
      find.descendant(
        of: find.byType(HomePage),
        matching: find.byType(FeedHeader),
      ),
    );
    await tester.pump(); // one frame
    expect(shellBar('Search'), findsOneWidget);
    await tester.pumpAndSettle();
    await teardownTree(tester);
  });

  // Re-audit 4A #6: the observer mirrors route removal and replacement.
  testWidgets('removing or replacing tab routes keeps the bar right', (
    tester,
  ) async {
    await pumpShell(tester);
    final nav = tester.state<NavigatorState>(
      find
          .descendant(
            of: find.byType(AppShell),
            matching: find.byType(Navigator),
          )
          .first,
    );
    final a = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('A')),
    );
    unawaited(nav.push(a));
    await tester.pumpAndSettle();
    expect(shellBar('OSML'), findsNothing);
    // Replace A with B: still a page above the root.
    unawaited(
      nav.pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('B')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
    expect(shellBar('OSML'), findsNothing);
    // Remove B without a pop: back at the root, the bar returns.
    final b = ModalRoute.of(tester.element(find.text('B')))!;
    nav.removeRoute(b);
    await tester.pumpAndSettle();
    expect(shellBar('OSML'), findsOneWidget);
    await teardownTree(tester);
  });

  // Audit 4A(a) m2: the bar matches the newly visible tab in the very
  // first frame of a switch (no frame without it, none with two).
  testWidgets('switching tabs updates the shell bar in the same frame', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(shellBar('OSML'), findsNothing);

    await tester.tap(
      find.descendant(of: navBar(), matching: find.text('Search')),
    );
    await tester.pump(); // one frame
    expect(shellBar('Search'), findsOneWidget);

    await tester.tap(
      find.descendant(of: navBar(), matching: find.text('Home')),
    );
    await tester.pump(); // one frame
    expect(shellBar('Search'), findsNothing);
    expect(shellBar('OSML'), findsNothing);
    expect(find.widgetWithText(AppBar, 'Artists'), findsOneWidget);
    await tester.pumpAndSettle();
    await teardownTree(tester);
  });

  testWidgets('selecting Search focuses its field; leaving unfocuses it', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(searchFocused(tester), isFalse, reason: 'no offstage autofocus');
    await tapTab(tester, 'Search');
    expect(searchFocused(tester), isTrue);
    // Leave without a tap (a tap outside the field could unfocus it by
    // itself): the shell must unfocus it.
    tester.state<AppShellState>(find.byType(AppShell)).selectTab(ShellTab.home);
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    expect(searchFocused(tester), isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    await teardownTree(tester);
  });

  testWidgets('Home\'s search affordance selects Search, pops its routes '
      'and focuses the field', (tester) async {
    await pumpShell(tester);
    await tapTab(tester, 'Search');
    await typeSearch(tester, 'Song');
    await tester.tap(find.text('Kept Song').first);
    await tester.pumpAndSettle();
    // Open an artist from Search to leave a detail on its stack.
    await typeSearch(tester, 'Streaming');
    await tester.tap(find.text('Streaming Artist').first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Streaming Artist'), findsOneWidget);
    await tapTab(tester, 'Home');

    await tester.tap(
      find.descendant(
        of: find.byType(HomePage),
        matching: find.byType(FeedHeader),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Streaming Artist'), findsNothing);
    expect(find.byType(SearchPage), findsOneWidget);
    expect(searchFocused(tester), isTrue);
    expect(
      searchField(tester).controller!.text,
      'Streaming',
      reason: 'query retained',
    );
    await teardownTree(tester);
  });

  testWidgets('returning to Search on a retained detail keeps it and does '
      'not steal focus', (tester) async {
    await pumpShell(tester);
    await tapTab(tester, 'Search');
    await typeSearch(tester, 'Streaming');
    await tester.tap(find.text('Streaming Artist').first);
    await tester.pumpAndSettle();
    await tapTab(tester, 'Home');
    await tapTab(tester, 'Search');
    expect(find.widgetWithText(AppBar, 'Streaming Artist'), findsOneWidget);
    expect(searchFocused(tester), isFalse);
    await teardownTree(tester);
  });

  testWidgets('re-tap with a detail on top pops to the root only, keeping '
      'query and chip', (tester) async {
    await pumpShell(tester);
    await tapTab(tester, 'Search');
    await typeSearch(tester, 'Song');
    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    await tester.pumpAndSettle();
    await typeSearch(tester, 'Downloaded');
    await tester.tap(find.text('Downloaded Artist').first);
    await tester.pumpAndSettle();
    await tapTab(tester, 'Search');
    expect(find.widgetWithText(AppBar, 'Downloaded Artist'), findsNothing);
    expect(searchField(tester).controller!.text, 'Downloaded');
    expect(
      tester
          .widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey))
          .selected,
      isTrue,
    );
    await teardownTree(tester);
  });

  // Audit 4A(c) #1: two routes deep, so pop-once can't pass for
  // pop-to-root (re-tap and Home's search header).
  for (final viaHeader in [false, true]) {
    testWidgets('${viaHeader ? 'Home\'s search header' : 're-tap'} pops a '
        'two-route Search stack to its root, keeping query and chip', (
      tester,
    ) async {
      await pumpShell(tester);
      await tapTab(tester, 'Search');
      await typeSearch(tester, 'Streaming');
      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FilterBar.downloadedChipKey)); // OFF again
      await tester.pumpAndSettle();
      await tester.tap(find.text('Streaming Artist').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remote Album'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Remote Album'), findsOneWidget);
      if (viaHeader) {
        await tapTab(tester, 'Home');
        await tester.tap(
          find.descendant(
            of: find.byType(HomePage),
            matching: find.byType(FeedHeader),
          ),
        );
        await tester.pumpAndSettle();
      } else {
        await tapTab(tester, 'Search');
      }
      expect(find.widgetWithText(AppBar, 'Remote Album'), findsNothing);
      expect(find.widgetWithText(AppBar, 'Streaming Artist'), findsNothing);
      expect(shellBar('Search'), findsOneWidget);
      expect(searchField(tester).controller!.text, 'Streaming');
      expect(
        tester
            .widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey))
            .selected,
        isFalse,
      );
      await teardownTree(tester);
    });
  }

  testWidgets('re-tap on a visible root scrolls it to the top', (tester) async {
    // Enough rails/text to scroll Search.
    await seedLibrary(db, [
      for (var i = 0; i < 6; i++)
        SeedTrack(
          uuid: 'z$i',
          title: 'Zed Song $i',
          artistId: 100 + i,
          artist: 'Zed Artist $i',
          albumId: 100 + i,
          album: 'Zed Album $i',
        ),
    ]);
    await pumpShell(tester);
    await tapTab(tester, 'Search');
    await typeSearch(tester, 'Zed');
    final feed = find.descendant(
      of: find.byType(SearchPage),
      matching: find.byType(CustomScrollView),
    );
    await tester.drag(feed, const Offset(0, -300));
    await tester.pumpAndSettle();
    ScrollPosition pos() => tester
        .state<ScrollableState>(
          find.descendant(of: feed, matching: find.byType(Scrollable)).first,
        )
        .position;
    expect(pos().pixels, greaterThan(0));
    await tapTab(tester, 'Search');
    expect(pos().pixels, 0);
    expect(searchField(tester).controller!.text, 'Zed');
    await teardownTree(tester);
  });

  // Audit 4A(c): Home's re-tap on its visible root scrolls it to the top.
  testWidgets('re-tap on the visible Home root scrolls it to the top', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 330);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpShell(tester);
    final feed = find
        .descendant(
          of: find.byType(HomePage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.drag(feed, const Offset(0, -200));
    await tester.pumpAndSettle();
    final pos = tester.state<ScrollableState>(feed).position;
    expect(pos.pixels, greaterThan(0), reason: 'precondition: scrolled');
    await tapTab(tester, 'Home');
    expect(pos.pixels, 0);
    await teardownTree(tester);
  });

  // Audit 4A(c): a hidden Search with a live query catches up on an outage
  // (Riverpod replays the last missed offline change on resume).
  testWidgets('hidden Search with a query re-runs downloaded-only after an '
      'outage while Home was visible', (tester) async {
    await pumpShell(tester);
    await tapTab(tester, 'Search');
    await typeSearch(tester, 'Song');
    expect(find.byType(TrackCard), findsNWidgets(2));
    await tapTab(tester, 'Home');
    h.offline.set(true);
    await tester.pumpAndSettle();
    await tapTab(tester, 'Search');
    expect(
      tester
          .widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey))
          .selected,
      isTrue,
    );
    expect(find.byType(TrackCard), findsOneWidget);
    expect(find.text('Kept Song'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('switching tabs keeps each tab\'s route, query and chip', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.text('Tracks'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    await tester.pumpAndSettle();
    expect(find.text('Remote Song'), findsNothing);

    await tapTab(tester, 'Search');
    expect(
      tester
          .widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey))
          .selected,
      isFalse,
      reason: 'Search has its own chip',
    );
    await typeSearch(tester, 'Song');
    expect(find.byType(TrackCard), findsNWidgets(2));

    await tapTab(tester, 'Home');
    expect(find.byType(TracksBrowsePage), findsOneWidget);
    expect(
      tester
          .widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey))
          .selected,
      isTrue,
    );
    await tapTab(tester, 'Search');
    expect(searchField(tester).controller!.text, 'Song');
    await teardownTree(tester);
  });

  testWidgets('tab taps never sync; opening Tracks browse does once', (
    tester,
  ) async {
    await pumpShell(tester);
    await tapTab(tester, 'Search');
    await tapTab(tester, 'Search');
    await tapTab(tester, 'Home');
    await tapTab(tester, 'Home');
    expect(browse.refreshes, 0);
    await tester.tap(find.text('Tracks'));
    await tester.pumpAndSettle();
    expect(browse.refreshes, 1);
    await teardownTree(tester);
  });

  testWidgets('fresh Home -> Search finds the mirror without any browse '
      'visit', (tester) async {
    await pumpShell(tester);
    await tapTab(tester, 'Search');
    await typeSearch(tester, 'Song');
    expect(find.byType(TrackCard), findsNWidgets(2));
    expect(browse.refreshes, 0);
    await teardownTree(tester);
  });

  // Audit 4A(a) m1: Escape in a focused field first leaves the field.
  testWidgets('Escape in a focused browse search field unfocuses it, then '
      'pops', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextField, 'Search artists'));
    await tester.pump();
    expect(textFocused(), isTrue, reason: 'precondition: field focused');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ArtistsBrowsePage), findsOneWidget);
    expect(textFocused(), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ArtistsBrowsePage), findsNothing);
    await teardownTree(tester);
  });

  // Audit 4A(a) m4: tab back asks the route (maybePop), so a route's
  // PopScope guard is honoured.
  testWidgets('system back respects a tab route that refuses to pop', (
    tester,
  ) async {
    await pumpShell(tester);
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
          builder: (_) => const PopScope(
            canPop: false,
            child: Scaffold(body: Text('guarded')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('guarded'), findsOneWidget);
    await teardownTree(tester);
  });

  // Audit 4A(c) #4 (phase-4 §4 back dispatch): an open modal closes first,
  // by system back and by Escape, and the route under it stays.
  for (final input in ['system back', 'Escape']) {
    Future<void> goBack(WidgetTester tester) async {
      if (input == 'Escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
    }

    testWidgets('$input closes the full player over a tab detail, then the '
        'detail', (tester) async {
      await pumpShell(tester);
      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();
      final track = await tester.runAsync(
        () => BrowseRepository(db).getTrack('d1'),
      );
      h.audio.showTrack(track!);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MiniPlayer));
      await tester.pumpAndSettle();
      expect(find.byType(FullPlayer), findsOneWidget);

      await goBack(tester);
      expect(find.byType(FullPlayer), findsNothing);
      expect(find.byType(ArtistsBrowsePage), findsOneWidget);
      await goBack(tester);
      expect(find.byType(ArtistsBrowsePage), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('$input closes a card menu sheet on the Search root only', (
      tester,
    ) async {
      await pumpShell(tester);
      await tapTab(tester, 'Search');
      await typeSearch(tester, 'Streaming');
      await tester.longPress(find.text('Streaming Artist').first);
      await tester.pumpAndSettle();
      expect(find.text('Play Next'), findsOneWidget);
      await goBack(tester);
      expect(find.text('Play Next'), findsNothing);
      expect(shellBar('Search'), findsOneWidget);
      expect(searchField(tester).controller!.text, 'Streaming');
      expect(find.text('Streaming Artist'), findsWidgets);
      await teardownTree(tester);
    });
  }

  testWidgets('Escape pops a browse route like system back', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ArtistsBrowsePage), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
    await teardownTree(tester);
  });
}
