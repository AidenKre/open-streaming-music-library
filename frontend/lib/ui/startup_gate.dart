import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/ui/disconnect_controller.dart';
import 'package:frontend/ui/login_page.dart';
import 'package:frontend/main.dart';

class StartupGate extends ConsumerStatefulWidget {
  final VoidCallback? onLocalResetComplete;

  const StartupGate({super.key, this.onLocalResetComplete});

  @override
  ConsumerState<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<StartupGate> {
  bool _ready = false;
  bool _hasServerUrl = false;
  bool _resetting = false;
  String? _connectError;

  @override
  void initState() {
    super.initState();
    _checkServerUrl();
  }

  Future<void> _checkServerUrl() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final url = prefs.getString('serverUrl');
    if (url == null) {
      setState(() => _ready = true);
      return;
    }
    ApiClient.init(url);
    final result = await ApiClient.instance.healthCheck();
    switch (result.status) {
      case HealthStatus.ok:
        setState(() {
          _hasServerUrl = true;
          _ready = true;
        });
      case HealthStatus.unreachable:
        // Network is down but the saved URL is still presumed valid — drop
        // into the app in offline mode rather than logging the user out.
        ref.read(offlineModeProvider.notifier).enterOffline();
        setState(() {
          _hasServerUrl = true;
          _ready = true;
        });
      case HealthStatus.serverError:
        // Server is reachable but rejected us — clear the saved URL and
        // surface the error on the login screen.
        await prefs.remove('serverUrl');
        setState(() {
          _connectError = result.message;
          _ready = true;
        });
    }
  }

  /// First-time / manual connect. Unlike a previously-saved URL, a manually
  /// entered host is not yet trusted — it may be mistyped or not an OSML
  /// server. So we only persist it and enter the app after a passing health
  /// check; any failure keeps the user on the connect screen with an error.
  Future<void> _onConnect(String url) async {
    ApiClient.init(url);
    final result = await ApiClient.instance.healthCheck();
    switch (result.status) {
      case HealthStatus.ok:
        final prefs = await ref.read(sharedPreferencesProvider.future);
        await prefs.setString('serverUrl', url);
        // Clear any stale offline state before entering the app. A prior
        // disconnect-while-offline can leave offline mode re-armed; without
        // this the app would open showing the offline banner until the next
        // health poll happens to clear it.
        ref.read(offlineModeProvider.notifier).exitOffline();
        setState(() {
          _hasServerUrl = true;
          _connectError = null;
        });
      case HealthStatus.unreachable:
      case HealthStatus.serverError:
        // Don't persist an unproven URL, and don't drop into an empty
        // offline app — surface the error so the user can fix the address.
        setState(() => _connectError = result.message);
    }
  }

  Future<void> _onDisconnect() async {
    setState(() {
      _resetting = true;
      _connectError = null;
    });
    LocalResetException? partialFailure;
    try {
      await ref.read(localResetServiceProvider).reset();
    } on LocalResetException catch (e) {
      // A subset of subsystems failed to reset. Every step still ran (see
      // LocalResetService.reset), but state is now partial — the live
      // session is unusable. Surface the failure to the user, then still
      // proceed with the scope rebuild so they land on a clean login
      // instead of a half-wiped app shell.
      partialFailure = e;
    } catch (e) {
      // Unexpected error from reset() itself (not a per-step failure). Treat
      // the same way — show what happened, then fall through to rebuild.
      partialFailure = LocalResetException([
        LocalResetFailure(LocalResetService, e, StackTrace.current),
      ]);
    }
    if (!mounted) return;
    if (partialFailure != null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reset incomplete'),
          content: Text(
            'Some local data could not be cleared:\n\n$partialFailure',
          ),
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
    setState(() {
      _hasServerUrl = false;
      _resetting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _resetting) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_hasServerUrl) {
      return LoginPage(onConnect: _onConnect, error: _connectError);
    }
    // Scope the disconnect controller to the live-session subtree only.
    // Login and reset screens stay outside this override and (correctly) see
    // disconnectControllerProvider == null.
    return ProviderScope(
      overrides: [
        disconnectControllerProvider.overrideWithValue(
          DisconnectController(_onDisconnect),
        ),
      ],
      child: const AppShell(),
    );
  }
}
