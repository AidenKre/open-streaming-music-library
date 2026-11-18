import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/session_controller.dart';

/// Create an account on the saved server (spec 7.1). A view over
/// [SessionControls]: the input checks and the server's message come from
/// the controller.
class CreateAccountPage extends ConsumerStatefulWidget {
  const CreateAccountPage({super.key});

  @override
  ConsumerState<CreateAccountPage> createState() => _CreateAccountPageState();
}

class _CreateAccountPageState extends ConsumerState<CreateAccountPage> {
  late final SessionControls _controls = ref.read(sessionControlsProvider);
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
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
    _confirm.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _register() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _controls.register(_username.text, _password.text, _confirm.text);
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
              const SizedBox(height: 24),
              KeyedSubtree(
                key: const Key('createAccount.username'),
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
                key: const Key('createAccount.password'),
                child: TextField(
                  controller: _password,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    helperText: 'At least $minPasswordLength characters.',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                  textInputAction: TextInputAction.next,
                ),
              ),
              const SizedBox(height: 12),
              KeyedSubtree(
                key: const Key('createAccount.confirm'),
                child: TextField(
                  controller: _confirm,
                  decoration: const InputDecoration(
                    labelText: 'Confirm password',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                  onSubmitted: (_) => _register(),
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
                  onPressed: _busy ? null : _register,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create account'),
                ),
              ),
              TextButton(
                onPressed: _controls.showLogIn,
                child: const Text('I have an account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
