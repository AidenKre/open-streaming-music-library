import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

void main() {
  group('ApiClient.init', () {
    test('sets baseUrl on the singleton', () {
      ApiClient.init('http://example.com:9000');
      expect(ApiClient.instance.baseUrl, 'http://example.com:9000');
    });
  });

  group('ApiClient.getJson', () {
    test('constructs correct URL with single path segment', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return Response(jsonEncode({}), 200);
        }),
      );

      await ApiClient.instance.getJson(['artists']);

      expect(captured?.host, 'localhost');
      expect(captured?.port, 8000);
      expect(captured?.pathSegments, ['artists']);
    });

    test('constructs URL with multiple path segments', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return Response(jsonEncode({}), 200);
        }),
      );

      await ApiClient.instance.getJson(['artists', 'Pink Floyd', 'albums']);

      expect(captured?.pathSegments, ['artists', 'Pink Floyd', 'albums']);
    });

    test('includes query parameters in URL', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return Response(jsonEncode({}), 200);
        }),
      );

      await ApiClient.instance.getJson(
        ['tracks'],
        query: {'limit': '100', 'cursor': 'abc'},
      );

      expect(captured?.queryParameters['limit'], '100');
      expect(captured?.queryParameters['cursor'], 'abc');
    });

    test('omits query string when query is null', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return Response(jsonEncode({}), 200);
        }),
      );

      await ApiClient.instance.getJson(['artists']);

      expect(captured?.hasQuery, isFalse);
    });

    test('sends Accept: application/json header by default', () async {
      Map<String, String>? capturedHeaders;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          capturedHeaders = req.headers;
          return Response(jsonEncode({}), 200);
        }),
      );

      await ApiClient.instance.getJson(['tracks']);

      expect(capturedHeaders?['Accept'], 'application/json');
    });

    test('merges custom headers alongside default Accept header', () async {
      Map<String, String>? capturedHeaders;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          capturedHeaders = req.headers;
          return Response(jsonEncode({}), 200);
        }),
      );

      await ApiClient.instance.getJson(
        ['tracks'],
        headers: {'Authorization': 'Bearer token123'},
      );

      expect(capturedHeaders?['Accept'], 'application/json');
      expect(capturedHeaders?['Authorization'], 'Bearer token123');
    });

    test('returns parsed JSON on 200 response', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => Response(
          jsonEncode({'data': ['a', 'b'], 'nextCursor': 'xyz'}),
          200,
        )),
      );

      final result = await ApiClient.instance.getJson(['artists']);

      expect(result['data'], ['a', 'b']);
      expect(result['nextCursor'], 'xyz');
    });

    test('returns empty map for empty response body on 204', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => Response('', 204)),
      );

      final result = await ApiClient.instance.getJson(['tracks']);

      expect(result, isEmpty);
    });

    test('throws ApiException with correct statusCode on 404', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => Response('Not Found', 404)),
      );

      expect(
        () => ApiClient.instance.getJson(['missing']),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', 'Not Found'),
        ),
      );
    });

    test('throws ApiException on 500', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => Response('Server Error', 500)),
      );

      expect(
        () => ApiClient.instance.getJson(['tracks']),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 500)),
      );
    });
  });

  group('ApiException', () {
    test('toString formats statusCode and message', () {
      final e = ApiException(422, 'Unprocessable Entity');
      expect(e.toString(), 'ApiException(422): Unprocessable Entity');
    });
  });
}