import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/model/database/database.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

Map<String, dynamic> _trackJson(String uuid) => {
      'uuid_id': uuid,
      'created_at': 1000,
      'last_updated': 2000,
    };

Response _tracksResponse(List<String> uuids, {String? nextCursor}) => Response(
      jsonEncode({
        'data': uuids.map(_trackJson).toList(),
        'nextCursor': nextCursor,
      }),
      200,
    );

void main() {
  group('TracksApi', () {
    late TracksApi api;

    setUp(() {
      api = TracksApi();
    });

    test('getInitialItems returns TracksCompanion list', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _tracksResponse(['uuid-1', 'uuid-2'])),
      );

      final result = await api.getInitialItems();

      expect(result.length, 2);
      expect((result[0] as TracksCompanion).uuidId, const Value('uuid-1'));
      expect((result[1] as TracksCompanion).uuidId, const Value('uuid-2'));
    });

    test('getInitialItems stores nextCursor for subsequent page request', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _tracksResponse(['uuid-1'], nextCursor: 'next-cursor')),
      );
      await api.getInitialItems();

      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _tracksResponse([]);
        }),
      );
      await api.getNextItems();

      expect(captured?.queryParameters['cursor'], 'next-cursor');
    });

    test('getNextItems returns empty list when no cursor is set', () async {
      final result = await api.getNextItems();
      expect(result, isEmpty);
    });

    test('getNextItems deduplicates tracks by uuidId', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _tracksResponse(['uuid-1', 'uuid-2'], nextCursor: 'c1'),
        ),
      );
      await api.getInitialItems();

      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _tracksResponse(['uuid-1', 'uuid-3'])),
      );
      final newItems = await api.getNextItems();

      expect(newItems.length, 1);
      expect((newItems[0] as TracksCompanion).uuidId, const Value('uuid-3'));
    });

    test('getGottenItems accumulates tracks across pages', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _tracksResponse(['uuid-1', 'uuid-2'], nextCursor: 'c1'),
        ),
      );
      await api.getInitialItems();

      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _tracksResponse(['uuid-3'])),
      );
      await api.getNextItems();

      expect(api.getGottenItems().length, 3);
    });

    test('convertToTrackCompanion maps all fields correctly', () {
      final jsonList = [
        {'uuid_id': 'a-1', 'created_at': 100, 'last_updated': 200},
        {'uuid_id': 'b-2', 'created_at': 300, 'last_updated': 400},
      ];

      final companions = api.convertToTrackCompanion(jsonList);

      expect(companions.length, 2);
      expect(companions[0].uuidId, const Value('a-1'));
      expect(companions[0].createdAt, const Value(100));
      expect(companions[0].lastUpdated, const Value(200));
      expect(companions[1].uuidId, const Value('b-2'));
    });

    test('getGottenItems returns empty list before any fetch', () {
      expect(api.getGottenItems(), isEmpty);
    });
  });
}