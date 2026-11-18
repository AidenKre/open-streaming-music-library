// Phase 8B.1b S7: a lost answer (SC-14; spec §6 para 4 "On timeout, GET by
// operation UUID before deciding to retry"; review 8-U07 response loss;
// plan exit "timeout → ambiguous → GET → accepted with no second POST";
// SC-13 Phase M "401 = wait"; SC-01 rule 6).
//  * A timeout or a dropped connection leaves the operation unconfirmed;
//    the next pass asks the server by the SAME operation UUID first. Found:
//    accepted, nothing sent again. Definitely absent (404
//    `deletion_job_not_found`): the same frozen body is sent again under
//    the same UUID. Nothing ever mints a new operation for an old
//    confirmation.
//  * A failed status query (any other 4xx, a 404 without that code, a 5xx)
//    is never a refusal: the operation stays unconfirmed.
//  * A 401 (on the send or the status query) is a wait: the row is not
//    failed, the runner parks and later requests send nothing.
//  * An answer from another server instance leaves the row exactly as it
//    was before the send and nothing more goes out in that pass.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/deletion/delete_job.dart';

import '../../helpers/delete_jobs_harness.dart';

void main() {
  late DeleteJobsHarness h;
  setUp(() async {
    h = await DeleteJobsHarness.create();
    await h.verify();
  });
  tearDown(() => h.dispose());

  /// The server stores the job, then the answer is lost with [error].
  void receivedButLost(Object error) {
    final store = h.api.onCreateJob;
    h.api.onCreateJob = (body) async {
      await store(body);
      throw error;
    };
  }

  test('exit proof: a timeout → unconfirmed → GET by the same UUID → '
      'accepted, with no second POST', () async {
    receivedButLost(TimeoutException('lost'));
    await h.submitAll([('a', 1), ('b', 2)]);
    await h.pump();

    expect(h.job('op-1')!.phase, DeleteJobPhase.unconfirmed);
    expect((await h.submissions()).single['state'], 'ambiguous');
    expect(h.api.calls, ['preview a,b', 'createJob op-1']);

    h.timers.fire(); // the runner's backoff retry
    await h.pump();

    expect(h.api.callsOf('createJob'), ['createJob op-1']);
    expect(h.api.calls[2], 'getJob op-1');
    expect((await h.submissions()).single['state'], 'accepted');
    final job = h.job('op-1')!;
    expect(job.phase, DeleteJobPhase.accepted);
    expect(job.items.map((i) => i.uuid), ['a', 'b']);
  });

  test('a dropped connection the server never saw: the same body is sent '
      'again under the same UUID', () async {
    var first = true;
    final store = h.api.onCreateJob;
    h.api.onCreateJob = (body) async {
      if (first) {
        first = false;
        throw NetworkException('dropped', attemptsMade: 1);
      }
      return store(body);
    };
    await h.submitAll([('a', 1)]);
    await h.pump();
    h.timers.fire();
    await h.pump();

    expect(
      h.api.calls.where((c) => !c.startsWith('preview')).take(3).toList(),
      ['createJob op-1', 'getJob op-1', 'createJob op-1'],
    );
    expect(h.api.createBodies, hasLength(2));
    expect(h.api.createBodies[1], h.api.createBodies[0]);
    expect((await h.submissions()).map((r) => r['operation_uuid']), ['op-1']);
    expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
  });

  // Sign-off OPEN-M-11 (E8): a withheld token means nothing was sent. The
  // row stays as it was (no "the answer was lost"), and the next pass sends
  // it, with no status query first.
  test('the token withheld on the send: nothing was sent, the row stays as '
      'it was, and the next pass sends the same body', () async {
    var first = true;
    final store = h.api.onCreateJob;
    h.api.onCreateJob = (body) async {
      if (first) {
        first = false;
        throw const TokenWithheldException();
      }
      return store(body);
    };
    await h.submitAll([('a', 1)]);
    await h.pump();

    expect((await h.submissions()).single['state'], 'prepared');
    expect(h.job('op-1')!.phase, isNot(DeleteJobPhase.unconfirmed));

    h.timers.fire();
    await h.pump();
    expect(
      h.api.calls.where((c) => !c.startsWith('preview')).toList(),
      ['createJob op-1', 'createJob op-1'],
      reason: 'no status query: nothing had been sent',
    );
    expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
  });

  test('while unconfirmed, the same confirmation cannot start a second '
      'operation', () async {
    receivedButLost(TimeoutException('lost'));
    final preview = await h.preview([('a', 1)]);
    await h.manager.submit(preview, confirmedCount: 1);
    await h.pump();
    expect(h.job('op-1')!.phase, DeleteJobPhase.unconfirmed);

    expect(await h.manager.submit(preview, confirmedCount: 1), 'op-1');
    await h.pump();
    expect(await h.submissions(), hasLength(1));
    expect(h.api.callsOf('createJob'), ['createJob op-1']);
  });

  group('a failed status query is never a refusal', () {
    for (final (name, error) in <(String, Object)>[
      ('403', apiError(403, 'forbidden', retryable: false)),
      ('422', apiError(422, 'invalid', retryable: false)),
      ('404 without the job code', ApiException(404, '{"detail":"Not Found"}')),
      ('500', apiError(500, 'internal', retryable: false)),
      ('a dropped connection', NetworkException('x', attemptsMade: 1)),
    ]) {
      test('$name: stays unconfirmed, nothing resent; a later definite '
          'absence resends the same body', () async {
        var first = true;
        final store = h.api.onCreateJob;
        h.api.onCreateJob = (body) async {
          if (first) {
            first = false;
            throw TimeoutException('lost');
          }
          return store(body);
        };
        await h.submitAll([('a', 1)]);
        await h.pump();

        final getJob = h.api.onGetJob;
        h.api.onGetJob = (_) async => throw error;
        h.timers.fire();
        await h.pump();

        expect(h.job('op-1')!.phase, DeleteJobPhase.unconfirmed);
        final row = (await h.submissions()).single;
        expect(row['state'], 'ambiguous');
        expect(h.api.callsOf('createJob'), ['createJob op-1']);

        h.api.onGetJob = getJob; // 404 deletion_job_not_found
        h.timers.fire();
        await h.pump();
        expect(h.api.callsOf('createJob'), ['createJob op-1', 'createJob op-1']);
        expect(h.api.createBodies[1], h.api.createBodies[0]);
        expect(h.job('op-1')!.phase, DeleteJobPhase.accepted);
      });
    }
  });

  group('a 401 is a wait', () {
    test('on the send: unconfirmed, not failed; the runner parks', () async {
      h.api.onCreateJob = (_) async =>
          throw apiError(401, 'auth_required', retryable: false);
      await h.submitAll([('a', 1)]);
      await h.pump();

      expect(h.job('op-1')!.phase, DeleteJobPhase.unconfirmed);
      expect((await h.submissions()).single['state'], isNot('rejected'));
      final sent = h.api.calls.length;

      h.timers.fire();
      h.manager.request('networkRecovered', bypassBackoff: true);
      await h.pump();
      expect(h.api.calls.length, sent, reason: 'parked: nothing more is sent');
    });

    test('on the status query: the row stays unconfirmed; parked', () async {
      receivedButLost(TimeoutException('lost'));
      await h.submitAll([('a', 1)]);
      await h.pump();
      h.api.onGetJob = (_) async =>
          throw apiError(401, 'invalid_token', retryable: false);
      h.timers.fire();
      await h.pump();

      expect((await h.submissions()).single['state'], 'ambiguous');
      expect(h.job('op-1')!.phase, DeleteJobPhase.unconfirmed);
      final sent = h.api.calls.length;
      h.timers.fire();
      h.manager.request('appResume', bypassBackoff: true);
      await h.pump();
      expect(h.api.calls.length, sent);
    });
  });

  test('another server answers: the row is left as it was, and nothing more '
      'goes out in that pass', () async {
    final hold = Completer<DeletionJobDto>();
    h.api.onCreateJob = (_) => hold.future;
    await h.submitAll([('a', 1)]);
    await h.pump();
    await h.submitAll([('b', 1)]); // op-2 waits behind the pass in flight
    await h.pump();

    final changed = ServerInstanceChangedException(
      boundInstanceId: 'inst-1',
      servedBy: 'inst-2',
    );
    // As the real transport does before rethrowing (LibraryToolsApi).
    h.gate.gate.reportDifferentInstance(h.gate.gate.verifiedConnection!, changed);
    hold.completeError(changed);
    await h.pump();

    expect(h.api.callsOf('createJob'), ['createJob op-1']);
    expect(h.api.callsOf('getJob'), isEmpty);
    final rows = {
      for (final r in await h.submissions()) r['operation_uuid']: r['state'],
    };
    expect(rows, {'op-1': 'prepared', 'op-2': 'prepared'});
    expect(h.job('op-1')!.phase, DeleteJobPhase.submitting);
  });
}
