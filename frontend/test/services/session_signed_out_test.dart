// Phase M §7.7 (M-U24): `serverBlocked` carries a reason,
// `none | differentServer | signedOut`, on the one blocked mechanism.
//  * a 401 (the authenticated client's synchronous hook ->
//    `SessionService.onUnauthorized`) sets `signedOut`: it closes the gate,
//    turns offline on through the reason (polling stops, so a healthy server
//    can't flip it back), and only sets in-memory state (the stored
//    credentials stay);
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
/// sends), recording each close.
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
  int closes = 0;

  @override
  Stream<BindingGateState> get states => script.stream;

  @override
  Future<void> startConnection(String baseUrl, {bool reportOffline = true}) =>
      Future.value();

  @override
  void closeSignedOut() => closes++;

  @override
  void dispose() {
    unawaited(script.close());
    super.dispose();
  }
}

void main() {
  late AppDatabase db;
  late FakeSecureBackend secure;
  late CredentialStore store;

  setUp(() async {
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

    test('a 401 sets signedOut, closes the gate and turns offline on',
        () async {
      service().onUnauthorized();
      expect(service().serverBlocked.value, ServerBlockedReason.signedOut,
          reason: 'set synchronously, before the response is returned');
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
      service().onUnauthorized();
      expect(c.read(offlineModeProvider), isTrue);
      expect(offline.isPolling, isFalse,
          reason: 'no health poll may bring a signed-out app back online');
    });

    test('a healthy health poll does not bring a signed-out app online',
        () async {
      service().onUnauthorized();
      await pumpEventQueue(times: 50);
      expect(c.read(offlineModeProvider), isTrue);
      expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
    });

    test('a later connection edge does not clear signedOut', () async {
      service().onUnauthorized();
      unawaited(controlled.gate.startConnection('http://s'));
      await pumpEventQueue();
      expect(controlled.pendingProbes, 0);
      expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
      expect(c.read(offlineModeProvider), isTrue);
    });

    test('a 401 keeps the stored credentials (memory only)', () async {
      service().onUnauthorized();
      await pumpEventQueue();
      expect(await store.read(), isNotNull);
    });

    test('repeated 401s are idempotent', () async {
      service().onUnauthorized();
      service().onUnauthorized();
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

    test('the 401 closes the gate', () {
      service().onUnauthorized();
      expect(gate.closes, 1);
    });

    test('a second 401 does not close the gate again', () {
      service().onUnauthorized();
      service().onUnauthorized();
      expect(gate.closes, 1);
    });

    test('a disposed scope no longer watches the gate', () async {
      await publish(verified); // the launch's own wait for a verdict ends
      c.dispose();
      expect(gate.script.hasListener, isFalse);
    });

    test('BindingVerified does not clear signedOut', () async {
      service().onUnauthorized();
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
    });

    test('both apply: differentServer wins; verified leaves signedOut',
        () async {
      service().onUnauthorized();
      await publish(different);
      expect(service().serverBlocked.value,
          ServerBlockedReason.differentServer);
      await publish(verified);
      expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
      expect(c.read(offlineModeProvider), isTrue);
    });
  });
}
