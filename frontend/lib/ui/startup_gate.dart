import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/shell/app_shell.dart';
import 'package:frontend/ui/login_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';

/// Renders the session phase: splash while starting/resetting, the login
/// screen, or the app. Every input goes to [SessionControls]; the rules live
/// in the model `SessionService` (SC-26).
class StartupGate extends ConsumerStatefulWidget {
  final VoidCallback? onLocalResetComplete;

  const StartupGate({super.key, this.onLocalResetComplete});

  @override
  ConsumerState<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<StartupGate> {
  late final SessionControls _session = ref.read(sessionControlsProvider);
  bool _finishingReset = false;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    _session.start();
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {});
    if (_session.phase == SessionPhase.resetComplete) _finishReset();
  }

  /// Show a partial reset honestly, then rebuild the provider scope (or, in
  /// tests without a rebuild hook, return to the login screen).
  Future<void> _finishReset() async {
    if (_finishingReset) return;
    _finishingReset = true;
    final failure = _session.resetFailure;
    if (failure != null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reset incomplete'),
          content: Text('Some local data could not be cleared:\n\n$failure'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (!mounted) return;
    }
    final onLocalResetComplete = widget.onLocalResetComplete;
    if (onLocalResetComplete != null) {
      onLocalResetComplete();
      return;
    }
    _finishingReset = false;
    _session.acknowledgeReset();
  }

  @override
  Widget build(BuildContext context) {
    switch (_session.phase) {
      case SessionPhase.starting:
      case SessionPhase.resetting:
      case SessionPhase.resetComplete:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case SessionPhase.signedOut:
        return LoginPage(
          onConnect: _session.connect,
          error: _session.connectError,
        );
      case SessionPhase.live:
        // Session destinations (Settings, Downloading, Conversions) and the
        // full player live on the session host above the shell (SC-08).
        return const SessionHost(root: AppShell());
    }
  }
}
