import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/models/dto/change_entry_dto.dart';
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

Response _changesResponse(
  List<String> uuids, {
  int? nextCursor,
  int latestRevision = 0,
}) => Response(
  jsonEncode({
    'changes': [
      for (var i = 0; i < uuids.length; i++)
        {
          'type': 'upsert',
          'revision': i + 1,
          'uuid_id': uuids[i],
          'track': _trackJson(uuids[i]),
        },
    ],
    'nextCursor': nextCursor,
    'latestRevision': latestRevision,
  }),
  200,
);

Response _rawChangesResponse(List<Map<String, dynamic>> changes) => Response(
  jsonEncode({
    'changes': changes,
    'nextCursor': null,
    'latestRevision': changes.isEmpty ? 0 : changes.last['revision'],
  }),
  200,
);

void main() {
  group('TracksApi.getChangesPage', () {
    late TracksApi api;

    setUp(() {
      api = TracksApi();
    });

    test('parses changes, nextCursor and latestRevision', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async =>
              _changesResponse(['uuid-1'], nextCursor: 7, latestRevision: 9),
        ),
      );

      final response = await api.getChangesPage(afterRevision: 3);

      expect(response.changes.single.uuidId, 'uuid-1');
      expect(response.changes.single.type, ChangeEntryType.upsert);
      expect(response.changes.single.isUpsert, true);
      expect(response.changes.single.track, isNotNull);
      expect(response.nextCursor, 7);
      expect(response.latestRevision, 9);
    });

    test('parses delete changes', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _rawChangesResponse([
            {
              'type': 'delete',
              'revision': 4,
              'uuid_id': 'uuid-1',
              'track': null,
            },
          ]),
        ),
      );

      final response = await api.getChangesPage();

      expect(response.changes.single.type, ChangeEntryType.delete);
      expect(response.changes.single.isUpsert, false);
      expect(response.changes.single.uuidId, 'uuid-1');
      expect(response.changes.single.track, isNull);
    });

    test('throws on unknown change type', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _rawChangesResponse([
            {
              'type': 'rename',
              'revision': 1,
              'uuid_id': 'uuid-1',
              'track': null,
            },
          ]),
        ),
      );

      expect(api.getChangesPage(), throwsA(isA<FormatException>()));
    });

    test('throws when upsert omits track payload', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _rawChangesResponse([
            {
              'type': 'upsert',
              'revision': 1,
              'uuid_id': 'uuid-1',
              'track': null,
            },
          ]),
        ),
      );

      expect(api.getChangesPage(), throwsA(isA<FormatException>()));
    });

    test('throws when delete includes track payload', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _rawChangesResponse([
            {
              'type': 'delete',
              'revision': 1,
              'uuid_id': 'uuid-1',
              'track': _trackJson('uuid-1'),
            },
          ]),
        ),
      );

      expect(api.getChangesPage(), throwsA(isA<FormatException>()));
    });

    test('throws when upsert change uuid differs from track uuid', () async {
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient(
          (req) async => _rawChangesResponse([
            {
              'type': 'upsert',
              'revision': 1,
              'uuid_id': 'uuid-change',
              'track': _trackJson('uuid-track'),
            },
          ]),
        ),
      );

      expect(api.getChangesPage(), throwsA(isA<FormatException>()));
    });

    test('sends after_revision and limit as query params', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _changesResponse([]);
        }),
      );

      await api.getChangesPage(afterRevision: 42, limit: 50);

      expect(captured?.queryParameters['after_revision'], '42');
      expect(captured?.queryParameters['limit'], '50');
    });

    test('defaults to after_revision=0 and limit=500', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _changesResponse([]);
        }),
      );

      await api.getChangesPage();

      expect(captured?.queryParameters['after_revision'], '0');
      expect(captured?.queryParameters['limit'], '500');
    });
  });

  group('TracksApi.getTracksPage (browse)', () {
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

    test('sends cursor and limit as query params', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _tracksResponse([]);
        }),
      );

      await api.getTracksPage(cursor: 'my-cursor', limit: 50);

      expect(captured?.queryParameters['cursor'], 'my-cursor');
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
      expect(captured?.queryParameters.containsKey('artist_id'), false);
      expect(captured?.queryParameters.containsKey('album_id'), false);
    });

    test('sends artist_id and album_id as query params', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _tracksResponse([]);
        }),
      );

      await api.getTracksPage(artistId: 1, albumId: 2);

      expect(captured?.queryParameters['artist_id'], '1');
      expect(captured?.queryParameters['album_id'], '2');
    });

    test('sends artist_id without album_id as query param', () async {
      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _tracksResponse([]);
        }),
      );

      await api.getTracksPage(artistId: 1);

      expect(captured?.queryParameters['artist_id'], '1');
      expect(captured?.queryParameters.containsKey('album_id'), false);
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
