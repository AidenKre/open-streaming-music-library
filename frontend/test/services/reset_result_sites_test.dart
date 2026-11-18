// What the app does with each result of a local reset or a log-out, at every
// place that reads one (refactor APP-SESSION-1, guide A.1). These pin today's
// behaviour so that judging the result in one place changes none of it.
//
// The kinds of result: nothing failed; only a stopping (quiesce) step failed;
// a wipe step failed; the database wipe failed; the reset marker could not be
// cleared; the fence failed (the reset aborted: nothing stopped or wiped). A
// log-out adds: the token rotation failed; the credential delete failed.
//
// The places, and the rule each follows today:
//  1. SessionService.confirmPendingSignIn: the held sign-in is saved only
//     when nothing but stopping failed and the reset did not abort;
//     otherwise it is revoked.
//  2. SessionService.resetForNewServer: the new address is saved unless the
//     database wipe failed or the reset aborted.
//  3. SignInNotSavedFailure.noticeFor: the "sign-in not saved" sentence only
//     when every failure other than stopping is the unsaved sign-in.
//  6. LocalResetService.signOut: throws only when a step other than stopping
//     failed.
// Places 4 and 5 (the StartupGate's log line and its dialog) are pinned in
// test/ui/startup_gate_reset_result_test.dart.
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
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/server_binding.dart';
import '../helpers/test_credentials.dart';

/// The ways a reset can end, as the tests stage them.
enum _Result { clean, quiesceOnly, wipeStep, database, marker, aborted }

class _FailingQuiesce implements Quiescable {
  @override
  String get quiesceName => 'history';
  @override
  Future<void> quiesce() async => throw StateError('history pass in flight');
}

/// The prefs wipe band: everything but the reset marker, like the real one.
class _ClearPrefs implements LocalResettable {
  _ClearPrefs({this.fail = false});
  final bool fail;
  @override
  int get resetPriority => ResetPriority.clearPreferences;
  @override
  Future<void> resetLocalState() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys().toList()) {
      if (k != LocalResetService.resetPendingKey) await prefs.remove(k);
    }
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

class _FailingRotate extends ServerBindingRepository {
  _FailingRotate(super.db);
  @override
  Future<ServerBindingRecord?> rotate() async => throw StateError('disk full');
}

class _FailingDeleteStore extends CredentialStore {
  _FailingDeleteStore(Directory dir)
      : super(secure: FakeSecureBackend(), directory: dir);
  @override
  Future<void> delete() async => throw StateError('keychain locked');
}

/// The real preferences, except that the reset marker cannot be removed
/// (the platform answers false).
class _MarkerKeepingPrefs implements SharedPreferences {
  _MarkerKeepingPrefs(this._real);
  final SharedPreferences _real;
  @override
  bool? getBool(String key) => _real.getBool(key);
  @override
  Future<bool> setBool(String key, bool value) => _real.setBool(key, value);
  @override
  String? getString(String key) => _real.getString(key);
  @override
  Future<bool> setString(String key, String value) =>
      _real.setString(key, value);
  @override
  Set<String> getKeys() => _real.getKeys();
  @override
  bool containsKey(String key) => _real.containsKey(key);
  @override
  Future<bool> remove(String key) async =>
      key == LocalResetService.resetPendingKey ? false : _real.remove(key);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late Directory dir;
  late CredentialStore store;
  late List<String> requests;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    controlled = ControlledGate(db);
    dir = await Directory.systemTemp.createTemp('osml-reset-result-');
    store = CredentialStore(
      secure: FakeSecureBackend(),
      directory: await Directory('${dir.path}/store').create(),
    );
    requests = [];
  });

  tearDown(() async {
    controlled.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  /// Bob (user 8) signs in on the bound instance; every request is recorded
  /// with its bearer.
  http.Client transport() => MockClient((req) async {
        final auth = req.headers['Authorization'];
        requests.add('${req.method} ${req.url.path}'
            '${auth == null ? '' : ' [$auth]'}');
        if (req.url.path == '/auth/login') {
          return http.Response(
            jsonEncode({
              'token': 'tok-bob',
              'media_token': 'med-bob',
              'server_instance_id': 'inst-1',
              'user': {
                'id': 8,
                'username': 'bob',
                'is_admin': false,
                'is_master_admin': false,
              },
            }),
            200,
          );
        }
        if (req.url.path == '/auth/logout') return http.Response('', 204);
        return http.Response('{"message":"Healthy"}', 200);
      });

  /// A scope whose reset ends as [result].
  Future<ProviderContainer> scope(
    _Result result, {
    bool signedIn = false,
    ServerBindingRepository? repository,
    List<String>? log,
  }) async {
    final t = transport();
    final failingDb = _FailingDbWipe();
    addTearDown(failingDb.close);
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      apiClientProvider.overrideWithValue(testApiClient('http://s', t)),
      unauthenticatedApiClientProvider
          .overrideWithValue((url) => testApiClient(url, t)),
      if (signedIn) credentialsProvider.overrideWithValue(testCredentials),
      credentialStoreProvider.overrideWithValue(store),
      serverBindingGateProvider.overrideWithValue(controlled.gate),
      if (result == _Result.marker)
        sharedPreferencesProvider
            .overrideWith((_) async => _MarkerKeepingPrefs(prefs)),
      if (result == _Result.aborted)
        serverBindingRepositoryProvider.overrideWithValue(_FailingFence(db))
      else if (repository != null)
        serverBindingRepositoryProvider.overrideWithValue(repository),
      localQuiescablesProvider.overrideWithValue(
          [if (result == _Result.quiesceOnly) _FailingQuiesce()]),
      localResettablesProvider.overrideWithValue([
        _ClearPrefs(fail: result == _Result.wipeStep),
        store,
        if (result == _Result.database) failingDb,
      ]),
      onSessionChangedProvider.overrideWithValue(() async {}),
      if (log != null) sessionEventLogProvider.overrideWithValue(log.add),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  ServerBindingRepository repo() => ServerBindingRepository(db);

  int revokesOfBob() =>
      requests.where((r) => r == 'POST /auth/logout [Bearer tok-bob]').length;

  // Place 1.
  group('confirmPendingSignIn (a confirmed user switch)', () {
    Future<LocalResetException?> confirm(_Result result) async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      await repo().ensureProvisional('http://s', userId: 7, instanceId: 'inst-1');
      final c = await scope(result);
      final service = c.read(sessionServiceProvider);
      expect(await service.login('bob', 'pw-bob-123'),
          isA<SignInNeedsUserSwitch>());
      return service.confirmPendingSignIn();
    }

    Future<void> expectSaved() async {
      expect(await store.read(),
          isA<Credentials>().having((x) => x.username, 'username', 'bob'));
      expect((await repo().current())!.userId, 8);
      expect(revokesOfBob(), 0);
    }

    Future<void> expectRevokedNotSaved() async {
      expect(await store.read(), isNull);
      expect(revokesOfBob(), 1);
    }

    test('nothing failed: saved, no failure', () async {
      expect(await confirm(_Result.clean), isNull);
      await expectSaved();
    });

    test('only stopping failed: saved, the stopping failure reported',
        () async {
      final failure = await confirm(_Result.quiesceOnly);
      expect(failure!.failures, hasLength(1));
      expect(failure.failures.single.quiesce, isTrue);
      await expectSaved();
    });

    test('a wipe step failed: revoked, not saved', () async {
      final failure = await confirm(_Result.wipeStep);
      expect(failure!.failures.any((f) => !f.quiesce), isTrue);
      await expectRevokedNotSaved();
      expect(await repo().current(), isNull, reason: 'fenced, not re-bound');
    });

    test('the database wipe failed: revoked, not saved', () async {
      final failure = await confirm(_Result.database);
      expect(failure!.failures.map((f) => f.participant),
          [isA<AppDatabase>()]);
      await expectRevokedNotSaved();
    });

    test('the reset marker could not be cleared: revoked, not saved',
        () async {
      final failure = await confirm(_Result.marker);
      expect(failure!.failures.map((f) => f.subsystem), [LocalResetService]);
      await expectRevokedNotSaved();
      expect((await SharedPreferences.getInstance())
          .getBool(LocalResetService.resetPendingKey), isTrue);
    });

    test('the fence failed: revoked, not saved, the old binding untouched',
        () async {
      final failure = await confirm(_Result.aborted);
      expect(failure!.failures.map((f) => f.subsystem), [LocalResetService]);
      await expectRevokedNotSaved();
      expect((await repo().current())!.userId, 7);
    });
  });

  // Place 2.
  group('resetForNewServer (a confirmed switch, nothing held)', () {
    Future<(LocalResetException?, String?)> switchTo(_Result result) async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://a'});
      await seedTestBinding(db, baseUrl: 'http://a', instanceId: 'inst-1');
      final c = await scope(result);
      final failure =
          await c.read(sessionServiceProvider).resetForNewServer('http://b');
      final saved = (await SharedPreferences.getInstance()).getString('serverUrl');
      return (failure, saved);
    }

    test('nothing failed: the new address is saved', () async {
      final (failure, saved) = await switchTo(_Result.clean);
      expect(failure, isNull);
      expect(saved, 'http://b');
    });

    test('only stopping failed: saved', () async {
      final (failure, saved) = await switchTo(_Result.quiesceOnly);
      expect(failure!.failures.every((f) => f.quiesce), isTrue);
      expect(saved, 'http://b');
    });

    test('a wipe step failed: still saved (the fence held)', () async {
      final (failure, saved) = await switchTo(_Result.wipeStep);
      expect(failure, isNotNull);
      expect(saved, 'http://b');
    });

    test('the database wipe failed: not saved', () async {
      final (failure, saved) = await switchTo(_Result.database);
      expect(failure, isNotNull);
      expect(saved, isNull);
    });

    test('the reset marker could not be cleared: still saved', () async {
      final (failure, saved) = await switchTo(_Result.marker);
      expect(failure!.failures.map((f) => f.subsystem), [LocalResetService]);
      expect(saved, 'http://b');
    });

    test('the fence failed: nothing saved, nothing wiped', () async {
      final (failure, saved) = await switchTo(_Result.aborted);
      expect(failure, isNotNull);
      expect(saved, 'http://a', reason: 'the old address is not wiped either');
      expect((await repo().current())!.instanceId, 'inst-1');
    });
  });

  // Places 1 and 2, what they are handed when the fence failed: one failure
  // that is not a stopping failure. confirmPendingSignIn refuses to save on
  // that failure and, separately, on the abort itself; an abort always
  // arrives as this failure, so no test can tell the two checks apart.
  // These pin the failure's kind, so the two cannot both be lost unseen.
  // Other-issues row 66: the dialog shows a fixed sentence; each failed step
  // is written to the session log by its name and the error's type, never
  // the error's text.
  group('the session log names each failed step', () {
    test('a wipe step failed', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://a'});
      final log = <String>[];
      final c = await scope(_Result.wipeStep, log: log);
      await c.read(sessionServiceProvider).resetLocalData();
      expect(log, ['Reset step failed: step=_ClearPrefs kind=wipe error=StateError']);
      expect(log.join(), isNot(contains('download dir busy')));
    });

    test('only stopping failed', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://a'});
      final log = <String>[];
      final c = await scope(_Result.quiesceOnly, log: log);
      await c.read(sessionServiceProvider).resetLocalData();
      expect(log,
          ['Reset step failed: step=_FailingQuiesce kind=stop error=StateError']);
    });

    test('the fence failed (the reset aborted)', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://a'});
      await seedTestBinding(db, baseUrl: 'http://a', instanceId: 'inst-1');
      final log = <String>[];
      final c = await scope(_Result.aborted, log: log);
      await c.read(sessionServiceProvider).resetLocalData();
      expect(log, [
        'Reset step failed: step=LocalResetService kind=fence '
            'error=LocalResetAbortedException',
      ]);
    });

    test('nothing failed: no line', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://a'});
      final log = <String>[];
      final c = await scope(_Result.clean, log: log);
      await c.read(sessionServiceProvider).resetLocalData();
      expect(log, isEmpty);
    });
  });

  group('the fence failed: the reported failure is not a stopping failure',
      () {
    test('resetLocalData', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://a'});
      await seedTestBinding(db, baseUrl: 'http://a', instanceId: 'inst-1');
      final c = await scope(_Result.aborted);
      final failure = await c.read(sessionServiceProvider).resetLocalData();
      expect(failure!.wipeFailed, isTrue);
    });

    test('resetForNewServer', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://a'});
      await seedTestBinding(db, baseUrl: 'http://a', instanceId: 'inst-1');
      final c = await scope(_Result.aborted);
      final failure =
          await c.read(sessionServiceProvider).resetForNewServer('http://b');
      expect(failure!.wipeFailed, isTrue);
    });

    test('confirmPendingSignIn', () async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      await repo().ensureProvisional('http://s', userId: 7, instanceId: 'inst-1');
      final c = await scope(_Result.aborted);
      final service = c.read(sessionServiceProvider);
      expect(await service.login('bob', 'pw-bob-123'),
          isA<SignInNeedsUserSwitch>());
      final failure = await service.confirmPendingSignIn();
      expect(failure!.wipeFailed, isTrue);
    });
  });

  // Place 3.
  group('SignInNotSavedFailure.noticeFor', () {
    LocalResetFailure quiesce() => LocalResetFailure(
        int, StateError('in flight'), StackTrace.empty,
        quiesce: true);
    LocalResetFailure wipe() =>
        LocalResetFailure(int, StateError('wipe failed'), StackTrace.empty);
    LocalResetFailure aborted() => LocalResetFailure(
        LocalResetService, StateError('fence failed'), StackTrace.empty);
    LocalResetFailure notSaved() =>
        SignInNotSavedFailure(StateError('keychain'), StackTrace.empty);
    const sentence = 'Could not save the sign-in on this device.';

    final cases = <String, (List<LocalResetFailure> Function()?, String?)>{
      'no failure': (null, null),
      'an empty failure list': (() => [], null),
      'only stopping failed': (() => [quiesce()], null),
      'a wipe step failed': (() => [wipe()], null),
      'the fence failed': (() => [aborted()], null),
      'only the sign-in was not saved': (() => [notSaved()], sentence),
      'stopping failed and the sign-in was not saved':
          (() => [quiesce(), notSaved()], sentence),
      'a wipe step failed and the sign-in was not saved':
          (() => [wipe(), notSaved()], null),
    };
    for (final MapEntry(key: name, value: (failures, notice)) in cases.entries) {
      test('$name: ${notice == null ? 'no sentence' : 'the sentence'}', () {
        final failure =
            failures == null ? null : LocalResetException(failures());
        expect(SignInNotSavedFailure.noticeFor(failure), notice);
      });
    }
  });

  // Place 6.
  group('LocalResetService.signOut', () {
    Future<Object?> signOut(
      _Result result, {
      ServerBindingRepository? repository,
    }) async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
      await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
      await store.save(testCredentials);
      final c = await scope(result, signedIn: true, repository: repository);
      return c
          .read(localResetServiceProvider)
          .signOut()
          .then<Object?>((_) => null, onError: (Object e) => e);
    }

    test('nothing failed: no throw, the sign-in deleted', () async {
      expect(await signOut(_Result.clean), isNull);
      expect(await store.read(), isNull);
    });

    test('only stopping failed: no throw, the sign-in deleted', () async {
      expect(await signOut(_Result.quiesceOnly), isNull);
      expect(await store.read(), isNull);
    });

    test('the rotation failed: throws, and the sign-in is still deleted',
        () async {
      final error = await signOut(_Result.clean, repository: _FailingRotate(db));
      expect(error, isA<LocalResetException>());
      expect((error! as LocalResetException).failures.map((f) => f.subsystem),
          [ServerBindingRepository]);
      expect(await store.read(), isNull);
    });

    test('stopping and the rotation failed: throws with both', () async {
      final error =
          await signOut(_Result.quiesceOnly, repository: _FailingRotate(db));
      final failures = (error! as LocalResetException).failures;
      expect(failures.map((f) => f.quiesce), [true, false]);
    });

    test('the credential delete failed: throws', () async {
      store = _FailingDeleteStore(await Directory('${dir.path}/bad').create());
      final error = await signOut(_Result.clean);
      expect(error, isA<LocalResetException>());
      expect((error! as LocalResetException).failures.map((f) => f.subsystem),
          [CredentialStore]);
    });
  });
}
