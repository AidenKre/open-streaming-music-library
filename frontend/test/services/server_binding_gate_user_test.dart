// Phase M §7.4 / SC-01 Phase M: the gate never verifies without stored
// credentials (it stays BindingNoSession, so every network runner waits and
// the Log in screen sends nothing), and it adds a LOCAL check that the
// binding row's user is the signed-in user. There is no /auth/me call.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/test_credentials.dart';

void main() {
  late AppDatabase db;
  late ServerBindingRepository repo;
  late List<Completer<ServerIdentity>> probes;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = ServerBindingRepository(db);
    probes = [];
  });
  tearDown(() => db.close());

  ServerBindingGate gate({required int? signedInUserId}) {
    final g = ServerBindingGate(
      repository: repo,
      signedInUserId: signedInUserId,
      probe: ({required String baseUrl, required bool reportOffline}) {
        final c = Completer<ServerIdentity>();
        probes.add(c);
        return c.future;
      },
      backoff: BackoffSchedule(jitter: 0),
      timer: (d, f) => Timer(const Duration(days: 1), f),
    );
    addTearDown(g.dispose);
    return g;
  }

  test('no credentials: BindingNoSession, no probe, awaiters keep waiting',
      () async {
    await repo.ensureProvisional('http://a', userId: 7, instanceId: 'i1');
    final g = gate(signedInUserId: null);
    var verified = false;
    unawaited(g
        .awaitVerified()
        .then((_) => verified = true)
        .catchError((Object _) => false)); // closed at teardown
    unawaited(g.startConnection('http://a'));
    await pumpEventQueue();
    expect(g.state, isA<BindingNoSession>());
    expect(probes, isEmpty);
    expect(verified, isFalse);
  });

  test('the bound user signed in: verifies as before', () async {
    final row =
        await repo.ensureProvisional('http://a', userId: 7, instanceId: 'i1');
    final g = gate(signedInUserId: 7);
    final done = g.startConnection('http://a');
    await pumpEventQueue();
    probes.single.complete(const ServerIdentity('i1', authVersion: 1));
    await done;
    expect(g.state, isA<BindingVerified>());
    expect(await g.awaitVerified(), row.localBindingId);
  });

  test('another user than the row\'s: never verified, nothing probed',
      () async {
    await repo.ensureProvisional('http://a', userId: 7, instanceId: 'i1');
    final g = gate(signedInUserId: 8);
    unawaited(g.startConnection('http://a'));
    await pumpEventQueue();
    expect(g.state, isA<BindingNoSession>());
    expect(probes, isEmpty);
  });

  test('a row with an unknown (NULL) user is not the signed-in user',
      () async {
    await repo.ensureProvisional('http://a', instanceId: 'i1');
    final g = gate(signedInUserId: 7);
    unawaited(g.startConnection('http://a'));
    await pumpEventQueue();
    expect(g.state, isA<BindingNoSession>());
    expect(probes, isEmpty);
  });

  group('the scope gate (provider)', () {
    late List<Uri> requests;
    ProviderContainer scope({required bool signedIn}) {
      requests = [];
      final transport = MockClient((req) async {
        requests.add(req.url);
        return http.Response('{"server":{"instance_id":"i1"},'
            '"auth":{"version":1,"signup_enabled":true}}', 200);
      });
      final c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        apiClientProvider
            .overrideWithValue(testApiClient('http://localhost:8000', transport)),
        unauthenticatedApiClientProvider
            .overrideWithValue((url) => testApiClient(url, transport)),
        sessionUrlProvider.overrideWithValue('http://localhost:8000'),
        if (signedIn) credentialsProvider.overrideWithValue(testCredentials),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('signed out: the gate stays BindingNoSession and recovery sends no '
        'request', () async {
      SharedPreferences.setMockInitialValues({});
      await repo.ensureProvisional('http://localhost:8000',
          userId: testCredentials.userId, instanceId: 'i1');
      final c = scope(signedIn: false);
      // The cold-start recovery run FrontendApp fires for every scope.
      unawaited(c.read(recoveryServiceProvider).runFor(RecoveryTrigger.coldStart));
      unawaited(c.read(serverBindingGateProvider)
          .startConnection('http://localhost:8000'));
      await pumpEventQueue();
      expect(c.read(serverBindingGateProvider).state, isA<BindingNoSession>());
      expect(requests, isEmpty);
    });

    test('signed in as the bound user: the provider gate verifies', () async {
      SharedPreferences.setMockInitialValues({});
      await repo.ensureProvisional('http://localhost:8000',
          userId: testCredentials.userId, instanceId: 'i1');
      final c = scope(signedIn: true);
      unawaited(c.read(serverBindingGateProvider)
          .startConnection('http://localhost:8000'));
      await pumpEventQueue();
      expect(c.read(serverBindingGateProvider).state, isA<BindingVerified>());
    });
  });
}
