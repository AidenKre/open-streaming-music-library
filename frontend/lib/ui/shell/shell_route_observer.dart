import 'package:flutter/widgets.dart';

/// Tracks a tab navigator's routes and tells the shell when they change.
/// Every mutation is mirrored (push, pop, remove, replace), so nothing
/// assumes pushes and pops pair up.
class ShellRouteObserver extends NavigatorObserver {
  ShellRouteObserver(this._changed);

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
