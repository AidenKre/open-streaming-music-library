import 'dart:io';
import 'package:drift/native.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/ui/server_address_page.dart';
import 'package:frontend/ui/startup_gate.dart';

import '../helpers/server_binding.dart';
import '../helpers/test_offline.dart';

/// Pumps the real `StartupGate` at the server-address screen; the tests call
/// `ServerAddressPage.onConnect` (the session controller's `connect`)
/// without pumping the post-connect frame, so `AppShell` (whose provider
/// graph is irrelevant to these tests) is never built.
Future<ServerAddressPage> _pumpServerAddressPage(
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
  expect(find.byType(ServerAddressPage), findsOneWidget);
  return tester.widget<ServerAddressPage>(find.byType(ServerAddressPage));
}

void main() {
  testWidgets('a successful manual connect clears offline mode', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({}); // no saved serverUrl
    final mock = MockClient((req) async => req.url.path.endsWith('/app/info')
        ? http.Response('{"server":{"instance_id":"inst-1"},"auth":{"version":1,"signup_enabled":true}}', 200)
        : http.Response('{"message": "Healthy"}', 200));
    // SC-01: connect writes the binding row and verifies the server's
    // identity through the binding gate (probe answered immediately).
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        unauthenticatedApiClientProvider.overrideWithValue(
          (url) => testApiClient(url, mock),
        ),
        offlineModeProvider.overrideWith(() => TestOffline(true)),
        databaseProvider.overrideWithValue(db),
        autoVerifiedGateOverride(startOnRead: false),
      ],
    );
    addTearDown(container.dispose);

    final loginPage = await _pumpServerAddressPage(tester, container);
    expect(container.read(offlineModeProvider), isTrue);

    await loginPage.onConnect('http://localhost:8000');

    expect(
      container.read(offlineModeProvider),
      isFalse,
      reason: 'a passing health check must clear offline mode on connect',
    );
  });

  testWidgets('a failed manual connect does not strand the app offline', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final mock =
        MockClient((_) async => throw const SocketException('unreachable'));
    // Real notifier — starts online. The health check must not flip it.
    final container = ProviderContainer(
      overrides: [
        unauthenticatedApiClientProvider.overrideWithValue(
          (url) => testApiClient(url, mock),
        ),
      ],
    );
    addTearDown(container.dispose);

    final loginPage = await _pumpServerAddressPage(tester, container);
    expect(container.read(offlineModeProvider), isFalse);

    await loginPage.onConnect('http://typo.invalid:9999');

    expect(
      container.read(offlineModeProvider),
      isFalse,
      reason: 'a failed connect attempt must not enter offline mode',
    );
  });

  // Not the gate: the health check a manual connect makes, called directly.
  test('a failed manual-connect health check uses a single attempt', () async {
    SharedPreferences.setMockInitialValues({});
    var attempts = 0;
    final client = testApiClient(
      'http://hang.invalid:9999',
      MockClient((_) async {
        attempts++;
        throw const SocketException('unreachable');
      }),
    );
    // Drive the health check directly so we don't have to stub the full
    // AppShell provider graph just to count attempts.
    final sw = Stopwatch()..start();
    final result = await client.healthCheck(retry: false);
    sw.stop();

    expect(result.status, HealthStatus.unreachable);
    expect(
      attempts,
      1,
      reason: 'retry: false must collapse the default 3-attempt retry '
          'policy to a single attempt — otherwise a hanging saved URL holds '
          'the splash for ~30s before showing downloaded content',
    );
    expect(
      sw.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: 'a single-attempt unreachable health check returns immediately, '
          'far below the 3×10s retry budget',
    );
  });
}
