// Phase M §7.1 (M-U19 store): `CredentialStore` keeps
// `{token, mediaToken, userId, username}` in secure storage, falls back to an
// owner-only file in app-support when secure storage is unavailable (decision
// O4: an unsigned or ad-hoc macOS build gets `-34018`), reads secure storage
// first and then the file, deletes the file after a successful secure write,
// reports which store it used for diagnostics, and clears stale iOS keychain
// items on a first launch with no prefs. Every test uses the in-memory fake
// and a temp directory: never the real keychain or app-support folder.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/credential_store.dart';

import '../helpers/fake_secure_backend.dart';

const _alice = Credentials(
  token: 'api-token-A',
  mediaToken: 'media-token-A',
  userId: 7,
  username: 'alice',
);
const _bob = Credentials(
  token: 'api-token-B',
  mediaToken: 'media-token-B',
  userId: 8,
  username: 'bob',
);

void main() {
  late Directory dir;
  late FakeSecureBackend secure;
  late CredentialStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('credential_store_test_');
    secure = FakeSecureBackend();
    store = CredentialStore(secure: secure, directory: dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File fallback() => File('${dir.path}/${CredentialStore.fallbackFileName}');

  List<String> dirListing() =>
      [for (final e in dir.listSync()) e.uri.pathSegments.last]..sort();

  group('secure storage', () {
    test('nothing stored reads as null', () async {
      expect(await store.read(), isNull);
    });

    test('save then read round-trips all four fields', () async {
      await store.save(_alice);
      final read = await store.read();
      expect(read, _alice);
      expect(read!.token, 'api-token-A');
      expect(read.mediaToken, 'media-token-A');
      expect(read.userId, 7);
      expect(read.username, 'alice');
    });

    test('a working secure store writes no file', () async {
      await store.save(_alice);
      expect(secure.values, isNotEmpty);
      expect(dirListing(), isEmpty);
      expect(store.status.value.kind, CredentialStorageKind.secure);
    });

    test('a fresh store reads what an earlier one saved', () async {
      await store.save(_alice);
      final again = CredentialStore(secure: secure, directory: dir);
      expect(await again.read(), _alice);
    });

    test('delete removes the credentials', () async {
      await store.save(_alice);
      await store.delete();
      expect(await store.read(), isNull);
      expect(secure.values, isEmpty);
    });

    test('an empty token is malformed, not credentials', () async {
      secure.values[CredentialStore.secureKey] = jsonEncode({
        ..._alice.toJson(),
        'token': '',
      });
      expect(await store.read(), isNull);
      secure.values[CredentialStore.secureKey] = jsonEncode({
        ..._alice.toJson(),
        'media_token': '',
      });
      expect(await store.read(), isNull);
    });

    // Review r1 finding 2: a secure read that fails (a locked iOS device) is
    // unknown, not "signed out".
    test('a failing secure read with no file is unavailable, not absent',
        () async {
      secure.readError = StateError('errSecInteractionNotAllowed');
      await expectLater(
        store.read(),
        throwsA(isA<CredentialsUnavailableException>()),
      );
    });

    test('the iOS keychain item stays readable after the first unlock', () {
      expect(
        FlutterSecureCredentialBackend.defaultStorage.iOptions.accessibility,
        KeychainAccessibility.first_unlock_this_device,
      );
    });

    test('a malformed stored value reads as no credentials', () async {
      secure.values[CredentialStore.secureKey] = '{"token": 1}';
      expect(await store.read(), isNull);
      secure.values[CredentialStore.secureKey] = 'not json';
      expect(await store.read(), isNull);
    });

    test('toString names the user but never shows a token', () {
      final text = '$_alice';
      expect(text, contains('alice'));
      expect(text, contains('7'));
      expect(text, isNot(contains('api-token-A')));
      expect(text, isNot(contains('media-token-A')));
    });
  });

  group('owner-only fallback file (decision O4)', () {
    test('an unusable secure store saves to an owner-only file and reads it '
        'back', () async {
      secure.makeUnusable();
      await store.save(_alice);
      expect(await fallback().exists(), isTrue);
      expect(await store.read(), _alice);
      // No temporary or extra file is left next to it.
      expect(dirListing(), [CredentialStore.fallbackFileName]);
    }, testOn: '!windows');

    test('the fallback file is readable and writable by the owner only',
        () async {
      secure.makeUnusable();
      await store.save(_alice);
      final mode = (await fallback().stat()).mode & 0x1ff;
      expect(mode.toRadixString(8), '600');
    }, testOn: '!windows');

    test('diagnostics say the fallback file is in use, and why', () async {
      secure.makeUnusable();
      await store.save(_alice);
      final status = store.status.value;
      expect(status.kind, CredentialStorageKind.fallbackFile);
      expect(status.diagnosticsLine, contains('file'));
      expect(status.diagnosticsLine, contains('-34018'));
      expect(status.diagnosticsLine, isNot(contains('api-token-A')));
    });

    test('diagnostics say secure storage is in use', () async {
      await store.save(_alice);
      expect(store.status.value.kind, CredentialStorageKind.secure);
      expect(
        store.status.value.diagnosticsLine,
        isNot(contains('file')),
      );
    });

    test('a read that falls back to the file also reports it', () async {
      secure.makeUnusable();
      await store.save(_alice);
      final again = CredentialStore(secure: secure, directory: dir);
      expect(again.status.value.kind, CredentialStorageKind.unknown);
      expect(await again.read(), _alice);
      expect(again.status.value.kind, CredentialStorageKind.fallbackFile);
    });

    // Review r1 finding 1 (DEV-M3b-01): a successful secure write always
    // deletes the file, so a file that exists is newer than any secure value
    // and wins; secure storage is read when there is no file.
    test('precedence: a file that exists is newer than the secure value and '
        'wins', () async {
      await store.save(_alice); // secure
      secure.writeError = StateError('keychain busy');
      secure.deleteError = StateError('keychain busy');
      await store.save(_bob); // the secure write fails: lands in the file
      secure
        ..writeError = null
        ..deleteError = null;
      expect(secure.values, isNotEmpty, reason: 'the older secure value');
      final fresh = CredentialStore(secure: secure, directory: dir);
      expect(await fresh.read(), _bob);
    });

    test('precedence: without a file, secure storage is read', () async {
      secure.values[CredentialStore.secureKey] = jsonEncode(_alice.toJson());
      expect(await store.read(), _alice);
    });

    test('a fallback save also clears the older secure value when it can',
        () async {
      await store.save(_alice);
      secure.writeError = StateError('keychain busy');
      await store.save(_bob);
      expect(secure.values, isEmpty);
    });

    test('precedence: an empty secure store falls through to the file',
        () async {
      secure.makeUnusable();
      await store.save(_bob);
      secure.readError = null; // usable again, but holds nothing
      expect(await store.read(), _bob);
    });

    test('a successful secure write deletes the fallback file', () async {
      secure.makeUnusable();
      await store.save(_bob);
      expect(await fallback().exists(), isTrue);
      secure
        ..readError = null
        ..writeError = null
        ..deleteError = null;
      await store.save(_alice);
      expect(await fallback().exists(), isFalse);
      expect(await store.read(), _alice);
      expect(store.status.value.kind, CredentialStorageKind.secure);
    });

    // Review r1 (DEV-M3b-01): with an unusable keychain the secure delete
    // fails too, so the fallback record is replaced by the signed-out
    // marker: the token is gone and the store reads as signed out.
    test('delete replaces the fallback record with the signed-out marker',
        () async {
      secure.makeUnusable();
      await store.save(_alice);
      await store.delete();
      expect(await fallback().readAsString(), isNot(contains('api-token-A')));
      expect(await store.read(), isNull);
    });

    test('with a working keychain, delete removes the file and the secure '
        'value', () async {
      secure.makeUnusable();
      await store.save(_bob); // a file from an unusable-keychain launch
      secure
        ..readError = null
        ..writeError = null
        ..deleteError = null;
      await store.delete();
      expect(await fallback().exists(), isFalse);
      expect(secure.values, isEmpty);
      expect(await store.read(), isNull);
    });

    // Review r1 finding 1: a secure delete that fails (a locked or busy
    // keychain) must not leave the old sign-in to come back once the keychain
    // works again. The store writes an owner-only "signed out" marker file
    // instead, which wins over the secure value.
    test('a secure delete that fails still signs out, also after the '
        'keychain recovers', () async {
      await store.save(_alice);
      secure.deleteError = StateError('keychain locked');
      await store.delete();
      expect(await store.read(), isNull);
      secure.deleteError = null; // the keychain works again
      final fresh = CredentialStore(secure: secure, directory: dir);
      expect(await fresh.read(), isNull);
    });

    test('the signed-out marker is owner-only and holds no token', () async {
      await store.save(_alice);
      secure.deleteError = StateError('keychain locked');
      await store.delete();
      final file = fallback();
      expect(await file.exists(), isTrue);
      expect((await file.stat()).mode & 0x1ff, 0x180);
      expect(await file.readAsString(), isNot(contains('api-token-A')));
    }, testOn: '!windows');

    test('a later successful secure save replaces the signed-out marker',
        () async {
      await store.save(_alice);
      secure.deleteError = StateError('keychain locked');
      await store.delete();
      secure.deleteError = null;
      await store.save(_bob);
      expect(await fallback().exists(), isFalse);
      expect(await store.read(), _bob);
    });

    test('delete reports a failure when neither the secure delete nor the '
        'marker succeeds', () async {
      final blocker = File('${dir.path}/not-a-directory');
      await blocker.writeAsString('x');
      final blocked = CredentialStore(secure: secure, directory: Directory(blocker.path));
      secure.values[CredentialStore.secureKey] = jsonEncode(_alice.toJson());
      secure.deleteError = StateError('keychain locked');
      await expectLater(blocked.delete(), throwsA(anything));
    });

    test('delete succeeds when secure storage is unusable', () async {
      secure.makeUnusable();
      await store.save(_alice);
      await store.delete();
      expect(await store.read(), isNull);
    });
  });

  // Review r1 m-R1-05 (amends DEV-M-08): a secure-storage error that means
  // "this build or machine has no usable secure store" is not unknown: the
  // fallback file is then the store, and no file means signed out. Every
  // other read error stays unknown (a retry state, never Log in).
  // Review r1 m-R1-32: a fallback file that can't be restricted to its owner
  // is never written (a world-readable token file is refused).
  test('a chmod that fails refuses the fallback file and leaves none',
      () async {
    final calls = <List<String>>[];
    final refusing = CredentialStore(
      secure: secure,
      directory: dir,
      runProcess: (executable, arguments) async {
        calls.add([executable, ...arguments]);
        return ProcessResult(0, 1, '', 'Operation not permitted');
      },
    );
    secure.makeUnusable();
    await expectLater(refusing.save(_alice), throwsA(isA<FileSystemException>()));
    expect(calls.single.take(2), ['chmod', '600']);
    expect(dirListing(), isEmpty);
    expect(await refusing.read(), isNull);
  }, skip: !(Platform.isMacOS || Platform.isLinux));

  group('secure storage errors are classified', () {
    PlatformException darwin(int status, String message) => PlatformException(
          code: 'Unexpected security result code',
          message: message,
          details: status,
        );

    final unusable = <String, Object>{
      'macOS/iOS -34018 (missing entitlement, unsigned or ad-hoc build)':
          darwin(-34018, "A required entitlement isn't present."),
      'macOS/iOS -34018 named only in the message':
          PlatformException(
            code: 'Unexpected security result code',
            message: "Code: -34018, Message: A required entitlement isn't "
                'present.',
          ),
      'macOS -25291 (no keychain is available)':
          darwin(-25291, 'No keychain is available.'),
      'Linux without a Secret Service (no keyring)': PlatformException(
        code: 'Libsecret error',
        message: 'secret_service_get_sync: The name org.freedesktop.secrets '
            'was not provided by any .service files',
      ),
      // Review r2 m-R2-11: the GDBus form of "no Secret Service installed".
      'Linux: D-Bus has no Secret Service to start (ServiceUnknown)':
          PlatformException(
        code: 'Libsecret error',
        message: 'GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown: The '
            'name org.freedesktop.secrets was not provided by any .service '
            'files',
      ),
      'no secure-storage plugin on this platform':
          MissingPluginException('No implementation found for method read'),
    };
    final transient = <String, Object>{
      'iOS -25308 (interaction not allowed: locked device)':
          darwin(-25308, 'User interaction is not allowed.'),
      'Linux keyring locked':
          PlatformException(code: 'KeyringLocked', message: 'KeyringLocked'),
      'any other Linux libsecret error': PlatformException(
        code: 'Libsecret error',
        message: 'secret_password_lookupv_sync: Timeout was reached',
      ),
      // Review r2 m-R2-11: these name the Secret Service too, but mean a
      // keyring that is still starting (an autostart at login) or crashed
      // once: never a silent switch to the fallback file.
      'Linux: the Secret Service is slow to start (activation timeout)':
          PlatformException(
        code: 'Libsecret error',
        message: 'Error calling StartServiceByName for '
            'org.freedesktop.secrets: Timeout was reached',
      ),
      'Linux: the Secret Service exited while starting': PlatformException(
        code: 'Libsecret error',
        message: 'GDBus.Error:org.freedesktop.DBus.Error.Spawn.ChildExited: '
            'Process org.freedesktop.secrets exited with status 1',
      ),
      'Linux: ServiceUnknown for another bus name': PlatformException(
        code: 'Libsecret error',
        message: 'GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown: The '
            'name :1.42 was not provided by any .service files',
      ),
      'an error of unknown shape': StateError('something else'),
    };

    unusable.forEach((name, error) {
      test('$name: no file reads as signed out, not unknown', () async {
        secure.values[CredentialStore.secureKey] = jsonEncode(_bob.toJson());
        secure.readError = error;
        expect(await store.read(), isNull);
      });
    });

    transient.forEach((name, error) {
      test('$name: unknown, never signed out', () async {
        secure.readError = error;
        await expectLater(
          store.read(),
          throwsA(isA<CredentialsUnavailableException>()),
        );
      });
    });

    test('an unusable secure store with a file reads the file', () async {
      secure.makeUnusable();
      await store.save(_alice);
      expect(await CredentialStore(secure: secure, directory: dir).read(),
          _alice);
    });

    test('an unusable store never strands a launch: every relaunch before '
        'the first login reads signed out, and a login lands in the file',
        () async {
      secure.makeUnusable();
      for (var launch = 0; launch < 3; launch++) {
        expect(await CredentialStore(secure: secure, directory: dir).read(),
            isNull);
      }
      await CredentialStore(secure: secure, directory: dir).save(_alice);
      expect(await fallback().exists(), isTrue);
      expect(await CredentialStore(secure: secure, directory: dir).read(),
          _alice);
    });
  });

  // Review r1 m-R1-07 / m-R1-05: once this run signed out (logout, a wipe, or
  // the retry screen's "Log in again"), it stays signed out until the next
  // successful save, even if nothing could be cleared on disk. The next
  // launch (a new store) reads what is really stored.
  group('after delete, this run is signed out', () {
    CredentialStore blockedStore() {
      final blocker = File('${dir.path}/not-a-directory');
      blocker.writeAsStringSync('x');
      return CredentialStore(secure: secure, directory: Directory(blocker.path));
    }

    test('a delete that clears nothing still throws, reads signed out for '
        'the rest of this run and says the clear failed', () async {
      final blocked = blockedStore();
      secure.values[CredentialStore.secureKey] = jsonEncode(_alice.toJson());
      secure.deleteError = StateError('keychain locked');
      await expectLater(blocked.delete(), throwsA(anything));
      expect(await blocked.read(), isNull);
      expect(blocked.clearFailed, isTrue);
      // The next launch reads what is really stored: the old sign-in.
      final nextLaunch =
          CredentialStore(secure: secure, directory: Directory('${dir.path}/not-a-directory'));
      expect(await nextLaunch.read(), _alice);
      expect(nextLaunch.clearFailed, isFalse);
    });

    test('a successful delete reads signed out even if the secure read then '
        'fails', () async {
      await store.save(_alice);
      await store.delete();
      secure.readError = StateError('errSecInteractionNotAllowed');
      expect(await store.read(), isNull);
      expect(store.clearFailed, isFalse);
    });

    test('a delete that fell back to the marker did not fail', () async {
      await store.save(_alice);
      secure.deleteError = StateError('keychain locked');
      await store.delete();
      expect(store.clearFailed, isFalse);
      expect(await store.read(), isNull);
    });

    test('the next successful save is read back and clears the failure',
        () async {
      final blocked = blockedStore();
      secure.values[CredentialStore.secureKey] = jsonEncode(_alice.toJson());
      secure.deleteError = StateError('keychain locked');
      await expectLater(blocked.delete(), throwsA(anything));
      secure.deleteError = null;
      await blocked.save(_bob);
      expect(blocked.clearFailed, isFalse);
      expect(await blocked.read(), _bob);
    });
  });

  // U21-FE-SESSION-A-04: the secure delete works, but the fallback file
  // (read first at every launch) cannot be deleted. The log-out must not be
  // undone at the next launch.
  group('logout when the fallback file cannot be deleted', () {
    Future<void> throwingDelete(File file) async =>
        throw FileSystemException('cannot delete', file.path);

    /// A sign-in that landed in the fallback file (secure write failed),
    /// with the secure store working again at log-out.
    Future<void> signInToFile() async {
      secure.writeError = StateError('keychain write failed');
      await CredentialStore(secure: secure, directory: dir).save(_alice);
      secure.writeError = null;
      expect(Credentials.tryParse(fallback().readAsStringSync()), _alice);
    }

    test('the signed-out marker replaces the file: the next launch reads '
        'signed out', () async {
      await signInToFile();
      final store =
          CredentialStore(secure: secure, directory: dir, deleteFile: throwingDelete);
      final error = await store
          .delete()
          .then<Object?>((_) => null, onError: (Object e) => e);
      final nextLaunch = CredentialStore(secure: secure, directory: dir);
      expect(await nextLaunch.read(), isNull,
          reason: 'the next launch must not sign the user back in');
      expect(error, isNull, reason: 'the marker took over: nothing failed');
      expect(store.clearFailed, isFalse);
      expect(await store.read(), isNull);
    });

    test('when the marker cannot be written either, delete throws and says '
        'the clear failed', () async {
      await signInToFile();
      final store = CredentialStore(
        secure: secure,
        directory: dir,
        deleteFile: throwingDelete,
        // The owner-only chmod of the marker's temp file fails.
        runProcess: (_, _) async => ProcessResult(0, 1, '', 'denied'),
      );
      final error = await store
          .delete()
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(store.clearFailed, isTrue,
          reason: 'the stored sign-in is still on disk');
      expect(error, isNotNull);
      expect(await store.read(), isNull, reason: 'this run stays signed out');
    }, skip: !(Platform.isMacOS || Platform.isLinux)
        ? 'the marker write runs chmod only on macOS and Linux'
        : false);
  });

  group('iOS stale keychain after a reinstall', () {
    test('iOS with no prefs clears the surviving keychain item', () async {
      secure.values[CredentialStore.secureKey] = jsonEncode(_alice.toJson());
      await store.clearStaleAfterReinstall(isIOS: true, hasPrefs: false);
      expect(secure.values, isEmpty);
      expect(await store.read(), isNull);
    });

    test('iOS with prefs keeps the credentials', () async {
      secure.values[CredentialStore.secureKey] = jsonEncode(_alice.toJson());
      await store.clearStaleAfterReinstall(isIOS: true, hasPrefs: true);
      expect(await store.read(), _alice);
      expect(secure.calls.where((c) => c.startsWith('delete')), isEmpty);
    });

    test('other platforms never clear, even with no prefs', () async {
      secure.values[CredentialStore.secureKey] = jsonEncode(_alice.toJson());
      await store.clearStaleAfterReinstall(isIOS: false, hasPrefs: false);
      expect(await store.read(), _alice);
      expect(secure.calls.where((c) => c.startsWith('delete')), isEmpty);
    });

    test('a failing clear does not stop the launch', () async {
      secure.deleteError = StateError('keychain locked');
      await store.clearStaleAfterReinstall(isIOS: true, hasPrefs: false);
    });
  });
}
