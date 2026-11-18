import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/session_controller.dart';

/// Log in to the saved server (spec 7.1). A view over [SessionControls]:
/// it shows the controller's state and forwards every input.
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  late final SessionControls _controls = ref.read(sessionControlsProvider);
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controls.addListener(_changed);
  }

  @override
  void dispose() {
    _controls.removeListener(_changed);
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _logIn() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _controls.login(_username.text, _password.text);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final error = _controls.authError;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('OSML', style: Theme.of(context).textTheme.headlineLarge),
              const SizedBox(height: 8),
              Text('Server: ${_controls.serverUrl ?? ''}'),
              const SizedBox(height: 24),
              KeyedSubtree(
                key: const Key('login.username'),
                child: TextField(
                  controller: _username,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    border: OutlineInputBorder(),
                  ),
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                ),
              ),
              const SizedBox(height: 12),
              KeyedSubtree(
                key: const Key('login.password'),
                child: TextField(
                  controller: _password,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                  onSubmitted: (_) => _logIn(),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _logIn,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Log in'),
                ),
              ),
              TextButton(
                onPressed: _controls.showCreateAccount,
                child: const Text('Create account'),
              ),
              TextButton(
                onPressed: _controls.changeServer,
                child: const Text('Change server'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
