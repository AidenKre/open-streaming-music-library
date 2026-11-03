import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/conversions_page.dart';
import 'package:frontend/ui/downloading_page.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/settings_page.dart';

/// Session-level destinations (SC-08): pushed above the whole shell by the
/// session host, inside the live-session provider scope, so every one of
/// them has the session's dependencies. Later phases add their own values
/// (no pre-built placeholders).
enum SessionDestination {
  settings,

  /// The Downloading page (download queue progress) — distinct from Home's
  /// `downloaded` entry point.
  downloadProgress,

  /// Reached from Settings -> Library tools.
  conversions,
}

/// The page for a [SessionDestination].
Widget sessionDestinationPage(SessionDestination destination) =>
    switch (destination) {
      SessionDestination.settings => const SettingsPage(),
      SessionDestination.downloadProgress => const DownloadingPage(),
      SessionDestination.conversions => const ConversionsPage(),
    };

/// The session route host (SC-08): a navigator above the shell (its root
/// route) and below the live-session scope. Session destinations and
/// session-level modals (the full player) live here; system back reaches
/// them first, then the shell's own back handling.
class SessionHost extends ConsumerStatefulWidget {
  const SessionHost({super.key, required this.root});

  /// The shell (today `AppShell`).
  final Widget root;

  /// Pushes [destination] on the nearest session host.
  static Future<void> open(
    BuildContext context,
    SessionDestination destination,
  ) async {
    final scope = context
        .getInheritedWidgetOfExactType<_SessionNavigatorScope>();
    final navigator = scope?.navigatorKey.currentState;
    if (navigator == null) return; // no live session (e.g. disposed)
    await navigator.push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: 'session/${destination.name}'),
        builder: (_) => sessionDestinationPage(destination),
      ),
    );
  }

  /// Where a sheet started from tab content opens: the session navigator,
  /// so it sits above the shell's floating chrome and closes with the
  /// session (4B). Outside a session host, [context] itself.
  static BuildContext sheetContext(BuildContext context) {
    final scope = context
        .getInheritedWidgetOfExactType<_SessionNavigatorScope>();
    return scope?.navigatorKey.currentContext ?? context;
  }

  @override
  ConsumerState<SessionHost> createState() => _SessionHostState();
}

/// Opens a session destination from anywhere below the session host.
void openSession(BuildContext context, SessionDestination destination) {
  SessionHost.open(context, destination);
}

class _SessionHostState extends ConsumerState<SessionHost> {
  final _navigatorKey = GlobalKey<NavigatorState>(debugLabel: 'session');

  @override
  void initState() {
    super.initState();
    // One named step of the session host (spec §4): the initial sync. After
    // this build (the sync publishes provider state immediately).
    Future.microtask(() {
      if (mounted) ref.read(sessionControlsProvider).onSessionActivated();
    });
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    final field = focused?.findAncestorStateOfType<EditableTextState>();
    if (field != null) {
      // The field's own chain (its toolbar, Autocomplete options, a dialog
      // or sheet around it) goes first: the app's shortcuts deliver it.
      final route = ModalRoute.of(field.context);
      if (_autocompleteOptionsOpen(field.context) ||
          (route != null && route is! PageRoute)) {
        return KeyEventResult.ignored;
      }
      // A field on a page: Escape leaves the field (the field's own chain
      // stops at the page route's disabled dismiss); the next one is back.
      FocusManager.instance.primaryFocus?.unfocus();
      return KeyEventResult.handled;
    }
    if (focused != null) {
      final dismiss = Actions.maybeFind<DismissIntent>(focused);
      if (dismiss != null && dismiss.isEnabled(const DismissIntent())) {
        return KeyEventResult.ignored;
      }
    }
    _navigatorKey.currentState?.maybePop();
    return KeyEventResult.handled;
  }

  static bool _autocompleteOptionsOpen(BuildContext context) {
    OverlayPortal? optionsPortal;
    var showing = false;
    context.visitAncestorElements((e) {
      // RawAutocomplete owns the portal immediately around its field.
      // Its DismissIntent stays enabled even after the options close, so
      // that action's enablement alone cannot tell us whether it can dismiss.
      final widget = e.widget;
      if (widget is OverlayPortal) optionsPortal = widget;
      if (widget is RawAutocomplete) {
        showing = optionsPortal?.controller.isShowing ?? false;
        return false;
      }
      return true;
    });
    return showing;
  }

  @override
  Widget build(BuildContext context) {
    return _SessionNavigatorScope(
      navigatorKey: _navigatorKey,
      // Escape is back too, in the same order. A modal or menu that can
      // dismiss itself (an enabled DismissIntent action nearest the focus)
      // handles it through the app's shortcuts; otherwise the session
      // navigator's top route pops (on the shell: the active tab's route).
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKeyEvent,
        // System back: the session navigator's top route first (a session
        // destination or modal; on the shell route the shell's PopScope
        // decides: active tab detail, then the app-root policy). Never
        // `canPop: true`: a NavigatorPopHandler derives it from the last
        // nested-navigator notification, which goes stale across tab
        // switches and would let back exit the app (audit 4A(a) M1).
        child: PopScope<Object?>(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _navigatorKey.currentState?.maybePop();
          },
          child: Navigator(
            key: _navigatorKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              settings: const RouteSettings(name: 'session/shell'),
              builder: (_) => widget.root,
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionNavigatorScope extends InheritedWidget {
  const _SessionNavigatorScope({
    required this.navigatorKey,
    required super.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  bool updateShouldNotify(_SessionNavigatorScope old) =>
      old.navigatorKey != navigatorKey;
}
