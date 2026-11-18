import 'dart:convert';
import 'dart:io';
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
  'revision': 1,
  'metadata': _minimalMetadataJson(),
};

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

TracksApi _tracksApi(String url, Client client) =>
    TracksApi(api: testApiClient(url, client));

void main() {
  group('TracksApi.getChangesPage', () {
    late TracksApi api;

    test('parses changes, nextCursor and latestRevision', () async {
      api = _tracksApi(
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
      api = _tracksApi(
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
      api = _tracksApi(
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
      api = _tracksApi(
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
      api = _tracksApi(
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
      api = _tracksApi(
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
      api = _tracksApi(
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
      api = _tracksApi(
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

  // Other-issues row 68 (U16-FE-API-B-11): the request shape of the
  // single-track read and the metadata edit, before the client's retry arms
  // are folded into one check.
  group('TracksApi.getTrack and patchTrack (request shape)', () {
    test('getTrack is one GET of /tracks/<uuid> with Accept json, '
        'parsed into the track', () async {
      final requests = <Request>[];
      final api = _tracksApi(
        'http://localhost:8000',
        MockClient((req) async {
          requests.add(req);
          return Response(jsonEncode(_trackJson('uuid-1')), 200);
        }),
      );

      final track = await api.getTrack('uuid-1');

      expect(track.uuidId, 'uuid-1');
      expect(track.revision, 1);
      final req = requests.single;
      expect(req.method, 'GET');
      expect(req.url.path, '/tracks/uuid-1');
      expect(req.url.query, isEmpty);
      expect(req.headers['Accept'], 'application/json');
      expect(req.body, isEmpty);
    });

    test('getTrack is a single attempt: a 503 and a transport error are not '
        'retried', () async {
      var calls = 0;
      var api = _tracksApi(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          return Response('busy', 503);
        }),
      );
      await expectLater(
        api.getTrack('uuid-1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 503)),
      );
      expect(calls, 1);

      calls = 0;
      api = _tracksApi(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          throw const SocketException('down');
        }),
      );
      await expectLater(api.getTrack('uuid-1'), throwsA(isA<NetworkException>()));
      expect(calls, 1);
    });

    test('getTrack surfaces a 404 as ApiException', () async {
      final api = _tracksApi(
        'http://localhost:8000',
        MockClient((req) async => Response('{"detail":"gone"}', 404)),
      );
      await expectLater(
        api.getTrack('uuid-1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
    });

    test('patchTrack is a PATCH of /tracks/<uuid> with the body as JSON and '
        'returns the parsed answer', () async {
      final requests = <Request>[];
      final api = _tracksApi(
        'http://localhost:8000',
        MockClient((req) async {
          requests.add(req);
          return Response(
            jsonEncode({
              'uuid_id': 'uuid-1',
              'revision': 8,
              'master_written': false,
            }),
            200,
          );
        }),
      );
      final body = {
        'title': 'New',
        'base_revision': 7,
        'write_mode': 'database_only',
      };

      final answer = await api.patchTrack('uuid-1', body);

      expect(answer, {
        'uuid_id': 'uuid-1',
        'revision': 8,
        'master_written': false,
      });
      final req = requests.single;
      expect(req.method, 'PATCH');
      expect(req.url.path, '/tracks/uuid-1');
      expect(req.headers['Accept'], 'application/json');
      expect(req.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(req.body), body);
    });

    test('patchTrack retries a transport error and a 503, sending the same '
        'body each time', () async {
      final bodies = <String>[];
      final api = _tracksApi(
        'http://localhost:8000',
        MockClient((req) async {
          bodies.add(req.body);
          if (bodies.length == 1) throw const SocketException('reset');
          if (bodies.length == 2) return Response('busy', 503);
          return Response(jsonEncode({'uuid_id': 'uuid-1', 'revision': 2}), 200);
        }),
      );

      final answer = await api.patchTrack('uuid-1', {'title': 'X'});

      expect(answer['revision'], 2);
      expect(bodies, hasLength(3));
      expect(bodies.toSet(), {jsonEncode({'title': 'X'})});
    });

    test('patchTrack does not retry a 409 conflict', () async {
      var calls = 0;
      final api = _tracksApi(
        'http://localhost:8000',
        MockClient((req) async {
          calls++;
          return Response('{"detail":"conflict"}', 409);
        }),
      );
      await expectLater(
        api.patchTrack('uuid-1', {'title': 'X'}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409)),
      );
      expect(calls, 1);
    });
  });
}
