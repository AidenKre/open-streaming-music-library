// SC-14 durable client submissions (Phase 7B.1b; 7-U01, 7-U08, 7-U11):
// persist before send, `prepared → sent → accepted | rejected | ambiguous`,
// status-first recovery, no new operation id on a timeout, a duplicate-tap
// guard, every write fenced by the row's `local_binding_id` (SC-01 rule 4)
// and an SC-15 quiesce. Rows are asserted through raw SQL, independently of
// the helper's own read path.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/operations/durable_submission.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/server_binding.dart';

/// A frozen body with deliberate whitespace, key order and a float written
/// as `1.0`: a re-encode of the decoded map would not reproduce it.
const _body = '{ "z": 1.0,  "a": ["x", "y"], "n": null }';

Future<List<Map<String, Object?>>> _rows(AppDatabase db) async => [
  for (final r in await db
      .customSelect(
        'SELECT operation_uuid, kind, local_binding_id, frozen_body_json, '
        'state, receipt_json, error_code, created_at, updated_at '
        'FROM durable_submissions ORDER BY operation_uuid',
      )
      .get())
    r.data,
];

/// A status query a test does not expect: counted through the outcome.
Future<SubmissionStatus> _noStatus(String operationUuid) async =>
    throw StateError('unexpected status query for $operationUuid');

void main() {
  late AppDatabase db;
  late ServerBindingRepository binding;
  late FakeClock clock;
  late DurableSubmission submissions;
  late String token;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    binding = ServerBindingRepository(db);
    clock = FakeClock(startUtcMs: 5000);
    token = await seedTestBinding(db, reconciled: true);
    submissions = DurableSubmission(db: db, binding: binding, clock: clock);
  });
  tearDown(() => db.close());

  group('prepare', () {
    test('persists a prepared row under the captured binding, with the '
        'frozen body stored verbatim', () async {
      final record = await submissions.prepare(
        kind: 'test.op',
        operationUuid: 'op-1',
        frozenBodyJson: _body,
        bindingToken: token,
      );

      expect(record.state, SubmissionState.prepared);
      expect(record.frozenBodyJson, _body);
      expect(await _rows(db), [
        {
          'operation_uuid': 'op-1',
          'kind': 'test.op',
          'local_binding_id': token,
          'frozen_body_json': _body,
          'state': 'prepared',
          'receipt_json': null,
          'error_code': null,
          'created_at': 5000,
          'updated_at': 5000,
        },
      ]);
    });

    test('a raw-stream operation has no frozen body', () async {
      await submissions.prepare(
        kind: 'test.stream',
        operationUuid: 'op-2',
        frozenBodyJson: null,
        bindingToken: token,
      );
      expect((await _rows(db)).single['frozen_body_json'], isNull);
    });

    test('preparing the same operation again with the same kind and body '
        'returns the stored row unchanged', () async {
      await submissions.prepare(
        kind: 'test.op',
        operationUuid: 'op-1',
        frozenBodyJson: _body,
        bindingToken: token,
      );
      final before = await _rows(db);
      clock.advance(const Duration(seconds: 5));

      final again = await submissions.prepare(
        kind: 'test.op',
        operationUuid: 'op-1',
        frozenBodyJson: _body,
        bindingToken: token,
      );

      expect(again.state, SubmissionState.prepared);
      expect(again.createdAtMs, 5000);
      expect(await _rows(db), before);
    });

    test('a different body, kind or a missing body for a stored operation '
        'is a conflict and never replaces the frozen body', () async {
      await submissions.prepare(
        kind: 'test.op',
        operationUuid: 'op-1',
        frozenBodyJson: _body,
        bindingToken: token,
      );
      final before = await _rows(db);

      for (final (kind, body) in [
        ('test.op', '{"z":1.0,"a":["x","y"],"n":null}'),
        ('other.op', _body),
        ('test.op', null),
      ]) {
        await expectLater(
          submissions.prepare(
            kind: kind,
            operationUuid: 'op-1',
            frozenBodyJson: body,
            bindingToken: token,
          ),
          throwsA(isA<SubmissionConflict>()),
          reason: '$kind $body',
        );
      }
      expect(await _rows(db), before);
    });

    test('a token from before a reset or a logout writes nothing', () async {
      await binding.rotate();
      await expectLater(
        submissions.prepare(
          kind: 'test.op',
          operationUuid: 'op-1',
          frozenBodyJson: _body,
          bindingToken: token,
        ),
        throwsA(isA<BindingFencedException>()),
      );

      await binding.fence();
      await expectLater(
        submissions.prepare(
          kind: 'test.op',
          operationUuid: 'op-2',
          frozenBodyJson: _body,
          bindingToken: token,
        ),
        throwsA(isA<BindingFencedException>()),
      );
      expect(await _rows(db), isEmpty);
    });

    test('find returns the stored record, or null for an unknown id',
        () async {
      await submissions.prepare(
        kind: 'test.op',
        operationUuid: 'op-1',
        frozenBodyJson: _body,
        bindingToken: token,
      );
      final found = await submissions.find('op-1');
      expect(found?.kind, 'test.op');
      expect(found?.localBindingId, token);
      expect(found?.state, SubmissionState.prepared);
      expect(await submissions.find('nope'), isNull);
    });
  });

  group('submit', () {
    Future<void> prepared([String uuid = 'op-1']) => submissions.prepare(
      kind: 'test.op',
      operationUuid: uuid,
      frozenBodyJson: _body,
      bindingToken: token,
    );

    test('marks the row sent before the request leaves, then stores the '
        'receipt', () async {
      await prepared();
      final statesAtSend = <Object?>[];
      final outcome = await submissions.submit(
        'op-1',
        send: (request) async {
          statesAtSend.add((await _rows(db)).single['state']);
          return {'item_uuid': 'i-1', 'state': 'committing'};
        },
        status: _noStatus,
      );

      expect(statesAtSend, ['sent']);
      expect(
        outcome,
        isA<SubmissionAccepted>().having((o) => o.receipt, 'receipt', {
          'item_uuid': 'i-1',
          'state': 'committing',
        }),
      );
      final row = (await _rows(db)).single;
      expect(row['state'], 'accepted');
      expect(jsonDecode(row['receipt_json']! as String), {
        'item_uuid': 'i-1',
        'state': 'committing',
      });
      expect(row['error_code'], isNull);
    });

    test('the send gets the operation id and the frozen body verbatim',
        () async {
      await prepared();
      final requests = <SubmissionRequest>[];
      await submissions.submit(
        'op-1',
        send: (request) async {
          requests.add(request);
          return const {};
        },
        status: _noStatus,
      );
      expect(requests.single.operationUuid, 'op-1');
      expect(requests.single.frozenBodyJson, _body);
    });

    test('updated_at follows the clock; created_at stays', () async {
      await prepared();
      clock.advance(const Duration(seconds: 3));
      await submissions.submit(
        'op-1',
        send: (_) async => const {},
        status: _noStatus,
      );
      final row = (await _rows(db)).single;
      expect(row['created_at'], 5000);
      expect(row['updated_at'], 8000);
    });

    test('an accepted operation is never sent or queried again', () async {
      await prepared();
      await submissions.submit(
        'op-1',
        send: (_) async => {'n': 1},
        status: _noStatus,
      );

      final again = await submissions.submit(
        'op-1',
        send: (_) => fail('an accepted operation was sent again'),
        status: (_) => fail('an accepted operation was queried'),
      );
      expect(
        again,
        isA<SubmissionAccepted>().having((o) => o.receipt, 'receipt', {'n': 1}),
      );
    });

    test('a definitive rejection stores its error code and is never sent '
        'again', () async {
      await prepared('op-1');
      await prepared('op-2');
      final conflict = await submissions.submit(
        'op-1',
        send: (_) async => throw ApiException(
          409,
          '{"detail":{"error":"operation_conflict","message":"m",'
          '"retryable":false}}',
        ),
        status: _noStatus,
      );
      final bare = await submissions.submit(
        'op-2',
        send: (_) async => throw ApiException(422, '{"detail":"bad"}'),
        status: _noStatus,
      );

      expect(
        conflict,
        isA<SubmissionRejected>().having((o) => o.code, 'code',
            'operation_conflict'),
      );
      expect(
        bare,
        isA<SubmissionRejected>().having((o) => o.code, 'code', 'http_422'),
      );
      expect([for (final r in await _rows(db)) (r['state'], r['error_code'])], [
        ('rejected', 'operation_conflict'),
        ('rejected', 'http_422'),
      ]);

      final again = await submissions.submit(
        'op-1',
        send: (_) => fail('a rejected operation was sent again'),
        status: (_) => fail('a rejected operation was queried'),
      );
      expect(
        again,
        isA<SubmissionRejected>().having((o) => o.code, 'code',
            'operation_conflict'),
      );
    });

    test('an unknown operation id is an error, never a send', () async {
      await expectLater(
        submissions.submit(
          'nope',
          send: (_) => fail('sent an unknown operation'),
          status: _noStatus,
        ),
        throwsStateError,
      );
    });
  });

  group('ambiguous', () {
    Future<void> prepared([String uuid = 'op-1']) => submissions.prepare(
      kind: 'test.op',
      operationUuid: uuid,
      frozenBodyJson: _body,
      bindingToken: token,
    );

    test('a transport failure, timeout, 5xx, 401 or retryable answer leaves '
        'the operation ambiguous with its error code', () async {
      final failures = <(Object, String)>[
        (NetworkException('down', attemptsMade: 1), 'network'),
        (TimeoutException('slow'), 'network'),
        (ApiException(500, 'boom'), 'http_500'),
        (ApiException(502, ''), 'http_502'),
        (
          ApiException(
            503,
            '{"detail":{"error":"upload_slots_busy","message":"m",'
            '"retryable":true}}',
          ),
          'upload_slots_busy',
        ),
        (ApiException(401, '{"detail":"Not authenticated"}'), 'http_401'),
        (ApiException(408, ''), 'http_408'),
        (ApiException(429, ''), 'http_429'),
        (
          ApiException(
            409,
            '{"detail":{"error":"busy","message":"m","retryable":true}}',
          ),
          'busy',
        ),
      ];
      for (final (i, (error, _)) in failures.indexed) {
        await prepared('op-$i');
        final outcome = await submissions.submit(
          'op-$i',
          send: (_) async => throw error,
          status: _noStatus,
        );
        expect(outcome, isA<SubmissionAmbiguous>(), reason: '$error');
      }
      expect([for (final r in await _rows(db)) (r['state'], r['error_code'])], [
        for (final (_, code) in failures) ('ambiguous', code),
      ]);
    });

    test('timeout → ambiguous → the status GET resolves it to accepted '
        'without a second POST', () async {
      await prepared();
      var sends = 0;
      final first = await submissions.submit(
        'op-1',
        send: (_) async {
          sends++;
          throw NetworkException('timed out', attemptsMade: 1);
        },
        status: _noStatus,
      );
      expect(first, isA<SubmissionAmbiguous>());

      final queried = <String>[];
      final second = await submissions.submit(
        'op-1',
        send: (_) async {
          sends++;
          return const {};
        },
        status: (uuid) async {
          queried.add(uuid);
          return const StatusAccepted({'state': 'imported'});
        },
      );

      expect(sends, 1);
      expect(queried, ['op-1']);
      expect(
        second,
        isA<SubmissionAccepted>().having((o) => o.receipt, 'receipt', {
          'state': 'imported',
        }),
      );
      final row = (await _rows(db)).single;
      expect(row['state'], 'accepted');
      expect(jsonDecode(row['receipt_json']! as String), {'state': 'imported'});
      expect(row['error_code'], isNull);
    });

    test('when the server never saw it, the retry resends the same '
        'operation id and the same frozen body', () async {
      await prepared();
      final requests = <SubmissionRequest>[];
      await submissions.submit(
        'op-1',
        send: (request) async {
          requests.add(request);
          throw NetworkException('reset by peer', attemptsMade: 1);
        },
        status: _noStatus,
      );

      final outcome = await submissions.submit(
        'op-1',
        send: (request) async {
          requests.add(request);
          return {'ok': true};
        },
        status: (_) async => const StatusAbsent(),
      );

      expect(outcome, isA<SubmissionAccepted>());
      expect([for (final r in requests) r.operationUuid], ['op-1', 'op-1']);
      expect([for (final r in requests) r.frozenBodyJson], [_body, _body]);
      expect((await _rows(db)).single['state'], 'accepted');
    });

    test('a status the server rejected resolves without sending', () async {
      await prepared();
      await submissions.submit(
        'op-1',
        send: (_) async => throw ApiException(504, ''),
        status: _noStatus,
      );
      var sends = 0;
      final outcome = await submissions.submit(
        'op-1',
        send: (_) async {
          sends++;
          return const {};
        },
        status: (_) async => const StatusRejected('expired'),
      );
      expect(sends, 0);
      expect(
        outcome,
        isA<SubmissionRejected>().having((o) => o.code, 'code', 'expired'),
      );
      expect(
        [for (final r in await _rows(db)) (r['state'], r['error_code'])],
        [('rejected', 'expired')],
      );
    });

    test('a failed status query keeps it ambiguous and sends nothing',
        () async {
      await prepared();
      await submissions.submit(
        'op-1',
        send: (_) async => throw NetworkException('down', attemptsMade: 1),
        status: _noStatus,
      );
      var sends = 0;
      final outcome = await submissions.submit(
        'op-1',
        send: (_) async {
          sends++;
          return const {};
        },
        status: (_) async => throw NetworkException('still down',
            attemptsMade: 1),
      );
      expect(sends, 0);
      expect(outcome, isA<SubmissionAmbiguous>());
      expect((await _rows(db)).single['state'], 'ambiguous');
    });

    // 7-R1-29 (D2): only a send can be refused; a status query that answers
    // a definitive 4xx never proves the operation was refused.
    test('a definitive 4xx on the status query, with no hook, keeps it '
        'ambiguous and sends nothing', () async {
      await prepared();
      await submissions.submit(
        'op-1',
        send: (_) async => throw NetworkException('down', attemptsMade: 1),
        status: _noStatus,
      );
      var sends = 0;
      final outcome = await submissions.submit(
        'op-1',
        send: (_) async {
          sends++;
          return const {};
        },
        status: (_) async => throw ApiException(
          404,
          '{"detail":{"error":"upload_item_not_found","retryable":false}}',
        ),
      );
      expect(sends, 0);
      expect(outcome, isA<SubmissionAmbiguous>());
      expect((await _rows(db)).single['state'], 'ambiguous');
    });

    test('a row left "sent" by a crash asks for status before any resend',
        () async {
      await prepared();
      // The process died after marking the row sent, before the response
      // was stored: the request may or may not have arrived.
      await db.customStatement(
        "UPDATE durable_submissions SET state = 'sent' WHERE operation_uuid = 'op-1'",
      );
      final calls = <String>[];
      final outcome = await submissions.submit(
        'op-1',
        send: (_) async {
          calls.add('send');
          return const {};
        },
        status: (_) async {
          calls.add('status');
          return const StatusAccepted({'replayed': true});
        },
      );
      expect(calls, ['status']);
      expect(outcome, isA<SubmissionAccepted>());
    });

    test('a prepared row was never sent: no status query before the first '
        'send', () async {
      await prepared();
      final calls = <String>[];
      await submissions.submit(
        'op-1',
        send: (_) async {
          calls.add('send');
          return const {};
        },
        status: (_) async {
          calls.add('status');
          return const StatusAbsent();
        },
      );
      expect(calls, ['send']);
    });

    test('an unexpected error marks the operation ambiguous and is '
        'rethrown', () async {
      await prepared();
      await expectLater(
        submissions.submit(
          'op-1',
          send: (_) async => throw const FormatException('bad receipt'),
          status: _noStatus,
        ),
        throwsFormatException,
      );
      expect((await _rows(db)).single['state'], 'ambiguous');
    });
  });

  group('fence', () {
    Future<void> prepared([String uuid = 'op-1']) => submissions.prepare(
      kind: 'test.op',
      operationUuid: uuid,
      frozenBodyJson: _body,
      bindingToken: token,
    );

    test('a response that arrives after a reset is a no-op', () async {
      await prepared();
      final response = Completer<Map<String, dynamic>>();
      final sent = Completer<void>();
      final outcome = submissions.submit(
        'op-1',
        send: (_) {
          sent.complete();
          return response.future;
        },
        status: _noStatus,
      );
      await sent.future;

      await binding.fence(); // SC-15 reset step 1: the binding row is gone
      response.complete({'state': 'imported'});

      expect(await outcome, isA<SubmissionFenced>());
      final row = (await _rows(db)).single;
      expect(row['state'], 'sent');
      expect(row['receipt_json'], isNull);
    });

    test('a failure that arrives after a logout is a no-op', () async {
      await prepared();
      final response = Completer<Map<String, dynamic>>();
      final sent = Completer<void>();
      final outcome = submissions.submit(
        'op-1',
        send: (_) {
          sent.complete();
          return response.future;
        },
        status: _noStatus,
      );
      await sent.future;

      await binding.rotate(); // logout / user switch: a new token
      response.completeError(NetworkException('lost', attemptsMade: 1));

      expect(await outcome, isA<SubmissionFenced>());
      final row = (await _rows(db)).single;
      expect(row['state'], 'sent');
      expect(row['error_code'], isNull);
    });

    test('an operation of an old binding is never sent or queried after a '
        'logout, a user switch or a change of server', () async {
      await prepared('op-prepared');
      await prepared('op-ambiguous');
      await submissions.submit(
        'op-ambiguous',
        send: (_) async => throw NetworkException('down', attemptsMade: 1),
        status: _noStatus,
      );
      final before = await _rows(db);

      Future<void> expectNeverSent() async {
        for (final uuid in ['op-prepared', 'op-ambiguous']) {
          var calls = 0;
          final outcome = await submissions.submit(
            uuid,
            send: (_) async {
              calls++;
              return const {};
            },
            status: (_) async {
              calls++;
              return const StatusAbsent();
            },
          );
          expect(outcome, isA<SubmissionFenced>(), reason: uuid);
          expect(calls, 0, reason: uuid);
        }
        expect(await _rows(db), before);
      }

      await binding.rotate(); // logout or a different user's login
      await expectNeverSent();

      await binding.fence(); // reset, then a different server is bound
      await ServerBindingRepository(db).ensureProvisional('http://other');
      await expectNeverSent();
    });

    test('a reset between prepare and send sends nothing', () async {
      await prepared();
      await binding.fence();
      var sends = 0;
      final outcome = await submissions.submit(
        'op-1',
        send: (_) async {
          sends++;
          return const {};
        },
        status: _noStatus,
      );
      expect(outcome, isA<SubmissionFenced>());
      expect(sends, 0);
      expect((await _rows(db)).single['state'], 'prepared');
    });

    test('a status answer that arrives after a reset is a no-op', () async {
      await prepared();
      await submissions.submit(
        'op-1',
        send: (_) async => throw NetworkException('down', attemptsMade: 1),
        status: _noStatus,
      );
      final answer = Completer<SubmissionStatus>();
      final queried = Completer<void>();
      var sends = 0;
      final outcome = submissions.submit(
        'op-1',
        send: (_) async {
          sends++;
          return const {};
        },
        status: (_) {
          queried.complete();
          return answer.future;
        },
      );
      await queried.future;
      await binding.fence();
      answer.complete(const StatusAbsent());

      expect(await outcome, isA<SubmissionFenced>());
      expect(sends, 0);
      expect((await _rows(db)).single['state'], 'ambiguous');
    });
  });

  group('single flight', () {
    Future<void> prepared([String uuid = 'op-1']) => submissions.prepare(
      kind: 'test.op',
      operationUuid: uuid,
      frozenBodyJson: _body,
      bindingToken: token,
    );

    test('two submits of the same operation at once send it once', () async {
      await prepared();
      final response = Completer<Map<String, dynamic>>();
      var sends = 0;
      Future<SubmissionOutcome> tap() => submissions.submit(
        'op-1',
        send: (_) {
          sends++;
          return response.future;
        },
        status: _noStatus,
      );

      final first = tap();
      final second = tap();
      await pumpEventQueue();
      response.complete({'n': 1});

      final outcomes = await Future.wait([first, second]);
      expect(sends, 1);
      for (final o in outcomes) {
        expect(
          o,
          isA<SubmissionAccepted>().having((a) => a.receipt, 'receipt', {
            'n': 1,
          }),
        );
      }
    });

    test('a tap during an in-flight failure gets the same ambiguous outcome '
        'instead of a second send', () async {
      await prepared();
      final response = Completer<Map<String, dynamic>>();
      var sends = 0;
      Future<SubmissionOutcome> tap() => submissions.submit(
        'op-1',
        send: (_) {
          sends++;
          return response.future;
        },
        status: (_) async => const StatusAbsent(),
      );

      final first = tap();
      await pumpEventQueue();
      final second = tap();
      response.completeError(NetworkException('lost', attemptsMade: 1));

      final outcomes = await Future.wait([first, second]);
      expect(sends, 1);
      expect(outcomes, everyElement(isA<SubmissionAmbiguous>()));
    });

    test('different operations are not serialized behind each other',
        () async {
      await prepared('op-1');
      await prepared('op-2');
      final held = Completer<Map<String, dynamic>>();
      final slow = submissions.submit(
        'op-1',
        send: (_) => held.future,
        status: _noStatus,
      );

      final fast = await submissions.submit(
        'op-2',
        send: (_) async => {'fast': true},
        status: _noStatus,
      );
      expect(fast, isA<SubmissionAccepted>());

      held.complete(const {});
      expect(await slow, isA<SubmissionAccepted>());
    });
  });

  group('quiesce', () {
    Future<void> prepared([String uuid = 'op-1']) => submissions.prepare(
      kind: 'test.op',
      operationUuid: uuid,
      frozenBodyJson: _body,
      bindingToken: token,
    );

    test('aborts an in-flight send and settles it before returning',
        () async {
      await prepared();
      final sent = Completer<void>();
      final outcome = submissions.submit(
        'op-1',
        send: (request) async {
          sent.complete();
          await request.abortSignal;
          throw NetworkException('aborted', attemptsMade: 1);
        },
        status: _noStatus,
      );
      await sent.future;
      var settled = false;
      unawaited(outcome.then((_) => settled = true));

      await submissions.quiesce();

      expect(settled, isTrue);
      expect(await outcome, isA<SubmissionAmbiguous>());
      expect((await _rows(db)).single['state'], 'ambiguous');
    });

    test('closes admission: nothing is prepared or sent afterwards',
        () async {
      await prepared();
      await submissions.quiesce();
      await submissions.quiesce(); // idempotent

      var sends = 0;
      await expectLater(
        submissions.submit(
          'op-1',
          send: (_) async {
            sends++;
            return const {};
          },
          status: _noStatus,
        ),
        throwsA(isA<SubmissionClosed>()),
      );
      await expectLater(
        submissions.prepare(
          kind: 'test.op',
          operationUuid: 'op-2',
          frozenBodyJson: _body,
          bindingToken: token,
        ),
        throwsA(isA<SubmissionClosed>()),
      );
      expect(sends, 0);
      expect([for (final r in await _rows(db)) (r['operation_uuid'], r['state'])],
          [('op-1', 'prepared')]);
    });

    test('the scope provider is quiesced when its scope is disposed',
        () async {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(clock),
        ],
      );
      final scoped = container.read(durableSubmissionProvider);
      await scoped.prepare(
        kind: 'test.op',
        operationUuid: 'op-1',
        frozenBodyJson: _body,
        bindingToken: token,
      );
      expect((await _rows(db)).single['created_at'], 5000);

      container.dispose();
      await expectLater(
        scoped.submit(
          'op-1',
          send: (_) async => const {},
          status: _noStatus,
        ),
        throwsA(isA<SubmissionClosed>()),
      );
    });

    test('a reset quiesces submissions after history, without building '
        'them', () async {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(clock),
        ],
      );
      addTearDown(container.dispose);
      final participants = container.read(localQuiescablesProvider);
      final names = [for (final q in participants) q.quiesceName];
      expect(names.indexOf('submissions'), greaterThan(names.indexOf('history')));
      final participant =
          participants.singleWhere((q) => q.quiesceName == 'submissions');

      await participant.quiesce();
      expect(container.exists(durableSubmissionProvider), isFalse);

      final scoped = container.read(durableSubmissionProvider);
      await participant.quiesce();
      await expectLater(
        scoped.prepare(
          kind: 'test.op',
          operationUuid: 'op-1',
          frozenBodyJson: _body,
          bindingToken: token,
        ),
        throwsA(isA<SubmissionClosed>()),
      );
    });
  });

  group('unresolved', () {
    Future<void> prepared(String uuid, {String kind = 'test.op'}) =>
        submissions.prepare(
          kind: kind,
          operationUuid: uuid,
          frozenBodyJson: _body,
          bindingToken: token,
        );

    test('lists the current binding\'s unfinished operations, oldest first',
        () async {
      await prepared('op-b');
      clock.advance(const Duration(seconds: 1));
      await prepared('op-a');
      clock.advance(const Duration(seconds: 1));
      await prepared('op-accepted');
      await prepared('op-rejected');
      await prepared('op-ambiguous');
      await prepared('op-other-kind', kind: 'other.op');
      await submissions.submit('op-accepted',
          send: (_) async => const {}, status: _noStatus);
      await submissions.submit('op-rejected',
          send: (_) async => throw ApiException(422, ''), status: _noStatus);
      await submissions.submit('op-ambiguous',
          send: (_) async => throw NetworkException('x', attemptsMade: 1),
          status: _noStatus);
      await db.customStatement(
        "UPDATE durable_submissions SET state = 'sent' "
        "WHERE operation_uuid = 'op-a'",
      );

      final all = await submissions.unresolved(bindingToken: token);
      expect([for (final r in all) (r.operationUuid, r.state)], [
        ('op-b', SubmissionState.prepared),
        ('op-a', SubmissionState.sent),
        ('op-ambiguous', SubmissionState.ambiguous),
        ('op-other-kind', SubmissionState.prepared),
      ]);

      final ofKind =
          await submissions.unresolved(bindingToken: token, kind: 'other.op');
      expect([for (final r in ofKind) r.operationUuid], ['op-other-kind']);
    });

    test('never lists another binding\'s operations', () async {
      await prepared('op-old');
      final newToken = (await binding.rotate())!.localBindingId;

      expect(await submissions.unresolved(bindingToken: newToken), isEmpty);
      expect(
        [for (final r in await submissions.unresolved(bindingToken: token))
          r.operationUuid],
        ['op-old'],
      );
    });
  });

  group('review r1', () {
    Future<void> prepared([String uuid = 'op-1']) => submissions.prepare(
      kind: 'test.op',
      operationUuid: uuid,
      frozenBodyJson: _body,
      bindingToken: token,
    );

    test('a quiesce that starts while the status query is out sends '
        'nothing afterwards', () async {
      await prepared();
      await submissions.submit(
        'op-1',
        send: (_) async => throw NetworkException('down', attemptsMade: 1),
        status: _noStatus,
      );
      final answer = Completer<SubmissionStatus>();
      final queried = Completer<void>();
      var sends = 0;
      final outcome = submissions.submit(
        'op-1',
        send: (_) async {
          sends++;
          return const {};
        },
        status: (_) {
          queried.complete();
          return answer.future;
        },
      );
      await queried.future;

      final quiesced = submissions.quiesce();
      answer.complete(const StatusAbsent());
      await quiesced;

      await expectLater(outcome, throwsA(isA<SubmissionClosed>()));
      expect(sends, 0);
      expect((await _rows(db)).single['state'], 'ambiguous');
    });

    test('a quiesce that starts before a prepared row is marked sent sends '
        'nothing', () async {
      await prepared();
      var sends = 0;
      // The submit is admitted, then quiesce starts before its first read
      // resolves.
      final outcome = submissions.submit(
        'op-1',
        send: (_) async {
          sends++;
          return const {};
        },
        status: _noStatus,
      );
      final quiesced = submissions.quiesce();
      await quiesced;

      await expectLater(outcome, throwsA(isA<SubmissionClosed>()));
      expect(sends, 0);
      expect((await _rows(db)).single['state'], 'prepared');
    });

    test('a status answer that the operation is still running keeps it '
        'ambiguous without a resend', () async {
      await prepared();
      await submissions.submit(
        'op-1',
        send: (_) async => throw NetworkException('down', attemptsMade: 1),
        status: _noStatus,
      );
      var sends = 0;
      final outcome = await submissions.submit(
        'op-1',
        send: (_) async {
          sends++;
          return const {};
        },
        status: (_) async => const StatusPending(),
      );
      expect(sends, 0);
      expect(outcome, isA<SubmissionAmbiguous>());
      expect(
        [for (final r in await _rows(db)) (r['state'], r['error_code'])],
        [('ambiguous', 'network')],
      );
    });

    test('preparing an operation id stored under another binding is a '
        'conflict, not a success', () async {
      await prepared();
      final newToken = (await binding.rotate())!.localBindingId;
      final before = await _rows(db);
      await expectLater(
        submissions.prepare(
          kind: 'test.op',
          operationUuid: 'op-1',
          frozenBodyJson: _body,
          bindingToken: newToken,
        ),
        throwsA(isA<SubmissionConflict>()),
      );
      expect(await _rows(db), before);
    });
  });

}
