// Phase M §7.1 StartupGate routing, in the session model (SessionService):
//  * saved URL and stored credentials -> resume as today;
//  * saved URL and no credentials -> Log in, also offline, with no request;
//  * credentials that could not be read (unknown, not absent; M.3b review 2)
//    -> a retry state, never Log in, and the stored sign-in is kept;
//  * the serverError path, which forgets the URL, also deletes the
//    credentials; since sign-off OPEN-A-04 only a 4xx or a non-OSML JSON
//    answer takes it, and a 5xx or 429 is "unreachable" (offline, all kept),
//    as is a 2xx answer that is not JSON (a Wi-Fi sign-in page, A5-02) or
//    is empty, a bare `{}` included;
//  * stored credentials without a binding row of their user are dropped
//    (sign-off DEV-M-13): Log in with "You have been logged out.", nothing
//    sent, and no row is created (login creates it, spec 7.4).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_event_log.dart';
import 'package:frontend/services/session_readiness.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/server_binding.dart';
import '../helpers/test_credentials.dart';

/// Neither secure storage nor the signed-out marker file can be written.
class _ThrowingDeleteStore extends CredentialStore {
  _ThrowingDeleteStore(Directory dir)
      : super(secure: FakeSecureBackend(), directory: dir);
  @override
  Future<void> delete() async => throw StateError('keychain locked');
}

/// A network-backed recovery member (it waits for the binding gate) that
/// runs [onRecover]: stands for sync, the edit flush, history and uploads.
class _NetworkedProbe implements RecoverableService {
  _NetworkedProbe(this.onRecover);
  final Future<void> Function() onRecover;
  @override
  bool get requiresBinding => true;
  @override
  int get recoveryPriority => RecoveryPriority.sync;
  @override
  Set<RecoveryTrigger> get triggers => {RecoveryTrigger.appResume};
  @override
  Future<void> recover(RecoveryTrigger trigger) => onRecover();
}

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late Directory dir;
  late CredentialStore store;
  late FakeSecureBackend secure;
  late List<Uri> requests;
  late Future<http.Response> Function(http.Request) server;
  late List<String> logLines;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    controlled = ControlledGate(db);
    dir = await Directory.systemTemp.createTemp('osml-launch-');
    secure = FakeSecureBackend();
    store = CredentialStore(secure: secure, directory: dir);
    requests = [];
    logLines = [];
    server = (_) async => http.Response('{"message":"Healthy"}', 200);
  });

  tearDown(() async {
    controlled.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  /// Every request any client of the scope sends is recorded.
  http.Client spy() => MockClient((req) async {
        requests.add(req.url);
        return server(req);
      });

  ProviderContainer scope({
    Credentials? credentials,
    bool credentialsUnavailable = false,
    Future<void> Function()? onSessionChanged,
    SessionEventLogFile? logFile,
  }) {
    final transport = spy();
    final c = ProviderContainer(
      overrides: [
        apiClientProvider
            .overrideWithValue(testApiClient('http://s', transport)),
        unauthenticatedApiClientProvider
            .overrideWithValue((url) => testApiClient(url, transport)),
        databaseProvider.overrideWithValue(db),
        serverBindingGateProvider.overrideWithValue(controlled.gate),
        credentialsProvider.overrideWithValue(credentials),
        credentialsUnavailableProvider
            .overrideWithValue(credentialsUnavailable),
        credentialStoreProvider.overrideWithValue(store),
        onSessionChangedProvider.overrideWithValue(onSessionChanged),
        // The app's own sink (sign-off s7-app-texts item 2) when a log file
        // is given; otherwise the lines are captured.
        if (logFile != null)
          sessionEventLogFileProvider.overrideWithValue(logFile)
        else
          sessionEventLogProvider.overrideWithValue(logLines.add),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  ServerBindingRepository repo() => ServerBindingRepository(db);

  group('saved URL, no credentials', () {
    test('goes to Log in without sending any request', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      final c = scope();
      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.logIn);
      expect(start.serverUrl, 'http://s');
      await pumpEventQueue();
      expect(requests, isEmpty, reason: 'no health check, no /app/info');
      expect(controlled.pendingProbes, 0, reason: 'the gate never starts');
    });

    test('offline: still Log in, and offline mode is not entered', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      server = (_) async => throw const SocketException('x');
      final c = scope();
      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.logIn);
      expect(c.read(offlineModeProvider), isFalse);
      expect(requests, isEmpty);
    });

    test('a kept binding row is left exactly as it was', () async {
      final token = await seedTestBinding(db,
          baseUrl: 'http://s', instanceId: 'inst-1');
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      final c = scope();
      await c.read(sessionServiceProvider).resumeSavedSession();
      final row = (await repo().current())!;
      expect(row.localBindingId, token);
      expect(row.instanceId, 'inst-1');
    });

    test('no row is created for the saved URL', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      final c = scope();
      await c.read(sessionServiceProvider).resumeSavedSession();
      expect(await repo().current(), isNull);
    });
  });

  group('credentials that could not be read', () {
    test('a retry state, not Log in; nothing sent, the sign-in kept',
        () async {
      await store.save(testCredentials);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      final c = scope(credentialsUnavailable: true);
      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.credentialsUnavailable);
      await pumpEventQueue();
      expect(requests, isEmpty);
      expect(await store.read(), testCredentials,
          reason: 'unknown is not absent: nothing is deleted');
      expect((await SharedPreferences.getInstance()).getString('serverUrl'),
          'http://s');
    });

    test('without a saved URL it is the server-address screen as usual',
        () async {
      SharedPreferences.setMockInitialValues({});
      final c = scope(credentialsUnavailable: true);
      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.serverAddress);
    });
  });

  // Review r1 m-R1-05 (amends DEV-M-08): the retry screen's "Log in again"
  // is the user's explicit choice to drop an unreadable sign-in. It clears
  // the store the way logout does (marker included) and goes to Log in;
  // "Try again" never deletes anything.
  group('"Log in again" from the retry screen', () {
    test('clears the stored sign-in, rebuilds, and the next scope is Log in '
        'for the kept URL', () async {
      await store.save(testCredentials);
      secure.readError = StateError('errSecInteractionNotAllowed');
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      var rebuilds = 0;
      final c = scope(
        credentialsUnavailable: true,
        onSessionChanged: () async => rebuilds++,
      );
      await c.read(sessionServiceProvider).forgetStoredSignIn();
      expect(secure.calls, contains('delete ${CredentialStore.secureKey}'));
      expect(secure.values, isEmpty);
      expect(rebuilds, 1);
      expect(await store.read(), isNull,
          reason: 'signed out for this run although the read still fails');
      final next = scope(credentials: await store.read());
      final start = await next.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.logIn);
      expect(start.serverUrl, 'http://s');
      await pumpEventQueue();
      expect(requests, isEmpty);
    });

    test('a store that cannot clear anything still reaches Log in', () async {
      store = _ThrowingDeleteStore(dir);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      var rebuilds = 0;
      final c = scope(
        credentialsUnavailable: true,
        onSessionChanged: () async => rebuilds++,
      );
      await c.read(sessionServiceProvider).forgetStoredSignIn();
      expect(rebuilds, 1);
    });

    test('"Try again" re-reads only: nothing is deleted', () async {
      await store.save(testCredentials);
      secure.readError = StateError('errSecInteractionNotAllowed');
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      var rebuilds = 0;
      final c = scope(
        credentialsUnavailable: true,
        onSessionChanged: () async => rebuilds++,
      );
      await c.read(sessionServiceProvider).reloadSession();
      expect(rebuilds, 1);
      expect(secure.calls.where((call) => call.startsWith('delete')), isEmpty);
      secure.readError = null;
      expect(await store.read(), testCredentials);
    });
  });

  // Review r1 m-R1-18: stored credentials are usable only with a saved URL
  // and a binding row for the same user. Anything else (a kill inside the
  // sign-in's persist, or a swallowed rollback) never reaches a server: the
  // credentials are deleted, no row is created and nothing is sent.
  // Sign-off DEV-M-13 (2026-11-17): every dropped sign-in shows the one
  // notice, wherever the app lands, and writes one log line naming the
  // reason (no token, no user name, no server address).
  const loggedOutNotice = 'You have been logged out.';
  String droppedLine(String reason) =>
      'Stored sign-in dropped at launch: reason=$reason';
  void expectNoSecretsLogged([List<String>? lines]) {
    for (final line in lines ?? logLines) {
      expect(line, isNot(contains(testCredentials.token)));
      expect(line, isNot(contains(testCredentials.mediaToken)));
      expect(line, isNot(contains(testCredentials.username)));
      expect(line, isNot(contains('http://')));
    }
  }

  group('credentials without a matching binding', () {
    CredentialStore nextLaunchStore() =>
        CredentialStore(secure: secure, directory: dir);

    test('a saved URL but no binding row: Log in, nothing sent, no row, the '
        'credentials deleted', () async {
      await store.save(testCredentials);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      final c = scope(credentials: testCredentials);
      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.logIn);
      expect(start.serverUrl, 'http://s');
      expect(start.error, loggedOutNotice);
      expect(logLines, [droppedLine('no_binding')]);
      expectNoSecretsLogged();
      await pumpEventQueue();
      expect(requests, isEmpty);
      expect(controlled.pendingProbes, 0);
      expect(await repo().current(), isNull);
      expect(await nextLaunchStore().read(), isNull);
    });

    // Sign-off s7-app-texts item 2: the app's sink keeps the same line in
    // the log file, after a timestamp, and nothing else.
    test('the log file keeps the same line after a timestamp, no secrets',
        () async {
      await store.save(testCredentials);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      final logFile = SessionEventLogFile(dir);
      final c = scope(credentials: testCredentials, logFile: logFile);
      await c.read(sessionServiceProvider).resumeSavedSession();
      await logFile.idle();
      final lines =
          await File('${dir.path}/session_events.log').readAsLines();
      expect(lines, hasLength(1));
      final match = RegExp(r'^(\S+) (.*)$').firstMatch(lines.single)!;
      expect(DateTime.parse(match.group(1)!).isUtc, isTrue);
      expect(match.group(2), droppedLine('no_binding'));
      expectNoSecretsLogged(lines);
      expect(lines.single, isNot(contains(dir.path)));
    });

    test('no saved URL: the server-address screen, the credentials deleted',
        () async {
      await store.save(testCredentials);
      SharedPreferences.setMockInitialValues({});
      final c = scope(credentials: testCredentials);
      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.serverAddress);
      expect(start.error, loggedOutNotice);
      expect(logLines, [droppedLine('no_saved_address')]);
      expectNoSecretsLogged();
      expect(await nextLaunchStore().read(), isNull);
    });

    test('a device with neither a URL nor a sign-in shows no notice',
        () async {
      SharedPreferences.setMockInitialValues({});
      final start =
          await scope().read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.serverAddress);
      expect(start.error, isNull);
      expect(logLines, isEmpty);
    });

    test("the reviewer's scenario: credentials with no URL and no row, a "
        'connect to another server, a relaunch: the token goes nowhere',
        () async {
      await store.save(testCredentials); // issued by server S1
      SharedPreferences.setMockInitialValues({});
      server = (req) async => req.url.path == '/app/info'
          ? http.Response(
              '{"server":{"instance_id":"inst-x"},'
              '"auth":{"version":1,"signup_enabled":true}}',
              200)
          : http.Response('{"message":"Healthy"}', 200);
      final first = scope(credentials: await nextLaunchStore().read());
      final service = first.read(sessionServiceProvider);
      await service.resumeSavedSession();
      expect(await service.connect('http://x'), isA<ConnectSucceeded>());

      requests.clear();
      final relaunch = scope(credentials: await nextLaunchStore().read());
      final start =
          await relaunch.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.logIn);
      await pumpEventQueue();
      expect(requests, isEmpty);
      expect(controlled.pendingProbes, 0, reason: 'the gate never probes');
      expect(await repo().current(), isNull);
    });
  });

  // Review r1 m-R1-36: credentials for another user than the binding row's
  // never stall silently: Log in with a notice, the credentials deleted,
  // nothing sent. A row without a user is never written (the sign-in stores
  // the user's id); if one were found, it counts as another user's. The next login goes
  // through the user-switch confirm-and-wipe sheet (session_login_test:
  // "same instance, a different user" and "a row with an unknown (NULL) user
  // also needs the switch").
  group('credentials for another user than the binding row', () {
    for (final (name, rowUser, reason) in [
      ('a row for another user', testCredentials.userId + 1,
          'binding_other_user'),
      ('a row with an unknown (NULL) user', null, 'binding_other_user'),
    ]) {
      test('$name: Log in with a notice, nothing sent, credentials deleted',
          () async {
        final token = await seedTestBinding(db,
            baseUrl: 'http://s', instanceId: 'inst-1', userId: rowUser);
        await store.save(testCredentials);
        SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
        final c = scope(credentials: testCredentials);
        final start =
            await c.read(sessionServiceProvider).resumeSavedSession();
        expect(start.kind, SessionStartKind.logIn);
        expect(start.serverUrl, 'http://s');
        expect(start.error, loggedOutNotice);
        expect(logLines, [droppedLine(reason)]);
        expectNoSecretsLogged();
        await pumpEventQueue();
        expect(requests, isEmpty);
        expect(controlled.pendingProbes, 0);
        expect(
            await CredentialStore(secure: secure, directory: dir).read(), isNull);
        final row = (await repo().current())!;
        expect(row.localBindingId, token, reason: 'the row is kept as it was');
        expect(row.userId, rowUser);
      });
    }
  });

  // Pre-merge review D3-01: a database of another schema version is
  // refused; the session log names the refusal (both versions, no path), so
  // the launch-fault screen's cause can be read from the log.
  group('a database of another schema version', () {
    late AppDatabase stamped;
    setUp(() {
      stamped = AppDatabase(NativeDatabase.memory(
          setup: (raw) => raw.execute('PRAGMA user_version = 8')));
    });
    tearDown(() => stamped.close());

    ProviderContainer stampedScope({Credentials? credentials}) {
      final transport = spy();
      final c = ProviderContainer(overrides: [
        apiClientProvider
            .overrideWithValue(testApiClient('http://s', transport)),
        unauthenticatedApiClientProvider
            .overrideWithValue((url) => testApiClient(url, transport)),
        databaseProvider.overrideWithValue(stamped),
        serverBindingGateProvider.overrideWithValue(controlled.gate),
        credentialsProvider.overrideWithValue(credentials),
        credentialStoreProvider.overrideWithValue(store),
        sessionEventLogProvider.overrideWithValue(logLines.add),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    const refusedLine =
        'Database not opened: reason=version_refused found=8 expected=1';

    test('launch with a stored sign-in: the launch fails and the log names '
        'the refusal', () async {
      await store.save(testCredentials);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      final c = stampedScope(credentials: testCredentials);
      await expectLater(c.read(sessionServiceProvider).resumeSavedSession(),
          throwsA(isA<DatabaseVersionRefused>()));
      expect(logLines, [refusedLine]);
      expect(await store.read(), testCredentials,
          reason: 'nothing is deleted');
      expect(requests, isEmpty);
    });

    // The app's own setup: a file on a background isolate, whose errors
    // arrive wrapped (DriftRemoteException).
    test('a file on the background isolate: the log names the refusal too',
        () async {
      final file = File('${dir.path}/database.db');
      final old = AppDatabase(NativeDatabase(file));
      await old.customSelect('SELECT 1').get();
      await old.customStatement('PRAGMA user_version = 8');
      await old.close();
      final real = AppDatabase(AppDatabaseConnection(() async => file));
      addTearDown(real.close);
      await store.save(testCredentials);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      final c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(real),
        serverBindingGateProvider.overrideWithValue(controlled.gate),
        credentialsProvider.overrideWithValue(testCredentials),
        credentialStoreProvider.overrideWithValue(store),
        sessionEventLogProvider.overrideWithValue(logLines.add),
      ]);
      addTearDown(c.dispose);
      await expectLater(
          c.read(sessionServiceProvider).resumeSavedSession(), throwsA(anything));
      expect(logLines, [refusedLine]);
    });

    test('connect without a sign-in: the connect fails and the log names the '
        'refusal', () async {
      SharedPreferences.setMockInitialValues({});
      server = (req) async => req.url.path == '/app/info'
          ? http.Response(
              '{"server":{"instance_id":"inst-x"},'
              '"auth":{"version":1,"signup_enabled":true}}',
              200)
          : http.Response('{"message":"Healthy"}', 200);
      final c = stampedScope();
      await expectLater(c.read(sessionServiceProvider).connect('http://x'),
          throwsA(isA<DatabaseVersionRefused>()));
      expect(logLines, [refusedLine]);
    });
  });

  group('saved URL and credentials', () {
    // Stored credentials are used only with a binding row for their user
    // (review r1 m-R1-18); login creates it.
    setUp(() => seedTestBinding(db,
        baseUrl: 'http://s', userId: testCredentials.userId));

    test('resumes online as today, the row carrying the signed-in user',
        () async {
      await store.save(testCredentials);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      final c = scope(credentials: testCredentials);
      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.online);
      expect(start.error, isNull);
      expect(logLines, isEmpty, reason: 'nothing was dropped');
      final row = (await repo().current())!;
      expect(row.userId, testCredentials.userId);
      expect(row.lastBaseUrl, 'http://s');
    });

    // Sign-off OPEN-A-04 (2026-11-17, amends spec §7.1): a server-side error
    // (5xx, or 429) at launch is "unreachable": offline, the URL and the
    // sign-in kept. A foreign server is still caught by the identity check.
    for (final code in [500, 502, 503, 504, 429]) {
      test('a $code answer opens offline and keeps the URL and the sign-in',
          () async {
        await store.save(testCredentials);
        SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
        server = (_) async => http.Response('Bad Gateway', code);
        final c = scope(credentials: testCredentials);
        final start =
            await c.read(sessionServiceProvider).resumeSavedSession();
        expect(start.kind, SessionStartKind.offline);
        expect(start.error, isNull);
        expect(c.read(offlineModeProvider), isTrue);
        expect((await SharedPreferences.getInstance()).getString('serverUrl'),
            'http://s');
        expect(await store.read(), testCredentials);
        expect(controlled.pendingProbes, 0,
            reason: 'like unreachable: no identity probe at launch');
      });
    }

    // The serverError path that forgets the URL also deletes the credentials:
    // a 4xx (a refusal, whatever its body) or a JSON answer that is not
    // OSML's. A 2xx answer that is not JSON at all is a web page in front of
    // the server instead (pre-merge review A5-02, below).
    for (final (name, response) in [
      ('a 404 answer', () => http.Response('{"detail":"Not Found"}', 404)),
      ('a 400 answer', () => http.Response('{}', 400)),
      ('a 401 answer',
          () => http.Response('{"detail":"Not authenticated"}', 401)),
      ('a 403 answer', () => http.Response('{"detail":"Forbidden"}', 403)),
      ('a 4xx HTML answer',
          () => http.Response('<html>Not found</html>', 404,
              headers: {'content-type': 'text/html'})),
      ('a non-OSML JSON answer', () => http.Response('{"hello":1}', 200)),
      ('a JSON error body with a 200',
          () => http.Response('{"detail":"no such user"}', 200)),
      // JSON, but not an object: another web service, not a sign-in page.
      ('a JSON list with a 200', () => http.Response('[]', 200)),
      ('a JSON string with a 200', () => http.Response('"ok"', 200)),
    ]) {
      test('$name forgets the URL and deletes the credentials', () async {
        await store.save(testCredentials);
        SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
        server = (_) async => response();
        final c = scope(credentials: testCredentials);
        final start =
            await c.read(sessionServiceProvider).resumeSavedSession();
        expect(start.kind, SessionStartKind.serverAddress);
        expect(start.error, isNotNull);
        expect((await SharedPreferences.getInstance()).getString('serverUrl'),
            isNull);
        expect(await store.read(), isNull);
        expect(c.read(offlineModeProvider), isFalse);
      });
    }

    // Pre-merge review A5-01: the launch that forgot the server deleted the
    // stored sign-in, but the scope still holds it. A later app resume must
    // not restart the gate on the forgotten address and let the runners
    // send with the deleted sign-in while the server-address page shows.
    test('a launch that forgot the server never verifies or sends with the '
        'deleted sign-in on a later resume', () async {
      await store.save(testCredentials);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      server = (_) async => http.Response('{"detail":"Not Found"}', 404);
      final authorizations = <String?>[];
      final ran = <String>[];
      final transport = MockClient((req) async {
        requests.add(req.url);
        authorizations.add(req.headers['Authorization']);
        return server(req);
      });
      // The app's own scope clients: the token client over the shared
      // transport, for the session URL, with the stored credentials.
      final c = ProviderContainer(
        overrides: [
          httpClientProvider.overrideWithValue(transport),
          sessionUrlProvider.overrideWithValue('http://s'),
          credentialsProvider.overrideWithValue(testCredentials),
          unauthenticatedApiClientProvider
              .overrideWithValue((url) => testApiClient(url, transport)),
          databaseProvider.overrideWithValue(db),
          serverBindingGateProvider.overrideWithValue(controlled.gate),
          credentialStoreProvider.overrideWithValue(store),
          sessionEventLogProvider.overrideWithValue(logLines.add),
          recoverablesProvider.overrideWith((ref) => [
                _NetworkedProbe(() async {
                  ran.add('networked');
                  await ref.read(apiClientProvider).getBytes(['tracks'],
                      retry: false, triggerOfflineHook: false);
                }),
              ]),
        ],
      );
      addTearDown(c.dispose);

      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.serverAddress);
      expect(await store.read(), isNull, reason: 'the sign-in was deleted');

      // The server at the forgotten address answers again; the app resumes.
      server = (_) async => http.Response('{"message":"Healthy"}', 200);
      // Not awaited: a run whose gate never verifies waits until the gate
      // closes (tearDown).
      unawaited(
          c.read(recoveryServiceProvider).runFor(RecoveryTrigger.appResume));
      await pumpEventQueue();
      if (controlled.pendingProbes > 0) controlled.respond('inst-1');
      await pumpEventQueue();

      expect(controlled.gate.state, isNot(isA<BindingVerified>()),
          reason: 'the gate must not verify the forgotten address');
      expect(controlled.probedUrls, isEmpty,
          reason: 'no identity probe of the forgotten address');
      expect(ran, isEmpty, reason: 'no networked runner ran');
      expect(authorizations.whereType<String>(), isEmpty,
          reason: 'no request carried the deleted sign-in');
    });

    // Pre-merge review A5-02 (owner, 2026-11-18): a web page answering 2xx
    // with something that is not JSON at the saved address (a hotel or
    // airport Wi-Fi sign-in page: the portal's redirect is followed for GET)
    // counts as "can't reach your server": offline, the address and the
    // sign-in kept.
    test('a 2xx HTML answer at launch keeps the address and the sign-in',
        () async {
      await store.save(testCredentials);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      server = (_) async => http.Response(
          '<html><body>Hotel Wi-Fi: log in</body></html>', 200,
          headers: {'content-type': 'text/html'});
      final c = scope(credentials: testCredentials);
      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.offline);
      expect((await SharedPreferences.getInstance()).getString('serverUrl'),
          'http://s');
      expect(await store.read(), testCredentials);
    });

    // An empty 2xx answer (or a bare `{}`, which the client cannot
    // tell from it) comes from something in front of the server too: the
    // address and the sign-in are kept.
    test('an empty 200 answer at launch keeps the address and the sign-in',
        () async {
      await store.save(testCredentials);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      server = (_) async => http.Response('', 200);
      final c = scope(credentials: testCredentials);
      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.offline);
      expect((await SharedPreferences.getInstance()).getString('serverUrl'),
          'http://s');
      expect(await store.read(), testCredentials);
    });

    // ... and the app is then exactly as offline at launch: the same start,
    // offline mode with its health poll, the session ready (the saved queue
    // may load), no identity probe, the binding row and the log as they were,
    // one request sent.
    Future<Map<String, Object?>> launchAgainst(
        Future<http.Response> Function(http.Request) answer) async {
      await store.save(testCredentials);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      server = answer;
      requests.clear();
      logLines.clear();
      final c = scope(credentials: testCredentials);
      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      await pumpEventQueue();
      final row = (await repo().current())!;
      return {
        'kind': start.kind,
        'error': start.error,
        'serverUrl': start.serverUrl,
        'offline': c.read(offlineModeProvider),
        'polling': c.read(offlineModeProvider.notifier).isPolling,
        'ready': c.read(sessionReadinessProvider).isReady,
        'probes': controlled.pendingProbes,
        'savedUrl':
            (await SharedPreferences.getInstance()).getString('serverUrl'),
        'signIn': await store.read() == testCredentials,
        'row': (row.localBindingId, row.instanceId, row.userId),
        'log': [...logLines],
        'requests': requests.length,
      };
    }

    for (final (name, answer) in [
      ('a 200 HTML page', (http.Request _) async => http.Response(
          '<html>Wi-Fi</html>', 200, headers: {'content-type': 'text/html'})),
      ('a 202 plain-text page',
          (http.Request _) async => http.Response('Please sign in', 202)),
      ('an empty 200 answer', (http.Request _) async => http.Response('', 200)),
      ('a {} 200 answer', (http.Request _) async => http.Response('{}', 200)),
    ]) {
      test('$name at launch behaves exactly as an unreachable server',
          () async {
        final offline = await launchAgainst(
            (_) async => throw const SocketException('no route'));
        final portal = await launchAgainst(answer);
        expect(portal, offline);
        expect(portal['kind'], SessionStartKind.offline);
      });
    }

    // Review F6: a credential delete that fails must not strand the launch.
    test('serverError with a failing credential delete still reaches the '
        'server-address screen', () async {
      store = _ThrowingDeleteStore(dir);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      server = (_) async => http.Response('{}', 404);
      final c = scope(credentials: testCredentials);
      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.serverAddress);
    });

    test('an unreachable server keeps the credentials (offline session)',
        () async {
      await store.save(testCredentials);
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      server = (_) async => throw const SocketException('x');
      final c = scope(credentials: testCredentials);
      final start = await c.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.offline);
      expect(await store.read(), testCredentials);
    });
  });

  // A sign-in saved before the scope rebuild threw is kept (the
  // next launch resumes signed in), so the sign-in's catch-all says it
  // could not be finished, not that it failed.
  test('a sign-in whose scope rebuild throws reads "Could not finish '
      'signing in."; the sign-in is saved', () async {
    SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
    server = (req) async => req.url.path == '/auth/login'
        ? http.Response(
            jsonEncode({
              'token': 'tok',
              'media_token': 'med',
              'server_instance_id': 'inst-1',
              'user': {
                'id': testUserId,
                'username': 'tester',
                'is_admin': false,
                'is_master_admin': false,
              },
            }),
            200)
        : http.Response('{"message":"Healthy"}', 200);
    final c = scope(
        onSessionChanged: () async => throw StateError('rebuild failed'));
    final controls = c.read(sessionControlsProvider);
    await controls.start();
    expect(controls.phase, SessionPhase.logIn);
    await controls.login('tester', 'pw-tester-1');
    expect(controls.authError, 'Could not finish signing in.');
    expect((await store.read())?.token, 'tok',
        reason: 'the sign-in was saved before the rebuild threw');
  });
}
