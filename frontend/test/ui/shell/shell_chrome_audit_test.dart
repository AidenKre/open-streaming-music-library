import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/browse/browse_pages.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/widgets/mini_player.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/shell/app_shell.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';

/// Audit 4B(a) fixes: sheets above the chrome, safe areas counted once,
/// a stable bottom stack, snackbars above the chrome, the bar returning
/// only after a pop, tiny windows, title capsule text scale, status text.
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
    Size? size,
    double textScale = 1,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      h.wrap(
        const SessionHost(root: AppShell()),
        overrides: [
          sessionControlsProvider.overrideWithValue(FakeSessionControls()),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> showPlayer(WidgetTester tester) async {
    final track = await tester.runAsync(
      () => BrowseRepository(db).getTrack('d1'),
    );
    h.audio.showTrack(track!);
    await tester.pumpAndSettle();
  }

  testWidgets('M1: a row menu opened in a tab sits above the chrome; every '
      'entry is tappable', (tester) async {
    await pumpShell(tester, size: const Size(400, 800));
    await showPlayer(tester);
    await tester.tap(find.text('Tracks'));
    await tester.pumpAndSettle();
    final row = find.ancestor(
      of: find.text('Kept Song'),
      matching: find.byType(TrackTile),
    );
    await tester.tap(
      find.descendant(of: row, matching: find.byIcon(Icons.more_vert)),
    );
    await tester.pumpAndSettle();
    for (final entry in [
      'Play Next',
      'Add to Queue',
      'Delete download',
      'Get Info',
    ]) {
      expect(find.text(entry).hitTestable(), findsOneWidget, reason: entry);
    }
    expect(
      find.byType(NavigationBar).hitTestable(),
      findsNothing,
      reason: 'the modal barrier covers the chrome too',
    );
    await teardownTree(tester);
  });

  testWidgets('M2: the bottom stack counts only the bottom safe area', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1; // padding below is physical pixels
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.resetPadding);
    await pumpShell(tester);
    final nav = tester.getSize(find.byType(NavigationBar)).height;
    expect(nav, 80 + 34);
    expect(tester.getSize(find.byKey(AppShell.bottomStackKey)).height, nav);
    await teardownTree(tester);
  });

  testWidgets('M3: pushing and popping a route keeps the bottom stack', (
    tester,
  ) async {
    await pumpShell(tester);
    final before = tester.element(find.byType(NavigationBar));
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(
      identical(tester.element(find.byType(NavigationBar)), before),
      isTrue,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      identical(tester.element(find.byType(NavigationBar)), before),
      isTrue,
    );
    await teardownTree(tester);
  });

  testWidgets('M4: a snackbar from tab content shows above the chrome', (
    tester,
  ) async {
    await pumpShell(tester);
    ScaffoldMessenger.of(
      tester.element(find.byType(HomePage)),
    ).showSnackBar(const SnackBar(content: Text('Saved')));
    await tester.pumpAndSettle();
    // The visible bar (the SnackBar widget also spans its inset margin).
    final bar = tester.getRect(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          )
          .first,
    );
    final chromeTop = tester.getTopLeft(find.byKey(AppShell.bottomStackKey)).dy;
    expect(bar.bottom, lessThanOrEqualTo(chromeTop + 0.5));
    await teardownTree(tester);
  });

  testWidgets('m1: the floating bar returns only after the pop transition', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pump(); // pop started
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byType(ArtistsBrowsePage),
      findsOneWidget,
      reason: 'sliding out',
    );
    expect(find.byKey(AppShell.topBarKey), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byKey(AppShell.topBarKey), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('m2: on a tiny window the bottom stack leaves the top bar '
      'reachable', (tester) async {
    await pumpShell(tester, size: const Size(800, 260), textScale: 2);
    await showPlayer(tester);
    expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
    final bar = tester.getRect(find.byKey(AppShell.topBarKey));
    final stack = tester.getRect(find.byKey(AppShell.bottomStackKey));
    expect(stack.top, greaterThanOrEqualTo(bar.bottom - 0.5));
    await teardownTree(tester);
  });

  testWidgets('m3: Home keeps the side safe areas', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.padding = const FakeViewPadding(left: 44, right: 44);
    addTearDown(tester.view.resetPadding);
    await pumpShell(tester);
    final entry = tester.getRect(
      find
          .ancestor(of: find.text('Artists'), matching: find.byType(Card))
          .first,
    );
    expect(entry.left, greaterThanOrEqualTo(44));
    await teardownTree(tester);
  });

  testWidgets('m4: the chrome\'s scroll views are not primary', (tester) async {
    await pumpShell(tester);
    final scrolls = tester.widgetList<SingleChildScrollView>(
      find.descendant(
        of: find.byKey(AppShell.bottomStackKey),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    expect(scrolls, isNotEmpty);
    expect(scrolls.every((s) => s.primary == false), isTrue);
    await teardownTree(tester);
  });

  // Audit 4B(b) F2: compare with the text's own (unclamped) height.
  testWidgets('m5: the title capsule grows with the text', (tester) async {
    await pumpShell(tester, textScale: 2);
    final title = find.descendant(
      of: find.byKey(AppShell.topBarKey),
      matching: find.text('OSML'),
    );
    final paragraph = tester.renderObject<RenderParagraph>(title);
    final needed = paragraph.getMinIntrinsicHeight(paragraph.size.width);
    expect(
      paragraph.size.height,
      greaterThanOrEqualTo(needed - 0.5),
      reason: 'not clipped to a fixed 48',
    );
    final capsule = tester.getRect(
      find.ancestor(of: title, matching: find.byType(ClipRRect)).first,
    );
    expect(capsule.height, greaterThanOrEqualTo(needed));
    await teardownTree(tester);
  });

  testWidgets('m7: an empty-state message sits above the chrome', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(800, 420));
    await tester.tap(find.text('Tracks'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Search tracks'),
      'zzz',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final msg = tester.getRect(find.text('No tracks match "zzz".'));
    final chromeTop = tester.getTopLeft(find.byKey(AppShell.bottomStackKey)).dy;
    // The message's area runs under the chrome; it centres in what's left.
    final area = tester.getRect(find.byType(ListStatusMessage));
    expect(msg.bottom, lessThanOrEqualTo(chromeTop));
    expect((msg.center.dy - (area.top + chromeTop) / 2).abs(), lessThan(2));
    await teardownTree(tester);
  });

  // Audit 4B(b) F3: inside Search's padded feed the message is not padded
  // by the chrome again.
  testWidgets('Search no-match message: chrome insets applied once', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Search'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).hitTestable(), 'Nope');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final msg = tester.getRect(find.text('No results match "Nope".'));
    final feedTop = tester
        .getTopLeft(find.byType(CustomScrollView).hitTestable().first)
        .dy;
    // ListStatusMessage's own padding is 32; no extra top-bar inset.
    expect(msg.top - feedTop, lessThan(32 + 24));
    await teardownTree(tester);
  });

  // Audit 4B(b) F4: the root keeps its top inset while covered, so it does
  // not jump when the pushed route leaves.
  testWidgets('the root feed keeps its top inset under a pushed route', (
    tester,
  ) async {
    await pumpShell(tester);
    final home = find.byType(HomePage, skipOffstage: false);
    final top = ShellChromeInsets.of(tester.element(home)).top;
    expect(top, greaterThan(0));
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(ShellChromeInsets.of(tester.element(home)).top, top);
    await teardownTree(tester);
  });

  // Audit 4B(b) F5: mid-session resize and safe-area change; reduced motion.
  testWidgets('a window resize and a safe-area change keep the insets right', (
    tester,
  ) async {
    await pumpShell(tester);
    final home = find.byType(HomePage, skipOffstage: false);
    for (final size in [const Size(420, 900), const Size(1400, 700)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpAndSettle();
      expect(
        ShellChromeInsets.of(tester.element(home)).bottom,
        tester.getSize(find.byKey(AppShell.bottomStackKey)).height,
      );
    }
    tester.view.padding = const FakeViewPadding(top: 40, bottom: 30);
    await tester.pumpAndSettle();
    final insets = ShellChromeInsets.of(tester.element(home));
    expect(insets.top, tester.getSize(find.byKey(AppShell.topBarKey)).height);
    expect(
      insets.bottom,
      tester.getSize(find.byKey(AppShell.bottomStackKey)).height,
    );
    expect(tester.getSize(find.byType(NavigationBar)).height, 80 + 30);
    tester.view.reset();
    await tester.pumpAndSettle();
    await teardownTree(tester);
  });

  testWidgets('reduced motion also selects the reduced-effects glass', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpShell(tester);
    expect(find.byType(BackdropFilter), findsNothing);
    await teardownTree(tester);
  });

  // Re-audit 4B #5: side safe areas on Search and on the bottom stack; a
  // snackbar sits just above a soft keyboard.
  testWidgets('Search and the bottom stack keep the side safe areas', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.padding = const FakeViewPadding(left: 44, right: 44);
    addTearDown(tester.view.resetPadding);
    await pumpShell(tester);
    await showPlayer(tester);
    expect(
      tester.getRect(find.byType(MiniPlayer)).left,
      greaterThanOrEqualTo(44),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Search'),
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.getRect(
      find.descendant(
        of: find.byType(SearchPage),
        matching: find.byType(TextField),
      ),
    );
    expect(field.left, greaterThanOrEqualTo(44));
    await teardownTree(tester);
  });

  testWidgets('a snackbar shown with the keyboard up sits above it', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(800, 600));
    tester.view.viewInsets = const FakeViewPadding(bottom: 100);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    ScaffoldMessenger.of(
      tester.element(find.byType(HomePage)),
    ).showSnackBar(const SnackBar(content: Text('Saved')));
    await tester.pumpAndSettle();
    final bar = tester.getRect(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(bar.bottom, lessThanOrEqualTo(500));
    expect(
      bar.bottom,
      greaterThan(500 - 40),
      reason: 'just above the keyboard, not a stale stack height above it',
    );
    await teardownTree(tester);
  });
}
