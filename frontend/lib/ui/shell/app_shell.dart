import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/widgets/mini_player.dart';
import 'package:frontend/ui/widgets/offline_banner.dart';
import 'package:frontend/ui/widgets/pending_edits_banner.dart';
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
    _navigator(ShellTab.search)?.popUntil((route) => route.isFirst);
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

  @override
  Widget build(BuildContext context) {
    final isOffline = ref.watch(offlineModeProvider);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // maybePop: the tab's top route may refuse (its own PopScope).
        _navigator(_tab)?.maybePop();
      },
      child: Scaffold(
        appBar: _activeAtRoot
            ? AppBar(
                title: Text(_tab == ShellTab.home ? 'OSML' : 'Search'),
                actions: buildTopBarActions(context, ref),
              )
            : null,
        body: Column(
          children: [
            Expanded(
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
            const PendingEditsBanner(),
            const StaleDownloadsBanner(),
            if (isOffline) const OfflineBanner(),
            const MiniPlayer(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab.index,
          onDestinationSelected: (i) => selectTab(ShellTab.values[i]),
          destinations: [
            for (final tab in ShellTab.values)
              NavigationDestination(
                icon: Icon(tab.icon),
                selectedIcon: Icon(tab.selectedIcon),
                label: tab.label,
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

  /// A page route (not a popup or sheet) sits above the first route.
  bool get hasPageAboveRoot => _routes.any((r) => r is PageRoute && !r.isFirst);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
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
