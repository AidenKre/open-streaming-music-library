import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/artist_api.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

Response _artistsResponse(List<String> artists, {String? nextCursor}) => Response(
      jsonEncode({'data': artists, 'nextCursor': nextCursor}),
      200,
    );

ArtistApi _artistApi(String url, Client client) =>
    ArtistApi(api: testApiClient(url, client));

void main() {
  group('ArtistApi', () {
    late ArtistApi api;

    test('getInitialItems returns artists from response', () async {
      api = _artistApi(
        'http://localhost:8000',
        MockClient((req) async => _artistsResponse(['Artist A', 'Artist B'])),
      );

      final result = await api.getInitialItems();

      expect(result, ['Artist A', 'Artist B']);
    });

    test('getInitialItems stores nextCursor for subsequent page request', () async {
      late Future<Response> Function(Request) handler;
      api = _artistApi(
        'http://localhost:8000',
        MockClient((req) => handler(req)),
      );
      handler = (req) async => _artistsResponse(['Artist A'], nextCursor: 'cursor-abc');
      await api.getInitialItems();

      Uri? captured;
      handler = (req) async {
        captured = req.url;
        return _artistsResponse([]);
      };
      await api.getNextItems();

      expect(captured?.queryParameters['cursor'], 'cursor-abc');
    });

    test('getNextItems returns empty list when no cursor is set', () async {
      final result = await api.getNextItems();
      expect(result, isEmpty);
    });

    test('getNextItems deduplicates artists already in the list', () async {
      late Future<Response> Function(Request) handler;
      api = _artistApi(
        'http://localhost:8000',
        MockClient((req) => handler(req)),
      );
      handler = (req) async => _artistsResponse(['Artist A', 'Artist B'], nextCursor: 'c1');
      await api.getInitialItems();

      handler = (req) async => _artistsResponse(['Artist A', 'Artist C']);
      final newItems = await api.getNextItems();

      expect(newItems, ['Artist C']);
    });

    test('getGottenItems accumulates items across pages', () async {
      late Future<Response> Function(Request) handler;
      api = _artistApi(
        'http://localhost:8000',
        MockClient((req) => handler(req)),
      );
      handler = (req) async => _artistsResponse(['Artist A', 'Artist B'], nextCursor: 'c1');
      await api.getInitialItems();

      handler = (req) async => _artistsResponse(['Artist C']);
      await api.getNextItems();

      expect(api.getGottenItems(), ['Artist A', 'Artist B', 'Artist C']);
    });

    test('getGottenItems returns empty list before any fetch', () {
      api = _artistApi('http://localhost:8000', MockClient((req) async => Response('', 500)));
      expect(api.getGottenItems(), isEmpty);
    });
  });
}