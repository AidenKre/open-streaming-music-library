import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/shell/app_shell.dart';
import 'package:frontend/ui/login_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/widgets/reset_confirm_sheet.dart';

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
  bool _askingServerSwitch = false;

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
    if (_session.pendingServerSwitch != null) _askServerSwitch();
  }

  /// A login found a different server: confirm the reset, naming what it
  /// loses (SC-01 rule 1, SC-15), with the shared reset confirmation. One
  /// at a time; dismissing counts as Cancel.
  Future<void> _askServerSwitch() async {
    final url = _session.pendingServerSwitch;
    if (_askingServerSwitch || url == null) return;
    _askingServerSwitch = true;
    try {
      final losses = await _session.pendingLossSummaries();
      if (!mounted) return;
      final confirmed = await showResetConfirmSheet(
        context,
        title: 'Connect to a different server?',
        body:
            'The server at $url is not the one this library belongs to. '
            'Connecting resets this device: the local library, downloads, '
            'queue and settings are deleted.',
        confirmLabel: 'Reset and connect',
        losses: losses,
      );
      if (!mounted) return;
      if (confirmed) {
        await _session.confirmServerSwitch();
      } else {
        _session.cancelServerSwitch();
      }
    } finally {
      _askingServerSwitch = false;
    }
  }

  /// Show a partial reset honestly, then rebuild the provider scope (or, in
  /// tests without a rebuild hook, return to the login screen).
  Future<void> _finishReset() async {
    if (_finishingReset) return;
    _finishingReset = true;
    final failure = _session.resetFailure;
    // Only a failed wipe leaves data behind. A quiesce step that failed or
    // timed out (a request still in flight) is logged: the wipe ran and the
    // fence keeps its late work out of the new store.
    if (failure != null && failure.failures.every((f) => f.quiesce)) {
      developer.log('Reset completed; quiesce issues: $failure', name: 'StartupGate');
    }
    if (failure != null && failure.failures.any((f) => !f.quiesce)) {
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
