import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
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
    if (url != null) {
      ApiClient.init(url);
      final error = await ApiClient.instance.healthCheck();
      if (error != null) {
        await prefs.remove('serverUrl');
        setState(() {
          _connectError = error;
          _ready = true;
        });
      } else {
        setState(() {
          _hasServerUrl = true;
          _ready = true;
        });
      }
    } else {
      setState(() => _ready = true);
    }
  }

  Future<void> _onConnect(String url) async {
    ApiClient.init(url);
    final error = await ApiClient.instance.healthCheck();
    if (error != null) {
      setState(() => _connectError = error);
      return;
    }
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.setString('serverUrl', url);
    setState(() {
      _hasServerUrl = true;
      _connectError = null;
    });
  }

  Future<void> _onDisconnect() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.remove('serverUrl');
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
