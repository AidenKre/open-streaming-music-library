// Phase M §7.4 connect, and decision O1 / DEV-M-01:
//  * without a binding row, connect does not run the gate: it requires
//    /app/info with server.instance_id and auth.version == 1 (a pre-M server
//    is rejected with a clear message), saves the URL, creates no row, and
//    goes to Log in (no scope rebuild, so no second health probe; M.3a
//    DEV-b's connect -> rebuild path is gone);
//  * with a kept row and no credentials (after a logout), connect compares
//    only the server instance through the unauthenticated /app/info probe
//    and does not start the runner gate: a different instance is today's
//    different-server reset sheet, the same instance saves the URL and goes
//    to Log in.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/server_binding.dart';

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late List<String> requests;
  late Map<String, Object?> appInfo;
  late int appInfoStatus;
  late int healthStatus;
  late int rebuilds;

  Map<String, Object?> info({
    String? instanceId = 'inst-1',
    Object? auth = const {'version': 1, 'signup_enabled': true},
  }) => {
        if (instanceId != null) 'server': {'instance_id': instanceId},
        if (auth != null) 'auth': auth,
      };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    controlled = ControlledGate(db);
    requests = [];
    appInfo = info();
    appInfoStatus = 200;
    healthStatus = 200;
    rebuilds = 0;
  });

  tearDown(() async {
    controlled.dispose();
    await db.close();
  });

  ProviderContainer scope() {
    final transport = MockClient((req) async {
      requests.add('${req.method} ${req.url}');
      if (req.url.path.endsWith('/app/info')) {
        return http.Response(jsonEncode(appInfo), appInfoStatus);
      }
      return http.Response('{"message":"Healthy"}', healthStatus);
    });
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      // The server-address screen's scope: no session URL, no credentials.
      apiClientProvider.overrideWithValue(
        testApiClient('', MockClient((_) async => fail('scope client used'))),
      ),
      unauthenticatedApiClientProvider
          .overrideWithValue((url) => testApiClient(url, transport)),
      serverBindingGateProvider.overrideWithValue(controlled.gate),
      onSessionChangedProvider.overrideWithValue(() async => rebuilds++),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<String?> savedUrl() async =>
      (await SharedPreferences.getInstance()).getString('serverUrl');
  ServerBindingRepository repo() => ServerBindingRepository(db);

  group('without a binding row', () {
    test('checks health and /app/info once each, saves the URL, creates no '
        'row, starts no gate and does not rebuild', () async {
      final c = scope();
      final outcome = await c.read(sessionServiceProvider).connect('http://new');
      expect(outcome, isA<ConnectSucceeded>());
      expect((outcome as ConnectSucceeded).url, 'http://new');
      expect(requests, hasLength(2));
      expect(requests.where((r) => r.endsWith('/app/info')), hasLength(1));
      expect(await savedUrl(), 'http://new');
      expect(await repo().current(), isNull, reason: 'login creates the row');
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0, reason: 'the gate is not run');
      expect(controlled.gate.state, isA<BindingIdle>());
      expect(rebuilds, 0, reason: 'no rebuild: no second health probe');
    });

    test('a pre-M server (no auth block) is rejected with a clear message',
        () async {
      appInfo = info(auth: null);
      final c = scope();
      final outcome = await c.read(sessionServiceProvider).connect('http://old');
      expect(outcome, isA<ConnectFailed>());
      expect((outcome as ConnectFailed).message, contains('accounts'));
      expect(await savedUrl(), isNull);
      expect(await repo().current(), isNull);
    });

    test('an unsupported auth version is rejected', () async {
      appInfo = info(auth: {'version': 2, 'signup_enabled': true});
      final c = scope();
      expect(await c.read(sessionServiceProvider).connect('http://x'),
          isA<ConnectFailed>());
      expect(await savedUrl(), isNull);
    });

    test('a server without server.instance_id is rejected', () async {
      appInfo = info(instanceId: null);
      final c = scope();
      expect(await c.read(sessionServiceProvider).connect('http://x'),
          isA<ConnectFailed>());
      expect(await savedUrl(), isNull);
    });

    test('a failing /app/info saves nothing', () async {
      appInfoStatus = 500;
      final c = scope();
      expect(await c.read(sessionServiceProvider).connect('http://x'),
          isA<ConnectFailed>());
      expect(await savedUrl(), isNull);
      expect(rebuilds, 0);
    });

    test('an unhealthy server is not probed further', () async {
      healthStatus = 500;
      final c = scope();
      expect(await c.read(sessionServiceProvider).connect('http://x'),
          isA<ConnectFailed>());
      expect(requests.where((r) => r.endsWith('/app/info')), isEmpty);
      expect(await savedUrl(), isNull);
    });
  });

  group('with a kept binding row and no credentials (O1)', () {
    test('the same instance saves the URL and leaves the row as it was',
        () async {
      await repo().ensureProvisional('http://a', userId: 7, instanceId: 'inst-1');
      final before = (await repo().current())!;
      final c = scope();
      final outcome =
          await c.read(sessionServiceProvider).connect('http://a-new-address');
      expect(outcome, isA<ConnectSucceeded>());
      expect(await savedUrl(), 'http://a-new-address');
      final row = (await repo().current())!;
      expect(row.localBindingId, before.localBindingId);
      expect(row.userId, 7);
      expect(row.instanceId, 'inst-1');
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0,
          reason: 'the instance is compared through /app/info, not the gate');
      expect(rebuilds, 0);
    });

    test('a different instance is the different-server sheet; nothing saved',
        () async {
      await repo().ensureProvisional('http://a', userId: 7, instanceId: 'inst-1');
      appInfo = info(instanceId: 'inst-2');
      final c = scope();
      final outcome = await c.read(sessionServiceProvider).connect('http://b');
      expect(outcome, isA<ConnectDifferentServer>());
      expect((outcome as ConnectDifferentServer).url, 'http://b');
      expect(await savedUrl(), isNull);
      expect((await repo().current())!.instanceId, 'inst-1');
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0);
    });

    test('a pre-M server is rejected even with a row', () async {
      await repo().ensureProvisional('http://a', userId: 7, instanceId: 'inst-1');
      appInfo = info(auth: null);
      final c = scope();
      expect(await c.read(sessionServiceProvider).connect('http://a'),
          isA<ConnectFailed>());
      expect(await savedUrl(), isNull);
    });
  });
}
