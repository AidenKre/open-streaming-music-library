// SC-14 durable submissions, 7B.1d: a caller-supplied failure hook decides
// what a failure the helper can't classify does to the row (7B.1c handover,
// trap 1): leave the row exactly as it was before the call (an answer from
// another server, DEV-7-09), settle it as a terminal rejection (a source
// that changed), or keep it ambiguous under the caller's code (a transfer
// the caller stopped). The helper itself stays free of any feature
// knowledge. Rows are asserted through raw SQL.

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/operations/durable_submission.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/server_binding.dart';

/// A failure type the helper knows nothing about.
class _ForeignAnswer implements Exception {
  const _ForeignAnswer();
}

class _CallerStopped implements Exception {
  const _CallerStopped();
}

Future<Map<String, Object?>> _row(AppDatabase db, String op) async => (await db
        .customSelect(
          'SELECT operation_uuid, kind, local_binding_id, frozen_body_json, '
          'state, receipt_json, error_code, created_at, updated_at '
          'FROM durable_submissions WHERE operation_uuid = ?',
          variables: [Variable.withString(op)],
        )
        .getSingle())
    .data;

SubmissionFailureDisposition? _hook(Object error) => switch (error) {
  _ForeignAnswer() => const LeaveSubmissionUntouched(),
  _CallerStopped() => const SubmissionAmbiguousAs('stopped'),
  StateError() => const SubmissionTerminal('source_changed'),
  _ => null,
};

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late DurableSubmission submissions;
  late String token;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(startUtcMs: 5000);
    token = await seedTestBinding(db, reconciled: true);
    submissions = DurableSubmission(
      db: db,
      binding: ServerBindingRepository(db),
      clock: clock,
    );
    await submissions.prepare(
      kind: 'test.op',
      operationUuid: 'op-1',
      frozenBodyJson: '{"a":1}',
      bindingToken: token,
    );
  });
  tearDown(() => db.close());

  Future<SubmissionStatus> noStatus(String op) async =>
      throw StateError('unexpected status query');

  group('leave untouched', () {
    test('a send failure the hook leaves untouched restores the row exactly '
        'as it was before the call and rethrows', () async {
      final before = await _row(db, 'op-1');
      clock.advance(const Duration(seconds: 3));

      await expectLater(
        submissions.submit(
          'op-1',
          send: (_) async => throw const _ForeignAnswer(),
          status: noStatus,
          onFailure: _hook,
        ),
        throwsA(isA<_ForeignAnswer>()),
      );

      expect(await _row(db, 'op-1'), before);
    });

    test('from an ambiguous row: status says never seen, the resend fails '
        'untouched → back to ambiguous with its earlier code and time',
        () async {
      await submissions.submit(
        'op-1',
        send: (_) async => throw NetworkException('down', attemptsMade: 1),
        status: noStatus,
      );
      final before = await _row(db, 'op-1');
      expect(before['state'], 'ambiguous');
      expect(before['error_code'], 'network');
      clock.advance(const Duration(seconds: 3));

      var sends = 0;
      await expectLater(
        submissions.submit(
          'op-1',
          send: (_) async {
            sends++;
            throw const _ForeignAnswer();
          },
          status: (_) async => const StatusAbsent(),
          onFailure: _hook,
        ),
        throwsA(isA<_ForeignAnswer>()),
      );

      expect(sends, 1);
      expect(await _row(db, 'op-1'), before);
    });

    test('a status query failure the hook leaves untouched writes nothing, '
        'sends nothing and rethrows', () async {
      await submissions.submit(
        'op-1',
        send: (_) async => throw NetworkException('down', attemptsMade: 1),
        status: noStatus,
      );
      final before = await _row(db, 'op-1');
      clock.advance(const Duration(seconds: 3));

      var sends = 0;
      await expectLater(
        submissions.submit(
          'op-1',
          send: (_) async {
            sends++;
            return {'ok': true};
          },
          status: (_) async => throw const _ForeignAnswer(),
          onFailure: _hook,
        ),
        throwsA(isA<_ForeignAnswer>()),
      );

      expect(sends, 0);
      expect(await _row(db, 'op-1'), before);
    });
  });

  group('terminal', () {
    test('a send failure the hook calls terminal is a rejection under the '
        "hook's code, never sent again", () async {
      final outcome = await submissions.submit(
        'op-1',
        send: (_) async => throw StateError('changed'),
        status: noStatus,
        onFailure: _hook,
      );

      expect(outcome, isA<SubmissionRejected>());
      expect((outcome as SubmissionRejected).code, 'source_changed');
      final row = await _row(db, 'op-1');
      expect(row['state'], 'rejected');
      expect(row['error_code'], 'source_changed');

      var sends = 0;
      final again = await submissions.submit(
        'op-1',
        send: (_) async {
          sends++;
          return {'ok': true};
        },
        status: noStatus,
      );
      expect(again, isA<SubmissionRejected>());
      expect(sends, 0);
    });
  });

  group('ambiguous', () {
    test('a send failure the hook calls ambiguous keeps the operation for a '
        'status-first retry under the same id', () async {
      final outcome = await submissions.submit(
        'op-1',
        send: (_) async => throw const _CallerStopped(),
        status: noStatus,
        onFailure: _hook,
      );

      expect(outcome, isA<SubmissionAmbiguous>());
      expect((outcome as SubmissionAmbiguous).cause, isA<_CallerStopped>());
      final row = await _row(db, 'op-1');
      expect(row['state'], 'ambiguous');
      expect(row['error_code'], 'stopped');

      final queried = <String>[];
      final again = await submissions.submit(
        'op-1',
        send: (r) async => {'op': r.operationUuid},
        status: (op) async {
          queried.add(op);
          return const StatusAbsent();
        },
      );
      expect(queried, ['op-1']);
      expect(again, isA<SubmissionAccepted>());
      expect((again as SubmissionAccepted).receipt, {'op': 'op-1'});
    });
  });

  group('precedence', () {
    test('the hook is asked first, even for an error the helper knows',
        () async {
      // A definitive 409 the caller wants kept ambiguous.
      final outcome = await submissions.submit(
        'op-1',
        send: (_) async => throw ApiException(409, '{}'),
        status: noStatus,
        onFailure: (e) =>
            e is ApiException ? const SubmissionAmbiguousAs('busy') : null,
      );
      expect(outcome, isA<SubmissionAmbiguous>());
      expect((await _row(db, 'op-1'))['error_code'], 'busy');
    });

    test('a hook answering null keeps the built-in classification',
        () async {
      final rejected = await submissions.submit(
        'op-1',
        send: (_) async => throw ApiException(422, '{}'),
        status: noStatus,
        onFailure: _hook,
      );
      expect(rejected, isA<SubmissionRejected>());
      expect((await _row(db, 'op-1'))['error_code'], 'http_422');

      await submissions.prepare(
        kind: 'test.op',
        operationUuid: 'op-2',
        frozenBodyJson: null,
        bindingToken: token,
      );
      await expectLater(
        submissions.submit(
          'op-2',
          send: (_) async => throw const FormatException('odd'),
          status: noStatus,
          onFailure: _hook,
        ),
        throwsA(isA<FormatException>()),
      );
      final row = await _row(db, 'op-2');
      expect(row['state'], 'ambiguous');
      expect(row['error_code'], 'unexpected');
    });
  });
}
