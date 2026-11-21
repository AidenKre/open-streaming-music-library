// Phase M §7.7 (M-U24): `serverBlocked` carries a reason,
// `none | differentServer | signedOut`, on the one blocked mechanism.
//  * a 401 (the authenticated client's synchronous hook ->
//    `SessionService.onUnauthorized`) makes the gate read the server's
//    identity again; the bound server answering sets `signedOut`: the gate
//    closes, offline turns on through the reason (polling stops, so a
//    healthy server can't flip it back), and only in-memory state is set
//    (the stored credentials stay). Another server answering is the
//    different-server block (`session_replaced_server_test.dart`);
//  * `BindingVerified` clears only `differentServer`; `signedOut` clears only
//    through a scope rebuild; `differentServer` wins when both apply.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/server_binding.dart';
import '../helpers/test_credentials.dart';

http.Client _healthy() => MockClient(
  (_) async => http.Response('{"message":"Healthy"}', 200),
);

/// A gate whose published states the test scripts (to drive a
/// `BindingVerified` after the sign-out, which a real closed gate never
/// sends), recording each identity check a 401 asks for.
class _ScriptedGate extends ServerBindingGate {
  _ScriptedGate(AppDatabase db)
    : super(
        repository: ServerBindingRepository(db),
        signedInUserId: testUserId,
        probe: ({required String baseUrl, required bool reportOffline}) =>
            Completer<ServerIdentity>().future,
        backoff: BackoffSchedule(jitter: 0),
        timer: (d, f) => Timer(const Duration(days: 1), f),
      );

  final script = StreamController<BindingGateState>.broadcast();
  final checks = <String>[];

  @override
  Stream<BindingGateState> get states => script.stream;

  @override
  Future<void> startConnection(String baseUrl, {bool reportOffline = true}) =>
      Future.value();

  @override
  void checkAfterUnauthorized(String baseUrl, {String? servedBy}) =>
      checks.add(servedBy == null ? baseUrl : '$baseUrl $servedBy');

  @override
  void dispose() {
    unawaited(script.close());
    super.dispose();
  }
}

/// Records the recovery runs the session asks for, and runs nothing.
class _RecordingRecovery extends RecoveryService {
  _RecordingRecovery(super.ref, this.runs);
  final List<RecoveryTrigger> runs;

  @override
  Future<void> runFor(RecoveryTrigger trigger) async => runs.add(trigger);
}

void main() {
  late AppDatabase db;
  late List<RecoveryTrigger> recoveries;
  late FakeSecureBackend secure;
  late CredentialStore store;

  setUp(() async {
    recoveries = [];
    db = AppDatabase(NativeDatabase.memory());
    secure = FakeSecureBackend();
    store = CredentialStore(
      secure: secure,
      directory: await Directory.systemTemp.createTemp('signed_out_test_'),
    );
    await store.save(testCredentials);
    final originalPoll = OfflineModeNotifier.pollInterval;
    addTearDown(() => OfflineModeNotifier.pollInterval = originalPoll);
    OfflineModeNotifier.pollInterval = const Duration(milliseconds: 1);
    SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer container(ServerBindingGate gate) {
    final c = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(
          testApiClient('http://s', _healthy()),
        ),
        unauthenticatedApiClientProvider.overrideWithValue(
          (url) => testApiClient(url, _healthy()),
        ),
        credentialsProvider.overrideWithValue(testCredentials),
        credentialStoreProvider.overrideWithValue(store),
        databaseProvider.overrideWithValue(db),
        serverBindingGateProvider.overrideWithValue(gate),
        recoveryServiceProvider.overrideWith(
          (ref) => _RecordingRecovery(ref, recoveries),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('with the real gate', () {
    late ControlledGate controlled;
    late ProviderContainer c;
    SessionService service() => c.read(sessionServiceProvider);

    setUp(() async {
      controlled = ControlledGate(db);
      addTearDown(controlled.dispose);
      c = container(controlled.gate);
      await service().resumeSavedSession();
      await pumpEventQueue();
      controlled.respond('inst-1');
      await pumpEventQueue();
      expect(controlled.gate.state, isA<BindingVerified>());
      expect(service().serverBlocked.value, ServerBlockedReason.none);
    });

    /// The 401, then the bound server's answer to the identity read.
    Future<void> unauthorizedByBoundServer() async {
      service().onUnauthorized();
      await pumpEventQueue();
      controlled.respond('inst-1');
      await pumpEventQueue();
    }

    test('a 401 withholds the token at once and decides nothing before the '
        "server's identity is read", () async {
      service().onUnauthorized();
      expect(controlled.gate.isVerifiedNow, isFalse,
          reason: 'set synchronously, before the response is returned');
      expect(controlled.gate.allowsTokenTo(Uri.parse('http://s/tracks')),
          isFalse);
      await pumpEventQueue();
      expect(controlled.pendingProbes, 1);
      expect(service().serverBlocked.value, ServerBlockedReason.none);
    });

    test('the bound server answering: signedOut, the gate closed, offline on',
        () async {
      await unauthorizedByBoundServer();
      expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
      expect(controlled.gate.state, isA<BindingSignedOut>());
      expect(c.read(offlineModeProvider), isTrue);
      expect(c.read(offlineModeProvider.notifier).isPolling, isFalse,
          reason: 'a healthy server must not flip a signed-out app online');
    });

    // U22-FE-LIFECYCLE-A-03: the app is already offline with a health poll
    // scheduled when the 401 comes; the 401 stops that poll too.
    test('already offline with a health poll scheduled: the 401 stops it',
        () async {
      OfflineModeNotifier.pollInterval = const Duration(hours: 1);
      final offline = c.read(offlineModeProvider.notifier)..enterOffline();
      expect(offline.isPolling, isTrue);
      await unauthorizedByBoundServer();
      expect(c.read(offlineModeProvider), isTrue);
      expect(offline.isPolling, isFalse,
          reason: 'no health poll may bring a signed-out app back online');
    });

    test('a healthy health poll does not bring a signed-out app online',
        () async {
      await unauthorizedByBoundServer();
      await pumpEventQueue(times: 50);
      expect(c.read(offlineModeProvider), isTrue);
      expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
    });

    test('a later connection edge does not clear signedOut', () async {
      await unauthorizedByBoundServer();
      unawaited(controlled.gate.startConnection('http://s'));
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0);
      expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
      expect(c.read(offlineModeProvider), isTrue);
    });

    test('a 401 keeps the stored credentials (memory only)', () async {
      await unauthorizedByBoundServer();
      expect(await store.read(), isNotNull);
    });

    test('repeated 401s are idempotent: one identity read, one sign-out',
        () async {
      service().onUnauthorized();
      await pumpEventQueue();
      expect(controlled.pendingProbes, 1);
      service().onUnauthorized();
      await pumpEventQueue();
      expect(controlled.pendingProbes, 1);
      controlled.respond('inst-1');
      await pumpEventQueue();
      expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
      service().onUnauthorized();
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0);
      expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
    });

    test('differentServer wins over a later 401', () async {
      final edge = controlled.gate.startConnection('http://s');
      await pumpEventQueue();
      controlled.respond('inst-2');
      await edge;
      await pumpEventQueue();
      expect(service().serverBlocked.value,
          ServerBlockedReason.differentServer);
      service().onUnauthorized();
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0,
          reason: 'the other server explains the 401: nothing to check');
      expect(service().serverBlocked.value,
          ServerBlockedReason.differentServer);
      expect(c.read(offlineModeProvider), isTrue);
    });

    test('a 401 after the scope is disposed does nothing', () async {
      final s = service();
      c.dispose();
      expect(s.onUnauthorized, returnsNormally);
    });
  });

  group('clearing (scripted gate states)', () {
    late _ScriptedGate gate;
    late ProviderContainer c;
    SessionService service() => c.read(sessionServiceProvider);

    setUp(() async {
      gate = _ScriptedGate(db);
      addTearDown(gate.dispose);
      c = container(gate);
      expect((await service().resumeSavedSession()).kind,
          SessionStartKind.online);
    });

    Future<void> publish(BindingGateState s) async {
      gate.script.add(s);
      await pumpEventQueue();
    }

    const verified = BindingVerified(token: 't', instanceId: 'inst-1');
    const different = BindingDifferentServer(
      boundInstanceId: 'inst-1',
      serverInstanceId: 'inst-2',
    );

    const signedOut = BindingSignedOut();

    test("the 401 asks the gate to decide, with the 401's stamp", () {
      service().onUnauthorized();
      service().onUnauthorized('inst-2');
      expect(gate.checks, ['http://s', 'http://s inst-2']);
    });

    test('once signed out, a 401 asks for no check', () async {
      await publish(signedOut);
      service().onUnauthorized();
      expect(gate.checks, isEmpty);
    });

    test('a disposed scope no longer watches the gate', () async {
      await publish(verified); // the launch's own wait for a verdict ends
      c.dispose();
      expect(gate.script.hasListener, isFalse);
    });

    test('BindingVerified does not clear signedOut', () async {
      await publish(signedOut);
      await publish(verified);
      expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
      expect(c.read(offlineModeProvider), isTrue,
          reason: 'offline stays on while signed out');
    });

    test('BindingVerified clears differentServer alone (D14)', () async {
      await publish(different);
      expect(service().serverBlocked.value,
          ServerBlockedReason.differentServer);
      await publish(verified);
      expect(service().serverBlocked.value, ServerBlockedReason.none);
      expect(c.read(offlineModeProvider), isFalse);
      expect(recoveries, [RecoveryTrigger.boundServerBack],
          reason: 'work parked by the other server resumes');
    });

    test('both apply: differentServer wins; verified leaves signedOut',
        () async {
      await publish(signedOut);
      await publish(different);
      expect(service().serverBlocked.value,
          ServerBlockedReason.differentServer);
      await publish(verified);
      expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
      expect(c.read(offlineModeProvider), isTrue);
      expect(recoveries, isEmpty, reason: 'signed out: nothing resumes');
    });
  });
}
