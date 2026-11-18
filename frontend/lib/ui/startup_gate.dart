import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/shell/app_shell.dart';
import 'package:frontend/ui/create_account_page.dart';
import 'package:frontend/ui/login_page.dart';
import 'package:frontend/ui/server_address_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/widgets/reset_confirm_sheet.dart';

/// Renders the session phase: splash while starting/resetting, the login
/// screen, or the app. Every input goes to [SessionControls]; the rules live
/// in the model `SessionService` (SC-26).
class StartupGate extends ConsumerStatefulWidget {
  const StartupGate({super.key});

  @override
  ConsumerState<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<StartupGate> {
  late final SessionControls _session = ref.read(sessionControlsProvider);
  bool _finishingReset = false;
  bool _askingServerSwitch = false;
  bool _askingUserSwitch = false;
  bool _askingReset = false;

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
    if (_session.pendingUserSwitch != null) _askUserSwitch();
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

  /// A login found another user than this device's data belongs to: confirm
  /// the reset (spec 7.5). One at a time; dismissing counts as Cancel.
  Future<void> _askUserSwitch() async {
    final username = _session.pendingUserSwitch;
    if (_askingUserSwitch || username == null) return;
    _askingUserSwitch = true;
    try {
      final losses = await _session.pendingLossSummaries();
      if (!mounted) return;
      final confirmed = await showResetConfirmSheet(
        context,
        title: 'Log in as $username?',
        body:
            "Signing in as $username removes the previous account's "
            'downloads and unsent plays from this device.',
        confirmLabel: 'Remove and log in',
        losses: losses,
      );
      if (!mounted) return;
      if (confirmed) {
        await _session.confirmUserSwitch();
      } else {
        await _session.cancelUserSwitch();
      }
    } finally {
      _askingUserSwitch = false;
    }
  }

  /// The refused database's Reset…: the shared Disconnect confirmation,
  /// then the reset. One at a time: a second tap while the losses are read
  /// or the sheet is open does nothing.
  Future<void> _resetRefusedDatabase() async {
    if (_askingReset) return;
    _askingReset = true;
    try {
      final losses = await _session.pendingLossSummaries();
      if (!mounted) return;
      final confirmed = await showDisconnectConfirmSheet(
        context,
        losses: losses,
      );
      if (confirmed && mounted) await _session.disconnect();
    } finally {
      _askingReset = false;
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
    if (failure != null && failure.quiesceOnly) {
      developer.log('Reset completed; quiesce issues: $failure', name: 'StartupGate');
    }
    // The sentence is the model's, never a failure's own text (row 66).
    final notSaved = _session.signInNotSavedNotice;
    final message = notSaved ?? _session.resetIncompleteMessage;
    if (failure != null && failure.wipeFailed && message != null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            notSaved != null ? 'Sign-in not saved' : 'Reset incomplete',
          ),
          content: Text(message),
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
    // The model rebuilds the scope (which disposes this gate) or, without a
    // rebuild hook, returns to the server-address screen.
    await _session.acknowledgeReset();
    _finishingReset = false;
  }

  @override
  Widget build(BuildContext context) {
    switch (_session.phase) {
      case SessionPhase.starting:
      case SessionPhase.resetting:
      case SessionPhase.signingOut:
      case SessionPhase.resetComplete:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case SessionPhase.serverAddress:
        return ServerAddressPage(
          onConnect: _session.connect,
          error: _session.connectError,
        );
      case SessionPhase.logIn:
        return const LoginPage();
      case SessionPhase.createAccount:
        return const CreateAccountPage();
      case SessionPhase.credentialsUnavailable:
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The database was made by another version of the app
                  // (pre-merge review D3-01, text approved 2026-11-18):
                  // trying again cannot open it; Reset… deletes it.
                  if (_session.databaseRefused) ...[
                    const Text(
                      "This device's saved app data was made by a different "
                      "version of the app and can't be opened. Resetting "
                      "removes this device's downloads, settings and "
                      'sign-in. Nothing on the server changes.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _resetRefusedDatabase,
                      child: const Text('Reset…'),
                    ),
                  ] else ...[
                    // A fault thrown at launch: whether a sign-in is stored is
                    // not known, so only the saved session is named.
                    if (_session.launchFailed) ...[
                      const Text(
                        "This device's saved session could not be read.",
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Logging in again replaces any sign-in saved on this '
                        'device.',
                        textAlign: TextAlign.center,
                      ),
                    ] else ...[
                      const Text(
                        'Your sign-in could not be read.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Your saved sign-in is still on this device. Try again, or log in again to '
                        'replace it.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _session.retryCredentials,
                      child: const Text('Try again'),
                    ),
                    TextButton(
                      onPressed: _session.logInAgain,
                      child: const Text('Log in again'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      case SessionPhase.live:
        // Session destinations (Settings, Downloading, Conversions) and the
        // full player live on the session host above the shell (SC-08).
        return const SessionHost(root: AppShell());
    }
  }
}
