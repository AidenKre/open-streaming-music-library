// Refactor A.3 slice 1, characterization: what "wait for the server check,
// then send" guarantees in each of the three API classes that have it
// (uploads, library tools, Last.fm), beyond what their own test files pin.
//
//  * The connection is captured right after the wait: a call that waited
//    reports another server's answer on the connection it verified on (once),
//    and an answer of an older connection never blocks a newer one.
//  * An abort ends only the wait: once fired nothing is sent, however the
//    trigger completes; fired during the request it does not discard the
//    answer.
//  * The gate closing ends a waiting call; nothing is sent.
//
// No real network: an in-memory transport that can hold its answer.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/lastfm_api.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;

import '../helpers/fake_library_tools_api.dart'
    show deletionItemJson, deletionJobJson;
import '../helpers/fake_uploads_api.dart' show itemJson;
import '../helpers/server_binding.dart';
import '../helpers/stamped_server.dart';

const _item = '11111111-1111-4111-8111-111111111111';
const _op = '33333333-3333-4333-8333-333333333333';
const _conn = 'c0ffee00-0000-4000-8000-000000000001';

/// Records every request; answers by path, stamped with [stamp]. While
/// [hold] is set the answer waits for it.
class _Server extends http.BaseClient {
  String? stamp = boundInstance;
  Completer<void>? hold;
  final requests = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    requests.add('${request.method} ${request.url.path}');
    await hold?.future;
    final path = request.url.path;
    final Object body = path.contains('/uploads/')
        ? itemJson(_item)
        : path.contains('/deletions')
        ? (path.endsWith('/deletions')
              ? {'jobs': <Object>[], 'next_after': null}
              : deletionJobJson(_op, [deletionItemJson('a')]))
        : {'connection_id': _conn, 'state': 'enabled'};
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      200,
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
  late UploadsApi uploads;
  late LibraryToolsApi tools;
  late LastfmApi lastfm;

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
    final bound = testApiClient(
      'http://s',
      server,
    ).withInstanceCheck(ServerBindingRepository(db).checkServedBy);
    uploads = UploadsApi(api: bound, gate: controlled.gate);
    tools = LibraryToolsApi(api: bound, gate: controlled.gate);
    lastfm = LastfmApi(api: bound, gate: controlled.gate);
  });

  tearDown(() async {
    controlled.dispose();
    await db.close();
  });

  /// One call of each class. Last.fm's has no abort trigger.
  Map<String, Future<Object?> Function({Future<void>? abort})> calls() => {
    'uploads getItem': ({abort}) =>
        uploads.getItem(_item, abortTrigger: abort),
    'library tools getJob': ({abort}) =>
        tools.getJob(_op, abortTrigger: abort),
    'Last.fm enable': ({abort}) => lastfm.enable(_conn),
  };

  /// The calls that take an abort trigger, with the exception each throws.
  Map<String, (Future<Object?> Function({Future<void>? abort}), Matcher)>
  abortable() => {
    'uploads getItem': (
      calls()['uploads getItem']!,
      isA<UploadTransferAborted>(),
    ),
    'library tools getJob': (
      calls()['library tools getJob']!,
      isA<LibraryToolsRequestAborted>(),
    ),
    'library tools listJobs, a page read that does not wait': (
      ({abort}) => tools.listJobs(abortTrigger: abort, waitForBinding: false),
      isA<LibraryToolsRequestAborted>(),
    ),
  };

  group('the connection is captured right after the wait', () {
    for (final name in calls().keys) {
      test('$name: a call that waited for the check reports another '
          "server's answer once, on the connection it verified on", () async {
        final different = <BindingDifferentServer>[];
        final sub = controlled.gate.states.listen((s) {
          if (s is BindingDifferentServer) different.add(s);
        });
        addTearDown(sub.cancel);
        server.stamp = otherInstance;

        Object? error;
        unawaited(calls()[name]!().then<void>(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        ));
        await pumpEventQueue();
        expect(server.requests, isEmpty, reason: 'it waits for the check');

        // The check passes; the waiting call is sent on this connection.
        unawaited(controlled.gate.startConnection('http://s'));
        await pumpEventQueue();
        controlled.respond(boundInstance);
        await pumpEventQueue();
        expect(server.requests, hasLength(1));
        expect(error, isA<ServerInstanceChangedException>());
        expect(controlled.gate.state, isA<BindingDifferentServer>());
        expect(different, hasLength(1), reason: 'reported once');
      });

      test("$name: an older connection's answer from another server is "
          'rethrown and does not block the newer connection', () async {
        await verify();
        server.hold = Completer<void>();
        Object? error;
        unawaited(calls()[name]!().then<void>(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        ));
        await pumpEventQueue();
        expect(server.requests, hasLength(1), reason: 'sent, answer held');

        await verify(); // a newer connection of the same server
        server.stamp = otherInstance;
        server.hold!.complete();
        await pumpEventQueue();

        expect(error, isA<ServerInstanceChangedException>());
        expect(
          controlled.gate.state,
          isA<BindingVerified>(),
          reason: 'the report names the older connection: dropped',
        );
      });
    }
  });

  group('an abort', () {
    for (final MapEntry(key: name, value: (call, aborted))
        in abortable().entries) {
      test('$name: fired before the call, nothing is sent even though the '
          'check has passed', () async {
        await verify();
        final abort = Completer<void>()..complete();

        await expectLater(call(abort: abort.future), throwsA(aborted));
        await pumpEventQueue();
        expect(server.requests, isEmpty);
      });

      test('$name: fired during the request, the answer is still returned',
          () async {
        await verify();
        server.hold = Completer<void>();
        final abort = Completer<void>();
        Object? value;
        Object? error;
        unawaited(call(abort: abort.future).then<void>(
          (v) {
            value = v;
          },
          onError: (Object e) {
            error = e;
          },
        ));
        await pumpEventQueue();
        expect(server.requests, hasLength(1));

        abort.complete();
        await pumpEventQueue();
        server.hold!.complete();
        await pumpEventQueue();
        expect(error, isNull);
        expect(value, isNotNull);
      });
    }

    for (final name in ['uploads getItem', 'library tools getJob']) {
      test('$name: a trigger that completes with an error also ends the '
          'wait as aborted, and nothing is sent once the check passes',
          () async {
        final (call, aborted) = abortable()[name]!;
        final abort = Completer<void>();
        final result = call(abort: abort.future);
        await pumpEventQueue();
        abort.completeError(StateError('the trigger failed'));

        await expectLater(result, throwsA(aborted));
        await verify();
        await pumpEventQueue();
        expect(server.requests, isEmpty);
      });
    }
  });

  group('the gate closes while a call waits', () {
    for (final name in ['uploads getItem', 'library tools getJob']) {
      for (final withTrigger in [false, true]) {
        test('$name${withTrigger ? ' (with an abort trigger)' : ''}: the '
            'call ends with the gate-closed error and nothing is sent',
            () async {
          final (call, _) = abortable()[name]!;
          final abort = Completer<void>();
          final result = call(abort: withTrigger ? abort.future : null);
          await pumpEventQueue();
          controlled.gate.dispose();

          await expectLater(
            result,
            throwsA(isA<BindingGateClosedException>()),
          );
          expect(server.requests, isEmpty);
        });
      }
    }
  });
}
