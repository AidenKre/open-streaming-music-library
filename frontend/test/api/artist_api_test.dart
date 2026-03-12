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

void main() {
  group('ArtistApi', () {
    late ArtistApi api;

    setUp(() {
      api = ArtistApi();
    });

    test('getInitialItems returns artists from response', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _artistsResponse(['Artist A', 'Artist B'])),
      );

      final result = await api.getInitialItems();

      expect(result, ['Artist A', 'Artist B']);
    });

    test('getInitialItems stores nextCursor for subsequent page request', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _artistsResponse(['Artist A'], nextCursor: 'cursor-abc')),
      );
      await api.getInitialItems();

      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _artistsResponse([]);
        }),
      );
      await api.getNextItems();

      expect(captured?.queryParameters['cursor'], 'cursor-abc');
    });

    test('getNextItems returns empty list when no cursor is set', () async {
      final result = await api.getNextItems();
      expect(result, isEmpty);
    });

    test('getNextItems deduplicates artists already in the list', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _artistsResponse(['Artist A', 'Artist B'], nextCursor: 'c1'),
        ),
      );
      await api.getInitialItems();

      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _artistsResponse(['Artist A', 'Artist C']),
        ),
      );
      final newItems = await api.getNextItems();

      expect(newItems, ['Artist C']);
    });

    test('getGottenItems accumulates items across pages', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _artistsResponse(['Artist A', 'Artist B'], nextCursor: 'c1'),
        ),
      );
      await api.getInitialItems();

      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _artistsResponse(['Artist C'])),
      );
      await api.getNextItems();

      expect(api.getGottenItems(), ['Artist A', 'Artist B', 'Artist C']);
    });

    test('getGottenItems returns empty list before any fetch', () {
      expect(api.getGottenItems(), isEmpty);
    });
  });
}