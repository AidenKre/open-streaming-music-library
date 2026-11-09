import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/shell/glass.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';
import 'package:frontend/ui/widgets/mini_player.dart';
import 'package:frontend/ui/widgets/offline_banner.dart';
import 'package:frontend/ui/widgets/pending_edits_banner.dart';
import 'package:frontend/ui/widgets/server_blocked_banner.dart';
import 'package:frontend/ui/widgets/stale_downloads_banner.dart';
import 'package:frontend/ui/widgets/top_bar_actions.dart';

/// The shell's tabs (phase-4 §3): Home first, then Search.
enum ShellTab {
  home('Home', Icons.home_outlined, Icons.home),
  search('Search', Icons.search, Icons.search);

  const ShellTab(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

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
      tab: _ShellRouteObserver(_scheduleChromeUpdate),
  };
  final _homeKey = GlobalKey<HomePageState>();
  final _searchKey = GlobalKey<SearchPageState>();

  bool _activeAtRoot = true;
  bool _chromeUpdateScheduled = false;

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
        child: GlassSurface(
          // The top safe area belongs to the top bar: without this the tab
          // bar's own SafeArea would add it again (audit 4B(a) M2). Side
          // safe areas apply to every row of the stack.
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: SafeArea(
              top: false,
              bottom: false,
              child: SingleChildScrollView(
                primary: false,
                reverse: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Blocked (different server) behaves as offline, so its
                    // banner replaces the offline one (SC-01 rule 1).
                    ListenableBuilder(
                      listenable: session,
                      builder: (context, _) => _BannerRegion(
                        key: AppShell.bannerRegionKey,
                        maxHeight: bodyHeight * 0.3,
                        banners: [
                          const PendingEditsBanner(),
                          const StaleDownloadsBanner(),
                          if (session.serverBlocked)
                            const ServerBlockedBanner()
                          else if (isOffline)
                            const OfflineBanner(),
                        ],
                      ),
                    ),
                    const MiniPlayer(),
                    NavigationBar(
                      // The glass behind it is the bar's surface.
                      backgroundColor: Colors.transparent,
                      elevation: 0,
                      selectedIndex: _tab.index,
                      onDestinationSelected: (i) =>
                          selectTab(ShellTab.values[i]),
                      destinations: [
                        for (final tab in ShellTab.values)
                          NavigationDestination(
                            icon: Icon(tab.icon),
                            selectedIcon: Icon(tab.selectedIcon),
                            label: tab.label,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
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
                    child: _ShellTopBar(
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

/// The banners above the mini player. Each banner decides its own
/// visibility; their MEASURED heights tell the region whether it fits in
/// [maxHeight]. When it doesn't, the region is capped, scrolls, and shows a
/// 'Notifications (n)' label counting the banners actually shown.
class _BannerRegion extends StatefulWidget {
  const _BannerRegion({
    super.key,
    required this.maxHeight,
    required this.banners,
  });

  final double maxHeight;
  final List<Widget> banners;

  @override
  State<_BannerRegion> createState() => _BannerRegionState();
}

class _BannerRegionState extends State<_BannerRegion> {
  final _heights = <Key, double>{};

  Key _keyOf(Widget banner) => ValueKey(banner.runtimeType);

  @override
  Widget build(BuildContext context) {
    final shown = {for (final b in widget.banners) _keyOf(b)};
    _heights.removeWhere((k, _) => !shown.contains(k));
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final banner in widget.banners)
          MeasuredSize(
            key: _keyOf(banner),
            onChange: (size) {
              if (mounted) {
                setState(() => _heights[_keyOf(banner)] = size.height);
              }
            },
            child: banner,
          ),
      ],
    );
    final total = _heights.values.fold<double>(0, (a, b) => a + b);
    if (total <= widget.maxHeight) return content;
    final count = _heights.values.where((h) => h > 0).length;
    final theme = Theme.of(context);
    return SizedBox(
      height: widget.maxHeight,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
              child: Text(
                'Notifications ($count)',
                style: theme.textTheme.labelMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              child: SingleChildScrollView(primary: false, child: content),
            ),
          ],
        ),
      ),
    );
  }
}

/// The floating top bar at a tab's root: two glass capsules (the title,
/// the top-bar actions) below the top safe area. The space between them is
/// empty, so taps there reach the content scrolling underneath.
class _ShellTopBar extends StatelessWidget {
  const _ShellTopBar({required this.title, required this.actions});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const capsule = BorderRadius.all(Radius.circular(28));
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            // The title takes the free space (left-aligned), so the
            // actions capsule sits at the right edge; the gap between them
            // stays pass-through (Align takes no hits itself).
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: GlassSurface(
                  borderRadius: capsule,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    // At least 48, growing with the text (audit 4B(b) F2).
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: 1,
                        heightFactor: 1,
                        child: Semantics(
                          header: true,
                          child: Text(
                            title,
                            style: theme.textTheme.titleLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (actions.isNotEmpty)
              GlassSurface(
                borderRadius: capsule,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Tracks a tab navigator's routes and tells the shell when they change.
/// Every mutation is mirrored (push, pop, remove, replace), so nothing
/// assumes pushes and pops pair up.
class _ShellRouteObserver extends NavigatorObserver {
  _ShellRouteObserver(this._changed);

  final VoidCallback _changed;
  final _routes = <Route<dynamic>>[];

  /// Page routes still sliding out after a pop (audit 4B(a) m1): they count
  /// as "above the root" until their exit animation ends, so the floating
  /// bar never overlaps an outgoing AppBar.
  final _leaving = <Route<dynamic>>{};

  /// A page route (not a popup or sheet) sits above the first route, or is
  /// still leaving.
  bool get hasPageAboveRoot =>
      _leaving.isNotEmpty || _routes.any((r) => r is PageRoute && !r.isFirst);

  /// Everything above the first route, top last.
  List<Route<dynamic>> get routesAboveRoot => [
    for (final r in _routes)
      if (!r.isFirst) r,
  ];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    final animation = route is PageRoute ? route.animation : null;
    if (animation != null && animation.status != AnimationStatus.dismissed) {
      _leaving.add(route);
      void listener(AnimationStatus status) {
        if (status != AnimationStatus.dismissed) return;
        animation.removeStatusListener(listener);
        if (_leaving.remove(route)) _changed();
      }

      animation.addStatusListener(listener);
    }
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _leaving.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (i >= 0) {
      if (newRoute == null) {
        _routes.removeAt(i);
      } else {
        _routes[i] = newRoute;
      }
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
    _changed();
  }
}
