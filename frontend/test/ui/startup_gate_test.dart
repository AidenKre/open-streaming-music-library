import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/ui/login_page.dart';
import 'package:frontend/ui/startup_gate.dart';

/// Forces [offlineModeProvider] to a starting value without running the real
/// health-poll timer. [OfflineModeNotifier.exitOffline] still works because
/// only `build()` is overridden.
class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

/// Drives the real `StartupGate._onConnect` through `LoginPage`'s callback,
/// without pumping the post-connect frame — so `AppShell` (whose provider
/// graph is irrelevant to these tests) is never built.
Future<LoginPage> _pumpLoginPage(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: StartupGate()),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(LoginPage), findsOneWidget);
  return tester.widget<LoginPage>(find.byType(LoginPage));
}

void main() {
  testWidgets('a successful manual connect clears offline mode', (tester) async {
    SharedPreferences.setMockInitialValues({}); // no saved serverUrl
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async => http.Response('{"message": "Healthy"}', 200)),
    );
    final container = ProviderContainer(
      overrides: [offlineModeProvider.overrideWith(() => _StubOffline(true))],
    );
    addTearDown(container.dispose);

    final loginPage = await _pumpLoginPage(tester, container);
    expect(container.read(offlineModeProvider), isTrue);

    await loginPage.onConnect('http://localhost:8000');

    expect(container.read(offlineModeProvider), isFalse,
        reason: 'a passing health check must clear offline mode on connect');
  });

  testWidgets('a failed manual connect does not strand the app offline',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async => throw const SocketException('unreachable')),
    );
    // Real notifier — starts online. The health check must not flip it.
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final loginPage = await _pumpLoginPage(tester, container);
    expect(container.read(offlineModeProvider), isFalse);

    await loginPage.onConnect('http://typo.invalid:9999');

    expect(container.read(offlineModeProvider), isFalse,
        reason: 'a failed connect attempt must not enter offline mode');
  });
}
