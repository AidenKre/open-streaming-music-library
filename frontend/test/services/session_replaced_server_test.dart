// A signed-in session whose server is replaced, mid-session, by another
// server at the same address. The first request after the change carries
// the token to the other server, which answers 401 (it does not know the
// token). Who answered decides what the 401 means: the server's identity is
// read again (token-free) before anything is concluded. Another server is
// the different-server block, as at start-up, not "signed out" (the token
// may still be good at the bound server); the bound server refusing the
// token is signed out, as before. From the 401 on, no token leaves until the
// identity is known.
//
// The real chain runs here: the scope's authenticated client, its 401 hook
// wired as FrontendApp wires it, the real binding gate probing `/app/info`
// through the token-free client, and the session's block watch.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/server_binding.dart';
import '../helpers/test_credentials.dart';

/// Whatever server answers at `http://s`: [instanceId] is the one answering
/// now; [acceptsToken] whether it accepts this app's token. [holdInfo], when
/// set, holds every `/app/info` answer until it completes.
class _AddressServer extends http.BaseClient {
  String instanceId = 'inst-1';
  bool acceptsToken = true;
  Completer<void>? holdInfo;

  /// Whether answers carry `X-Server-Instance-Id` (an OSML server stamps
  /// every answer; a proxy may strip it).
  bool stamps = true;

  /// False: not an OSML server at all; every path answers 401, unstamped.
  bool osml = true;

  /// Every request: method, path, whether it carried a token, and which
  /// server instance it reached.
  final requests = <({String path, bool token, String servedBy})>[];

  List<({String path, bool token, String servedBy})> get withToken => [
    for (final r in requests)
      if (r.token) r,
  ];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final served = instanceId;
    requests.add((
      path: path,
      token: request.headers.containsKey('Authorization'),
      servedBy: served,
    ));
    if (path == '/app/info') await holdInfo?.future;
    final (int status, String body) = !osml
        ? (401, 'Unauthorized')
        : switch (path) {
            '/' || '' => (200, '{"message":"Healthy"}'),
            '/app/info' => (
              200,
              '{"server":{"instance_id":"$instanceId"},'
                  '"auth":{"version":1,"signup_enabled":true}}',
            ),
            _ when acceptsToken => (200, '{}'),
            _ => (
              401,
              '{"detail":{"code":"invalid_token","message":"Sign in again."}}',
            ),
          };
    final stamped = stamps && osml;
    return http.StreamedResponse(
      Stream.value(body.codeUnits),
      status,
      request: request,
      headers: {
        'content-type': 'application/json',
        if (stamped) 'x-server-instance-id': served,
        if (status == 401) 'www-authenticate': 'Bearer',
      },
    );
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
  late Directory storeDirectory;
  late CredentialStore store;
  late _AddressServer server;
  late ProviderContainer c;

  SessionService service() => c.read(sessionServiceProvider);
  ServerBindingGate gate() => c.read(serverBindingGateProvider);
  ApiClient api() => c.read(apiClientProvider);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storeDirectory = await Directory.systemTemp.createTemp('replaced_server_');
    store = CredentialStore(
      secure: FakeSecureBackend(),
      directory: storeDirectory,
    );
    await store.save(testCredentials);
    server = _AddressServer();
    recoveries = [];
    SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
    final originalPoll = OfflineModeNotifier.pollInterval;
    OfflineModeNotifier.pollInterval = const Duration(hours: 1);
    c = ProviderContainer(
      overrides: [
        httpClientProvider.overrideWithValue(server),
        sessionUrlProvider.overrideWithValue('http://s'),
        credentialsProvider.overrideWithValue(testCredentials),
        credentialStoreProvider.overrideWithValue(store),
        databaseProvider.overrideWithValue(db),
        onUnauthorizedProvider.overrideWith(
          (ref) => ref.read(sessionServiceProvider).onUnauthorized,
        ),
        recoveryServiceProvider.overrideWith(
          (ref) => _RecordingRecovery(ref, recoveries),
        ),
      ],
    );
    final offlineWatch = c.listen(offlineModeProvider, (_, _) {});
    addTearDown(() async {
      offlineWatch.close();
      c.dispose();
      OfflineModeNotifier.pollInterval = originalPoll;
      await db.close();
      if (await storeDirectory.exists()) {
        await storeDirectory.delete(recursive: true);
      }
    });

    // The saved session starts online and verifies the bound server.
    final start = await service().resumeSavedSession();
    expect(start.kind, SessionStartKind.online);
    await pumpEventQueue();
    expect(gate().state, isA<BindingVerified>());
    expect(service().serverBlocked.value, ServerBlockedReason.none);
    server.requests.clear();
  });

  /// The bound server is replaced by another one at the same address.
  void replaceServer() {
    server
      ..instanceId = 'inst-2'
      ..acceptsToken = false;
  }

  test('another server answering 401 at the address: the different-server '
      'block, not signed out', () async {
    replaceServer();

    await expectLater(api().getJson(['tracks']), throwsA(isA<ApiException>()));
    await pumpEventQueue();

    expect(service().serverBlocked.value, ServerBlockedReason.differentServer);
    expect(gate().state, isA<BindingDifferentServer>());
    expect(c.read(offlineModeProvider), isTrue);
    expect(await store.read(), testCredentials,
        reason: 'the sign-in is kept, as for any 401');
    expect(server.withToken, hasLength(1),
        reason: 'only the request that found the other server carried the '
            'token');
    expect(server.requests.where((r) => r.path == '/app/info'), isEmpty,
        reason: "the 401's own stamp named the sender: no identity read");
  });

  test('the bound server answering again clears the block, and the same '
      'sign-in works: nothing signed it out', () async {
    replaceServer();
    await expectLater(api().getJson(['tracks']), throwsA(isA<ApiException>()));
    await pumpEventQueue();
    expect(service().serverBlocked.value, ServerBlockedReason.differentServer);

    server
      ..instanceId = 'inst-1'
      ..acceptsToken = true;
    await gate().startConnection('http://s'); // a recovery edge
    await pumpEventQueue();

    expect(gate().state, isA<BindingVerified>());
    expect(service().serverBlocked.value, ServerBlockedReason.none);
    expect(c.read(offlineModeProvider), isFalse);
    expect(await api().getJson(['tracks']), isA<Map<String, dynamic>>());
    expect(recoveries, contains(RecoveryTrigger.boundServerBack),
        reason: 'the runners the other server parked are resumed');
  });

  test('a token revoked meanwhile: the bound server back, the resumed work '
      "gets the bound server's 401, and that is signed out, not another "
      'resume', () async {
    replaceServer();
    await expectLater(api().getJson(['tracks']), throwsA(isA<ApiException>()));
    await pumpEventQueue();
    expect(service().serverBlocked.value, ServerBlockedReason.differentServer);

    server.instanceId = 'inst-1'; // the bound server, which revoked the token
    await gate().startConnection('http://s');
    await pumpEventQueue();
    expect(recoveries.where((t) => t == RecoveryTrigger.boundServerBack),
        hasLength(1));
    expect(gate().state, isA<BindingVerified>());

    // The resumed work's first request.
    await expectLater(api().getJson(['tracks']), throwsA(isA<ApiException>()));
    await pumpEventQueue();
    expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
    expect(gate().state, isA<BindingSignedOut>());
    expect(server.withToken.where((r) => r.servedBy == 'inst-1'),
        hasLength(1), reason: 'one request reached the bound server');

    await gate().startConnection('http://s'); // later edges change nothing
    await pumpEventQueue();
    expect(recoveries.where((t) => t == RecoveryTrigger.boundServerBack),
        hasLength(1), reason: 'no resume after a real sign-out');
    expect(gate().state, isA<BindingSignedOut>());
  });

  test('a 401 with no stamp: from the 401 until the identity is known, no '
      'token leaves and offline mode stays off', () async {
    replaceServer();
    server.stamps = false; // a proxy that strips the stamp
    final hold = server.holdInfo = Completer<void>();

    await expectLater(api().getJson(['tracks']), throwsA(isA<ApiException>()));
    await pumpEventQueue();
    expect(server.requests.last.path, '/app/info',
        reason: 'the identity read is out, and held');

    expect(gate().allowsTokenTo(Uri.parse('http://s/tracks')), isFalse);
    expect(gate().lastVerdictFailed, isTrue,
        reason: 'streams count as unavailable while the identity is read');
    expect(gate().maySendTokenTo('http://s'), isFalse,
        reason: 'not even a log-out revoke goes to an unknown server');
    // A request made meanwhile waits for the verdict, then is withheld.
    final meanwhile = api().getJson(['tracks']);
    await pumpEventQueue();
    expect(server.withToken, hasLength(1));
    expect(service().serverBlocked.value, ServerBlockedReason.none,
        reason: 'nothing is concluded before the identity is known');
    expect(c.read(offlineModeProvider), isFalse,
        reason: 'offline comes with the verdict, not with the 401');

    hold.complete();
    await expectLater(meanwhile, throwsA(isA<TokenWithheldException>()));
    await pumpEventQueue();
    expect(service().serverBlocked.value, ServerBlockedReason.differentServer);
    expect(server.withToken, hasLength(1));
  });

  test('the bound server refusing the token is still signed out, without '
      'the token being handed out again on the way', () async {
    server.acceptsToken = false; // the same server revoked this sign-in
    final states = <BindingGateState>[];
    final sub = gate().states.listen(states.add);
    addTearDown(sub.cancel);

    await expectLater(api().getJson(['tracks']), throwsA(isA<ApiException>()));
    await pumpEventQueue();

    expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
    expect(gate().state, isA<BindingSignedOut>());
    expect(states.whereType<BindingVerified>(), isEmpty,
        reason: 'the identity read does not reopen the gate in between');
    expect(c.read(offlineModeProvider), isTrue);
    expect(server.withToken, hasLength(1));
    expect(await store.read(), testCredentials);
    expect(recoveries, isNot(contains(RecoveryTrigger.boundServerBack)),
        reason: 'a real sign-out resumes nothing');
    expect(server.requests.where((r) => r.path == '/app/info'), isEmpty,
        reason: "the bound server's stamp on the 401: signed out at once");
  });

  test('a responder that is not an OSML server (401 everywhere, no stamp): '
      'not signed out; the bound server answering next is verified, and the '
      'parked work resumes', () async {
    server
      ..osml = false
      ..acceptsToken = false;

    await expectLater(api().getJson(['tracks']), throwsA(isA<ApiException>()));
    await pumpEventQueue();
    expect(service().serverBlocked.value, ServerBlockedReason.none,
        reason: 'who sent the 401 cannot be told: nothing is concluded');
    expect(gate().state, isA<BindingUnverified>());
    expect(gate().isVerifiedNow, isFalse, reason: 'the token stays withheld');
    expect(server.withToken, hasLength(1));

    server
      ..osml = true
      ..acceptsToken = true; // the bound server is back
    await gate().startConnection('http://s');
    await pumpEventQueue();
    expect(gate().state, isA<BindingVerified>());
    expect(service().serverBlocked.value, ServerBlockedReason.none);
    expect(recoveries, contains(RecoveryTrigger.boundServerBack));
    expect(await api().getJson(['tracks']), isA<Map<String, dynamic>>());
  });
}
