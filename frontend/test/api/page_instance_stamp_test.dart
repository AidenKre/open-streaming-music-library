// Phase 7B.1a (D24, SC-01 rule 6): the catalog and history page fetchers
// carry the server's `X-Server-Instance-Id` stamp on the page they return,
// so the page commit can compare it with the bound instance. A missing (or
// blank) header is "no stamp" (a pre-Phase-7 server), never an invented
// value.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/history_api.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/models/instance_stamp.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

const _instance = '3f1c2a9e-7b4d-4e2a-9c1f-0a1b2c3d4e5f';

Response _changes(Map<String, String> headers) => Response(
  jsonEncode({'changes': [], 'nextCursor': null, 'latestRevision': 0}),
  200,
  headers: headers,
);

Response _history(Map<String, String> headers) => Response(
  jsonEncode({'events': [], 'nextCursor': null, 'latestRevision': 0}),
  200,
  headers: headers,
);

ApiClient _client(Response Function() answer) =>
    testApiClient('http://srv', MockClient((_) async => answer()));

void main() {
  group('instanceStampFrom', () {
    test('reads the header whatever the case of its name', () {
      expect(instanceStampFrom({'x-server-instance-id': _instance}), _instance);
      expect(instanceStampFrom({'X-Server-Instance-Id': _instance}), _instance);
      expect(instanceStampFrom({'X-SERVER-INSTANCE-ID': _instance}), _instance);
    });

    test('trims surrounding whitespace', () {
      expect(instanceStampFrom({'x-server-instance-id': '  $_instance \t'}),
          _instance);
    });

    test('a missing or blank header is no stamp', () {
      expect(instanceStampFrom(const {}), isNull);
      expect(instanceStampFrom({'content-type': 'application/json'}), isNull);
      expect(instanceStampFrom({'x-server-instance-id': ''}), isNull);
      expect(instanceStampFrom({'x-server-instance-id': '   '}), isNull);
    });
  });

  group('catalog page (TracksApi.getChangesPage)', () {
    test('carries the stamp of the response', () async {
      final api = TracksApi(
        api: _client(() => _changes({'x-server-instance-id': _instance})),
      );
      expect((await api.getChangesPage()).servedBy, _instance);
    });

    test('a response without the header has no stamp', () async {
      final api = TracksApi(api: _client(() => _changes(const {})));
      expect((await api.getChangesPage()).servedBy, isNull);
    });
  });

  group('history page (HistoryApi.changes)', () {
    test('carries the stamp of the response', () async {
      final api = HistoryApi(
        api: _client(() => _history({'X-Server-Instance-Id': _instance})),
      );
      expect((await api.changes(after: 0)).servedBy, _instance);
    });

    test('a response without the header has no stamp', () async {
      final api = HistoryApi(api: _client(() => _history(const {})));
      expect((await api.changes(after: 0)).servedBy, isNull);
    });
  });
}
