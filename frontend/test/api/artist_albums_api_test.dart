import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/artist_albums_api.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

Response _albumsResponse(List<String> albums, {String? nextCursor}) => Response(
      jsonEncode({'data': albums, 'nextCursor': nextCursor}),
      200,
    );

void main() {
  group('ArtistAlbumsApi', () {
    late ArtistAlbumsApi api;
    const artist = 'Pink Floyd';

    setUp(() {
      api = ArtistAlbumsApi(artist);
    });

    test('getInitialItems returns albums for the artist', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _albumsResponse(['The Wall', 'Animals'])),
      );

      final result = await api.getInitialItems();

      expect(result, ['The Wall', 'Animals']);
    });

    test('getInitialItems sends request with artist name and albums in path', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _albumsResponse([]);
        }),
      );

      await api.getInitialItems();

      expect(captured?.pathSegments, contains('Pink Floyd'));
      expect(captured?.pathSegments, contains('albums'));
    });

    test('getNextItems returns empty list when no cursor is set', () async {
      final result = await api.getNextItems();
      expect(result, isEmpty);
    });

    test('getNextItems sends cursor in query', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _albumsResponse(['The Wall'], nextCursor: 'album-cursor'),
        ),
      );
      await api.getInitialItems();

      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _albumsResponse([]);
        }),
      );
      await api.getNextItems();

      expect(captured?.queryParameters['cursor'], 'album-cursor');
    });

    test('getNextItems deduplicates albums already in the list', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _albumsResponse(['The Wall', 'Animals'], nextCursor: 'c1'),
        ),
      );
      await api.getInitialItems();

      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _albumsResponse(['The Wall', 'Meddle'])),
      );
      final newItems = await api.getNextItems();

      expect(newItems, ['Meddle']);
    });

    test('getGottenItems accumulates albums across pages', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _albumsResponse(['The Wall'], nextCursor: 'c1'),
        ),
      );
      await api.getInitialItems();

      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _albumsResponse(['Animals'])),
      );
      await api.getNextItems();

      expect(api.getGottenItems(), ['The Wall', 'Animals']);
    });

    test('getGottenItems returns empty list before any fetch', () {
      expect(api.getGottenItems(), isEmpty);
    });
  });
}