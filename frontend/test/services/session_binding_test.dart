// SC-01 rules 1-3 in the session model (SessionService):
//  * a session URL always has a binding row (provisional, D2);
//  * every connection is verified through the gate; playback readiness
//    (restore) waits for the verdict on an online start;
//  * a different server found at the saved URL leaves the app BLOCKED: it
//    behaves as offline (no network runner proceeds, no health polling flips
//    it back), local playback/browse keep working (D10);
//  * the serverError path keeps the binding, so the next connection is
//    verified against it before any sync (rule 3).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_readiness.dart';
import 'package:frontend/services/session_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/server_binding.dart';

http.Client _health(int status) => MockClient(
  (_) async => http.Response('{"message":"Healthy"}', status),
);
http.Client _unreachable() =>
    MockClient((_) async => throw const SocketException('down'));

/// The prefs wipe step, standing in for the real wipe bands.
class _ClearPrefs implements LocalResettable {
  _ClearPrefs({this.fail = false});
  final bool fail;
  @override
  int get resetPriority => ResetPriority.clearPreferences;
  @override
  Future<void> resetLocalState() async {
    await (await SharedPreferences.getInstance()).clear();
    if (fail) throw StateError('download dir busy');
  }
}

class _FailingDbWipe extends AppDatabase {
  _FailingDbWipe() : super(NativeDatabase.memory());
  @override
  Future<void> resetLocalState() async => throw StateError('db wipe failed');
}

class _FailingFence extends ServerBindingRepository {
  _FailingFence(super.db);
  @override
  Future<void> fence() async => throw StateError('disk I/O error');
}

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late ProviderContainer c;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    controlled = ControlledGate(db);
    OfflineModeNotifier.pollInterval = const Duration(milliseconds: 1);
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        serverBindingGateProvider.overrideWithValue(controlled.gate),
      ],
    );
  });

  tearDown(() async {
    OfflineModeNotifier.pollInterval = const Duration(seconds: 5);
    controlled.dispose();
    c.dispose();
    await db.close();
  });

  SessionService service() => c.read(sessionServiceProvider);
  ServerBindingRepository repo() => ServerBindingRepository(db);
  bool ready() => c.read(sessionReadinessProvider).isReady;

  group('resumeSavedSession', () {
    test('online: provisional row, verification started, ready after verdict',
        () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      ApiClient.initForTest('http://s', _health(200));
      final start = await service().resumeSavedSession();
      expect(start.kind, SessionStartKind.online);
      final row = (await repo().current())!;
      expect(row.lastBaseUrl, 'http://s');
      expect(row.instanceId, isNull);
      await pumpEventQueue();
      expect(controlled.pendingProbes, 1);
      expect(ready(), isFalse, reason: 'restore waits for bindingVerified');

      controlled.respond('inst-1');
      await pumpEventQueue();
      expect(ready(), isTrue);
      expect((await repo().current())!.instanceId, 'inst-1');
    });

    test('an existing row is reused (same token), not replaced', () async {
      final token = await seedTestBinding(db, baseUrl: 'http://old');
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      ApiClient.initForTest('http://s', _health(200));
      await service().resumeSavedSession();
      await pumpEventQueue();
      controlled.respond(null); // legacy server
      await pumpEventQueue();
      final row = (await repo().current())!;
      expect(row.localBindingId, token);
      expect(row.lastBaseUrl, 'http://s');
      expect(ready(), isTrue);
    });

    test('a different server at the saved URL: blocked, behaves as offline',
        () async {
      await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      ApiClient.initForTest('http://s', _health(200));
      final start = await service().resumeSavedSession();
      expect(start.kind, SessionStartKind.online);
      await pumpEventQueue();
      controlled.respond('inst-2');
      await pumpEventQueue();
      expect(controlled.gate.state, isA<BindingDifferentServer>());
      expect(c.read(offlineModeProvider), isTrue);
      expect(ready(), isTrue, reason: 'local playback keeps working');
      // Health polling must not flip it back online (the server IS healthy).
      expect(c.read(offlineModeProvider.notifier).isPolling, isFalse);
      expect(c.read(offlineModeProvider), isTrue);
      // Nothing changed in the binding: the reset is the user's choice.
      expect((await repo().current())!.instanceId, 'inst-1');
      expect(service().serverBlocked.value, isTrue);
    });

    // Audit 5A.0(a) #2: an online start whose probe fails is ready once the
    // session went offline (offline restore needs no binding); a server
    // that answers but can't be verified keeps network playback waiting.
    test('a probe failure that takes the session offline makes it ready',
        () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      ApiClient.initForTest('http://s', _health(200));
      await service().resumeSavedSession();
      await pumpEventQueue();
      c.read(offlineModeProvider.notifier).enterOffline(); // the probe's hook
      controlled.fail(NetworkException('down', attemptsMade: 1));
      await pumpEventQueue();
      expect(ready(), isTrue);
    });

    test('an online, unverifiable server keeps readiness waiting', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      ApiClient.initForTest('http://s', _health(200));
      await service().resumeSavedSession();
      await pumpEventQueue();
      controlled.fail(ApiException(500, 'app/info broke'));
      await pumpEventQueue();
      expect(c.read(offlineModeProvider), isFalse);
      expect(ready(), isFalse);
    });

    test('a launch probe may report the outage (offline hook on)', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      ApiClient.initForTest('http://s', _health(200));
      await service().resumeSavedSession();
      await pumpEventQueue();
      expect(controlled.reportOfflineFlags, [true]);
    });

    test('unreachable: offline session, row kept, no probe, ready', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      ApiClient.initForTest('http://s', _unreachable());
      final start = await service().resumeSavedSession();
      expect(start.kind, SessionStartKind.offline);
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0);
      expect(await repo().current(), isNotNull);
      expect(ready(), isTrue);
    });

    test('server error: URL forgotten but the binding kept (rule 3)', () async {
      await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      ApiClient.initForTest('http://s', _health(500));
      final start = await service().resumeSavedSession();
      expect(start.kind, SessionStartKind.signedOut);
      expect(controlled.pendingProbes, 0);
      expect((await repo().current())!.instanceId, 'inst-1');
    });
  });

  group('connect', () {
    test('verified: URL saved, row bound, ready', () async {
      SharedPreferences.setMockInitialValues({});
      ApiClient.initForTest('http://new', _health(200));
      final result = service().connect('http://new');
      await pumpEventQueue();
      expect(controlled.pendingProbes, 1);
      controlled.respond('inst-9');
      expect(await result, isA<ConnectSucceeded>());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('serverUrl'), 'http://new');
      final row = (await repo().current())!;
      expect(row.instanceId, 'inst-9');
      expect(row.lastBaseUrl, 'http://new');
      expect(ready(), isTrue);
    });

    test('verification fails: URL not saved, the attempt leaves no row',
        () async {
      SharedPreferences.setMockInitialValues({});
      ApiClient.initForTest('http://new', _health(200));
      final result = service().connect('http://new');
      await pumpEventQueue();
      controlled.fail(ApiException(500, 'app/info broke'));
      expect(await result, isA<ConnectFailed>());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('serverUrl'), isNull);
      expect(await repo().current(), isNull);
      expect(ready(), isFalse);
    });

    // Audit 5A.0(a) #4: a login probe never flips the app offline, and a
    // failed login stops verifying the URL the user typed (never saved).
    test('the login probe never reports offline', () async {
      SharedPreferences.setMockInitialValues({});
      ApiClient.initForTest('http://new', _health(200));
      final result = service().connect('http://new');
      await pumpEventQueue();
      expect(controlled.reportOfflineFlags, [false]);
      controlled.respond('inst-9');
      await result;
    });

    test('a failed login stops verifying the unsaved URL', () async {
      await seedTestBinding(db, baseUrl: 'http://a', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({});
      ApiClient.initForTest('http://typo', _health(200));
      final result = service().connect('http://typo');
      await pumpEventQueue();
      controlled.fail(ApiException(500, 'app/info broke'));
      expect(await result, isA<ConnectFailed>());
      expect(controlled.gate.state, isA<BindingIdle>());
      expect((await repo().current())!.lastBaseUrl, 'http://a');
    });

    test('a different server: nothing saved or changed; the user decides',
        () async {
      await seedTestBinding(db, baseUrl: 'http://a', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({});
      ApiClient.initForTest('http://b', _health(200));
      final result = service().connect('http://b');
      await pumpEventQueue();
      controlled.respond('inst-2');
      final outcome = await result;
      expect(outcome, isA<ConnectDifferentServer>());
      expect((outcome as ConnectDifferentServer).url, 'http://b');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('serverUrl'), isNull);
      final row = (await repo().current())!;
      expect(row.instanceId, 'inst-1');
      expect(row.lastBaseUrl, 'http://a');
      expect(c.read(offlineModeProvider), isFalse);
      expect(ready(), isFalse);
    });
  });

  group('blocked: different server (SC-01 rule 1, D10)', () {
    Future<void> liveOn(String instanceId) async {
      await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      ApiClient.initForTest('http://s', _health(200));
      await service().resumeSavedSession();
      await pumpEventQueue();
      controlled.respond(instanceId);
      await pumpEventQueue();
    }

    Future<void> connectionEdge(String instanceId) async {
      // networkRecovered / appResume start a new verification.
      final edge = controlled.gate.startConnection('http://s');
      await pumpEventQueue();
      controlled.respond(instanceId);
      await edge;
      await pumpEventQueue();
    }

    test('found on a later connection edge, not only at launch', () async {
      await liveOn('inst-1');
      expect(service().serverBlocked.value, isFalse);
      await connectionEdge('inst-2');
      expect(service().serverBlocked.value, isTrue);
      expect(c.read(offlineModeProvider), isTrue);
      expect(c.read(offlineModeProvider.notifier).isPolling, isFalse,
          reason: 'no polling');
      expect(c.read(offlineModeProvider), isTrue);
    });

    test('an offline launch that reconnects to a different server blocks',
        () async {
      await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      ApiClient.initForTest('http://s', _unreachable());
      await service().resumeSavedSession();
      await connectionEdge('inst-2');
      expect(service().serverBlocked.value, isTrue);
    });

    test('the bound server answering again clears the block (D14)', () async {
      await liveOn('inst-2');
      expect(service().serverBlocked.value, isTrue);
      await connectionEdge('inst-1');
      expect(service().serverBlocked.value, isFalse);
      expect(c.read(offlineModeProvider), isFalse);
    });

    test('a login that finds a different server is not the blocked state',
        () async {
      await seedTestBinding(db, baseUrl: 'http://a', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({});
      ApiClient.initForTest('http://b', _health(200));
      final result = service().connect('http://b');
      await pumpEventQueue();
      controlled.respond('inst-2');
      expect(await result, isA<ConnectDifferentServer>());
      expect(service().serverBlocked.value, isFalse);
      expect(c.read(offlineModeProvider), isFalse);
    });
  });

  // Review major 2 (user, 2026-11-09): a reset that never finished its wipe
  // (the app was killed, or a wipe step failed) is finished at the next
  // launch or login, before anything binds, so no server adopts the store.
  group('an interrupted reset', () {
    ProviderContainer scopeWith(List<LocalResettable> wipe) {
      final scope = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          serverBindingGateProvider.overrideWithValue(controlled.gate),
          localQuiescablesProvider.overrideWithValue(const []),
          localResettablesProvider.overrideWithValue(wipe),
        ],
      );
      addTearDown(scope.dispose);
      return scope;
    }

    for (final fenced in [false, true]) {
      test('is finished at launch before the saved URL binds '
          '(${fenced ? 'killed after the fence' : 'killed before the fence'})',
          () async {
        if (!fenced) {
          await seedTestBinding(db, baseUrl: 'http://a', instanceId: 'inst-1');
        }
        SharedPreferences.setMockInitialValues(
            {'serverUrl': 'http://a', 'resetPending': true});
        ApiClient.initForTest('http://a', _health(200));
        final scope = scopeWith([_ClearPrefs()]);
        final start =
            await scope.read(sessionServiceProvider).resumeSavedSession();
        expect(start.kind, SessionStartKind.resetFinished);
        expect(await repo().current(), isNull,
            reason: 'no row for the next server to adopt');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('serverUrl'), isNull);
        expect(prefs.getBool('resetPending'), isNull);
        await pumpEventQueue();
        expect(controlled.pendingProbes, 0, reason: 'nothing was verified');
      });
    }

    test('a launch whose wipe fails again signs out with the error and binds '
        'nothing', () async {
      SharedPreferences.setMockInitialValues(
          {'serverUrl': 'http://a', 'resetPending': true});
      ApiClient.initForTest('http://a', _health(200));
      final failingDb = _FailingDbWipe();
      addTearDown(failingDb.close);
      final scope = scopeWith([failingDb]);
      final start =
          await scope.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.signedOut);
      expect(start.error, contains('earlier reset'));
      expect(await repo().current(), isNull);
      expect((await SharedPreferences.getInstance()).getBool('resetPending'),
          isTrue, reason: 'tried again at the next launch or login');
    });

    test('a login is refused until the wipe succeeds', () async {
      SharedPreferences.setMockInitialValues({'resetPending': true});
      ApiClient.initForTest('http://b', _health(200));
      final failingDb = _FailingDbWipe();
      addTearDown(failingDb.close);
      final scope = scopeWith([failingDb]);
      final outcome = await scope.read(sessionServiceProvider).connect('http://b');
      expect(outcome, isA<ConnectFailed>());
      expect(await repo().current(), isNull);
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0);
    });

    test('a login after a successful finish connects as usual', () async {
      SharedPreferences.setMockInitialValues({'resetPending': true});
      ApiClient.initForTest('http://b', _health(200));
      final scope = scopeWith([_ClearPrefs()]);
      final outcome = scope.read(sessionServiceProvider).connect('http://b');
      await pumpEventQueue();
      controlled.respond('inst-2');
      expect(await outcome, isA<ConnectSucceeded>());
      expect((await repo().current())!.instanceId, 'inst-2');
      expect((await SharedPreferences.getInstance()).getBool('resetPending'),
          isNull);
    });
  });

  group('confirmed switch to a different server (resetForNewServer)', () {
    ProviderContainer resetScope({
      ServerBindingRepository? binding,
      bool wipeFails = false,
    }) {
      final scope = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          if (binding != null)
            serverBindingRepositoryProvider.overrideWithValue(binding),
          localQuiescablesProvider.overrideWithValue(const []),
          localResettablesProvider.overrideWithValue([
            _ClearPrefs(fail: wipeFails),
          ]),
        ],
      );
      addTearDown(scope.dispose);
      return scope;
    }

    test('resets, then keeps the new URL so the rebuilt session binds to it',
        () async {
      await seedTestBinding(db, baseUrl: 'http://a', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({'settings.x': 'old'});
      final scope = resetScope();
      final failure = await scope
          .read(sessionServiceProvider)
          .resetForNewServer('http://b');
      expect(failure, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('serverUrl'), 'http://b');
      expect(prefs.containsKey('settings.x'), isFalse);
      expect(await repo().current(), isNull, reason: 'fenced');
    });

    test('a partial wipe is reported; the URL is still kept (fence held)',
        () async {
      await seedTestBinding(db, baseUrl: 'http://a', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({});
      final scope = resetScope(wipeFails: true);
      final failure = await scope
          .read(sessionServiceProvider)
          .resetForNewServer('http://b');
      expect(failure, isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('serverUrl'), 'http://b');
    });

    test('Reset on the blocked banner keeps the saved URL', () async {
      await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({
        'serverUrl': 'http://s',
        'settings.x': 'old',
      });
      final scope = resetScope();
      final failure =
          await scope.read(sessionServiceProvider).resetForBlockedServer();
      expect(failure, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('serverUrl'), 'http://s');
      expect(prefs.containsKey('settings.x'), isFalse);
      expect(await repo().current(), isNull, reason: 'fenced');
    });

    // Audit 5A.0(a) #3: if the database wipe failed, the old catalog and
    // cursors are still there; binding the next server to them would mix
    // libraries, so the URL is not kept (back to login).
    test('a failed database wipe does not keep the URL', () async {
      await seedTestBinding(db, baseUrl: 'http://a', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({});
      final failingDb = _FailingDbWipe();
      addTearDown(failingDb.close);
      final scope = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          localQuiescablesProvider.overrideWithValue(const []),
          localResettablesProvider.overrideWithValue([_ClearPrefs(), failingDb]),
        ],
      );
      addTearDown(scope.dispose);
      final failure = await scope
          .read(sessionServiceProvider)
          .resetForNewServer('http://b');
      expect(failure, isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('serverUrl'), isNull);
    });

    test('an aborted reset (fence failed) saves nothing', () async {
      await seedTestBinding(db, baseUrl: 'http://a', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({});
      final scope = resetScope(binding: _FailingFence(db));
      final failure = await scope
          .read(sessionServiceProvider)
          .resetForNewServer('http://b');
      expect(failure, isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('serverUrl'), isNull);
      expect((await repo().current())!.instanceId, 'inst-1');
    });
  });

  test('the confirmation copy comes from the reset loss reporters', () async {
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, status, '
      "updated_at) VALUES ('a', '{}', 'db_only', 'pending', 1)",
    );
    expect(
      await service().pendingLossSummaries(),
      ['1 unsent metadata edit'],
    );
  });
}
