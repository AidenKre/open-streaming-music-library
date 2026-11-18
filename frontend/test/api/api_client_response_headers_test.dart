// Phase 7B.1a (D24, SC-01 rule 6): a GET that returns the response headers
// with the JSON body, so a page fetcher can read the server's
// `X-Server-Instance-Id` stamp. Same request, retry and error semantics as
// `getJson`.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

void main() {
  test('returns the decoded body and the headers of the response', () async {
    late Request seen;
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((req) async {
        seen = req;
        return Response(
          jsonEncode({'changes': [], 'latestRevision': 3}),
          200,
          headers: {'x-server-instance-id': 'abc', 'content-type': 'application/json'},
        );
      }),
    );

    final response = await api.getJsonResponse(
      ['changes'],
      query: {'after_revision': '2'},
    );

    expect(response.body, {'changes': [], 'latestRevision': 3});
    expect(response.headers['x-server-instance-id'], 'abc');
    expect(seen.method, 'GET');
    expect(seen.url.toString(), 'http://localhost:8000/changes?after_revision=2');
    expect(seen.headers['Accept'], 'application/json');
  });

  test('a retried request returns the headers of the answer that succeeded',
      () async {
    var calls = 0;
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((req) async {
        calls++;
        if (calls == 1) {
          return Response('busy', 503, headers: {'x-server-instance-id': 'first'});
        }
        return Response(jsonEncode({'ok': true}), 200,
            headers: {'x-server-instance-id': 'second'});
      }),
    );

    final response = await api.getJsonResponse(['changes']);

    expect(calls, 2);
    expect(response.body, {'ok': true});
    expect(response.headers['x-server-instance-id'], 'second');
  });

  test('a response without the header has none (no invented value)', () async {
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((req) async => Response(jsonEncode({'ok': true}), 200)),
    );

    final response = await api.getJsonResponse(['changes']);

    expect(response.headers.containsKey('x-server-instance-id'), isFalse);
  });

  test('an HTTP error is an ApiException, as with getJson', () async {
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((req) async => Response('{"detail": "nope"}', 404,
          headers: {'x-server-instance-id': 'abc'})),
    );

    await expectLater(
      api.getJsonResponse(['changes']),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
    );
  });
}
