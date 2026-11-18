// Review s7-session-network F2 (sign-off OPEN-M-11): the cover-art disk cache
// (flutter_cache_manager) queues its downloads process-wide and sends them
// later. Its HTTP goes through the scope token route, which hands each
// request to the live scope's token client at the moment it is really sent,
// so the permit is asked then, not when the image was requested.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/scope_token_route.dart';
import 'package:frontend/api/token_permit.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/server_binding.dart';
import '../helpers/test_credentials.dart';

const _bob = Credentials(
  token: 'api-token-B',
  mediaToken: 'media-token-B',
  userId: 8,
  username: 'bob',
);

class _Permit implements TokenPermit {
  _Permit(this.allow);
  bool allow;
  @override
  bool allowsTokenTo(Uri url) => allow;
  @override
  Future<void> verdictSettled() async {}
}

void main() {
  late List<http.BaseRequest> wire;
  late http.Client transport;

  setUp(() {
    wire = [];
    transport = MockClient((req) async {
      wire.add(req);
      return http.Response.bytes([1, 2, 3], 200);
    });
  });

  String? auth(http.BaseRequest r) => r.headers['Authorization'];
  final art = Uri.parse('http://s/cover_art/1');
  Map<String, String> aliceHeader() => bearerAuthHeader(testCredentials.token);

  group('the route', () {
    test('no live scope: withheld, nothing reaches the transport', () async {
      final route = ScopeTokenRoute();
      await expectLater(
        route.client.send(http.Request('GET', art)..headers.addAll(aliceHeader())),
        throwsA(isA<TokenWithheldException>()),
      );
      await expectLater(route.client.send(http.Request('GET', art)),
          throwsA(isA<TokenWithheldException>()));
      expect(wire, isEmpty);
    });

    test("a live scope whose permit allows: sent with that scope's token",
        () async {
      final route = ScopeTokenRoute();
      route.attach(AuthenticatedClient(transport, testCredentials,
          permit: _Permit(true)));
      await route.client
          .send(http.Request('GET', art)..headers.addAll(aliceHeader()));
      expect(auth(wire.single), 'Bearer ${testCredentials.token}');
    });

    test('a request queued while allowed and sent after the permit turned '
        'no is withheld at the send', () async {
      final route = ScopeTokenRoute();
      final permit = _Permit(true);
      route.attach(
          AuthenticatedClient(transport, testCredentials, permit: permit));
      permit.allow = false; // went offline / different server / signed out
      await expectLater(
        route.client.send(http.Request('GET', art)..headers.addAll(aliceHeader())),
        throwsA(isA<TokenWithheldException>()),
      );
      expect(wire, isEmpty);
    });

    test("after a switch, a queued request with the old scope's token is "
        "refused, never sent with either token", () async {
      final route = ScopeTokenRoute();
      final alice =
          AuthenticatedClient(transport, testCredentials, permit: _Permit(true));
      final bob = AuthenticatedClient(transport, _bob, permit: _Permit(true));
      route.attach(alice);
      route.attach(bob);
      route.detach(alice); // the old scope's disposal does not detach bob
      await expectLater(
        route.client.send(http.Request('GET', art)..headers.addAll(aliceHeader())),
        throwsA(anything),
      );
      expect(wire, isEmpty);
      await route.client.send(http.Request('GET', art));
      expect(auth(wire.single), 'Bearer api-token-B');
    });

    test('the cover cache file service sends through it (the exact call the '
        'cache makes), asking the permit at the send', () async {
      final route = ScopeTokenRoute();
      final permit = _Permit(false);
      route.attach(
          AuthenticatedClient(transport, testCredentials, permit: permit));
      final service = HttpFileService(httpClient: route.client);
      await expectLater(service.get(art.toString(), headers: aliceHeader()),
          throwsA(isA<TokenWithheldException>()));
      expect(wire, isEmpty);
      permit.allow = true;
      final response = await service.get(art.toString(), headers: aliceHeader());
      expect(response.statusCode, 200);
      expect(auth(wire.single), 'Bearer ${testCredentials.token}');
    });
  });

  group('the scope wiring', () {
    late AppDatabase db;
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
    });
    tearDown(() => db.close());

    test("each scope's token client is the live one; disposal detaches it",
        () async {
      final route = ScopeTokenRoute();
      final controlled = ControlledGate(db);
      addTearDown(controlled.dispose);
      final c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        httpClientProvider.overrideWithValue(transport),
        sessionUrlProvider.overrideWithValue('http://s'),
        credentialsProvider.overrideWithValue(testCredentials),
        serverBindingGateProvider.overrideWithValue(controlled.gate),
        scopeTokenRouteProvider.overrideWithValue(route),
      ]);
      c.read(apiClientProvider);

      // Not verified yet: the cover request is withheld at its send.
      await expectLater(route.client.send(http.Request('GET', art)),
          throwsA(isA<TokenWithheldException>()));
      unawaited(controlled.gate.startConnection('http://s'));
      await pumpEventQueue();
      controlled.respond('inst-1');
      await pumpEventQueue();
      await route.client.send(http.Request('GET', art));
      expect(auth(wire.single), 'Bearer ${testCredentials.token}');

      c.dispose();
      await expectLater(route.client.send(http.Request('GET', art)),
          throwsA(isA<TokenWithheldException>()));
      expect(wire, hasLength(1));
    });
  });
}
