import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/login_page.dart';
import 'package:frontend/main.dart';

class StartupGate extends ConsumerStatefulWidget {
  const StartupGate();

  @override
  ConsumerState<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<StartupGate> {
  bool _ready = false;
  bool _hasServerUrl = false;
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
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.remove('serverUrl');
    // No trusted server URL remains, so leave offline mode and stop the health
    // poll — otherwise the poll keeps hitting the now-stale base URL.
    ref.read(offlineModeProvider.notifier).exitOffline();
    setState(() {
      _hasServerUrl = false;
      _connectError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_hasServerUrl) {
      return LoginPage(onConnect: _onConnect, error: _connectError);
    }
    return AppShell(onDisconnect: _onDisconnect);
  }
}
