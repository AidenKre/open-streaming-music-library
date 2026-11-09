// PR 5A: the /history transport and the `history` capability (SC-03).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/history_api.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

HistoryEventPayload _event(String uuid, {String ref = 'track-1'}) =>
    HistoryEventPayload(
      eventUuid: uuid,
      kind: 'play',
      entityType: 'track',
      entityRef: ref,
      occurredAt: 1000,
      secondsPlayed: 30.5,
      trackLength: null,
    );

HistoryUploadBatch _batch(List<HistoryEventPayload> events) => HistoryUploadBatch(
  events,
  utf8.encode(jsonEncode({'events': [for (final e in events) e.toJson()]})),
);

void main() {
  late List<http.Request> requests;

  void serve(http.Response Function(http.Request) handler) {
    requests = [];
    ApiClient.initForTest(
      'http://srv',
      MockClient((req) async {
        requests.add(req);
        return handler(req);
      }),
    );
  }

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  group('post', () {
    test('sends the batch body byte for byte and returns the raw ACK', () async {
      serve((_) => json({'acknowledged': ['a', 'b']}));
      final batch = _batch([_event('a', ref: 'é🎵"\\'), _event('b')]);
      final ack = await HistoryApi().post(batch);
      expect(ack, ['a', 'b']);
      final req = requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, '/history');
      expect(req.bodyBytes, batch.body);
      expect(req.headers['content-type'], contains('application/json'));
    });

    test('a response without an ACK list returns it as-is (null)', () async {
      serve((_) => json({'unexpected': true}));
      expect(await HistoryApi().post(_batch([_event('a')])), isNull);
    });

    test('a 409 conflict is a typed ApiException', () async {
      serve((_) => json({
        'detail': {
          'error': 'history_event_conflict',
          'message': 'conflict',
          'retryable': false,
          'conflicting_event_uuids': ['a'],
        },
      }, 409));
      await expectLater(
        HistoryApi().post(_batch([_event('a')])),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'status', 409)
            .having((e) => e.errorCode, 'code', 'history_event_conflict')
            .having((e) => e.details?['conflicting_event_uuids'], 'uuids', ['a'])),
      );
    });
  });

  group('changes', () {
    test('requests after/limit and parses the page', () async {
      serve((_) => json({
        'events': [
          {
            'event_uuid': 'x1', 'revision': 7, 'kind': 'play',
            'entity_type': 'track', 'entity_ref': 't', 'occurred_at': 1000,
            'seconds_played': 30, 'track_length': null, 'received_at': 2000,
          },
        ],
        'nextCursor': 7,
        'latestRevision': 9,
      }));
      final page = await HistoryApi().changes(after: 5, limit: 50);
      final req = requests.single;
      expect(req.url.path, '/history/changes');
      expect(req.url.queryParameters, {'after': '5', 'limit': '50'});
      final e = page.events.single;
      expect(e.revision, 7);
      expect(e.receivedAt, 2000);
      expect(e.payload.eventUuid, 'x1');
      expect(e.payload.secondsPlayed, 30.0);
      expect(e.payload.secondsPlayed, isA<double>());
      expect(e.payload.trackLength, isNull);
      expect(page.nextCursor, 7);
      expect(page.latestRevision, 9);
    });

    test('the default limit is 200; a null nextCursor parses', () async {
      serve((_) => json({'events': [], 'nextCursor': null, 'latestRevision': 0}));
      final page = await HistoryApi().changes(after: 0);
      expect(requests.single.url.queryParameters['limit'], '200');
      expect(page.events, isEmpty);
      expect(page.nextCursor, isNull);
    });

    for (final (label, body) in <(String, Object)>[
      ('events not a list', {'events': {}, 'nextCursor': null, 'latestRevision': 0}),
      ('missing latestRevision', {'events': [], 'nextCursor': null}),
      ('an event missing a field', {
        'events': [{'event_uuid': 'x', 'revision': 1}],
        'nextCursor': null, 'latestRevision': 1,
      }),
      ('a wrong type', {
        'events': [{
          'event_uuid': 'x', 'revision': '1', 'kind': 'play',
          'entity_type': 'track', 'entity_ref': 't', 'occurred_at': 1,
          'seconds_played': null, 'track_length': null, 'received_at': 2,
        }],
        'nextCursor': null, 'latestRevision': 1,
      }),
    ]) {
      test('a malformed page ($label) is a FormatException', () async {
        serve((_) => json(body));
        await expectLater(
          HistoryApi().changes(after: 0),
          throwsA(isA<FormatException>()),
        );
      });
    }
  });

  group('AppInfo history capability (SC-03)', () {
    test('advertised version 1 is supported', () {
      final info = AppInfo.fromJson({'history': {'version': 1}});
      expect(info.historyVersion, 1);
      expect(info.supportsHistory, isTrue);
    });

    test('a missing or malformed block means unsupported', () {
      for (final json in <Map<String, dynamic>>[
        {},
        {'history': true},
        {'history': {'version': 'one'}},
      ]) {
        final info = AppInfo.fromJson(json);
        expect(info.historyVersion, isNull, reason: '$json');
        expect(info.supportsHistory, isFalse, reason: '$json');
      }
    });

    test('the cached blob round-trips the block', () {
      final info = AppInfo.fromJson({'history': {'version': 1}});
      expect(AppInfo.fromJson(info.toJson()).supportsHistory, isTrue);
      expect(AppInfo.fromJson(const AppInfo().toJson()).supportsHistory, isFalse);
    });
  });
}
