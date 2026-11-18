// Phase 9D.2d: LastfmApi, the client of /settings/integrations/lastfm
// (spec §7.4, §7.8, §7.10; 9D.1d / 9D.2a hand-overs).
//  * D24 / SC-01: every call waits for the binding gate and goes through the
//    bound client; an answer stamped by another instance is never returned,
//    the gate's different-server flow runs, and nothing further is sent.
//  * Routes, methods and bodies exactly as the server built them.
//  * §7.8: "The app gives `connect` and `complete` one attempt with a
//    45-second timeout and does not treat a timeout as the device being
//    offline." A failed connect or complete never flips the app offline.
//  * §7.10: Now Playing is one attempt, never retried, and a failure does
//    not flip the app offline (nothing is shown to the user).
//
// No real network: a scripted in-memory transport. Every value is made up.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/api/lastfm_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;

import '../helpers/server_binding.dart';
import '../helpers/stamped_server.dart';

const _base = '/settings/integrations/lastfm';
const _key = '0123456789abcdef0123456789abcdef';
const _token = 'made-up-token';
const _authUrl = 'https://www.last.fm/api/auth/?api_key=$_key&token=$_token';
const _conn = 'c0ffee00-0000-4000-8000-000000000001';
const _track = '44444444-4444-4444-8444-444444444444';

Map<String, dynamic> _statusJson() => {
  'service': 'running',
  'state': 'enabled',
  'needs_reconnect': false,
  'account_name': 'listener_01',
  'connection_id': _conn,
  'approval_expires_at': null,
  'counts': {'pending': 1, 'sent': 2, 'ignored': 0, 'failed': 0, 'dropped': 0},
  'recent_problems': [],
  'last_success_at': 1800000000000,
};

/// A scripted server: records every request and answers with [answer],
/// stamped with [stamp]. [hang] never answers; [fail] throws a transport
/// error.
class _Server extends http.BaseClient {
  String? stamp = boundInstance;
  (int, Object?) Function(String method, Uri url) answer =
      (_, _) => (200, _statusJson());
  bool hang = false;
  bool fail = false;
  final requests = <({String method, Uri url, String body})>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    requests.add((
      method: request.method,
      url: request.url,
      body: utf8.decode(bytes),
    ));
    if (hang) return Completer<http.StreamedResponse>().future;
    if (fail) throw http.ClientException('connection refused');
    final (status, json) = answer(request.method, request.url);
    return http.StreamedResponse(
      Stream.value(json == null ? <int>[] : utf8.encode(jsonEncode(json))),
      status,
      headers: {
        'content-type': 'application/json',
        'x-server-instance-id': ?stamp,
      },
    );
  }
}

(int, Object?) _answerFor(String name) => switch (name) {
  'status' => (200, _statusJson()),
  'connect' => (200, {'authorization_url': _authUrl, 'expires_at': 1800000600000}),
  'complete' => (200, {
    'connection_id': _conn,
    'account_name': 'listener_01',
    'state': 'connected_disabled',
  }),
  'enable' => (200, {'connection_id': _conn, 'state': 'enabled'}),
  'disconnect' => (204, null),
  _ => (202, null), // nowPlaying
};

/// The user's own actions (9-R2-03).
const mutations = ['connect', 'complete', 'enable', 'disconnect'];

/// Records how a call ended, without awaiting it.
class _Outcome {
  _Outcome(Future<Object?> call) {
    unawaited(call.then<void>(
      (_) => done = true,
      onError: (Object e) {
        error = e;
        done = true;
      },
    ));
  }
  bool done = false;
  Object? error;
}

Map<String, dynamic> _error(String code, {bool retryable = false}) => {
  'detail': {'error': code, 'message': 'x', 'retryable': retryable},
};

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late _Server server;
  late ApiClient plain;
  late LastfmApi api;
  late int offline;

  Future<void> verify() async {
    unawaited(controlled.gate.startConnection('http://s'));
    await pumpEventQueue();
    controlled.respond(boundInstance);
    await pumpEventQueue();
    expect(controlled.gate.state, isA<BindingVerified>());
  }

  Future<void> openRig({bool fakeTimeBound = false}) async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: boundInstance);
    controlled = ControlledGate(
      db,
      timer: fakeTimeBound ? boundOnlyGateTimer : null,
    );
    server = _Server();
    offline = 0;
    plain = testApiClient('http://s', server)
      ..addNetworkFailureListener(() => offline++);
    api = LastfmApi(
      api: plain.withInstanceCheck(ServerBindingRepository(db).checkServedBy),
      gate: controlled.gate,
    );
  }

  Future<void> closeRig() async {
    controlled.dispose();
    await db.close();
  }

  Map<String, Future<Object?> Function()> calls() => {
    'status': () => api.status(),
    'connect': () => api.connect(),
    'complete': () => api.complete(),
    'enable': () => api.enable(_conn),
    'disconnect': () => api.disconnect(),
    'nowPlaying': () => api.nowPlaying(_track),
  };

  group('with a database', () {
    setUp(openRig);
    tearDown(closeRig);

    // 9-R1-38: a read never waits at the gate. While the current connection
    // is not verified it fails fast with the shared BindingNotVerified (the
    // type LibraryToolsApi throws too) and sends nothing; a new call after
    // verification sends once.
    test('status fails fast while the gate is unverified, sends nothing',
        () async {
      await expectLater(api.status(), throwsA(isA<BindingNotVerified>()));
      expect(server.requests, isEmpty);

      await verify();
      await api.status();
      expect(server.requests, hasLength(1));
    });

    test('status fails fast while a new connection starts (a resume)',
        () async {
      await verify();
      unawaited(controlled.gate.startConnection('http://s'));
      await expectLater(api.status(), throwsA(isA<BindingNotVerified>()));
      expect(server.requests, isEmpty);
    });

    // 9-R2-03: a user's own action (connect, finish, opt in, disconnect)
    // waits a bounded time for a verdict that is pending: returning from the
    // browser is an app resume, which re-probes the binding. It proceeds once
    // verified; it is refused at once when the verdict is already a
    // different server, no session or signed out, and the moment a negative
    // verdict lands while it waits.
    group('a user action waits for a pending verdict (9-R2-03)', () {
      for (final name in mutations) {
        test('$name right after a resume is sent once the probe verifies',
            () async {
          await verify();
          server.answer = (_, _) => _answerFor(name);
          unawaited(controlled.gate.startConnection('http://s'));
          expect(controlled.gate.isVerifiedNow, isFalse);
          final out = _Outcome(calls()[name]!());
          await pumpEventQueue();
          expect(out.done, isFalse, reason: 'a verdict is pending: it waits');
          expect(server.requests, isEmpty);

          controlled.respond(boundInstance);
          await pumpEventQueue();
          expect(out.done, isTrue);
          expect(out.error, isNull);
          expect(server.requests, hasLength(1));
        });

        test('$name before the first verdict waits, then is sent', () async {
          server.answer = (_, _) => _answerFor(name);
          final out = _Outcome(calls()[name]!());
          await pumpEventQueue();
          expect(out.done, isFalse);
          await verify();
          await pumpEventQueue();
          expect(out.error, isNull);
          expect(server.requests, hasLength(1));
        });

        test('$name: the probe answering another server refuses it, '
            'nothing sent', () async {
          await verify();
          server.answer = (_, _) => _answerFor(name);
          unawaited(controlled.gate.startConnection('http://s'));
          final out = _Outcome(calls()[name]!());
          await pumpEventQueue();
          controlled.respond(otherInstance);
          await pumpEventQueue();
          expect(controlled.gate.state, isA<BindingDifferentServer>());
          expect(out.error, isA<BindingNotVerified>());
          expect(server.requests, isEmpty);
        });

        // Review of this piece, M1: a failed probe schedules a retry, which
        // may still verify inside the bound; the action keeps waiting.
        test('$name: a failed probe while it waits keeps it waiting; the '
            'retry verifies and it is sent', () async {
          await verify();
          server.answer = (_, _) => _answerFor(name);
          unawaited(controlled.gate.startConnection('http://s'));
          final out = _Outcome(calls()[name]!());
          await pumpEventQueue();
          controlled.fail(StateError('probe failed'));
          await pumpEventQueue();
          expect(controlled.gate.state, isA<BindingUnverified>());
          expect(out.done, isFalse, reason: 'a retry is pending: still waiting');
          expect(server.requests, isEmpty);

          unawaited(controlled.gate.startConnection('http://s')); // the retry
          await pumpEventQueue();
          controlled.respond(boundInstance);
          await pumpEventQueue();
          expect(out.error, isNull);
          expect(server.requests, hasLength(1));
        });

        test('$name: signed out while it waits refuses it, nothing sent',
            () async {
          await verify();
          server.answer = (_, _) => _answerFor(name);
          unawaited(controlled.gate.startConnection('http://s'));
          final out = _Outcome(calls()[name]!());
          await pumpEventQueue();
          controlled.gate.closeSignedOut();
          await pumpEventQueue();
          expect(out.error, isA<BindingNotVerified>());
          controlled.respond(boundInstance);
          await pumpEventQueue();
          expect(server.requests, isEmpty);
        });

        test('$name: the gate disposed while it waits refuses it', () async {
          await verify();
          server.answer = (_, _) => _answerFor(name);
          unawaited(controlled.gate.startConnection('http://s'));
          final out = _Outcome(calls()[name]!());
          await pumpEventQueue();
          controlled.gate.dispose();
          await pumpEventQueue();
          expect(out.error, isA<BindingNotVerified>());
          expect(server.requests, isEmpty);
        });

        test('$name is refused at once when signed out', () async {
          await verify();
          controlled.gate.closeSignedOut();
          final out = _Outcome(calls()[name]!());
          await pumpEventQueue();
          expect(out.error, isA<BindingNotVerified>());
          expect(server.requests, isEmpty);
        });
      }

      test('no session: every action is refused at once, nothing sent',
          () async {
        final other = ControlledGate(db, signedInUserId: null);
        addTearDown(other.dispose);
        final noSession = LastfmApi(
          api: plain.withInstanceCheck(ServerBindingRepository(db).checkServedBy),
          gate: other.gate,
        );
        await other.gate.startConnection('http://s');
        expect(other.gate.state, isA<BindingNoSession>());
        final outs = [
          _Outcome(noSession.connect()),
          _Outcome(noSession.complete()),
          _Outcome(noSession.enable(_conn)),
          _Outcome(noSession.disconnect()),
        ];
        await pumpEventQueue();
        for (final o in outs) {
          expect(o.error, isA<BindingNotVerified>());
        }
        expect(server.requests, isEmpty);
      });

      test('nowPlaying never waits: dropped during the re-probe', () async {
        await verify();
        server.answer = (_, _) => _answerFor('nowPlaying');
        unawaited(controlled.gate.startConnection('http://s'));
        final out = _Outcome(api.nowPlaying(_track));
        await pumpEventQueue();
        expect(out.done, isTrue, reason: 'Now Playing does not wait');
        controlled.respond(boundInstance);
        await pumpEventQueue();
        expect(server.requests, isEmpty);
      });
    });

    // 9-R2-04: a refusal says why, from the gate's state, so the page can
    // say what is true: a pending verdict may still verify; a different
    // server or no session never does by itself.
    group('why a call was refused (9-R2-04)', () {
      Matcher refused(BindingRefusal why) => isA<BindingNotVerified>()
          .having((e) => e.reason, 'reason', why);

      test('during a re-probe and after a failed probe: not yet', () async {
        await verify();
        unawaited(controlled.gate.startConnection('http://s'));
        await expectLater(api.status(), throwsA(refused(BindingRefusal.notYet)));
        await pumpEventQueue();
        controlled.fail(StateError('probe failed'));
        await pumpEventQueue();
        await expectLater(api.status(), throwsA(refused(BindingRefusal.notYet)));
      });

      test('a different server: differentServer, for reads and actions',
          () async {
        await verify();
        server.stamp = otherInstance;
        await expectLater(api.status(),
            throwsA(isA<ServerInstanceChangedException>()));
        await expectLater(
            api.status(), throwsA(refused(BindingRefusal.differentServer)));
        await expectLater(
            api.complete(), throwsA(refused(BindingRefusal.differentServer)));
      });

      test('the probe answering another server while an action waits: '
          'differentServer', () async {
        await verify();
        unawaited(controlled.gate.startConnection('http://s'));
        final out = _Outcome(api.disconnect());
        await pumpEventQueue();
        controlled.respond(otherInstance);
        await pumpEventQueue();
        expect(out.error, refused(BindingRefusal.differentServer));
      });

      test('signed out: noSession', () async {
        await verify();
        controlled.gate.closeSignedOut();
        await expectLater(
            api.status(), throwsA(refused(BindingRefusal.noSession)));
        await expectLater(
            api.enable(_conn), throwsA(refused(BindingRefusal.noSession)));
      });

      test('no session for this binding: noSession', () async {
        final other = ControlledGate(db, signedInUserId: null);
        addTearDown(other.dispose);
        final noSession = LastfmApi(
          api: plain.withInstanceCheck(ServerBindingRepository(db).checkServedBy),
          gate: other.gate,
        );
        await other.gate.startConnection('http://s');
        await expectLater(
            noSession.status(), throwsA(refused(BindingRefusal.noSession)));
        await expectLater(
            noSession.connect(), throwsA(refused(BindingRefusal.noSession)));
        expect(server.requests, isEmpty);
      });
    });

    group('the gate (D24, 9-R1-38 fast fail)', () {
      for (final name in mutations) {
        test('$name fails at once on a different server, sends nothing',
            () async {
          await verify();
          server.stamp = otherInstance;
          await expectLater(
            api.status(),
            throwsA(isA<ServerInstanceChangedException>()),
          );
          expect(controlled.gate.state, isA<BindingDifferentServer>());
          final sent = server.requests.length;
          server.answer = (_, _) => _answerFor(name);
          final out = _Outcome(calls()[name]!());
          await pumpEventQueue();
          expect(out.done, isTrue, reason: 'a known verdict: no wait');
          expect(
            out.error,
            isA<LibraryToolsNotConnected>(),
            reason: 'one shared fast-fail type for Last.fm and library tools',
          );
          expect(server.requests.length, sent);
        });
      }
    });

    // §7.10 "queues nothing for later" (review r1 #3): a notice never waits
    // at the gate; while it is unverified the notice is dropped.
    test('nowPlaying while the gate is unverified sends nothing, ever',
        () async {
      server.answer = (_, _) => _answerFor('nowPlaying');
      await api.nowPlaying(_track);
      await verify();
      await pumpEventQueue();
      expect(server.requests, isEmpty);

      await api.nowPlaying(_track);
      expect(server.requests, hasLength(1), reason: 'verified: sent');
    });

    // 9-R1-39: right after startConnection the state still reads verified
    // while isVerifiedNow is false; a notice then must be dropped, never
    // held and sent once the connection verifies again.
    test('nowPlaying while a new connection starts is dropped, never late',
        () async {
      await verify();
      server.answer = (_, _) => _answerFor('nowPlaying');
      unawaited(controlled.gate.startConnection('http://s'));
      expect(controlled.gate.state, isA<BindingVerified>());
      expect(controlled.gate.isVerifiedNow, isFalse);
      await api.nowPlaying(_track);
      await pumpEventQueue();
      controlled.fail(StateError('probe failed'));
      await pumpEventQueue();
      unawaited(controlled.gate.startConnection('http://s'));
      await pumpEventQueue();
      controlled.respond(boundInstance);
      await pumpEventQueue();
      expect(controlled.gate.state, isA<BindingVerified>());
      expect(server.requests, isEmpty);
    });

    group('routes and bodies', () {
      setUp(verify);

      test('status GETs the route and parses the body', () async {
        final s = await api.status();
        final r = server.requests.single;
        expect(r.method, 'GET');
        expect(r.url.path, _base);
        expect(r.url.query, isEmpty);
        expect(s.state, LastfmAccountState.enabled);
        expect(s.connectionId, _conn);
        expect(s.counts.sent, 2);
      });

      test('connect POSTs {} and returns the validated URL', () async {
        server.answer = (_, _) => _answerFor('connect');
        final a = await api.connect();
        final r = server.requests.single;
        expect(r.method, 'POST');
        expect(r.url.path, '$_base/connect');
        expect(jsonDecode(r.body), <String, Object?>{});
        expect(a!.url.uri.queryParameters['token'], _token);
        expect(a.expiresAt, 1800000600000);
      });

      test('connect: an answer whose URL fails the validator is null',
          () async {
        server.answer = (_, _) => (200, {
          'authorization_url':
              'https://evil.example/api/auth/?api_key=$_key&token=$_token',
          'expires_at': 1,
        });
        expect(await api.connect(), isNull);
      });

      test('complete POSTs {} and parses the binding', () async {
        server.answer = (_, _) => _answerFor('complete');
        final c = await api.complete();
        final r = server.requests.single;
        expect(r.method, 'POST');
        expect(r.url.path, '$_base/complete');
        expect(jsonDecode(r.body), <String, Object?>{});
        expect(c!.connectionId, _conn);
        expect(c.accountName, 'listener_01');
        expect(c.state, LastfmAccountState.connectedDisabled);
      });

      test('complete: a malformed 200 answer is null', () async {
        server.answer = (_, _) => (200, {'connection_id': _conn});
        expect(await api.complete(), isNull);
      });

      test('enable POSTs exactly {connection_id}', () async {
        server.answer = (_, _) => _answerFor('enable');
        await api.enable(_conn);
        final r = server.requests.single;
        expect(r.method, 'POST');
        expect(r.url.path, '$_base/enable');
        expect(jsonDecode(r.body), {'connection_id': _conn});
      });

      test('disconnect DELETEs the route; 204 is success', () async {
        server.answer = (_, _) => _answerFor('disconnect');
        await api.disconnect();
        final r = server.requests.single;
        expect(r.method, 'DELETE');
        expect(r.url.path, _base);
      });

      test('nowPlaying POSTs exactly {track_uuid}; 202 is success', () async {
        server.answer = (_, _) => _answerFor('nowPlaying');
        await api.nowPlaying(_track);
        final r = server.requests.single;
        expect(r.method, 'POST');
        expect(r.url.path, '$_base/now-playing');
        expect(jsonDecode(r.body), {'track_uuid': _track});
      });

      test('an SC-22 error keeps its code (each route)', () async {
        final cases = {
          'connect': (429, 'lastfm_too_soon'),
          'complete': (410, 'lastfm_approval_expired'),
          'enable': (409, 'lastfm_connection_changed'),
          'nowPlaying': (403, 'lastfm_disabled'),
        };
        for (final e in cases.entries) {
          server.answer = (_, _) => (e.value.$1, _error(e.value.$2));
          await expectLater(
            calls()[e.key]!(),
            throwsA(isA<ApiException>()
                .having((x) => x.statusCode, 'status', e.value.$1)
                .having((x) => x.errorCode, 'code', e.value.$2)),
            reason: e.key,
          );
        }
      });
    });

    group('one attempt; no offline flip (§7.8, §7.10)', () {
      setUp(verify);

      for (final name in ['connect', 'complete', 'enable', 'nowPlaying']) {
        test('$name: a 503 is not resent', () async {
          server.answer =
              (_, _) => (503, _error('lastfm_unavailable', retryable: true));
          await expectLater(calls()[name]!(), throwsA(isA<ApiException>()));
          expect(server.requests, hasLength(1));
        });
      }

      for (final name in ['connect', 'complete', 'nowPlaying']) {
        test('$name: a transport failure is one attempt and not "offline"',
            () async {
          server.fail = true;
          await expectLater(
              calls()[name]!(), throwsA(isA<NetworkException>()));
          expect(server.requests, hasLength(1));
          expect(offline, 0);
        });
      }
    });

    group('another server answers (SC-01 rule 6)', () {
      setUp(verify);

      for (final name in calls().keys) {
        test('$name: the answer is not returned and the gate blocks',
            () async {
          server.stamp = otherInstance;
          server.answer = (_, _) => _answerFor(name);

          await expectLater(
            calls()[name]!(),
            throwsA(isA<ServerInstanceChangedException>()),
          );
          expect(controlled.gate.state, isA<BindingDifferentServer>());

          final sent = server.requests.length;
          unawaited(api.status().then<Object?>(
            (_) => null,
            onError: (_) => null,
          ));
          await pumpEventQueue();
          expect(server.requests.length, sent);
        });
      }
    });

    test('lastfmApiProvider uses the bound client and the scope gate',
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
        c.read(lastfmApiProvider).status(),
        throwsA(isA<ServerInstanceChangedException>()),
      );
      expect(controlled.gate.state, isA<BindingDifferentServer>());
    });
  });

  // 9-R2-03: the wait for a pending verdict is bounded (about 10 s, fake
  // time). When it expires the action is refused with BindingNotVerified
  // and nothing is sent, not even once the probe verifies later.
  for (final name in mutations) {
    testWidgets('$name: the wait for a verdict ends after about 10 s, '
        'nothing sent', (tester) async {
      await tester.runAsync(() async {
        // The gate's wait bound runs on this test's fake time.
        await openRig(fakeTimeBound: true);
        await verify();
        unawaited(controlled.gate.startConnection('http://s'));
        await pumpEventQueue();
      });
      server.answer = (_, _) => _answerFor(name);
      final out = _Outcome(calls()[name]!());
      await tester.pump(const Duration(seconds: 9));
      expect(out.done, isFalse, reason: 'still waiting after 9 s');

      await tester.pump(const Duration(seconds: 2));
      expect(out.done, isTrue);
      expect(
        out.error,
        isA<BindingNotVerified>()
            .having((e) => e.reason, 'reason', BindingRefusal.notYet),
      );
      expect(server.requests, isEmpty);

      await tester.runAsync(() async {
        controlled.respond(boundInstance);
        await pumpEventQueue();
      });
      await tester.pump();
      expect(server.requests, isEmpty, reason: 'a refused action stays refused');

      await tester.runAsync(closeRig);
    });
  }

  // §7.8: one attempt with a 45-second timeout (not the client's 10 s
  // default), and a timeout is not "offline". Fake time.
  for (final name in ['connect', 'complete']) {
    testWidgets('$name waits 45 s, then times out without going offline',
        (tester) async {
      await tester.runAsync(() async {
        await openRig();
        await verify();
      });
      server.hang = true;

      Object? error;
      var done = false;
      unawaited(calls()[name]!().then<void>(
        (_) => done = true,
        onError: (Object e) {
          error = e;
          done = true;
        },
      ));
      await tester.pump(const Duration(seconds: 44));
      expect(done, isFalse, reason: 'still waiting after 44 s');

      await tester.pump(const Duration(seconds: 2));
      expect(done, isTrue);
      expect(
        error,
        isA<NetworkException>()
            .having((e) => e.cause, 'cause', isA<TimeoutException>()),
      );
      expect(server.requests, hasLength(1));
      expect(offline, 0);

      await tester.runAsync(closeRig);
    });
  }
}
