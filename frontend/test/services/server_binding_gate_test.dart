// SC-01 rule 1: binding verification is a GATE, not a step.
//
// Each connection (session activation, networkRecovered, appResume) starts a
// verification that fetches /app/info DIRECTLY (never the prefs-cached blob).
// Network participants await `awaitVerified()` before their first request.
// Outcomes: same instance -> update URL; NULL row -> fill in place; legacy
// server (no `server` block) -> verified, row stays NULL; different instance
// -> blocked (no change, awaiters keep waiting); fetch failure -> unverified,
// retried with BackoffSchedule, never "verified" from a cache.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTimers {
  final scheduled = <({Duration delay, void Function() fire})>[];
  final cancelled = <int>[];

  Timer call(Duration delay, void Function() fire) {
    final index = scheduled.length;
    scheduled.add((delay: delay, fire: fire));
    return _FakeTimer(() => cancelled.add(index));
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this._onCancel);
  final void Function() _onCancel;
  bool _active = true;
  @override
  void cancel() {
    if (_active) _onCancel();
    _active = false;
  }

  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

void main() {
  group('ServerIdentityApi (direct /app/info)', () {
    Future<ServerIdentity> fetchWith(http.Response response) {
      ApiClient.initForTest(
        'http://srv',
        MockClient((req) async {
          expect(req.url.path, '/app/info');
          return response;
        }),
      );
      return ServerIdentityApi().fetch();
    }

    test('reads server.instance_id', () async {
      final id = await fetchWith(http.Response(
        jsonEncode({
          'server': {'instance_id': 'inst-1'},
          'entities': {},
          'conversion': {},
        }),
        200,
      ));
      expect(id.instanceId, 'inst-1');
    });

    test('a server without the block is legacy (null id)', () async {
      final id = await fetchWith(
        http.Response(jsonEncode({'entities': {}}), 200),
      );
      expect(id.instanceId, isNull);
    });

    test('a failure throws and never falls back to the cached blob', () async {
      SharedPreferences.setMockInitialValues({
        'appInfo.cache': jsonEncode({
          'server': {'instance_id': 'cached'},
        }),
      });
      await expectLater(
        fetchWith(http.Response('boom', 500)),
        throwsA(isA<ApiException>()),
      );
    });

    test('a malformed server block is a failure, not legacy', () async {
      await expectLater(
        fetchWith(http.Response(jsonEncode({'server': {'instance_id': 5}}), 200)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ServerBindingGate', () {
    late AppDatabase db;
    late ServerBindingRepository repo;
    late _FakeTimers timers;
    late List<Completer<ServerIdentity>> probes;
    late ServerBindingGate gate;
    late String token;

    ServerBindingGate makeGate() => ServerBindingGate(
      repository: repo,
      probe: ({required bool reportOffline}) {
        final c = Completer<ServerIdentity>();
        probes.add(c);
        return c.future;
      },
      backoff: BackoffSchedule(jitter: 0),
      timer: timers.call,
    );

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = ServerBindingRepository(db);
      timers = _FakeTimers();
      probes = [];
      token = (await repo.ensureProvisional('http://a')).localBindingId;
      gate = makeGate();
    });

    tearDown(() async {
      gate.dispose();
      await db.close();
    });

    Future<void> settle() => pumpEventQueue();

    test('starts idle; awaiters wait for a connection', () async {
      expect(gate.state, isA<BindingIdle>());
      var done = false;
      unawaited(gate.awaitVerified().then((_) => done = true, onError: (_) {}));
      await settle();
      expect(done, isFalse);
      expect(probes, isEmpty);
    });

    test('NULL row + instance id: filled in place, verified with the token',
        () async {
      final verified = gate.awaitVerified();
      unawaited(gate.startConnection('http://a'));
      await settle();
      expect(gate.state, isA<BindingVerifying>());
      probes.single.complete(const ServerIdentity('inst-1'));
      expect(await verified, token);
      final state = gate.state as BindingVerified;
      expect(state.token, token);
      expect(state.instanceId, 'inst-1');
      final row = (await repo.current())!;
      expect(row.instanceId, 'inst-1');
      expect(row.localBindingId, token);
    });

    test('same instance at a new URL: verified, only the URL changes', () async {
      await repo.recordVerified(token, instanceId: 'inst-1', baseUrl: 'http://a');
      unawaited(gate.startConnection('http://alias:9'));
      await settle();
      probes.single.complete(const ServerIdentity('inst-1'));
      expect(await gate.awaitVerified(), token);
      final row = (await repo.current())!;
      expect(row.lastBaseUrl, 'http://alias:9');
      expect(row.localBindingId, token);
    });

    test('legacy server: verified, row stays NULL; later block fills it',
        () async {
      unawaited(gate.startConnection('http://a'));
      await settle();
      probes.single.complete(const ServerIdentity(null));
      expect(await gate.awaitVerified(), token);
      expect((await repo.current())!.instanceId, isNull);

      unawaited(gate.startConnection('http://a')); // e.g. appResume after upgrade
      await settle();
      probes.last.complete(const ServerIdentity('inst-1'));
      await settle();
      expect((await repo.current())!.instanceId, 'inst-1');
      expect((await repo.current())!.localBindingId, token);
    });

    test('different instance: blocked, nothing changes, awaiters keep waiting',
        () async {
      await repo.recordVerified(token, instanceId: 'inst-1', baseUrl: 'http://a');
      var released = false;
      unawaited(gate.awaitVerified().then((_) => released = true, onError: (_) {}));
      unawaited(gate.startConnection('http://a'));
      await settle();
      probes.single.complete(const ServerIdentity('inst-2'));
      await settle();
      final state = gate.state as BindingDifferentServer;
      expect(state.boundInstanceId, 'inst-1');
      expect(state.serverInstanceId, 'inst-2');
      expect(released, isFalse);
      expect((await repo.current())!.instanceId, 'inst-1');
      expect(timers.scheduled, isEmpty, reason: 'no retry loop while blocked');
    });

    test('fetch failure: unverified, retried with backoff, then verified',
        () async {
      var released = false;
      unawaited(gate.awaitVerified().then((_) => released = true, onError: (_) {}));
      unawaited(gate.startConnection('http://a'));
      await settle();
      probes[0].completeError(NetworkException('down', attemptsMade: 1));
      await settle();
      expect(gate.state, isA<BindingUnverified>());
      expect(released, isFalse);
      expect(timers.scheduled.single.delay, const Duration(seconds: 1));

      timers.scheduled[0].fire();
      await settle();
      probes[1].completeError(ApiException(500, 'boom'));
      await settle();
      expect(timers.scheduled[1].delay, const Duration(seconds: 2));

      timers.scheduled[1].fire();
      await settle();
      probes[2].complete(const ServerIdentity('inst-1'));
      await settle();
      expect(released, isTrue);
      expect(gate.state, isA<BindingVerified>());

      // Backoff reset on success: the next failure starts at 1 s again.
      unawaited(gate.startConnection('http://a'));
      await settle();
      probes[3].completeError(NetworkException('down', attemptsMade: 1));
      await settle();
      expect(timers.scheduled.last.delay, const Duration(seconds: 1));
    });

    test('a new connection verifies now and cancels a pending retry', () async {
      unawaited(gate.startConnection('http://a'));
      await settle();
      probes[0].completeError(NetworkException('down', attemptsMade: 1));
      await settle();
      expect(timers.scheduled, hasLength(1));
      unawaited(gate.startConnection('http://a')); // networkRecovered
      await settle();
      expect(timers.cancelled, [0]);
      expect(probes, hasLength(2));
      probes[1].complete(const ServerIdentity('inst-1'));
      expect(await gate.awaitVerified(), token);
    });

    test('branch audit (5A.0 m5): a new connection starts its backoff over',
        () async {
      unawaited(gate.startConnection('http://a'));
      await settle();
      for (var i = 0; i < 6; i++) {
        probes.last.completeError(NetworkException('down', attemptsMade: 1));
        await settle();
        timers.scheduled.last.fire(); // the retry
        await settle();
      }
      final grown = timers.scheduled.last.delay;
      unawaited(gate.startConnection('http://a')); // a fresh connection
      await settle();
      probes.last.completeError(NetworkException('down', attemptsMade: 1));
      await settle();
      expect(timers.scheduled.last.delay, lessThan(grown),
          reason: 'not the previous outage\'s capped delay');
      expect(timers.scheduled.last.delay, timers.scheduled.first.delay);
    });

    test('each connection is verified again before awaiters proceed', () async {
      unawaited(gate.startConnection('http://a'));
      await settle();
      probes[0].complete(const ServerIdentity('inst-1'));
      expect(await gate.awaitVerified(), token);

      unawaited(gate.startConnection('http://a')); // appResume edge
      await settle();
      var released = false;
      unawaited(gate.awaitVerified().then((_) => released = true, onError: (_) {}));
      await settle();
      expect(released, isFalse, reason: 'the new connection is not verified yet');
      probes[1].complete(const ServerIdentity('inst-1'));
      await settle();
      expect(released, isTrue);
    });

    // Audit 5A.0(c) #2: each connection has its own verdict; an older
    // connection's late answer never overwrites a newer one's.
    test('a late answer from an older connection is ignored', () async {
      await repo.recordVerified(token, instanceId: 'inst-1', baseUrl: 'http://a');
      unawaited(gate.startConnection('http://a')); // connection 1
      await settle();
      unawaited(gate.startConnection('http://a')); // connection 2 (an edge)
      await settle();
      expect(probes, hasLength(2));
      probes[1].complete(const ServerIdentity('inst-1'));
      await settle();
      expect(gate.state, isA<BindingVerified>());
      probes[0].complete(const ServerIdentity('inst-2')); // stale "different"
      await settle();
      expect(gate.state, isA<BindingVerified>());
      expect((await repo.current())!.instanceId, 'inst-1');
    });

    test('stop drops a probe already in flight', () async {
      unawaited(gate.startConnection('http://typo'));
      await settle();
      gate.stop();
      expect(gate.state, isA<BindingIdle>());
      probes.single.complete(const ServerIdentity('inst-9'));
      await settle();
      expect(gate.state, isA<BindingIdle>());
      expect((await repo.current())!.instanceId, isNull);
      expect((await repo.current())!.lastBaseUrl, 'http://a');
    });

    // Audit 5A.0(c) #3, D11: a bound row answered by a server WITHOUT an
    // instance id can't prove it's the same server: unverified, retrying.
    test('a bound row and a server without an instance id stay unverified',
        () async {
      await repo.recordVerified(token, instanceId: 'inst-1', baseUrl: 'http://a');
      var released = false;
      unawaited(gate.awaitVerified().then((_) => released = true, onError: (_) {}));
      unawaited(gate.startConnection('http://a'));
      await settle();
      probes.single.complete(const ServerIdentity(null));
      await settle();
      expect(gate.state, isA<BindingUnverified>());
      expect(timers.scheduled, hasLength(1), reason: 'retried with backoff');
      expect(released, isFalse);
      expect((await repo.current())!.instanceId, 'inst-1');
    });

    test('no binding row (reset started / no session): no probe, state noSession',
        () async {
      await repo.fence();
      unawaited(gate.startConnection('http://a'));
      await settle();
      expect(probes, isEmpty);
      expect(gate.state, isA<BindingNoSession>());
    });

    test('a probe that resolves after a reset fences itself and stays noSession',
        () async {
      unawaited(gate.startConnection('http://a'));
      await settle();
      await repo.fence();
      probes.single.complete(const ServerIdentity('inst-1'));
      await settle();
      expect(gate.state, isA<BindingNoSession>());
      expect(await repo.current(), isNull);
    });

    test('dispose fails pending awaiters and cancels the retry timer', () async {
      unawaited(gate.startConnection('http://a'));
      await settle();
      probes[0].completeError(NetworkException('down', attemptsMade: 1));
      await settle();
      final waiting = gate.awaitVerified();
      gate.dispose();
      await expectLater(waiting, throwsA(isA<BindingGateClosedException>()));
      expect(timers.cancelled, [0]);
    });

    test('states are published on the stream in order', () async {
      final seen = <Type>[];
      final sub = gate.states.listen((s) => seen.add(s.runtimeType));
      addTearDown(sub.cancel);
      unawaited(gate.startConnection('http://a'));
      await settle();
      probes.single.complete(const ServerIdentity('inst-1'));
      await settle();
      expect(seen, [BindingVerifying, BindingVerified]);
    });
  });

  // Audit 5A.0(c) #9: the production wiring (real provider, real direct
  // /app/info probe) — a failed probe is unverified, never "legacy", and
  // the prefs-cached app info is never consulted.
  group('serverBindingGateProvider (production probe)', () {
    late AppDatabase db;
    late ProviderContainer c;

    Future<ServerBindingGate> gateWith(http.Response appInfo) async {
      SharedPreferences.setMockInitialValues({
        'appInfo.cache': jsonEncode({
          'server': {'instance_id': 'cached'},
        }),
      });
      ApiClient.initForTest('http://srv', MockClient((req) async => appInfo));
      db = AppDatabase(NativeDatabase.memory());
      await ServerBindingRepository(db).ensureProvisional('http://srv');
      c = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
      return c.read(serverBindingGateProvider);
    }

    tearDown(() async {
      c.dispose();
      await db.close();
    });

    test('a failing /app/info leaves the connection unverified', () async {
      final gate = await gateWith(http.Response('boom', 500));
      await gate.startConnection('http://srv');
      expect(gate.state, isA<BindingUnverified>());
      expect((await ServerBindingRepository(db).current())!.instanceId, isNull);
    });

    test('a server block verifies and fills the row', () async {
      final gate = await gateWith(http.Response(
        jsonEncode({
          'server': {'instance_id': 'inst-7'},
        }),
        200,
      ));
      await gate.startConnection('http://srv');
      expect(gate.state, isA<BindingVerified>());
      expect((await ServerBindingRepository(db).current())!.instanceId, 'inst-7');
    });
  });
}
