// B.13 (U26-A-01, U26-A-12): one strict reader for a history event, used by
// the /history/changes transport and by the listen drafts' stored payload.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/history_event.dart';

const _payload = HistoryEventPayload(
  eventUuid: '11111111-1111-4111-8111-111111111111',
  kind: HistoryKind.play,
  entityType: 'track',
  entityRef: 'track-1',
  occurredAt: 1700000000000,
  secondsPlayed: 30.5,
  trackLength: null,
);

Map<String, Object?> _wire([Map<String, Object?> extra = const {}]) => {
  ..._payload.toJson(),
  ...extra,
};

final _malformed = throwsA(isA<FormatException>());

void main() {
  group('HistoryEventPayload.fromJson', () {
    test('reads back what toJson wrote', () {
      expect(HistoryEventPayload.fromJson(_wire()), _payload);
      const both = HistoryEventPayload(
        eventUuid: 'e',
        kind: 'clicked',
        entityType: 'album',
        entityRef: 'a',
        occurredAt: 1,
        secondsPlayed: null,
        trackLength: 240.25,
      );
      expect(HistoryEventPayload.fromJson(both.toJson()), both);
    });

    test('a whole-number measure is read as a double; null is unknown, '
        'not 0', () {
      final read = HistoryEventPayload.fromJson(
        _wire({'seconds_played': 30, 'track_length': null}),
      );
      expect(read.secondsPlayed, 30.0);
      expect(read.secondsPlayed, isA<double>());
      expect(read.trackLength, isNull);
    });

    test('not an object is malformed', () {
      expect(() => HistoryEventPayload.fromJson('x'), _malformed);
      expect(() => HistoryEventPayload.fromJson(null), _malformed);
      expect(() => HistoryEventPayload.fromJson([_wire()]), _malformed);
    });

    for (final key in [
      'event_uuid',
      'kind',
      'entity_type',
      'entity_ref',
      'occurred_at',
      'seconds_played',
      'track_length',
    ]) {
      test('a missing $key is malformed (every key is present on the wire)',
          () {
        expect(
          () => HistoryEventPayload.fromJson(Map.of(_wire())..remove(key)),
          _malformed,
        );
      });
    }

    for (final (label, extra) in <(String, Map<String, Object?>)>[
      ('event_uuid a number', {'event_uuid': 1}),
      ('kind null', {'kind': null}),
      ('entity_ref a list', {'entity_ref': <String>[]}),
      ('occurred_at a string', {'occurred_at': '1'}),
      ('occurred_at a float', {'occurred_at': 1.0}),
      ('seconds_played a string', {'seconds_played': '3'}),
      ('track_length a boolean', {'track_length': true}),
    ]) {
      test('$label is malformed', () {
        expect(() => HistoryEventPayload.fromJson(_wire(extra)), _malformed);
      });
    }
  });

  group('HistoryServerEvent.fromJson', () {
    test('reads the payload, revision and received_at', () {
      final e = HistoryServerEvent.fromJson(
        _wire({'revision': 7, 'received_at': 2000}),
      );
      expect(e.payload, _payload);
      expect(e.revision, 7);
      expect(e.receivedAt, 2000);
    });

    for (final (label, extra) in <(String, Map<String, Object?>)>[
      ('revision missing', {'received_at': 2000}),
      ('revision a string', {'revision': '7', 'received_at': 2000}),
      ('received_at missing', {'revision': 7}),
      ('a payload field null', {
        'revision': 7,
        'received_at': 2000,
        'kind': null,
      }),
    ]) {
      test('$label is malformed', () {
        expect(() => HistoryServerEvent.fromJson(_wire(extra)), _malformed);
      });
    }
  });
}
