// Phase M §7.2 (M-U19 scope): the scope's client is immutable, so calls for
// a URL that is not the session's yet (connect's health check, the gate's
// /app/info probe for it) go through a pre-session client for that URL, the
// probe takes the URL explicitly, and a successful connect saves the URL and
// then rebuilds the scope (`onSessionChanged`) so the new scope's client
// carries it.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/server_binding.dart';
import '../helpers/test_credentials.dart';

void main() {
  late AppDatabase db;
  late List<Uri> scopeRequests;
  late List<Uri> preSessionRequests;
  late int healthStatus;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    scopeRequests = [];
    preSessionRequests = [];
    healthStatus = 200;
  });

  tearDown(() => db.close());

  http.Response answer(http.Request req) => req.url.path.endsWith('/app/info')
      ? http.Response('{"server":{"instance_id":"inst-1"},"auth":{"version":1,"signup_enabled":true}}', 200)
      : http.Response('{"message":"Healthy"}', healthStatus);

  List<Override> clients(String scopeUrl) => [
        databaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(
          testApiClient(scopeUrl, MockClient((req) async {
            scopeRequests.add(req.url);
            return answer(req);
          })),
        ),
        unauthenticatedApiClientProvider.overrideWithValue(
          (url) => testApiClient(url, MockClient((req) async {
            preSessionRequests.add(req.url);
            return answer(req);
          })),
        ),
      ];

  group('the binding gate', () {
    test('passes the connection URL to its probe', () async {
      final controlled = ControlledGate(db);
      addTearDown(controlled.dispose);
      await seedTestBinding(db, baseUrl: 'http://x');

      unawaited(controlled.gate.startConnection('http://x'));
      await pumpEventQueue();

      expect(controlled.probedUrls, ['http://x']);
    });

    test("probes another URL with a pre-session client, the session's own "
        'with the scope client', () async {
      final c = ProviderContainer(overrides: [
        ...clients('http://scope'),
        credentialsProvider.overrideWithValue(testCredentials),
      ]);
      addTearDown(c.dispose);
      await seedTestBinding(db, baseUrl: 'http://scope');
      final gate = c.read(serverBindingGateProvider);

      await gate.startConnection('http://other', reportOffline: false);
      await pumpEventQueue();
      expect(preSessionRequests.map((u) => '$u'), ['http://other/app/info']);
      expect(scopeRequests, isEmpty);

      await gate.startConnection('http://scope');
      await pumpEventQueue();
      expect(scopeRequests.map((u) => '$u'), ['http://scope/app/info']);
    });
  });

  group('connect', () {
    late List<String?> savedUrlAtRebuild;
    late ControlledGate controlled;

    ProviderContainer scope() {
      savedUrlAtRebuild = [];
      controlled = ControlledGate(db);
      addTearDown(controlled.dispose);
      final c = ProviderContainer(
        overrides: [
          ...clients(''), // the server-address screen: no session URL yet
          serverBindingGateProvider.overrideWithValue(controlled.gate),
          onSessionChangedProvider.overrideWithValue(() async {
            final prefs = await SharedPreferences.getInstance();
            savedUrlAtRebuild.add(prefs.getString(SessionService.serverUrlKey));
          }),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    // Phase M 7.4: connect checks the typed URL's health and /app/info with
    // a pre-session client and saves it; Log in follows in the same scope,
    // so there is no rebuild (and no second probe) until login.
    test('checks the typed URL with a pre-session client, then saves it '
        'without rebuilding the scope', () async {
      final c = scope();
      final outcome = await c.read(sessionServiceProvider).connect('http://new');

      expect(outcome, isA<ConnectSucceeded>());
      expect(controlled.probedUrls, isEmpty, reason: 'the gate is not run');
      expect(preSessionRequests.map((u) => '${u.host}${u.path}'),
          ['new', 'new/app/info']);
      expect(scopeRequests, isEmpty, reason: "the scope client has no URL");
      expect(savedUrlAtRebuild, isEmpty, reason: 'no rebuild before login');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SessionService.serverUrlKey), 'http://new');
    });

    test('a failed connect saves nothing and does not rebuild', () async {
      healthStatus = 500;
      final c = scope();

      expect(await c.read(sessionServiceProvider).connect('http://typo'),
          isA<ConnectFailed>());
      expect(savedUrlAtRebuild, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SessionService.serverUrlKey), isNull);
    });
  });
}
