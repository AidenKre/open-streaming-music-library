// U21-FE-SESSION-A-04: Log out with the sign-in in the fallback file
// (`credentials.json`, read first at every launch) when the secure delete
// works but the file cannot be deleted. The next launch must read signed
// out; when the signed-out marker cannot be written either, the next scope
// shows the existing "could not be removed" notice.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/server_binding.dart';
import '../helpers/test_credentials.dart';

const _notice =
    'You are logged out, but your sign-in could not be removed from this '
    "device's storage. The next time the app starts, it may find it and "
    'sign you in again; if it does, log out again.';

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late Directory dir;
  late FakeSecureBackend secure;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
    db = AppDatabase(NativeDatabase.memory());
    controlled = ControlledGate(db);
    dir = await Directory.systemTemp.createTemp('osml-signout-file-');
    secure = FakeSecureBackend();
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: 'inst-1');
    // The sign-in landed in the fallback file (the secure write failed);
    // the secure store works again by the time the user logs out.
    secure.writeError = StateError('keychain write failed');
    await CredentialStore(secure: secure, directory: dir).save(testCredentials);
    secure.writeError = null;
  });

  tearDown(() async {
    controlled.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<void> throwingDelete(File file) async =>
      throw FileSystemException('cannot delete', file.path);

  ProviderContainer scope(CredentialStore store, {bool signedIn = true}) {
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      httpClientProvider.overrideWithValue(
          MockClient((_) async => http.Response('', 204))),
      sessionUrlProvider.overrideWithValue('http://s'),
      if (signedIn) credentialsProvider.overrideWithValue(testCredentials),
      credentialStoreProvider.overrideWithValue(store),
      serverBindingGateProvider.overrideWithValue(controlled.gate),
      localQuiescablesProvider.overrideWithValue(const []),
      localResettablesProvider.overrideWithValue([store]),
      onSessionChangedProvider.overrideWithValue(() async {}),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('the file cannot be deleted: logout ends cleanly and the next launch '
      'opens at Log in, signed out', () async {
    final store = CredentialStore(
        secure: secure, directory: dir, deleteFile: throwingDelete);
    await scope(store)
        .read(sessionServiceProvider)
        .logout()
        .then<void>((_) {}, onError: (Object _) {});

    // The next launch: a new process reads what is on disk.
    final nextLaunch = CredentialStore(secure: secure, directory: dir);
    expect(await nextLaunch.read(), isNull,
        reason: 'the log-out is not undone at the next launch');
    final start = await scope(nextLaunch, signedIn: false)
        .read(sessionServiceProvider)
        .resumeSavedSession();
    expect(start.kind, SessionStartKind.logIn);
    expect(start.error, isNull);
  });

  test('the marker cannot be written either: the next scope says the '
      'sign-in could not be removed', () async {
    final store = CredentialStore(
      secure: secure,
      directory: dir,
      deleteFile: throwingDelete,
      runProcess: (_, _) async => ProcessResult(0, 1, '', 'denied'),
    );
    await expectLater(
        scope(store).read(sessionServiceProvider).logout(), throwsA(anything));
    final start = await scope(store, signedIn: false)
        .read(sessionServiceProvider)
        .resumeSavedSession();
    expect(start.kind, SessionStartKind.logIn);
    expect(start.error, _notice);
  }, skip: !(Platform.isMacOS || Platform.isLinux)
      ? 'the marker write runs chmod only on macOS and Linux'
      : false);
}
