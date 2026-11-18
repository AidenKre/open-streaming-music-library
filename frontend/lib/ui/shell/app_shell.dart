import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/home/home_suggestions_controller.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/shell/shell_bottom_stack.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';
import 'package:frontend/ui/shell/shell_route_observer.dart';
import 'package:frontend/ui/shell/shell_tab.dart';
import 'package:frontend/ui/shell/shell_top_bar.dart';
import 'package:frontend/ui/widgets/top_bar_actions.dart';

export 'package:frontend/ui/shell/shell_tab.dart' show ShellTab;

/// The live-session shell: Home and Search, each with its own nested
/// navigator kept alive in an [IndexedStack], above the banners, the mini
/// player and the tab bar.
///
/// * Switching tabs keeps each tab's routes, query, chip and scroll.
/// * Re-tapping a tab with a route on top pops it to its root only;
///   re-tapping a visible root scrolls its feed to the top. Neither clears
///   query/filter or touches playback.
/// * Search's field is focused when Search is shown at its root (direct tab
///   activation or Home's search header), never when returning to a
///   retained Search detail. Leaving Search unfocuses it: [IndexedStack]
///   excludes focus from its hidden children (pinned by the shell tests).
///   It never autofocuses (both roots are mounted).
/// * The shell's top bar shows only while the active tab is at its root;
///   pushed routes (browse pages, details) bring their own back AppBar.
///   Each navigator has an observer that schedules this re-evaluation after
///   any route mutation (never a synchronous setState during a navigator
///   build, and no assumption that pushes and pops pair up).
/// * Back: the session host asks this route to pop; the shell pops the
///   active tab's top route, and at a root does nothing (app-root policy).
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  /// The floating top bar (shown only at the active tab's root).
  static const topBarKey = ValueKey('shell.topBar');

  /// The floating bottom stack: banners, mini player, tab bar.
  static const bottomStackKey = ValueKey('shell.bottomStack');

  /// The banner part of the bottom stack (capped on short windows).
  static const bannerRegionKey = ValueKey('shell.banners');

  @override
  ConsumerState<AppShell> createState() => AppShellState();
}

class AppShellState extends ConsumerState<AppShell> {
  ShellTab _tab = ShellTab.home;

  final _navigatorKeys = {
    for (final tab in ShellTab.values)
      tab: GlobalKey<NavigatorState>(debugLabel: 'shell.${tab.name}'),
  };
  late final _observers = {
    for (final tab in ShellTab.values)
      tab: ShellRouteObserver(_scheduleChromeUpdate),
  };
  final _homeKey = GlobalKey<HomePageState>();
  final _searchKey = GlobalKey<SearchPageState>();

  bool _activeAtRoot = true;
  bool _chromeUpdateScheduled = false;

  /// What the suggestions controller was last told (Home starts visible).
  bool? _homeVisible; // null until the first report
  bool _appVisible = true;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final launch = WidgetsBinding.instance.lifecycleState;
    _appVisible =
        launch == null ||
        launch == AppLifecycleState.resumed ||
        launch == AppLifecycleState.inactive;
    // Tell the controller where Home stands once the first frame is built
    // (an app that starts in the background gets its first frame on resume).
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncHomeVisible());
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _appVisible =
            state == AppLifecycleState.resumed ||
            state == AppLifecycleState.inactive;
        _syncHomeVisible();
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Forward "Home's root is what the user sees" to the controller (SC-26),
  /// only when it changes. Never called during build.
  void _syncHomeVisible() {
    if (!mounted) return;
    final visible =
        _appVisible && _tab == ShellTab.home && _atRoot(ShellTab.home);
    if (visible == _homeVisible) return;
    _homeVisible = visible;
    ref.read(homeSuggestionsControlsProvider).setHomeVisible(visible);
  }

  /// The visible tab.
  ShellTab get tab => _tab;

  NavigatorState? _navigator(ShellTab tab) => _navigatorKeys[tab]!.currentState;

  /// No page route above the tab's first route. Popups and sheets (a card
  /// menu) don't count: the tab is still showing its root.
  bool _atRoot(ShellTab tab) => !_observers[tab]!.hasPageAboveRoot;

  /// Re-evaluate the top bar after a route mutation, once, after the frame.
  void _scheduleChromeUpdate() {
    if (_chromeUpdateScheduled) return;
    _chromeUpdateScheduled = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _chromeUpdateScheduled = false;
        if (!mounted) return;
        final atRoot = _atRoot(_tab);
        if (atRoot != _activeAtRoot) setState(() => _activeAtRoot = atRoot);
        _syncHomeVisible();
      })
      ..scheduleFrame();
  }

  /// A tab-bar tap.
  void selectTab(ShellTab next) {
    if (next == _tab) {
      _reselect(next);
      return;
    }
    // The bar follows the new tab in this very frame.
    setState(() {
      _tab = next;
      _activeAtRoot = _atRoot(next);
    });
    _syncHomeVisible();
    if (next == ShellTab.search) _focusSearchWhenAtRoot();
  }

  void _reselect(ShellTab tab) {
    final navigator = _navigator(tab);
    if (navigator != null && navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
      return;
    }
    switch (tab) {
      case ShellTab.home:
        _homeKey.currentState?.scrollToTop();
      case ShellTab.search:
        _searchKey.currentState?.scrollToTop();
    }
  }

  /// Home's search header: show Search at its root and focus the field.
  void activateSearch() {
    // Search may be hidden: remove its routes without a pop animation
    // nobody would see, so its root (and bar) show at once.
    final navigator = _navigator(ShellTab.search);
    if (navigator != null) {
      for (final route
          in _observers[ShellTab.search]!.routesAboveRoot.reversed) {
        navigator.removeRoute(route);
      }
    }
    setState(() {
      _tab = ShellTab.search;
      _activeAtRoot = _atRoot(ShellTab.search);
    });
    _syncHomeVisible();
    _focusSearchWhenAtRoot();
  }

  /// After the frame (the root is mounted and visible): focus the field only
  /// if Search is still the visible tab and at its root.
  void _focusSearchWhenAtRoot() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Nothing at all above the root: not a page, and not a sheet either
      // (the field must not take focus under a modal barrier).
      final nothingAbove = !(_navigator(ShellTab.search)?.canPop() ?? true);
      if (!mounted || _tab != ShellTab.search || !nothingAbove) return;
      _searchKey.currentState?.focusSearchField();
    });
  }

  Widget _tabNavigator(ShellTab tab, Widget Function() root) {
    return Navigator(
      key: _navigatorKeys[tab],
      observers: [_observers[tab]!],
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        settings: RouteSettings(name: 'shell/${tab.name}'),
        builder: (_) => root(),
      ),
    );
  }

  /// Measured heights of the floating chrome (actual layout, phase-4 §8).
  double _topBarHeight = 0;
  double _bottomStackHeight = 0;

  /// Content toward the screen edge (phase-4 §8): banners (capped at 30%
  /// of the body, scrolling, with a count when capped), mini player,
  /// Home/Search navigation incl. the bottom safe area. The whole stack is
  /// at most the body's height and scrolls (navigation first in view) on
  /// impractically short windows instead of overflowing.
  Widget _bottomStack(double bodyHeight, bool isOffline) {
    final session = ref.watch(sessionControlsProvider);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: bodyHeight),
      child: MeasuredSize(
        key: AppShell.bottomStackKey,
        onChange: (size) => setState(() => _bottomStackHeight = size.height),
        child: ShellBottomStack(
          bodyHeight: bodyHeight,
          isOffline: isOffline,
          session: session,
          selectedTab: _tab,
          onSelectTab: selectTab,
          bannerRegionKey: AppShell.bannerRegionKey,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isOffline = ref.watch(offlineModeProvider);
    // A soft keyboard hides the bottom stack (its services keep running);
    // the Scaffold's own resize reserves the keyboard inset once.
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    // In a landscape keyboard viewport the bar can leave less than one
    // input row. Give that space to the editor until the keyboard closes.
    final compactKeyboard = keyboardUp &&
        MediaQuery.sizeOf(context).height -
                MediaQuery.viewInsetsOf(context).bottom <
            _topBarHeight + kMinInteractiveDimension + 16;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // maybePop: the tab's top route may refuse (its own PopScope).
        _navigator(_tab)?.maybePop();
      },
      // Snackbars float above the bottom chrome (audit 4B(a) M4).
      child: Theme(
        data: _withChromeSnackBars(
          Theme.of(context),
          keyboardUp ? 0 : _bottomStackHeight,
        ),
        child: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              // Content runs the full height under the chrome; every nested
              // surface pads itself by these insets.
              ShellChromeInsets(
                // Root surfaces keep the bar's measured height even while a
                // route covers them, so a root never jumps when it reappears
                // (audit 4B(b) F4; pushed routes have their own AppBar).
                top: compactKeyboard ? 0 : _topBarHeight,
                bottom: keyboardUp ? 0 : _bottomStackHeight,
                child: IndexedStack(
                  index: _tab.index,
                  children: [
                    _tabNavigator(
                      ShellTab.home,
                      () => HomePage(
                        key: _homeKey,
                        onSearchActivated: activateSearch,
                      ),
                    ),
                    _tabNavigator(
                      ShellTab.search,
                      () => SearchPage(key: _searchKey),
                    ),
                  ],
                ),
              ),
              if (_activeAtRoot && !compactKeyboard)
                Positioned(
                  // Keys keep each overlay's element (and state) when the
                  // other comes or goes (audit 4B(a) M3).
                  key: const ValueKey('shell.overlay.top'),
                  top: 0,
                  left: 0,
                  right: 0,
                  child: MeasuredSize(
                    key: AppShell.topBarKey,
                    onChange: (size) =>
                        setState(() => _topBarHeight = size.height),
                    child: ShellTopBar(
                      title: _tab == ShellTab.home ? 'OSML' : 'Search',
                      actions: buildTopBarActions(context, ref),
                    ),
                  ),
                ),
              if (!keyboardUp)
                Positioned(
                  key: const ValueKey('shell.overlay.bottom'),
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LayoutBuilder(
                    builder: (context, constraints) => _bottomStack(
                      // The AVAILABLE body height: the window minus the top
                      // bar when shown (the Positioned child is unbounded
                      // upward; the stack must never cover the bar, audit
                      // 4B(b) F1).
                      // A pushed route's own AppBar (+ top safe area) is
                      // kept clear the same way (re-audit 4B #1).
                      MediaQuery.sizeOf(context).height -
                          (_activeAtRoot
                              ? _topBarHeight
                              : kToolbarHeight +
                                    MediaQuery.paddingOf(context).top),
                      isOffline,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static ThemeData _withChromeSnackBars(ThemeData theme, double bottom) =>
      theme.copyWith(
        snackBarTheme: theme.snackBarTheme.copyWith(
          behavior: SnackBarBehavior.floating,
          insetPadding: EdgeInsets.fromLTRB(16, 8, 16, bottom + 8),
        ),
      );
}
