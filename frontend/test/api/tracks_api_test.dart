import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
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

    test('getTracksPage returns parsed response', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async =>
              _tracksResponse(['uuid-1', 'uuid-2'], nextCursor: 'c1'),
        ),
      );

      final response = await api.getTracksPage();

      expect(response.data.length, 2);
      expect(response.data[0].uuidId, 'uuid-1');
      expect(response.data[1].uuidId, 'uuid-2');
      expect(response.nextCursor, 'c1');
    });

    test('sends cursor, newer_than, older_than, limit as query params',
        () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _tracksResponse([]);
        }),
      );

      await api.getTracksPage(
        cursor: 'my-cursor',
        newerThan: 100,
        olderThan: 200,
        limit: 50,
      );

      expect(captured?.queryParameters['cursor'], 'my-cursor');
      expect(captured?.queryParameters['newer_than'], '100');
      expect(captured?.queryParameters['older_than'], '200');
      expect(captured?.queryParameters['limit'], '50');
    });

    test('sends only limit when no optional params provided', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _tracksResponse([]);
        }),
      );

      await api.getTracksPage();

      expect(captured?.queryParameters['limit'], '500');
      expect(captured?.queryParameters.containsKey('cursor'), false);
      expect(captured?.queryParameters.containsKey('newer_than'), false);
      expect(captured?.queryParameters.containsKey('older_than'), false);
      expect(captured?.queryParameters.containsKey('artist'), false);
      expect(captured?.queryParameters.containsKey('album'), false);
    });

    test('sends artist and album as query params', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _tracksResponse([]);
        }),
      );

      await api.getTracksPage(artist: 'some-artist', album: 'some-album');

      expect(captured?.queryParameters['artist'], 'some-artist');
      expect(captured?.queryParameters['album'], 'some-album');
    });

    test('sends artist without album as query param', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _tracksResponse([]);
        }),
      );

      await api.getTracksPage(artist: 'some-artist');

      expect(captured?.queryParameters['artist'], 'some-artist');
      expect(captured?.queryParameters.containsKey('album'), false);
    });

    test('returns null nextCursor when not present in response', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _tracksResponse(['uuid-1'])),
      );

      final response = await api.getTracksPage();

      expect(response.nextCursor, isNull);
    });
  });
}
