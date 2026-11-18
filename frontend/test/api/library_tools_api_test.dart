// Phase 8B.1b: LibraryToolsApi, the client of /tracks/deletions and
// /tracks/duplicates (spec §4, server as built in 8A.2b and 8A.4).
//  * D33 / OPEN-M-11: every request waits for the binding gate's
//    verification; while the gate is unverified nothing is built or sent.
//  * SC-01 rule 6: every request goes through the bound client; an answer
//    stamped by another instance is never returned (not even an error
//    body), the gate's different-server flow runs for the connection the
//    request used, and nothing further is sent.
//  * An abort trigger ends a wait at the gate and sends nothing.
//  * No call retries a mutation on its own.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;

import '../helpers/server_binding.dart';
import '../helpers/stamped_server.dart';

const _a = '11111111-1111-4111-8111-111111111111';
const _b = '22222222-2222-4222-8222-222222222222';
const _op = '33333333-3333-4333-8333-333333333333';

Map<String, dynamic> _jobJson({String status = 'pending'}) => {
  'operation_uuid': _op,
  'created_at': 1762800000,
  'status': status,
  'item_count': 1,
  'items': [
    {
      'uuid_id': _a,
      'base_revision': 4,
      'status': 'pending',
      'error': null,
      'tombstone_revision': null,
      'details': [],
    },
  ],
};

Map<String, dynamic> _previewJson() => {
  'targets': [
    {
      'uuid_id': _a,
      'base_revision': 4,
      'revision': 4,
      'title': 'Song',
      'artist': null,
      'album': null,
      'master_exists': true,
      'master_size': 10,
      'unknown': false,
      'already_deleted': false,
      'missing_master': false,
      'conflict': false,
      'busy': false,
    },
  ],
};

Map<String, dynamic> _summaryJson() => {
  'bands': {
    'exact': {'open': 1, 'dismissed': 0},
    'strong': {'open': 0, 'dismissed': 0},
    'possible': {'open': 0, 'dismissed': 0},
  },
  'coverage': {
    'exact': {'pending': 0, 'current': 1, 'failed': 0, 'unsupported': 0},
    'fingerprint': {
      'pending': 0,
      'current': 1,
      'unavailable': 0,
      'too_short': 0,
      'low_information': 0,
      'failed': 0,
    },
    'match': {'pending': 0, 'current': 1},
  },
  'fingerprinter': null,
};

String _frozen() => DeletionJobRequestDto(
  operationUuid: _op,
  targets: const [DeletionTargetDto(uuidId: _a, baseRevision: 4)],
  confirmedCount: 1,
).toFrozenJson();

/// A scripted server: records every request and answers with [answer],
/// stamped with [stamp].
class _Server extends http.BaseClient {
  String? stamp = boundInstance;
  (int, Object?) Function(String method, Uri url) answer =
      (_, _) => (200, _jobJson());
  final requests = <({String method, Uri url, String body})>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    requests.add((
      method: request.method,
      url: request.url,
      body: utf8.decode(bytes),
    ));
    final (status, json) = answer(request.method, request.url);
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(json))),
      status,
      headers: {
        'content-type': 'application/json',
        'x-server-instance-id': ?stamp,
      },
    );
  }
}

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late _Server server;
  late LibraryToolsApi api;

  Future<void> verify() async {
    unawaited(controlled.gate.startConnection('http://s'));
    await pumpEventQueue();
    controlled.respond(boundInstance);
    await pumpEventQueue();
    expect(controlled.gate.state, isA<BindingVerified>());
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: boundInstance);
    controlled = ControlledGate(db);
    server = _Server();
    final plain = testApiClient('http://s', server);
    api = LibraryToolsApi(
      api: plain.withInstanceCheck(ServerBindingRepository(db).checkServedBy),
      gate: controlled.gate,
    );
  });

  tearDown(() async {
    controlled.dispose();
    await db.close();
  });

  (int, Object?) answerFor(String name) => switch (name) {
    'preview' => (200, _previewJson()),
    'createJob' => (202, _jobJson()),
    'listJobs' => (200, {'jobs': [], 'next_after': null}),
    'listDuplicates' => (200, {'pairs': [], 'next_after': null}),
    'duplicateSummary' => (200, _summaryJson()),
    'dismissPair' || 'restorePair' => (200, {
      'uuid_a': _a,
      'uuid_b': _b,
      'status': 'dismissed',
    }),
    _ => (200, _jobJson()),
  };

  Map<String, Future<Object?> Function({Future<void>? abort})> calls() => {
    'preview': ({abort}) => api.preview(
      const [DeletionTargetDto(uuidId: _a, baseRevision: 4)],
      abortTrigger: abort,
    ),
    'createJob': ({abort}) => api.createJob(_frozen(), abortTrigger: abort),
    'getJob': ({abort}) => api.getJob(_op, abortTrigger: abort),
    'listJobs': ({abort}) => api.listJobs(abortTrigger: abort),
    'listDuplicates': ({abort}) => api.listDuplicates(abortTrigger: abort),
    'duplicateSummary': ({abort}) => api.duplicateSummary(abortTrigger: abort),
    'dismissPair': ({abort}) => api.dismissPair(_a, _b, abortTrigger: abort),
    'restorePair': ({abort}) => api.restorePair(_a, _b, abortTrigger: abort),
  };

  group('the gate (D33, OPEN-M-11)', () {
    for (final name in calls().keys) {
      test('$name sends nothing while the gate is unverified, then goes once',
          () async {
        server.answer = (_, _) => answerFor(name);
        var done = false;
        final call = calls()[name]!().whenComplete(() => done = true);
        await pumpEventQueue();

        expect(server.requests, isEmpty);
        expect(done, isFalse);

        await verify();
        await call;
        expect(server.requests, hasLength(1));
      });

      test('$name: an abort while waiting at the gate sends nothing',
          () async {
        final abort = Completer<void>();
        final result = calls()[name]!(abort: abort.future);
        await pumpEventQueue();
        abort.complete();

        await expectLater(result, throwsA(isA<LibraryToolsRequestAborted>()));
        await verify();
        await pumpEventQueue();
        expect(server.requests, isEmpty);
      });
    }

    // U33-B-02: a page's reads fail fast while the binding is unverified
    // (as the preview does) instead of waiting at the gate with a spinner.
    final pageReads = <String, Future<Object?> Function()>{
      'listJobs': () => api.listJobs(waitForBinding: false),
      'listDuplicates': () => api.listDuplicates(waitForBinding: false),
      'duplicateSummary': () => api.duplicateSummary(waitForBinding: false),
    };
    for (final MapEntry(key: name, value: call) in pageReads.entries) {
      test('$name without waiting for the binding: unverified fails at once '
          'with not-connected and sends nothing', () async {
        server.answer = (_, _) => answerFor(name);
        await expectLater(call(), throwsA(isA<LibraryToolsNotConnected>()));
        await verify();
        await pumpEventQueue();
        expect(server.requests, isEmpty);
      });

      // Review r1 R2: a connection edge clears the verification at once,
      // before the gate publishes a new state.
      test('$name without waiting for the binding: right after a new '
          'connection starts, not connected, nothing sent', () async {
        server.answer = (_, _) => answerFor(name);
        await verify();
        unawaited(controlled.gate.startConnection('http://s'));
        await expectLater(call(), throwsA(isA<LibraryToolsNotConnected>()));
        await pumpEventQueue();
        controlled.respond(boundInstance);
        await pumpEventQueue();
        expect(server.requests, isEmpty);
      });

      test('$name without waiting for the binding: verified sends once',
          () async {
        server.answer = (_, _) => answerFor(name);
        await verify();
        await call();
        expect(server.requests, hasLength(1));
      });
    }
  });

  group('routes (server as built)', () {
    setUp(verify);

    test('preview POSTs the targets and parses the answer', () async {
      server.answer = (_, _) => (200, _previewJson());

      final preview = await api.preview(const [
        DeletionTargetDto(uuidId: _a, baseRevision: 4),
        DeletionTargetDto(uuidId: _b, baseRevision: 9),
      ]);

      final r = server.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/tracks/deletions/preview');
      expect(jsonDecode(r.body), {
        'targets': [
          {'uuid_id': _a, 'base_revision': 4},
          {'uuid_id': _b, 'base_revision': 9},
        ],
      });
      expect(preview.targets.single.title, 'Song');
    });

    test('createJob POSTs exactly the frozen body, once, and parses the job',
        () async {
      server.answer = (_, _) => (202, _jobJson());

      final job = await api.createJob(_frozen());

      final r = server.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/tracks/deletions');
      expect(jsonDecode(r.body), jsonDecode(_frozen()));
      expect(job.operationUuid, _op);
      expect(job.items.single.status, 'pending');
    });

    // 8-fix-r1 8-R1-23: an accepted job whose receipt can't be read is
    // still known to be accepted; a refusal stays an ApiException.
    for (final (what, body) in <(String, Object?)>[
      ('a wrong-shaped job', {'unexpected': true}),
      ('a body that is not an object', [1]),
    ]) {
      test('createJob: a 202 with $what is DeletionReceiptUnreadable',
          () async {
        server.answer = (_, _) => (202, body);
        await expectLater(api.createJob(_frozen()),
            throwsA(isA<DeletionReceiptUnreadable>()));
        expect(server.requests, hasLength(1));
      });
    }

    test('createJob does not resend on its own (one attempt)', () async {
      server.answer = (_, _) => (503, {'detail': 'down'});

      await expectLater(api.createJob(_frozen()), throwsA(isA<ApiException>()));
      expect(server.requests, hasLength(1));
    });

    test('getJob GETs the job by operation id; a 404 keeps its code',
        () async {
      server.answer = (_, _) => (200, _jobJson(status: 'running'));
      final job = await api.getJob(_op);
      expect(server.requests.single.method, 'GET');
      expect(server.requests.single.url.path, '/tracks/deletions/$_op');
      expect(job.status, 'running');

      server.answer = (_, _) => (404, {
        'detail': {
          'error': 'deletion_job_not_found',
          'message': 'Deletion job not found.',
          'retryable': false,
        },
      });
      await expectLater(
        api.getJob(_op),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'status', 404)
            .having((e) => e.errorCode, 'code', 'deletion_job_not_found')),
      );
    });

    test('the lists send after, limit and status only when given', () async {
      server.answer = (_, url) => url.path == '/tracks/deletions'
          ? (200, {'jobs': [], 'next_after': 'c2'})
          : (200, {'pairs': [], 'next_after': null});

      await api.listJobs();
      final jobs = await api.listJobs(after: 'c1', limit: 100);
      await api.listDuplicates();
      await api.listDuplicates(status: 'dismissed', after: 'd1', limit: 50);

      final q = [for (final r in server.requests) r.url];
      expect(q[0].path, '/tracks/deletions');
      expect(q[0].queryParameters, isEmpty);
      expect(q[1].queryParameters, {'after': 'c1', 'limit': '100'});
      expect(q[2].path, '/tracks/duplicates');
      expect(q[2].queryParameters, isEmpty);
      expect(q[3].queryParameters,
          {'status': 'dismissed', 'after': 'd1', 'limit': '50'});
      expect(jobs.nextAfter, 'c2');
    });

    test('summary, dismiss and restore use their routes', () async {
      server.answer = (method, url) => url.path.endsWith('/summary')
          ? (200, _summaryJson())
          : (200, {
              'uuid_a': _a,
              'uuid_b': _b,
              'status': url.path.endsWith('/dismiss') ? 'dismissed' : 'open',
            });

      final summary = await api.duplicateSummary();
      final dismissed = await api.dismissPair(_b, _a);
      final restored = await api.restorePair(_a, _b);

      expect(
        [for (final r in server.requests) '${r.method} ${r.url.path}'],
        [
          'GET /tracks/duplicates/summary',
          'POST /tracks/duplicates/dismiss',
          'POST /tracks/duplicates/restore',
        ],
      );
      expect(jsonDecode(server.requests[1].body), {'uuid_a': _b, 'uuid_b': _a});
      expect(summary.fingerprinter, isNull);
      expect(dismissed.status, 'dismissed');
      expect(restored.status, 'open');
    });

    test('the switch turned off is a 403 library_delete_disabled', () async {
      server.answer = (_, _) => (403, {
        'detail': {
          'error': 'library_delete_disabled',
          'message': 'Server deletion is turned off.',
          'retryable': false,
        },
      });

      await expectLater(
        api.createJob(_frozen()),
        throwsA(isA<ApiException>()
            .having((e) => e.errorCode, 'code', 'library_delete_disabled')),
      );
    });
  });

  group('another server answers (SC-01 rule 6)', () {
    setUp(verify);

    for (final name in ['preview', 'createJob', 'getJob', 'dismissPair']) {
      test('$name: the answer is not returned and the gate blocks', () async {
        server.stamp = otherInstance;
        server.answer = (_, _) => answerFor(name);

        await expectLater(
          calls()[name]!(),
          throwsA(isA<ServerInstanceChangedException>()),
        );
        expect(
          controlled.gate.state,
          isA<BindingDifferentServer>()
              .having((s) => s.serverInstanceId, 'server', otherInstance),
        );

        final sent = server.requests.length;
        unawaited(calls()['getJob']!().then<Object?>(
          (_) => null,
          onError: (_) => null,
        ));
        await pumpEventQueue();
        expect(server.requests.length, sent);
      });
    }

    test('an error status from another server is not an ApiException',
        () async {
      server.stamp = otherInstance;
      server.answer = (_, _) => (404, {
        'detail': {'error': 'deletion_job_not_found', 'retryable': false},
      });

      await expectLater(
        api.getJob(_op),
        throwsA(isA<ServerInstanceChangedException>()),
      );
    });
  });

  group('provider', () {
    test('libraryToolsApiProvider uses the bound client and the scope gate',
        () async {
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(testApiClient('http://s', server)),
          serverBindingGateProvider.overrideWithValue(controlled.gate),
        ],
      );
      addTearDown(c.dispose);
      await verify();
      server.stamp = otherInstance;

      await expectLater(
        c.read(libraryToolsApiProvider).getJob(_op),
        throwsA(isA<ServerInstanceChangedException>()),
      );
      expect(controlled.gate.state, isA<BindingDifferentServer>());
    });
  });
}
