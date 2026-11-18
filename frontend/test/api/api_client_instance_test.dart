// Phase M §7.2 / SC-27 invariant 14: an ApiClient is an instance owned by
// one provider scope. Its network-failure listeners are its own, so a
// request that outlives its scope can't flip another scope offline, and
// disposing it never closes the transport shared with newer scopes.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/spy_inner_client.dart';

http.Client _down() =>
    MockClient((_) async => throw const SocketException('down'));

void main() {
  test('a transport failure fires only its own client\'s listeners', () async {
    final a = testApiClient('http://a', _down());
    final b = testApiClient('http://b', _down());
    var aFired = 0;
    var bFired = 0;
    a.addNetworkFailureListener(() => aFired++);
    b.addNetworkFailureListener(() => bFired++);

    await expectLater(
      a.getJson(['tracks'], policy: RetryPolicy.noRetry),
      throwsA(isA<NetworkException>()),
    );

    expect(aFired, 1);
    expect(bFired, 0, reason: "another client's failure is not this one's");
  });

  test('a request outliving its disposed client fires no listener', () async {
    final gate = Completer<void>();
    final old = testApiClient(
      'http://a',
      MockClient((_) async {
        await gate.future;
        throw const SocketException('down');
      }),
    );
    var fired = 0;
    old.addNetworkFailureListener(() => fired++);

    final inFlight = old.getJson(['tracks'], policy: RetryPolicy.noRetry);
    old.dispose(); // its scope was replaced
    gate.complete();

    await expectLater(inFlight, throwsA(isA<NetworkException>()));
    expect(fired, 0);
  });

  test('a listener added after dispose is never called', () async {
    final old = testApiClient('http://a', _down());
    old.dispose();
    var fired = 0;
    old.addNetworkFailureListener(() => fired++);

    await expectLater(
      old.getJson(['tracks'], policy: RetryPolicy.noRetry),
      throwsA(isA<NetworkException>()),
    );
    expect(fired, 0);
  });

  test('dispose leaves the shared inner client open for newer clients',
      () async {
    final inner = SpyInnerClient();
    final old = ApiClient('http://a', inner);
    final current = ApiClient('http://b', inner);

    old.dispose();

    expect(inner.closed, isFalse);
    expect(await current.getJson(['tracks']), isEmpty);
    expect(inner.requests, hasLength(1));
  });

  test('an instance keeps its own base URL', () async {
    final seen = <Uri>[];
    final inner = MockClient((req) async {
      seen.add(req.url);
      return http.Response('{}', 200);
    });
    final a = ApiClient('http://a:1', inner);
    final b = ApiClient('http://b:2', inner);

    await a.getJson(['x']);
    await b.getJson(['y']);

    expect(seen.map((u) => u.toString()), ['http://a:1/x', 'http://b:2/y']);
  });
}
