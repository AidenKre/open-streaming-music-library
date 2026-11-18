// M.3b exit proof (Phase M §7.2, SC-27 invariant 14, M-U19 client): the
// scope's `apiClientProvider` is built from the scope's immutable
// credentials over the shared transport. A request created in scope A
// carries A's token even when it is sent after the switch to scope B; a 401
// reaches the scope's `onUnauthorized` hook synchronously, never after the
// scope is disposed, and never deletes the stored credentials. Without
// credentials the scope's client sends no Authorization header.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;

import '../helpers/fake_secure_backend.dart';

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

/// The process-lifetime transport. Requests to a path in [held] wait for
/// [release]; every request is recorded as it reaches the wire.
class _Transport extends http.BaseClient {
  int status = 200;
  final held = <String>{};
  final release = Completer<void>();
  final List<http.BaseRequest> wire = [];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) throw StateError('transport used after close');
    if (held.contains(request.url.path)) await release.future;
    wire.add(request);
    return http.StreamedResponse(
      Stream.value('{}'.codeUnits),
      status,
      request: request,
    );
  }

  @override
  void close() => closed = true;
}

String? _auth(http.BaseRequest r) => r.headers['Authorization'];

/// Answers each request with the status [_status] returns for it.
class _FlakyTransport extends http.BaseClient {
  _FlakyTransport(this._status);
  final Future<int> Function(http.BaseRequest) _status;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream.value('{}'.codeUnits),
        await _status(request),
        request: request,
      );

  @override
  void close() {}
}

/// Fixture: these tests are about which scope's token goes out, not about
/// verification (sign-off OPEN-M-11 has its own tests), so the gate allows.
class _AllowingGate extends Fake implements ServerBindingGate {
  @override
  bool allowsTokenTo(Uri url) => true;
  @override
  Future<void> verdictSettled() async {}
}

void main() {
  late _Transport transport;

  setUp(() => transport = _Transport());

  ProviderContainer scope(Credentials? credentials, {void Function()? hook}) {
    return ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(transport),
        sessionUrlProvider.overrideWithValue('http://srv:1'),
        credentialsProvider.overrideWithValue(credentials),
        serverBindingGateProvider.overrideWithValue(_AllowingGate()),
        if (hook != null) onUnauthorizedProvider.overrideWithValue(hook),
      ],
    );
  }

  test("the scope's client sends the scope's token", () async {
    final a = scope(_alice);
    addTearDown(a.dispose);
    await a.read(apiClientProvider).getJson(['tracks']);
    expect(_auth(transport.wire.single), 'Bearer api-token-A');
  });

  test('without credentials the client sends no Authorization header',
      () async {
    final none = scope(null);
    addTearDown(none.dispose);
    await none.read(apiClientProvider).getJson(['tracks']);
    expect(
      transport.wire.single.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('authorization')),
    );
  });

  test("a request created in scope A carries A's token after the switch to "
      'B', () async {
    transport.held.add('/tracks/slow');
    final a = scope(_alice);
    final pending = a.read(apiClientProvider).getJson(['tracks', 'slow']);
    // Sign-off OPEN-M-11: the request reaches the transport (it is in
    // flight) before the switch; one not yet sent when A goes is withheld.
    await pumpEventQueue();
    final notYetSent = a.read(apiClientProvider).getJson(['tracks', 'late']);
    // Switch: scope A is disposed, scope B (bob) takes over.
    a.dispose();
    await expectLater(notYetSent, throwsA(isA<TokenWithheldException>()));
    final b = scope(_bob);
    addTearDown(b.dispose);
    await b.read(apiClientProvider).getJson(['tracks', 'fast']);
    transport.release.complete();
    await pending;

    final byPath = {for (final r in transport.wire) r.url.path: _auth(r)};
    expect(byPath['/tracks/slow'], 'Bearer api-token-A');
    expect(byPath['/tracks/fast'], 'Bearer api-token-B');
    expect(transport.closed, isFalse,
        reason: "disposing a scope never closes the shared transport");
  });

  test("a retry of scope A's request after the switch to B never carries "
      "B's token (it is withheld: A's scope is gone)", () async {
    // The first attempt answers 503 (retryable); its retry is sent only
    // after scope A is disposed and scope B exists.
    final retryGate = Completer<void>();
    var attempts = 0;
    final wire = <String?>[];
    final flaky = _FlakyTransport((request) async {
      wire.add(_auth(request));
      attempts++;
      if (attempts == 1) return 503;
      return 200;
    });
    final a = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(flaky),
        sessionUrlProvider.overrideWithValue('http://srv:1'),
        credentialsProvider.overrideWithValue(_alice),
        serverBindingGateProvider.overrideWithValue(_AllowingGate()),
      ],
    );
    final api = a.read(apiClientProvider)
      ..setDelayFnForTest((_) => retryGate.future);
    final pending = api.getJson(['tracks']);
    await Future<void>.delayed(Duration.zero);
    a.dispose();
    final b = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(flaky),
        sessionUrlProvider.overrideWithValue('http://srv:1'),
        credentialsProvider.overrideWithValue(_bob),
        serverBindingGateProvider.overrideWithValue(_AllowingGate()),
      ],
    );
    addTearDown(b.dispose);
    b.read(apiClientProvider); // B's client now exists
    retryGate.complete();
    // Sign-off OPEN-M-11: scope A's permit asks A's gate, which went with
    // A's disposal, so the retry fails closed: withheld, never sent, and
    // never with B's token.
    await expectLater(pending, throwsA(isA<TokenWithheldException>()));
    expect(wire, ['Bearer api-token-A']);
  });

  test("a 401 calls the scope's hook synchronously, and the stored "
      'credentials stay', () async {
    final dir = await Directory.systemTemp.createTemp('scope_cred_test_');
    addTearDown(() => dir.delete(recursive: true));
    final secure = FakeSecureBackend();
    final store = CredentialStore(secure: secure, directory: dir);
    await store.save(_alice);
    secure.calls.clear();

    transport.status = 401;
    var hookCalls = 0;
    final a = scope(_alice, hook: () => hookCalls++);
    addTearDown(a.dispose);
    await expectLater(
      a.read(apiClientProvider).getJson(['tracks']),
      throwsA(anything),
    );
    expect(hookCalls, 1);
    expect(secure.calls.where((c) => c.startsWith('delete')), isEmpty);
    expect(await store.read(), _alice);
  });

  test("a 401 arriving after the scope was disposed doesn't call its hook",
      () async {
    transport
      ..status = 401
      ..held.add('/tracks');
    var hookCalls = 0;
    final a = scope(_alice, hook: () => hookCalls++);
    final pending = a.read(apiClientProvider).getJson(['tracks']);
    a.dispose();
    transport.release.complete();
    await expectLater(pending, throwsA(anything));
    expect(hookCalls, 0);
  });

  test('hasSessionProvider follows the stored credentials', () {
    final withCreds = scope(_alice);
    final without = scope(null);
    addTearDown(withCreds.dispose);
    addTearDown(without.dispose);
    expect(withCreds.read(hasSessionProvider), isTrue);
    expect(without.read(hasSessionProvider), isFalse);
  });

  // Review r1 finding 6: credentials without a session URL are no session
  // (runners would send requests to '' and flip the app offline).
  test('credentials without a session URL are not a session', () {
    final noUrl = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(transport),
        credentialsProvider.overrideWithValue(_alice),
      ],
    );
    addTearDown(noUrl.dispose);
    expect(noUrl.read(hasSessionProvider), isFalse);
  });

  test('the pre-session client for another URL sends no token and never '
      "calls the scope's hook", () async {
    transport.status = 401;
    var hookCalls = 0;
    final a = scope(_alice, hook: () => hookCalls++);
    addTearDown(a.dispose);
    final pre = a.read(unauthenticatedApiClientProvider)('http://other:2');
    await expectLater(pre.getJson(['app', 'info']), throwsA(anything));
    final r = transport.wire.single;
    expect(r.url.host, 'other');
    expect(r.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')));
    expect(hookCalls, 0);
  });
}
