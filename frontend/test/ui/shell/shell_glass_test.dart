import 'dart:ui' show ImageFilter;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/shell/app_shell.dart';
import 'package:frontend/ui/shell/glass.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';

/// 4B.2 (phase-4 §8): clipped glass chrome, pass-through overlay space,
/// reachable controls, and a reduced-effects fallback.
void main() {
  late AppDatabase db;
  late BrowseHarness h;

  setUpAll(() => ApiClient.init('http://localhost:8000'));

  setUp(() async {
    initCoverArtCache(CoverArtCacheManager.noop());
    db = AppDatabase(NativeDatabase.memory());
    h = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await db.close();
    await h.dispose();
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    bool highContrast = false,
  }) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(highContrast: highContrast);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
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

  testWidgets('every blur is clipped to its own bar, none covers the view', (
    tester,
  ) async {
    await pumpShell(tester);
    final filters = find.byType(BackdropFilter);
    expect(filters, findsWidgets);
    final view = tester.getSize(find.byType(AppShell));
    for (final e in filters.evaluate()) {
      final f = find.byWidget(e.widget);
      expect(
        find.ancestor(of: f, matching: find.byType(ClipRRect)),
        findsWidgets,
        reason: 'BackdropFilter blurs only within its ancestor clip',
      );
      final size = tester.getSize(f);
      expect(
        size.height,
        lessThan(view.height / 2),
        reason: 'not the viewport',
      );
      expect((e.widget as BackdropFilter).filter, isA<ImageFilter>());
    }
    await teardownTree(tester);
  });

  testWidgets('top overlay: separate capsules; the space between them '
      'passes taps through to the content', (tester) async {
    await pumpShell(tester);
    final bar = tester.getRect(find.byKey(AppShell.topBarKey));
    final probe = Offset(bar.center.dx, bar.center.dy);
    final result = HitTestResult();
    tester.binding.hitTestInView(result, probe, tester.view.viewId);
    final barBox = tester.renderObject(find.byKey(AppShell.topBarKey));
    final content = tester.renderObject(find.byType(IndexedStack));
    bool inside(Object target, RenderObject ancestor) {
      RenderObject? n = target is RenderObject ? target : null;
      while (n != null) {
        if (identical(n, ancestor)) return true;
        n = n.parent;
      }
      return false;
    }

    expect(
      result.path.where((e) => inside(e.target, barBox)),
      isEmpty,
      reason: 'nothing in the top bar takes a tap in its empty middle',
    );
    expect(
      inside(result.path.first.target, content),
      isTrue,
      reason:
          'the tab content underneath gets it '
          '(${result.path.first.target.runtimeType})',
    );
    // The capsules themselves still take taps.
    final settings = tester.getCenter(find.byTooltip('Settings'));
    final onButton = HitTestResult();
    tester.binding.hitTestInView(onButton, settings, tester.view.viewId);
    expect(onButton.path.any((e) => inside(e.target, barBox)), isTrue);
    await teardownTree(tester);
  });

  testWidgets('top-bar buttons: tooltips and >= 48 px targets', (tester) async {
    await pumpShell(tester);
    for (final tip in ['Downloads', 'Settings']) {
      final button = find.byTooltip(tip);
      expect(button, findsOneWidget);
      final size = tester.getSize(button);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    await teardownTree(tester);
  });

  testWidgets('reduced effects (high contrast): no blur, opaque tint', (
    tester,
  ) async {
    await pumpShell(tester, highContrast: true);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      GlassSurface.reducedEffects(tester.element(find.byType(AppShell))),
      isTrue,
    );
    await teardownTree(tester);
  });

  testWidgets('semantics: the bar title is a header; buttons and tabs are '
      'labelled', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpShell(tester);
    expect(
      tester.getSemantics(find.text('OSML')),
      matchesSemantics(label: 'OSML', isHeader: true),
    );
    expect(find.bySemanticsLabel('Settings'), findsOneWidget);
    expect(find.bySemanticsLabel('Downloads'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Home')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Search')), findsWidgets);
    handle.dispose();
    await teardownTree(tester);
  });

  testWidgets('keyboard: Tab reaches the top-bar buttons and both tabs', (
    tester,
  ) async {
    await pumpShell(tester);
    final reached = <String>{};
    for (var i = 0; i < 40; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null) continue;
      final tooltip = ctx.findAncestorWidgetOfExactType<Tooltip>()?.message;
      if (tooltip != null) reached.add(tooltip);
      final dest = ctx.findAncestorWidgetOfExactType<NavigationDestination>();
      if (dest != null) reached.add(dest.label);
    }
    expect(reached, containsAll(['Downloads', 'Settings', 'Home', 'Search']));
    await teardownTree(tester);
  });

  // Live C05 screenshot: the action capsule sat mid-right (a loose
  // Flexible title shared the free space with the Spacer).
  testWidgets('top bar: title capsule at the left edge, actions at the right', (
    tester,
  ) async {
    await pumpShell(tester);
    final width = tester.getSize(find.byType(AppShell)).width;
    final settings = tester.getRect(find.byTooltip('Settings'));
    expect(
      width - settings.right,
      lessThan(12 + 8 + 1),
      reason: 'actions capsule ends at the bar\'s right padding',
    );
    final title = tester.getRect(
      find.descendant(
        of: find.byKey(AppShell.topBarKey),
        matching: find.text('OSML'),
      ),
    );
    expect(title.left, lessThan(12 + 20 + 1));
    await teardownTree(tester);
  });
}
