// PR 5A (5-U04): the local history repository.
//
//  * insertLocal: atomic insert, pending true, fenced by the binding.
//  * nextUploadBatch: pending, non-quarantined rows in local_id order; stop
//    before 200 events or 256 KiB of the EXACT UTF-8 `{"events":[...]}`
//    body (escapes and multi-byte characters counted); a single event too
//    large is quarantined (`oversized`), not resubmitted.
//  * applyAck: clears only submitted AND acknowledged UUIDs; malformed,
//    duplicate or unexpected ACKs are protocol errors that clear nothing; an
//    event inserted after the batch snapshot stays pending.
//  * applyPage: validates (ascending > after, unique UUIDs, nextCursor rules,
//    field bounds) before any write; detects a regressed server (rule 5);
//    inserts other devices' events (pending false); fills echo metadata but
//    NEVER clears pending; a different payload for a known UUID blocks the
//    page (cursor stays); cursor + rows commit together.
//  * keepServerVersion: archive + in-place UPDATE (local_id kept,
//    history_content bumps) + pending cleared, one transaction.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/sync_service.dart' show ServerRegressedException;

import '../helpers/server_binding.dart';

HistoryEventPayload _event(
  String uuid, {
  String kind = 'play',
  String ref = 'track-1',
  int at = 1000,
  double? seconds = 30.5,
  double? length = 200.0,
}) => HistoryEventPayload(
  eventUuid: uuid,
  kind: kind,
  entityType: 'track',
  entityRef: ref,
  occurredAt: at,
  secondsPlayed: seconds,
  trackLength: length,
);

HistoryServerEvent _server(HistoryEventPayload p, int revision, {int received = 5000}) =>
    HistoryServerEvent(payload: p, revision: revision, receivedAt: received);

HistoryPage _page(List<HistoryServerEvent> events, {int? next, int? latest}) =>
    HistoryPage(
      events: events,
      nextCursor: next,
      latestRevision: latest ?? (events.isEmpty ? 0 : events.last.revision),
    );

void main() {
  late AppDatabase db;
  late HistoryRepository repo;
  late String token;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db);
    repo = HistoryRepository(db);
  });

  tearDown(() => db.close());

  Future<List<Map<String, Object?>>> rows() async => [
    for (final r in await db
        .customSelect('SELECT * FROM history_events ORDER BY local_id')
        .get())
      r.data,
  ];

  Future<int> cursor() => SyncCursorStore(db).read(SyncStream.history);

  Future<int> counter() async {
    final r = await db
        .customSelect("SELECT value FROM local_counters WHERE key='history_content'")
        .get();
    return r.isEmpty ? 0 : r.single.read<int>('value');
  }

  group('insertLocal', () {
    test('stores the payload pending, without server metadata', () async {
      await repo.insertLocal(token, _event('e1'));
      final r = (await rows()).single;
      expect(r['event_uuid'], 'e1');
      expect(r['pending_upload'], 1);
      expect(r['server_revision'], isNull);
      expect(r['received_at'], isNull);
      expect(r['seconds_played'], 30.5);
    });

    test('unknown measures stay null (never zero)', () async {
      await repo.insertLocal(token, _event('e1', kind: 'clicked', seconds: null, length: null));
      final r = (await rows()).single;
      expect(r['seconds_played'], isNull);
      expect(r['track_length'], isNull);
    });

    // Audit 5A(a) #4/#5: never store an event the server would reject.
    for (final (label, bad) in <(String, HistoryEventPayload)>[
      ('a NUL in entity_ref', _event('00000000-0000-4000-8000-000000000001', ref: '\x00abc')),
      ('a control char in kind', _event('00000000-0000-4000-8000-000000000001', kind: 'pl\nay')),
      ('an empty kind', _event('00000000-0000-4000-8000-000000000001', kind: '')),
      ('a negative measure', _event('00000000-0000-4000-8000-000000000001', seconds: -1)),
      ('a NaN measure', _event('00000000-0000-4000-8000-000000000001', seconds: double.nan)),
    ]) {
      test('rejects an invalid payload ($label)', () async {
        await expectLater(repo.insertLocal(token, bad), throwsArgumentError);
        expect(await rows(), isEmpty);
      });
    }

    test('is fenced: a stale token writes nothing', () async {
      await ServerBindingRepository(db).fence();
      await seedTestBinding(db);
      await expectLater(
        repo.insertLocal(token, _event('e1')),
        throwsA(isA<BindingFencedException>()),
      );
      expect(await rows(), isEmpty);
    });
  });

  group('nextUploadBatch', () {
    test('null when nothing is pending', () async {
      expect(await repo.nextUploadBatch(token), isNull);
    });

    test('pending rows in local_id order, at most maxEvents', () async {
      for (var i = 0; i < 5; i++) {
        await repo.insertLocal(token, _event('e$i'));
      }
      final batch = (await repo.nextUploadBatch(token, maxEvents: 3))!;
      expect(batch.eventUuids, ['e0', 'e1', 'e2']);
      final body = jsonDecode(utf8.decode(batch.body)) as Map<String, dynamic>;
      expect((body['events'] as List).map((e) => (e as Map)['event_uuid']), ['e0', 'e1', 'e2']);
      expect(body.keys, ['events']);
    });

    test('the byte bound uses the exact UTF-8 body, escapes included', () async {
      final refs = ['é' * 20, '"\\' * 15, '🎵' * 10, 'plain' * 6];
      for (var i = 0; i < 8; i++) {
        await repo.insertLocal(token, _event('e$i', ref: refs[i % refs.length]));
      }
      final sizes = <int>[];
      for (var n = 1; n <= 8; n++) {
        final events = [
          for (var i = 0; i < n; i++) _event('e$i', ref: refs[i % refs.length]).toJson(),
        ];
        sizes.add(utf8.encode(jsonEncode({'events': events})).length);
      }
      final maxBytes = sizes[4] + 1; // room for 5 events, not 6
      final batch = (await repo.nextUploadBatch(token, maxBytes: maxBytes))!;
      expect(batch.events, hasLength(5));
      expect(batch.body.length, sizes[4]);
      expect(batch.body.length, lessThanOrEqualTo(maxBytes));
    });

    test('a single event larger than a batch is quarantined, not resubmitted',
        () async {
      await repo.insertLocal(token, _event('big', ref: 'r' * 256));
      await repo.insertLocal(token, _event('small'));
      final small = utf8.encode(jsonEncode({'events': [_event('small').toJson()]})).length;
      final batch = (await repo.nextUploadBatch(token, maxBytes: small))!;
      expect(batch.eventUuids, ['small']);
      final failures = await db.customSelect('SELECT event_uuid, reason FROM history_sync_failures').get();
      expect(failures.single.data, {'event_uuid': 'big', 'reason': 'oversized'});
      final again = (await repo.nextUploadBatch(token, maxBytes: small))!;
      expect(again.eventUuids, ['small'], reason: 'big stays out');
      expect((await rows()).first['pending_upload'], 1, reason: 'retained, not dropped');
    });

    test('quarantined events are skipped; the rest still upload', () async {
      await repo.insertLocal(token, _event('bad'));
      await repo.insertLocal(token, _event('good'));
      await repo.recordFailure(token, 'bad', reason: 'conflict', detail: '409');
      expect((await repo.nextUploadBatch(token))!.eventUuids, ['good']);
      expect(await repo.counts(), (pending: 1, quarantined: 1));
    });
  });

  group('applyAck', () {
    test('clears only submitted and acknowledged events', () async {
      for (final id in ['a', 'b', 'c']) {
        await repo.insertLocal(token, _event(id));
      }
      final batch = (await repo.nextUploadBatch(token))!;
      await repo.insertLocal(token, _event('late')); // after the snapshot
      await repo.applyAck(token, batch.eventUuids, ['a', 'c']); // partial
      final pending = {
        for (final r in await rows()) r['event_uuid']: r['pending_upload'],
      };
      expect(pending, {'a': 0, 'b': 1, 'c': 0, 'late': 1});
    });

    for (final (label, ack) in <(String, Object?)>[
      ('not a list', {'acknowledged': 'a'}),
      ('a non-string entry', ['a', 7]),
      ('null', null),
      ('a duplicate', ['a', 'a']),
      ('an unexpected UUID', ['a', 'zzz']),
    ]) {
      test('a malformed ACK ($label) clears nothing', () async {
        await repo.insertLocal(token, _event('a'));
        await repo.insertLocal(token, _event('b'));
        await expectLater(
          repo.applyAck(token, ['a', 'b'], ack),
          throwsA(isA<HistoryProtocolException>()),
        );
        expect((await rows()).map((r) => r['pending_upload']), [1, 1]);
      });
    }

    test('is fenced', () async {
      await repo.insertLocal(token, _event('a'));
      await ServerBindingRepository(db).fence();
      await seedTestBinding(db);
      await expectLater(
        repo.applyAck(token, ['a'], ['a']),
        throwsA(isA<BindingFencedException>()),
      );
    });
  });

  group('applyPage', () {
    for (final failureAtCursor in [false, true]) {
      test('rolls back writes when ${failureAtCursor ? 'cursor' : 'second event'} fails', () async {
        await db.customStatement(failureAtCursor
            ? "CREATE TRIGGER fail_history_cursor BEFORE INSERT ON sync_cursors "
              "WHEN NEW.stream = 'history' BEGIN SELECT RAISE(ABORT, 'cursor failure'); END"
            : "CREATE TRIGGER fail_history_event BEFORE INSERT ON history_events "
              "WHEN NEW.event_uuid = 'second' BEGIN SELECT RAISE(ABORT, 'row failure'); END");
        await expectLater(repo.applyPage(token, requestedAfter: 0, page: _page([
          _server(_event('first'), 5), _server(_event('second'), 7),
        ])), throwsA(anything));
        expect(await rows(), isEmpty, reason: 'first row must roll back too');
        expect(await cursor(), 0);
      });
    }
    test("inserts other devices' events (not pending) and advances the cursor",
        () async {
      await repo.applyPage(
        token,
        requestedAfter: 0,
        page: _page([_server(_event('x1'), 3), _server(_event('x2'), 8)], next: 8),
      );
      final r = await rows();
      expect(r.map((e) => (e['event_uuid'], e['pending_upload'], e['server_revision'], e['received_at'])), [
        ('x1', 0, 3, 5000),
        ('x2', 0, 8, 5000),
      ]);
      expect(await cursor(), 8);
    });

    test('a final partial page advances the cursor to its last revision', () async {
      await repo.applyPage(token, requestedAfter: 0, page: _page([_server(_event('x1'), 4)], latest: 9));
      expect(await cursor(), 4);
    });

    test('an empty final page leaves the cursor', () async {
      await repo.applyPage(token, requestedAfter: 0, page: _page([_server(_event('x1'), 4)]));
      await repo.applyPage(token, requestedAfter: 4, page: _page(const [], latest: 4));
      expect(await cursor(), 4);
    });

    test('an echo fills server metadata but never clears pending', () async {
      await repo.insertLocal(token, _event('mine'));
      await repo.applyPage(token, requestedAfter: 0, page: _page([_server(_event('mine'), 6, received: 7000)]));
      final r = (await rows()).single;
      expect(r['pending_upload'], 1, reason: 'only an ACK clears pending');
      expect(r['server_revision'], 6);
      expect(r['received_at'], 7000);
      expect(r['seconds_played'], 30.5, reason: 'payload untouched');
    });

    test('a different payload for a known UUID blocks the page', () async {
      await repo.insertLocal(token, _event('mine', seconds: 30.5));
      final theirs = _server(_event('mine', seconds: 99.0), 6);
      final other = _server(_event('x9'), 5);
      await expectLater(
        repo.applyPage(token, requestedAfter: 0, page: _page([other, theirs])),
        throwsA(isA<HistoryPayloadConflict>().having(
          (c) => c.events.map((e) => e.payload.eventUuid).toList(),
          'events',
          ['mine'],
        )),
      );
      expect((await rows()).map((r) => r['event_uuid']), ['mine'], reason: 'nothing applied');
      expect(await cursor(), 0);
    });

    final malformed = <String, HistoryPage>{
      'not ascending': _page([_server(_event('a'), 5), _server(_event('b'), 4)]),
      'not above after': _page([_server(_event('a'), 2)]),
      'duplicate UUIDs': _page([_server(_event('a'), 5), _server(_event('a'), 6)]),
      'nextCursor not the last revision': _page([_server(_event('a'), 5)], next: 4),
      'empty page with a nextCursor': _page(const [], next: 9, latest: 9),
      'empty kind': _page([_server(_event('a', kind: ''), 5)]),
      'kind over 64': _page([_server(_event('a', kind: 'k' * 65), 5)]),
      'entity_ref over 256': _page([_server(_event('a', ref: 'r' * 257), 5)]),
      'occurred_at negative': _page([_server(_event('a', at: -1), 5)]),
      'non-finite seconds': _page([_server(_event('a', seconds: double.nan), 5)]),
      'negative seconds': _page([_server(_event('a', seconds: -1), 5)]),
      'zero track_length': _page([_server(_event('a', length: 0), 5)]),
      'a NUL in kind': _page([_server(_event('a', kind: '\x00x'), 5)]),
    };
    for (final MapEntry(key: label, value: page) in malformed.entries) {
      test('a malformed page ($label) changes nothing', () async {
        await expectLater(
          repo.applyPage(token, requestedAfter: 3, page: page),
          throwsA(isA<HistoryProtocolException>()),
        );
        expect(await rows(), isEmpty);
        expect(await cursor(), 0);
      });
    }

    test('unknown kinds and entity types are valid', () async {
      await repo.applyPage(
        token,
        requestedAfter: 0,
        page: _page([
          _server(HistoryEventPayload(
            eventUuid: 'f1', kind: 'future', entityType: 'playlist',
            entityRef: 'x:1', occurredAt: 0,
          ), 2),
        ]),
      );
      expect((await rows()).single['kind'], 'future');
    });

    test('a regressed server (latest below the requested after) is detected',
        () async {
      await expectLater(
        repo.applyPage(token, requestedAfter: 10, page: _page(const [], latest: 4)),
        throwsA(isA<ServerRegressedException>()),
      );
      expect(await cursor(), 0);
    });

    test('rows and cursor are fenced together', () async {
      await ServerBindingRepository(db).fence();
      await seedTestBinding(db);
      await expectLater(
        repo.applyPage(token, requestedAfter: 0, page: _page([_server(_event('x1'), 3)])),
        throwsA(isA<BindingFencedException>()),
      );
      expect(await rows(), isEmpty);
      expect(await cursor(), 0);
    });
  });

  group('keepServerVersion', () {
    test('archives, replaces in place, clears pending and the failure', () async {
      await repo.insertLocal(token, _event('other'));
      await repo.insertLocal(token, _event('mine', seconds: 30.5));
      await repo.recordFailure(token, 'mine', reason: 'conflict');
      final before = (await rows()).firstWhere((r) => r['event_uuid'] == 'mine');
      final server = _server(_event('mine', seconds: 99.0), 12, received: 8000);

      await repo.keepServerVersion(token, server);

      final after = (await rows()).firstWhere((r) => r['event_uuid'] == 'mine');
      expect(after['local_id'], before['local_id'], reason: 'in-place UPDATE');
      expect(after['seconds_played'], 99.0);
      expect(after['pending_upload'], 0);
      expect(after['server_revision'], 12);
      expect(after['received_at'], 8000);
      expect(await counter(), 1, reason: 'history_content bumped by the trigger');
      final archive = await db
          .customSelect('SELECT event_uuid, payload_json FROM history_conflict_archive')
          .get();
      expect(archive.single.read<String>('event_uuid'), 'mine');
      expect(
        jsonDecode(archive.single.read<String>('payload_json')),
        _event('mine', seconds: 30.5).toJson(),
      );
      expect(
        await db.customSelect('SELECT * FROM history_sync_failures').get(),
        isEmpty,
      );
    });

    test('a no-op when the local payload already equals the server\'s',
        () async {
      await repo.insertLocal(token, _event('mine', seconds: 30.5));
      await repo.keepServerVersion(token, _server(_event('mine', seconds: 30.5), 3));
      expect(
        await db.customSelect('SELECT * FROM history_conflict_archive').get(),
        isEmpty,
        reason: 'nothing to archive: no conflict any more',
      );
    });

    test('is fenced', () async {
      await repo.insertLocal(token, _event('mine'));
      await ServerBindingRepository(db).fence();
      await seedTestBinding(db);
      await expectLater(
        repo.keepServerVersion(token, _server(_event('mine', seconds: 1), 3)),
        throwsA(isA<BindingFencedException>()),
      );
      expect((await rows()).single['seconds_played'], 30.5);
    });
  });
}
