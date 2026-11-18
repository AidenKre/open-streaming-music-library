// Phase M §7.5 login ordering and the user switch (M-U22), in the session
// model:
//  1. finish any pending reset first;
//  2. authenticate through the unhooked client;
//  3. compare (instance_id, user_id) with the binding row BEFORE the
//     credentials are stored or any scope uses them:
//     - no row / same pair: store, bind with both IDs, rebuild the scope;
//     - same instance, different (or NULL) user: hold the new sign-in in
//       memory only; confirm runs the SC-15 reset (resetPending) and persists
//       only if no wipe step failed; cancel revokes the new session through
//       the unhooked client and leaves the store untouched;
//     - different instance: the different-server sheet, same rules.
//  4. an interrupted switch is finished by resetPending at the next launch:
//     server-address screen, then Log in.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/server_binding.dart';

/// Every durable step of the flow, in order, across the store, the wipe and
/// the network: the ordering assertions read this one log.
final _events = <String>[];

/// The real store, spied: records saves (with the user) and deletes.
class _SpyStore extends CredentialStore {
  _SpyStore(Directory dir) : super(secure: FakeSecureBackend(), directory: dir);
  Object? saveError;
  @override
  Future<void> save(Credentials credentials) async {
    _events.add('store.save ${credentials.username}');
    if (saveError != null) throw saveError!;
    await super.save(credentials);
  }

  @override
  Future<void> delete() async {
    _events.add('store.delete');
    await super.delete();
  }
}

/// A wipe band standing in for the catalog/download/prefs wipe. Clears the
/// prefs (except the reset marker) like the real one.
class _Wipe implements LocalResettable {
  bool fail = false;
  @override
  int get resetPriority => ResetPriority.clearPreferences;
  @override
  Future<void> resetLocalState() async {
    _events.add('wipe');
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().toList()) {
      if (k != LocalResetService.resetPendingKey) await prefs.remove(k);
    }
    if (fail) throw StateError('download dir busy');
  }
}

/// A quiesce step that fails (a request still in flight): the wipe runs.
class _FailingQuiesce implements Quiescable {
  @override
  String get quiesceName => 'history';
  @override
  Future<void> quiesce() async => throw StateError('history pass in flight');
}

class _FailingProvisional extends ServerBindingRepository {
  _FailingProvisional(super.db);
  @override
  Future<ServerBindingRecord> ensureProvisional(String baseUrl,
          {int? userId, String? instanceId}) async =>
      throw StateError('disk full');
}

/// The SC-15 fence (the binding-row delete) fails: the reset aborts before
/// anything is quiesced or wiped.
class _FailingFence extends ServerBindingRepository {
  _FailingFence(super.db);
  @override
  Future<void> fence() async => throw StateError('disk I/O error');
}

class _FailingDbWipe extends AppDatabase {
  _FailingDbWipe() : super(NativeDatabase.memory());
  @override
  Future<void> resetLocalState() async {
    _events.add('wipe db (fails)');
    throw StateError('db wipe failed');
  }
}

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late Directory dir;
  late Directory downloads;
  late _SpyStore store;
  late _Wipe wipe;
  late int rebuilds;

  // The server: who logs in, on which instance.
  late int userId;
  late String username;
  late String instanceId;
  late int authStatus;
  late Map<String, Object?> authError;
  late int logoutStatus;

  setUp(() async {
    _events.clear();
    db = AppDatabase(NativeDatabase.memory());
    controlled = ControlledGate(db);
    dir = await Directory.systemTemp.createTemp('osml-login-');
    downloads = await Directory('${dir.path}/downloads').create();
    await File('${downloads.path}/a.flac').writeAsString('x');
    store = _SpyStore(await Directory('${dir.path}/store').create());
    wipe = _Wipe();
    rebuilds = 0;
    userId = 7;
    username = 'alice';
    instanceId = 'inst-1';
    authStatus = 200;
    authError = const {};
    logoutStatus = 204;
    SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
  });

  tearDown(() async {
    controlled.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  /// Records every request (with its bearer, if any) the scope sends,
  /// through either client.
  http.Client transport() => MockClient((req) async {
        final auth = req.headers['Authorization'];
        _events.add('${req.method} ${req.url.path}'
            '${auth == null ? '' : ' [$auth]'}');
        final path = req.url.path;
        if (path == '/auth/login' || path == '/auth/register') {
          if (authStatus != 200) {
            return http.Response(jsonEncode({'detail': authError}), authStatus);
          }
          return http.Response(
            jsonEncode({
              'token': 'tok-$username',
              'media_token': 'med-$username',
              'server_instance_id': instanceId,
              'user': {
                'id': userId,
                'username': username,
                'is_admin': false,
                'is_master_admin': false,
              },
            }),
            path == '/auth/register' ? 201 : 200,
          );
        }
        if (path == '/auth/logout') return http.Response('', logoutStatus);
        return http.Response('{"message":"Healthy"}', 200);
      });

  ProviderContainer scope({
    List<LocalResettable>? wipeSteps,
    ServerBindingRepository? repository,
    ApiClient Function(String url)? unauthenticated,
    List<Quiescable> quiescables = const [],
  }) {
    final t = transport();
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      // The Log in screen's scope: a saved URL, no credentials.
      apiClientProvider.overrideWithValue(testApiClient('http://s', t)),
      unauthenticatedApiClientProvider.overrideWithValue(
          unauthenticated ?? (url) => testApiClient(url, t)),
      if (repository != null)
        serverBindingRepositoryProvider.overrideWithValue(repository),
      serverBindingGateProvider.overrideWithValue(controlled.gate),
      credentialStoreProvider.overrideWithValue(store),
      downloadDirectoryProvider.overrideWithValue(() async => downloads),
      localQuiescablesProvider.overrideWithValue(quiescables),
      localResettablesProvider
          .overrideWithValue(wipeSteps ?? [wipe, store]),
      onSessionChangedProvider.overrideWithValue(() async {
        _events.add('onSessionChanged');
        rebuilds++;
      }),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  ServerBindingRepository repo() => ServerBindingRepository(db);
  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  /// A's kept store: a bound row, an unsent edit, a setting, a download.
  Future<String> seedAlice() async {
    final row =
        await repo().ensureProvisional('http://s', userId: 7, instanceId: 'inst-1');
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, status, '
      "updated_at) VALUES ('a', '{}', 'db_only', 'pending', 1)",
    );
    (await prefs()).setString('settings.x', 'A');
    return row.localBindingId;
  }

  Future<int> pendingEdits() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM pending_edits')
              .getSingle())
          .read<int>('n');

  Future<Map<String, Object?>> prefsSnapshot() async {
    final p = await prefs();
    return {for (final k in p.getKeys()) k: p.get(k)};
  }

  List<String> downloadListing() =>
      downloads.listSync().map((e) => e.path).toList()..sort();

  List<String> bearerRequestsFor(String user) =>
      _events.where((e) => e.contains('Bearer tok-$user')).toList();

  group('no row, or the same pair', () {
    test('a fresh device: stores, binds with both IDs, rebuilds', () async {
      final c = scope();
      final outcome = await c.read(sessionServiceProvider).login('alice', 'pw-alice-1');
      expect(outcome, isA<SignInSucceeded>());
      expect(await store.read(),
          isA<Credentials>().having((x) => x.userId, 'userId', 7));
      final row = (await repo().current())!;
      expect(row.userId, 7);
      expect(row.instanceId, 'inst-1');
      expect(row.lastBaseUrl, 'http://s');
      expect(rebuilds, 1);
      expect(_events.indexOf('store.save alice'),
          lessThan(_events.indexOf('onSessionChanged')));
    });

    test('the same pair keeps every row: no reset, nothing wiped', () async {
      final token = await seedAlice();
      final c = scope();
      final outcome = await c.read(sessionServiceProvider).login('alice', 'pw-alice-1');
      expect(outcome, isA<SignInSucceeded>());
      expect(_events, isNot(contains('wipe')));
      expect((await repo().current())!.localBindingId, token);
      expect(await pendingEdits(), 1);
      expect((await prefs()).getString('settings.x'), 'A');
      expect(downloadListing(), hasLength(1));
      expect((await prefs()).getBool(LocalResetService.resetPendingKey), isNull);
      expect(rebuilds, 1);
    });

    // Review r1 m-R1-44: a row whose instance is unknown (NULL) is compared
    // as at connect: unknown is not "different". The same user keeps
    // everything and the login fills the instance in.
    test('a row with an unknown (NULL) instance and the same user is the '
        'same pair', () async {
      final row = await repo().ensureProvisional('http://s', userId: 7);
      await db.customStatement(
        'INSERT INTO pending_edits (uuid_id, values_json, write_mode, status, '
        "updated_at) VALUES ('a', '{}', 'db_only', 'pending', 1)",
      );
      final c = scope();
      expect(await c.read(sessionServiceProvider).login('alice', 'pw-alice-1'),
          isA<SignInSucceeded>());
      expect(_events, isNot(contains('wipe')));
      expect(await pendingEdits(), 1);
      final bound = (await repo().current())!;
      expect(bound.localBindingId, row.localBindingId);
      expect(bound.instanceId, 'inst-1');
      expect(bound.userId, 7);
    });

    // Review r2 m-R2-08: an unknown (NULL) instance is not "matches any
    // server". It may be filled only by a login for the same user on the URL
    // the row was created for (above). On another URL the login could be any
    // server (user ids are small per-server integers): the different-server
    // sheet, nothing persisted.
    group('a row with an unknown (NULL) instance, a login on another URL', () {
      Future<String> seedLegacyRow({required int userId}) async {
        final row =
            await repo().ensureProvisional('http://old', userId: userId);
        await db.customStatement(
          'INSERT INTO pending_edits (uuid_id, values_json, write_mode, '
          "status, updated_at) VALUES ('a', '{}', 'db_only', 'pending', 1)",
        );
        return row.localBindingId;
      }

      test('the same user id is the different-server sheet; nothing is '
          'persisted or bound', () async {
        final token = await seedLegacyRow(userId: 7);
        final c = scope();
        expect(
            await c.read(sessionServiceProvider).login('alice', 'pw-alice-1'),
            isA<SignInDifferentServer>()
                .having((o) => o.url, 'url', 'http://s'));
        expect(_events, isNot(contains('store.save alice')));
        expect(await store.read(), isNull);
        final row = (await repo().current())!;
        expect(row.localBindingId, token);
        expect(row.instanceId, isNull, reason: 'not filled by another server');
        expect(row.lastBaseUrl, 'http://old');
        expect(await pendingEdits(), 1);
        expect(rebuilds, 0);
      });

      test('another user id is the different-server sheet too', () async {
        await seedLegacyRow(userId: 7);
        userId = 9;
        username = 'bob';
        final c = scope();
        expect(await c.read(sessionServiceProvider).login('bob', 'pw-bob-123'),
            isA<SignInDifferentServer>());
        expect(await store.read(), isNull);
      });
    });

    test('register follows the same ordering', () async {
      final c = scope();
      final outcome =
          await c.read(sessionServiceProvider).register('alice', 'pw-alice-1');
      expect(outcome, isA<SignInSucceeded>());
      expect(_events.first, 'POST /auth/register');
      expect((await repo().current())!.userId, 7);
    });

    test('authentication goes through the unhooked client with no bearer',
        () async {
      final c = scope();
      await c.read(sessionServiceProvider).login('alice', 'pw-alice-1');
      expect(_events.first, 'POST /auth/login');
    });

    test("a rejected login shows the server's SC-22 message; nothing stored",
        () async {
      authStatus = 401;
      authError = {
        'error': 'invalid_credentials',
        'message': 'Wrong username or password.',
        'retryable': false,
      };
      final c = scope();
      final outcome = await c.read(sessionServiceProvider).login('alice', 'nope-nope');
      expect(outcome, isA<SignInFailed>());
      expect((outcome as SignInFailed).message, 'Wrong username or password.');
      expect(_events.where((e) => e.startsWith('store.')), isEmpty);
      expect(await repo().current(), isNull);
      expect(rebuilds, 0);
    });

    test('a pending reset is finished before authenticating', () async {
      SharedPreferences.setMockInitialValues(
          {'serverUrl': 'http://s', 'resetPending': true});
      final c = scope();
      await c.read(sessionServiceProvider).login('alice', 'pw-alice-1');
      expect(_events.indexOf('wipe'), greaterThanOrEqualTo(0));
      expect(_events.indexOf('wipe'), lessThan(_events.indexOf('POST /auth/login')));
    });

    test('a pending reset that fails again refuses the login', () async {
      SharedPreferences.setMockInitialValues(
          {'serverUrl': 'http://s', 'resetPending': true});
      final failingDb = _FailingDbWipe();
      addTearDown(failingDb.close);
      final c = scope(wipeSteps: [failingDb]);
      final outcome = await c.read(sessionServiceProvider).login('alice', 'pw-alice-1');
      expect(outcome, isA<SignInFailed>());
      expect(_events, isNot(contains('POST /auth/login')));
    });
  });

  group('same instance, a different user', () {
    setUp(() {
      userId = 8;
      username = 'bob';
    });

    test('is held in memory: nothing persisted, no rebuild, the sheet asks',
        () async {
      final token = await seedAlice();
      final c = scope();
      final outcome = await c.read(sessionServiceProvider).login('bob', 'pw-bob-123');
      expect(outcome, isA<SignInNeedsUserSwitch>());
      expect((outcome as SignInNeedsUserSwitch).username, 'bob');
      expect(_events.where((e) => e.startsWith('store.')), isEmpty);
      expect(await store.read(), isNull);
      expect((await repo().current())!.localBindingId, token);
      expect((await repo().current())!.userId, 7);
      expect(rebuilds, 0);
      expect(bearerRequestsFor('bob'), isEmpty);
    });

    test('a row with an unknown (NULL) user also needs the switch', () async {
      await repo().ensureProvisional('http://s', instanceId: 'inst-1');
      userId = 7;
      username = 'alice';
      final c = scope();
      expect(await c.read(sessionServiceProvider).login('alice', 'pw-alice-1'),
          isA<SignInNeedsUserSwitch>());
      expect(await store.read(), isNull);
    });

    test('confirm: the SC-15 reset first, then B is persisted and bound; no '
        "request ever carried B's token", () async {
      await seedAlice();
      final c = scope();
      final service = c.read(sessionServiceProvider);
      await service.login('bob', 'pw-bob-123');
      final failure = await service.confirmPendingSignIn();
      expect(failure, isNull);
      final wipeAt = _events.indexOf('wipe');
      final saveAt = _events.indexOf('store.save bob');
      expect(wipeAt, greaterThanOrEqualTo(0));
      expect(saveAt, greaterThan(wipeAt), reason: 'persisted only after');
      expect(_events.indexOf('store.delete'), lessThan(saveAt),
          reason: "the wipe deletes A's credentials first");
      expect(bearerRequestsFor('bob'), isEmpty);
      expect(await store.read(),
          isA<Credentials>().having((x) => x.username, 'username', 'bob'));
      final row = (await repo().current())!;
      expect(row.userId, 8);
      expect(row.instanceId, 'inst-1');
      expect((await prefs()).getString('serverUrl'), 'http://s',
          reason: 'the URL is re-saved after the prefs wipe');
      expect((await prefs()).getString('settings.x'), isNull);
      expect((await prefs()).getBool(LocalResetService.resetPendingKey), isNull);
    });

    test('a wipe failure persists nothing', () async {
      await seedAlice();
      wipe.fail = true;
      final c = scope();
      final service = c.read(sessionServiceProvider);
      await service.login('bob', 'pw-bob-123');
      final failure = await service.confirmPendingSignIn();
      expect(failure, isNotNull);
      expect(_events, isNot(contains('store.save bob')));
      expect(await store.read(), isNull);
      expect(await repo().current(), isNull, reason: 'fenced, not re-bound');
      expect((await prefs()).getString('serverUrl'), isNull);
      expect((await prefs()).getBool(LocalResetService.resetPendingKey), isTrue,
          reason: 'the next launch or login wipes again');
    });

    // Review r1 m-R1-06 (DEV-M-09): an aborted reset wiped nothing, so the
    // held sign-in must never be persisted next to A's untouched data.
    test('an aborted reset (the fence failed) persists nothing and revokes '
        'the held session once', () async {
      final token = await seedAlice();
      final c = scope(repository: _FailingFence(db));
      final service = c.read(sessionServiceProvider);
      await service.login('bob', 'pw-bob-123');
      expect(await service.confirmPendingSignIn(), isNotNull);
      expect(_events, isNot(contains('store.save bob')));
      expect(await store.read(), isNull);
      final row = (await repo().current())!;
      expect(row.localBindingId, token, reason: "A's binding is untouched");
      expect(row.userId, 7);
      expect(await pendingEdits(), 1, reason: "A's data was not wiped");
      expect(_events.where((e) => e == 'POST /auth/logout [Bearer tok-bob]'),
          hasLength(1));
      expect(bearerRequestsFor('bob'), hasLength(1),
          reason: "the revoke is the only request with B's token");
      expect(rebuilds, 0);
    });

    test('a NULL row instance with another user is the user switch, not a '
        'different server', () async {
      await repo().ensureProvisional('http://s', userId: 7);
      final c = scope();
      expect(await c.read(sessionServiceProvider).login('bob', 'pw-bob-123'),
          isA<SignInNeedsUserSwitch>());
    });

    // Review r1 m-R1-45: a held sign-in is never dropped without a revoke:
    // not when the scope is rebuilt, not when the user connects elsewhere.
    test('a scope rebuilt while a sign-in is held revokes it once', () async {
      await seedAlice();
      final c = scope();
      await c.read(sessionServiceProvider).login('bob', 'pw-bob-123');
      c.dispose();
      await pumpEventQueue();
      expect(_events.where((e) => e == 'POST /auth/logout [Bearer tok-bob]'),
          hasLength(1));
    });

    test('a connect while a sign-in is held revokes it once', () async {
      await seedAlice();
      final c = scope();
      final service = c.read(sessionServiceProvider);
      await service.login('bob', 'pw-bob-123');
      await service.connect('http://other');
      expect(_events.where((e) => e == 'POST /auth/logout [Bearer tok-bob]'),
          hasLength(1));
      await service.cancelPendingSignIn();
      expect(_events.where((e) => e == 'POST /auth/logout [Bearer tok-bob]'),
          hasLength(1), reason: 'nothing is held any more');
    });

    test('a failed database wipe persists nothing', () async {
      await seedAlice();
      final failingDb = _FailingDbWipe();
      addTearDown(failingDb.close);
      final c = scope(wipeSteps: [wipe, store, failingDb]);
      final service = c.read(sessionServiceProvider);
      await service.login('bob', 'pw-bob-123');
      expect(await service.confirmPendingSignIn(), isNotNull);
      expect(await store.read(), isNull);
      expect(await repo().current(), isNull);
    });

    test("cancel revokes B's session through the unhooked client and leaves "
        "A's store unchanged", () async {
      await seedAlice();
      final c = scope();
      final service = c.read(sessionServiceProvider);
      final rowBefore = (await repo().current())!;
      final prefsBefore = await prefsSnapshot();
      final listingBefore = downloadListing();
      await service.login('bob', 'pw-bob-123');
      await service.cancelPendingSignIn();
      expect(_events.where((e) => e.startsWith('POST /auth/logout')).toList(),
          ['POST /auth/logout [Bearer tok-bob]']);
      final row = (await repo().current())!;
      expect(row.localBindingId, rowBefore.localBindingId);
      expect(row.userId, 7);
      expect(await pendingEdits(), 1);
      expect(await prefsSnapshot(), prefsBefore);
      expect(downloadListing(), listingBefore);
      expect(_events, isNot(contains('wipe')));
      expect(await store.read(), isNull);
      expect(rebuilds, 0);
      expect(await service.confirmPendingSignIn(), isNull,
          reason: 'the cancelled sign-in is gone: nothing to confirm');
      expect(_events, isNot(contains('store.save bob')));
    });

    test('cancel treats a 401 (already revoked) or an outage as done',
        () async {
      await seedAlice();
      logoutStatus = 401;
      final c = scope();
      final service = c.read(sessionServiceProvider);
      await service.login('bob', 'pw-bob-123');
      await service.cancelPendingSignIn(); // does not throw
      expect(await store.read(), isNull);
    });
  });

  // U21-FE-SESSION-B-02: the confirmed switch's reset ran, then the held
  // sign-in could not be saved. That is its own failure: never dropped
  // behind a quiesce-only reset result, never reported as a failed wipe.
  group('the sign-in cannot be saved after a confirmed switch', () {
    setUp(() {
      userId = 8;
      username = 'bob';
    });

    test('after a clean wipe: a sign-in-not-saved failure, not a wipe '
        'failure', () async {
      await seedAlice();
      final c = scope();
      final service = c.read(sessionServiceProvider);
      await service.login('bob', 'pw-bob-123');
      store.saveError = StateError('keychain and file both unavailable');
      final failure = await service.confirmPendingSignIn();
      expect(failure, isNotNull);
      expect(failure!.failures, [isA<SignInNotSavedFailure>()]);
      expect(failure.failures.single.quiesce, isFalse);
      expect(_events, contains('POST /auth/logout [Bearer tok-bob]'),
          reason: 'the unsaved session is revoked');
    });

    test('after a reset with only quiesce failures: both are reported',
        () async {
      await seedAlice();
      final c = scope(quiescables: [_FailingQuiesce()]);
      final service = c.read(sessionServiceProvider);
      await service.login('bob', 'pw-bob-123');
      store.saveError = StateError('keychain and file both unavailable');
      final failure = await service.confirmPendingSignIn();
      expect(failure, isNotNull);
      expect(failure!.failures.where((f) => f.quiesce), hasLength(1),
          reason: 'the quiesce failure is kept');
      expect(failure.failures.whereType<SignInNotSavedFailure>(), hasLength(1),
          reason: 'the unsaved sign-in is not dropped');
    });
  });

  group('hardening', () {
    test('a credential save that fails is an error, binds nothing and '
        'revokes the new session', () async {
      store.saveError = StateError('keychain and file both unavailable');
      final c = scope();
      final outcome =
          await c.read(sessionServiceProvider).login('alice', 'pw-alice-1');
      expect(outcome, isA<SignInFailed>());
      expect(await repo().current(), isNull);
      expect(rebuilds, 0);
      expect(_events, contains('POST /auth/logout [Bearer tok-alice]'));
    });

    test('a second login while a switch is held revokes the first one',
        () async {
      await seedAlice();
      userId = 8;
      username = 'bob';
      final c = scope();
      final service = c.read(sessionServiceProvider);
      await service.login('bob', 'pw-bob-123');
      userId = 9;
      username = 'carol';
      await service.login('carol', 'pw-carol-1');
      expect(_events, contains('POST /auth/logout [Bearer tok-bob]'));
      await service.confirmPendingSignIn();
      expect(_events, contains('store.save carol'));
      expect(_events, isNot(contains('store.save bob')));
    });
  });

  // Review F9: a malformed answer is not "could not reach the server".
  test('a malformed sign-in response says so', () async {
    final c = scope(
      unauthenticated: (url) => testApiClient(
          url, MockClient((_) async => http.Response('{"token":"t"}', 200))),
    );
    final outcome =
        await c.read(sessionServiceProvider).login('alice', 'pw-alice-1');
    expect(outcome, isA<SignInFailed>());
    expect((outcome as SignInFailed).message, isNot(contains('reach')));
  });

  // Review F7: the binding row is written before the URL, so a kill between
  // them never leaves a saved URL with a NULL-instance row (a later offline
  // launch would create one) after a confirmed switch wiped the prefs.
  test('a failed binding write after a confirmed switch leaves no URL',
      () async {
    await seedAlice();
    userId = 8;
    username = 'bob';
    final c = scope(repository: _FailingProvisional(db));
    final service = c.read(sessionServiceProvider);
    await service.login('bob', 'pw-bob-123');
    await service.confirmPendingSignIn();
    expect((await prefs()).getString('serverUrl'), isNull);
    expect(await store.read(), isNull);
  });

  group('a different instance', () {
    setUp(() {
      instanceId = 'inst-2';
    });

    test('is the different-server sheet; nothing persisted', () async {
      await seedAlice();
      final c = scope();
      final outcome = await c.read(sessionServiceProvider).login('alice', 'pw-alice-1');
      expect(outcome, isA<SignInDifferentServer>());
      expect((outcome as SignInDifferentServer).url, 'http://s');
      expect(await store.read(), isNull);
      expect((await repo().current())!.instanceId, 'inst-1');
      expect(bearerRequestsFor('alice'), isEmpty);
    });

    // The different-server sheet confirms through resetForNewServer (as for
    // a connect-time switch); the held sign-in is persisted after the wipe.
    test('confirm resets, then binds to the new instance', () async {
      await seedAlice();
      final c = scope();
      final service = c.read(sessionServiceProvider);
      await service.login('alice', 'pw-alice-1');
      expect(await service.resetForNewServer('http://s'), isNull);
      expect(_events.indexOf('store.save alice'),
          greaterThan(_events.indexOf('wipe')));
      final row = (await repo().current())!;
      expect(row.instanceId, 'inst-2');
      expect(row.userId, 7);
      expect((await prefs()).getString('serverUrl'), 'http://s');
    });

    // Review r1 m-R1-06: the different-server sheet's confirm goes through
    // the same rule.
    test('an aborted reset persists nothing for the new instance', () async {
      await seedAlice();
      final c = scope(repository: _FailingFence(db));
      final service = c.read(sessionServiceProvider);
      await service.login('alice', 'pw-alice-1');
      expect(await service.resetForNewServer('http://s'), isNotNull);
      expect(_events, isNot(contains('store.save alice')));
      expect((await repo().current())!.instanceId, 'inst-1');
      expect(_events.where((e) => e == 'POST /auth/logout [Bearer tok-alice]'),
          hasLength(1));
    });

    test('cancel (the sheet\'s Cancel) revokes and keeps the store', () async {
      final token = await seedAlice();
      final c = scope();
      final service = c.read(sessionServiceProvider);
      await service.login('alice', 'pw-alice-1');
      await service.cancelPendingSignIn();
      expect(_events, contains('POST /auth/logout [Bearer tok-alice]'));
      expect((await repo().current())!.localBindingId, token);
      expect(await store.read(), isNull);
    });
  });

  test('an interrupted switch: the next launch finishes the wipe, shows the '
      'server-address screen, then Log in after connect', () async {
    await seedAlice();
    // Killed mid-switch: the marker is saved, A's row fenced, B never
    // persisted.
    SharedPreferences.setMockInitialValues({
      'serverUrl': 'http://s',
      'settings.x': 'A',
      LocalResetService.resetPendingKey: true,
    });
    await repo().fence();
    final launch = scope();
    final first =
        await launch.read(sessionServiceProvider).resumeSavedSession();
    expect(first.kind, SessionStartKind.resetFinished);
    expect(await store.read(), isNull);

    final next = scope(); // the rebuilt scope
    final second = await next.read(sessionServiceProvider).resumeSavedSession();
    expect(second.kind, SessionStartKind.serverAddress);
  });
}
