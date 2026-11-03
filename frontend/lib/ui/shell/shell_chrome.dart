import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// The space the shell's floating chrome covers over its tabs' content
/// (phase-4 §8): [top] is the floating top bar's measured height, which the
/// tab ROOTS pad by (kept while a pushed route covers them, D33, so a root
/// never jumps when it reappears); [bottom] is the MEASURED bottom stack
/// (banners, mini player, navigation, bottom safe area).
///
/// Every nested surface applies [bottom] as terminal padding (see [padEnd]),
/// so content scrolls behind the glass while its last item stays reachable.
/// Only the roots (Home, Search) use [top]: pushed routes own an AppBar and
/// must not pad by it. Outside the shell (session routes, tests) both are
/// zero.
@immutable
class ShellChromeInsets extends InheritedWidget {
  const ShellChromeInsets({
    super.key,
    required this.top,
    required this.bottom,
    required super.child,
  });

  final double top;
  final double bottom;

  static ShellChromeInsets? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellChromeInsets>();

  /// [base] plus the bottom chrome: a scrolling surface inside the shell
  /// uses it as its padding so its last item ends above the glass.
  static EdgeInsets padEnd(
    BuildContext context, [
    EdgeInsets base = EdgeInsets.zero,
  ]) => base + EdgeInsets.only(bottom: of(context).bottom);

  /// The insets as padding (zero outside the shell).
  static EdgeInsets of(BuildContext context) {
    final insets = maybeOf(context);
    if (insets == null) return EdgeInsets.zero;
    return EdgeInsets.only(top: insets.top, bottom: insets.bottom);
  }

  @override
  bool updateShouldNotify(ShellChromeInsets old) =>
      old.top != top || old.bottom != bottom;
}

/// Reports its child's ACTUAL laid-out size after layout, and again only
/// when that size changes (never estimated from what the child contains).
/// The report is posted after the frame, so a listener may setState.
class MeasuredSize extends SingleChildRenderObjectWidget {
  const MeasuredSize({super.key, required this.onChange, required super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasuredSize(onChange);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderMeasuredSize).onChange = onChange;
  }
}

class _RenderMeasuredSize extends RenderProxyBox {
  _RenderMeasuredSize(this.onChange);

  ValueChanged<Size> onChange;
  Size? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final measured = size;
    if (measured == _reported) return;
    _reported = measured;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      // A newer layout may have superseded this one; report the latest.
      if (attached && _reported == measured) onChange(measured);
    });
  }
}
