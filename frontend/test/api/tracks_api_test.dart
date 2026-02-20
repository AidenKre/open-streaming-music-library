import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

Map<String, dynamic> _minimalMetadataJson() => {
  'duration': 0.0,
  'bitrate_kbps': 0.0,
  'sample_rate_hz': 0,
  'channels': 0,
  'has_album_art': false,
};

Map<String, dynamic> _trackJson(String uuid) => {
  'uuid_id': uuid,
  'created_at': 1000,
  'last_updated': 2000,
  'metadata': _minimalMetadataJson(),
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

    test('getInitialItems returns ClientTrackDto list', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _tracksResponse(['uuid-1', 'uuid-2'])),
      );

      final result = await api.getInitialItems();

      expect(result.length, 2);
      expect((result[0] as ClientTrackDto).uuidId, 'uuid-1');
      expect((result[1] as ClientTrackDto).uuidId, 'uuid-2');
    });

    test(
      'getInitialItems stores nextCursor for subsequent page request',
      () async {
        ApiClient.initForTest(
          'http://localhost:8000',
          MockClient(
            (req) async =>
                _tracksResponse(['uuid-1'], nextCursor: 'next-cursor'),
          ),
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
      },
    );

    test('getNextItems returns empty list when no cursor is set', () async {
      final result = await api.getNextItems();
      expect(result, isEmpty);
    });

    test('getNextItems deduplicates tracks by uuidId', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async =>
              _tracksResponse(['uuid-1', 'uuid-2'], nextCursor: 'c1'),
        ),
      );
      await api.getInitialItems();

      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _tracksResponse(['uuid-1', 'uuid-3'])),
      );
      final newItems = await api.getNextItems();

      expect(newItems.length, 1);
      expect((newItems[0] as ClientTrackDto).uuidId, 'uuid-3');
    });

    test('getGottenItems accumulates tracks across pages', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async =>
              _tracksResponse(['uuid-1', 'uuid-2'], nextCursor: 'c1'),
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

    test('convertToDtos maps all fields correctly', () {
      final jsonList = [
        {
          'uuid_id': 'a-1',
          'created_at': 100,
          'last_updated': 200,
          'metadata': _minimalMetadataJson(),
        },
        {
          'uuid_id': 'b-2',
          'created_at': 300,
          'last_updated': 400,
          'metadata': _minimalMetadataJson(),
        },
      ];

      final dtos = api.convertToDtos(jsonList);

      expect(dtos.length, 2);
      expect(dtos[0].uuidId, 'a-1');
      expect(dtos[0].createdAt, 100);
      expect(dtos[0].lastUpdated, 200);
      expect(dtos[1].uuidId, 'b-2');
    });

    test('getGottenItems returns empty list before any fetch', () {
      expect(api.getGottenItems(), isEmpty);
    });
  });
}
