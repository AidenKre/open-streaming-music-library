// Phase M §7.2 (M-U19 client): `AuthenticatedClient extends http.BaseClient`
// adds `Authorization: Bearer` to every request (the JSON verbs, `getBytes`
// and `send()`), calls `onUnauthorized` synchronously on a 401 before the
// response is returned, is a no-op after its scope is disposed, and its
// `close()` leaves the shared inner client open. `UnauthenticatedClient`
// (pre-session calls) sends no header and has no hook.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/token_permit.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:http/http.dart' as http;

import '../helpers/spy_inner_client.dart';

const _alice = Credentials(
  token: 'api-token-A',
  mediaToken: 'media-token-A',
  userId: 7,
  username: 'alice',
);
const _bob = Credentials(
  token: 'api-token-B',
  mediaToken: 'media-token-B',
  userId: 8,
  username: 'bob',
);

String? _auth(http.BaseRequest r) => r.headers['Authorization'];

/// A permit the test controls (sign-off OPEN-M-11).
class _FakePermit implements TokenPermit {
  _FakePermit({this.allow = true});
  bool allow;
  Object? throwOnAsk;
  Completer<void>? settle;
  final asked = <Uri>[];
  int settledCalls = 0;

  @override
  bool allowsTokenTo(Uri url) {
    asked.add(url);
    final e = throwOnAsk;
    if (e != null) throw e;
    return allow;
  }

  @override
  Future<void> verdictSettled() {
    settledCalls++;
    return settle?.future ?? Future.value();
  }
}

/// Fixture for tests whose subject is not the permit: always allows.
final _allowAll = _FakePermit();

void main() {
  group('AuthenticatedClient adds the header', () {
    late SpyInnerClient inner;
    late ApiClient api;

    setUp(() {
      inner = SpyInnerClient();
      api = testApiClient('http://srv:1', AuthenticatedClient(inner, _alice, permit: _allowAll));
    });

    test('on every JSON verb', () async {
      await api.getJson(['tracks']);
      await api.postJson(['jobs'], body: {'a': 1});
      await api.putJson(['settings', 'quality'], body: {'q': '256'});
      await api.patchJson(['tracks', 'u1'], body: {'title': 't'});
      await api.deleteJson(['jobs', '1']);
      expect(inner.requests.map((r) => r.method), [
        'GET',
        'POST',
        'PUT',
        'PATCH',
        'DELETE',
      ]);
      for (final r in inner.requests) {
        expect(_auth(r), 'Bearer api-token-A', reason: r.method);
      }
    });

    test('on getBytes', () async {
      await api.getBytes(['cover_art', '42']);
      expect(_auth(inner.requests.single), 'Bearer api-token-A');
    });

    test('on send()', () async {
      final response = await api.send(
        () => http.Request(
          'GET',
          Uri.parse('http://srv:1/tracks/u1/stream?quality=256'),
        ),
      );
      await response.stream.drain<void>();
      expect(_auth(inner.requests.single), 'Bearer api-token-A');
    });

    // Review r1 finding 4: the scope's token always wins (invariant 14); a
    // caller that sets another bearer (a revoke meant for the unhooked
    // client) fails loudly instead of revoking the scope's own session.
    test("refuses a request that carries another token's header", () async {
      await expectLater(
        api.postJson(
          ['auth', 'logout'],
          headers: {'Authorization': 'Bearer api-token-B'},
        ),
        throwsA(isA<StateError>()),
      );
      expect(inner.requests, isEmpty);
    });

    test("accepts a request that already carries the scope's own header",
        () async {
      await api.getJson(
        ['tracks'],
        headers: {'authorization': 'Bearer api-token-A'},
      );
      expect(_auth(inner.requests.single), 'Bearer api-token-A');
    });

    test('never in the URL', () async {
      await api.getJson(['tracks'], query: {'after': '3'});
      await api.getBytes(['cover_art', '42']);
      for (final r in inner.requests) {
        expect(r.url.toString(), isNot(contains('api-token-A')));
        expect(r.url.toString(), isNot(contains('media-token-A')));
        expect(r.url.queryParameters, isNot(contains('access_token')));
      }
    });
  });

  group('onUnauthorized', () {
    test('is called on a 401, synchronously, before the caller gets the '
        'response', () async {
      final inner = SpyInnerClient(status: 401);
      var callerHasResponse = false;
      final seenByHook = <bool>[];
      final client = AuthenticatedClient(
        inner,
        _alice,
        permit: _allowAll,
        onUnauthorized: (_) => seenByHook.add(callerHasResponse),
      );
      final response = await client.send(
        http.Request('GET', Uri.parse('http://srv:1/tracks')),
      );
      callerHasResponse = true;
      expect(response.statusCode, 401);
      expect(seenByHook, [false]);
    });

    test('is called once per 401 through ApiClient, which still throws the '
        '401', () async {
      final inner = SpyInnerClient(status: 401);
      var calls = 0;
      final api = testApiClient(
        'http://srv:1',
        AuthenticatedClient(inner, _alice, permit: _allowAll, onUnauthorized: (_) => calls++),
      );
      await expectLater(
        api.getJson(['tracks']),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
      );
      expect(calls, 1);
    });

    test("hands over the 401's server stamp, or null without one", () async {
      final seen = <String?>[];
      for (final headers in [
        {'X-Server-Instance-Id': ' inst-9 '},
        <String, String>{},
      ]) {
        final client = AuthenticatedClient(
          SpyInnerClient(status: 401, headers: headers),
          _alice,
          permit: _allowAll,
          onUnauthorized: seen.add,
        );
        await client.send(http.Request('GET', Uri.parse('http://srv:1/x')));
      }
      expect(seen, ['inst-9', null]);
    });

    test('is not called for other statuses', () async {
      for (final status in [200, 204, 403, 404, 409, 500]) {
        final inner = SpyInnerClient(status: status);
        var calls = 0;
        final client = AuthenticatedClient(
          inner,
          _alice,
          permit: _allowAll,
          onUnauthorized: (_) => calls++,
        );
        await client.send(http.Request('GET', Uri.parse('http://srv:1/x')));
        expect(calls, 0, reason: 'status $status');
      }
    });

    test('is a no-op after dispose', () async {
      final inner = SpyInnerClient(status: 401);
      var calls = 0;
      final client = AuthenticatedClient(
        inner,
        _alice,
        permit: _allowAll,
        onUnauthorized: (_) => calls++,
      )..dispose();
      final response = await client.send(
        http.Request('GET', Uri.parse('http://srv:1/tracks')),
      );
      expect(response.statusCode, 401);
      expect(calls, 0);
    });

    test('a 401 arriving after dispose for a request sent before it is a '
        'no-op', () async {
      final gate = Completer<void>();
      final inner = SpyInnerClient(status: 401, gate: gate);
      var calls = 0;
      final client = AuthenticatedClient(
        inner,
        _alice,
        permit: _allowAll,
        onUnauthorized: (_) => calls++,
      );
      final pending = client.send(
        http.Request('GET', Uri.parse('http://srv:1/tracks')),
      );
      await Future<void>.delayed(Duration.zero);
      client.dispose();
      gate.complete();
      expect((await pending).statusCode, 401);
      expect(calls, 0);
    });
  });

  group('scope lifetime', () {
    test('a request created by a disposed client still carries its own '
        "token, not the next scope's", () async {
      final inner = SpyInnerClient();
      final a = AuthenticatedClient(inner, _alice, permit: _allowAll);
      final b = AuthenticatedClient(inner, _bob, permit: _allowAll);
      a.dispose();
      await a.send(http.Request('GET', Uri.parse('http://srv:1/a')));
      await b.send(http.Request('GET', Uri.parse('http://srv:1/b')));
      expect(inner.requests.map(_auth), [
        'Bearer api-token-A',
        'Bearer api-token-B',
      ]);
    });

    test('close() leaves the shared inner client open', () async {
      final inner = SpyInnerClient();
      AuthenticatedClient(inner, _alice, permit: _allowAll).close();
      expect(inner.closed, isFalse);
      final next = AuthenticatedClient(inner, _bob, permit: _allowAll);
      final response = await next.send(
        http.Request('GET', Uri.parse('http://srv:1/x')),
      );
      expect(response.statusCode, 200);
    });
  });

  // Sign-off OPEN-M-11 (2026-11-17): the token is attached only while the
  // permit (the binding gate) says this server is verified. A refused request
  // is never handed to the transport and fails with its own error, which
  // ApiClient neither retries nor reports as a lost connection.
  group('permit', () {
    late SpyInnerClient inner;
    late _FakePermit permit;
    late ApiClient api;
    late int networkFailures;

    setUp(() {
      inner = SpyInnerClient();
      permit = _FakePermit(allow: false);
      api = testApiClient(
        'http://srv:1',
        AuthenticatedClient(inner, _alice, permit: permit),
      );
      networkFailures = 0;
      api.addNetworkFailureListener(() => networkFailures++);
    });

    test('a refused request is withheld: nothing reaches the transport',
        () async {
      await expectLater(
        AuthenticatedClient(inner, _alice, permit: permit)
            .send(http.Request('GET', Uri.parse('http://srv:1/tracks'))),
        throwsA(isA<TokenWithheldException>()),
      );
      expect(inner.requests, isEmpty);
      expect(permit.asked.single, Uri.parse('http://srv:1/tracks'));
    });

    test('through ApiClient: its own error, no retry, no offline signal',
        () async {
      await expectLater(
        api.getJson(['tracks']), // retries by default
        throwsA(isA<TokenWithheldException>()),
      );
      await expectLater(
        api.putJson(['settings', 'quality'], body: {'q': '1'}, retry: true),
        throwsA(isA<TokenWithheldException>()),
      );
      await expectLater(
        api.send(() => http.Request(
            'GET', Uri.parse('http://srv:1/tracks/u1/stream'))),
        throwsA(isA<TokenWithheldException>()),
      );
      await expectLater(api.getBytes(['cover_art', '1']),
          throwsA(isA<TokenWithheldException>()));
      expect(inner.requests, isEmpty);
      expect(permit.asked, hasLength(4), reason: 'asked once each: no retry');
      expect(networkFailures, 0);
    });

    test('a permit that throws is a no (fail closed)', () async {
      permit
        ..allow = true
        ..throwOnAsk = StateError('scope disposed');
      await expectLater(
        api.getJson(['tracks']),
        throwsA(isA<TokenWithheldException>()),
      );
      expect(inner.requests, isEmpty);
    });

    test('allowed: sent with the header', () async {
      permit.allow = true;
      await api.getJson(['tracks']);
      expect(_auth(inner.requests.single), 'Bearer api-token-A');
    });

    test('ApiClient waits for a pending verdict before the attempt, outside '
        'the per-attempt timeout, then decides', () async {
      permit.settle = Completer<void>();
      api.setPerAttemptTimeoutForTest(Duration.zero);
      Object? error;
      var done = false;
      unawaited(api
          .getJson(['tracks'])
          .then((_) => done = true, onError: (Object e) => error = e));
      await pumpEventQueue(times: 20);
      expect(done, isFalse);
      expect(error, isNull,
          reason: 'the wait is not an attempt: no timeout, no retry');
      expect(inner.requests, isEmpty);
      expect(permit.asked, isEmpty, reason: 'decided only after the verdict');
      expect(permit.settledCalls, 1);
      permit.settle!.complete(); // a negative verdict: withheld, not retried
      await pumpEventQueue();
      expect(error, isA<TokenWithheldException>());
      expect(inner.requests, isEmpty);
    });

    test('after the wait: allowed goes with the token, refused is withheld',
        () async {
      permit.settle = Completer<void>();
      final allowed = api.getJson(['tracks']);
      await pumpEventQueue();
      permit.allow = true;
      permit.settle!.complete();
      await allowed;
      expect(_auth(inner.requests.single), 'Bearer api-token-A');

      permit
        ..allow = false
        ..settle = Completer<void>();
      final refused = api.getJson(['tracks']);
      permit.settle!.complete();
      await expectLater(refused, throwsA(isA<TokenWithheldException>()));
      expect(inner.requests, hasLength(1));
    });

    test('a token-free client never asks the permit or waits', () async {
      final bare = api.withoutToken();
      permit.settle = Completer<void>(); // would hang if asked
      await bare.getJson(['app', 'info']);
      expect(_auth(inner.requests.single), isNull);
      expect(permit.settledCalls, 0);
      expect(permit.asked, isEmpty);
    });
  });

  // Sign-off OPEN-M-11: log-out and Disconnect decide before the gate is
  // stopped whether the revoke may go (today's rule, LocalResetService). The
  // exemption sends exactly one POST /auth/logout with the scope's token,
  // whatever the permit says afterwards, and nothing else.
  group('revoke exemption', () {
    late SpyInnerClient inner;
    late _FakePermit permit;
    late ApiClient api;

    setUp(() {
      inner = SpyInnerClient();
      permit = _FakePermit(allow: false);
      api = testApiClient(
        'http://srv:1',
        AuthenticatedClient(inner, _alice, permit: permit),
      );
    });

    test('one POST /auth/logout goes with the token, though the permit '
        'now refuses', () async {
      final revoker = api.revokeOnceClient()!;
      await revoker.postJson(['auth', 'logout']);
      expect(inner.requests.single.method, 'POST');
      expect(inner.requests.single.url, Uri.parse('http://srv:1/auth/logout'));
      expect(_auth(inner.requests.single), 'Bearer api-token-A');
    });

    test('a second request through it is refused', () async {
      final revoker = api.revokeOnceClient()!;
      await revoker.postJson(['auth', 'logout']);
      await expectLater(revoker.postJson(['auth', 'logout']),
          throwsA(isA<TokenWithheldException>()));
      expect(inner.requests, hasLength(1));
    });

    test('anything but POST /auth/logout is refused, and does not use up '
        'the one revoke', () async {
      final revoker = api.revokeOnceClient()!;
      await expectLater(revoker.getJson(['tracks']),
          throwsA(isA<TokenWithheldException>()));
      await expectLater(revoker.getJson(['auth', 'logout']),
          throwsA(isA<TokenWithheldException>()));
      await expectLater(
        AuthenticatedClient(inner, _alice, permit: permit)
            .revokeExemption(Uri.parse('http://srv:1/auth/logout'))
            .send(http.Request('POST', Uri.parse('http://other/auth/logout'))),
        throwsA(isA<TokenWithheldException>()),
      );
      expect(inner.requests, isEmpty);
      await revoker.postJson(['auth', 'logout']);
      expect(_auth(inner.requests.single), 'Bearer api-token-A');
    });

    test('no exemption without a token client', () {
      expect(api.withoutToken().revokeOnceClient(), isNull);
      expect(UnauthenticatedClient.forUrl('http://srv:1', inner)
          .revokeOnceClient(), isNull);
    });
  });

  group('UnauthenticatedClient', () {
    test('forUrl builds a client for that URL that sends no Authorization '
        'header', () async {
      final inner = SpyInnerClient();
      final api = UnauthenticatedClient.forUrl('http://new:2', inner);
      expect(api.baseUrl, 'http://new:2');
      await api.getJson(['app', 'info']);
      await api.postJson(['auth', 'login'], body: {'username': 'a'});
      expect(inner.requests.map((r) => r.url.host), ['new', 'new']);
      for (final r in inner.requests) {
        expect(r.headers.keys.map((k) => k.toLowerCase()),
            isNot(contains('authorization')));
      }
    });

    test('keeps an explicit Authorization header the caller sets (the '
        'cancel-time revoke)', () async {
      final inner = SpyInnerClient();
      final api = UnauthenticatedClient.forUrl('http://new:2', inner);
      await api.postJson(
        ['auth', 'logout'],
        headers: {'Authorization': 'Bearer api-token-B'},
      );
      expect(_auth(inner.requests.single), 'Bearer api-token-B');
    });

    test('close() leaves the shared inner client open', () async {
      final inner = SpyInnerClient();
      final client = UnauthenticatedClient(inner)..close();
      expect(inner.closed, isFalse);
      final response = await client.send(
        http.Request('GET', Uri.parse('http://srv:1/x')),
      );
      expect(response.statusCode, 200);
    });
  });
}
