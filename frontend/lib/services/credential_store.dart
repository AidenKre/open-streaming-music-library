import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:frontend/models/credential_storage_status.dart';
import 'package:frontend/services/local_resettable.dart';

export 'package:frontend/models/credential_storage_status.dart';

/// Whether a secure-storage error means "this build or machine has no usable
/// secure store" (DEV-M-04: the fallback file is then the store, and no file
/// means signed out). Only a *transient* failure is "unknown" (DEV-M-08 as
/// amended by review r1 m-R1-05). The one place errors are classified.
///
/// Permanent classes:
/// - darwin `PlatformException('Unexpected security result code')` with status
///   -34018 (errSecMissingEntitlement: unsigned or ad-hoc build) or -25291
///   (errSecNotAvailable: no keychain). The status is `details` when an int,
///   else the first `-\d+` after `Code:` in the message.
/// - Linux `PlatformException('Libsecret error')` whose D-Bus error is
///   `org.freedesktop.DBus.Error.ServiceUnknown` for
///   `org.freedesktop.secrets` (no Secret Service installed), or that says
///   "The name org.freedesktop.secrets was not provided by any .service
///   files". A ServiceUnknown for another service or a unique connection
///   (`:1.42`), and a timeout or a crash while it starts, are transient.
/// - [MissingPluginException] (no plugin on this platform).
///
/// Everything else (darwin -25308 on a locked device, `KeyringLocked`, other
/// libsecret errors, unknown errors) is transient: unknown, never signed out.
bool secureStorageIsUnusable(Object error) {
  if (error is MissingPluginException) return true;
  if (error is! PlatformException) return false;
  if (error.code == 'Unexpected security result code') {
    final details = error.details;
    final int? status = details is int
        ? details
        : int.tryParse(
            RegExp(r'Code:\s*(-\d+)').firstMatch(error.message ?? '')?.group(1) ??
                '',
          );
    return status == -34018 || status == -25291;
  }
  if (error.code == 'Libsecret error') {
    // D-Bus ServiceUnknown for the Secret Service: nothing on this machine
    // provides it. Matched on the D-Bus error name together with the Secret
    // Service's own name (dbus-broker words the sentence differently from
    // dbus-daemon), and on dbus-daemon's sentence for a message without the
    // error name. A ServiceUnknown for another service (the keyring's
    // prompter) or for a unique connection name (`:1.42`, a connection that
    // went away), and activation timeouts and crashes, are transient
    // (m-R2-11).
    final message = error.message ?? '';
    if (message.contains(_noSecretServiceSentence)) return true;
    return message.contains(_serviceUnknownErrorName) &&
        message.contains(_secretServiceName) &&
        !_uniqueBusName.hasMatch(message);
  }
  return false;
}

const _serviceUnknownErrorName = 'org.freedesktop.DBus.Error.ServiceUnknown';
const _secretServiceName = 'org.freedesktop.secrets';
const _noSecretServiceSentence =
    'The name org.freedesktop.secrets was not provided by any .service files';

/// A unique D-Bus connection name such as `:1.42`, bare or quoted.
final _uniqueBusName = RegExp(r'''(^|[\s'"]):\d+\.\d+''');

/// The signed-in session's credentials (spec §7.1): immutable, scope-bound.
@immutable
class Credentials {
  const Credentials({
    required this.token,
    required this.mediaToken,
    required this.userId,
    required this.username,
  });

  final String token;
  final String mediaToken;
  final int userId;
  final String username;

  Map<String, Object> toJson() => {
    'token': token,
    'media_token': mediaToken,
    'user_id': userId,
    'username': username,
  };

  /// Parses a stored JSON blob. Returns null on anything malformed or
  /// mistyped (unknown is never coerced).
  static Credentials? tryParse(String source) {
    try {
      final json = jsonDecode(source);
      if (json is! Map) return null;
      final token = json['token'];
      final mediaToken = json['media_token'];
      final userId = json['user_id'];
      final username = json['username'];
      if (token is! String ||
          token.isEmpty ||
          mediaToken is! String ||
          mediaToken.isEmpty ||
          userId is! int ||
          username is! String) {
        return null;
      }
      return Credentials(
        token: token,
        mediaToken: mediaToken,
        userId: userId,
        username: username,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Credentials &&
      other.token == token &&
      other.mediaToken == mediaToken &&
      other.userId == userId &&
      other.username == username;

  @override
  int get hashCode => Object.hash(token, mediaToken, userId, username);

  /// Never shows either token.
  @override
  String toString() => 'Credentials(userId: $userId, username: $username)';
}

/// The platform secure storage behind a seam.
abstract interface class SecureCredentialBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production adapter: a thin pass-through to [FlutterSecureStorage].
class FlutterSecureCredentialBackend implements SecureCredentialBackend {
  FlutterSecureCredentialBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? defaultStorage;

  final FlutterSecureStorage _storage;

  /// Readable after the first unlock (a background launch works) and never
  /// migrated to another device.
  static const defaultStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Secure storage could not be read, so whether anyone is signed in is
/// unknown (a locked iOS device): not the same as signed out.
class CredentialsUnavailableException implements Exception {
  CredentialsUnavailableException([this.reason]);

  /// A short reason from the platform error; it contains no secret.
  final String? reason;

  @override
  String toString() => 'CredentialsUnavailableException(${reason ?? 'unknown'})';
}

/// Stores the session's [Credentials] in secure storage, with an owner-only
/// file when secure storage is unavailable (decision O4).
///
/// Precedence (DEV-M3b-01): a file that exists is newer than any secure
/// value. A successful secure write always deletes the file, so the file
/// exists only if it was written after the last successful secure write. It
/// also carries the signed-out marker, written when a secure delete fails so
/// the old secure value can never come back.
class CredentialStore implements LocalResettable {
  CredentialStore({
    required SecureCredentialBackend secure,
    required Directory directory,
    /// Test seam for the owner-only chmod; defaults to [Process.run].
    Future<ProcessResult> Function(String executable, List<String> arguments)?
        runProcess,
    /// Test seam for deleting the fallback file; defaults to [File.delete].
    Future<void> Function(File file)? deleteFile,
  }) : _secure = secure,
       _directory = directory,
       _runProcess = runProcess ?? Process.run,
       _deleteFile = deleteFile ?? _defaultDeleteFile;

  static Future<void> _defaultDeleteFile(File file) => file.delete();

  static const secureKey = 'osml.credentials';
  static const fallbackFileName = 'credentials.json';
  static const _signedOutMarker = '{"signed_out":true}';

  final SecureCredentialBackend _secure;
  final Directory _directory;
  final Future<ProcessResult> Function(String, List<String>) _runProcess;
  final Future<void> Function(File) _deleteFile;
  final ValueNotifier<CredentialStorageStatus> _status = ValueNotifier(
    const CredentialStorageStatus(CredentialStorageKind.unknown),
  );

  String? _secureFailure;

  ValueListenable<CredentialStorageStatus> get status => _status;

  /// Set at the start of [delete], so it holds however delete ends. After Log
  /// out, this run never resumes the old sign-in (whatever is on disk, even if
  /// the secure read would now throw); the next launch's stale token ends at
  /// the 401 signed-out banner. Cleared by the next successful [save]; a new
  /// instance starts false.
  bool _signedOutThisRun = false;

  bool _clearFailed = false;

  /// True when the last [delete] cleared nothing: the secure delete failed or
  /// the fallback file could not be deleted, AND the signed-out marker could
  /// not be written (delete also threw). False otherwise, including when the
  /// marker file took over. Cleared by a successful [save].
  bool get clearFailed => _clearFailed;

  File get _file => File('${_directory.path}/$fallbackFileName');

  static String _reasonOf(Object error) {
    if (error is PlatformException) {
      return error.message ?? error.code;
    }
    return error.runtimeType.toString();
  }

  CredentialStorageStatus get _fileStatus => CredentialStorageStatus(
    CredentialStorageKind.fallbackFile,
    reason: _secureFailure ?? 'secure storage was unavailable at sign-in',
  );

  /// The stored credentials, or null when signed out. Throws
  /// [CredentialsUnavailableException] when secure storage cannot be read and
  /// no file overrides it.
  Future<Credentials?> read() async {
    if (_signedOutThisRun) return null;
    // Synchronous on purpose: a tiny local file, and it keeps the launch path
    // free of real I/O round-trips.
    final file = _file;
    if (file.existsSync()) {
      final credentials = Credentials.tryParse(file.readAsStringSync());
      if (credentials != null) _status.value = _fileStatus;
      return credentials; // the signed-out marker (or junk) reads as null
    }
    final String? value;
    try {
      value = await _secure.read(secureKey);
    } catch (e) {
      _secureFailure = _reasonOf(e);
      if (secureStorageIsUnusable(e)) return null; // the file is the store
      throw CredentialsUnavailableException(_secureFailure);
    }
    if (value == null) return null;
    final credentials = Credentials.tryParse(value);
    if (credentials != null) {
      _status.value = const CredentialStorageStatus(
        CredentialStorageKind.secure,
      );
    }
    return credentials;
  }

  Future<void> save(Credentials credentials) async {
    final json = jsonEncode(credentials.toJson());
    try {
      await _secure.write(secureKey, json);
    } catch (e) {
      _secureFailure = _reasonOf(e);
      await _writeFallback(json);
      // The file wins anyway; clearing the older secure value is best effort.
      try {
        await _secure.delete(secureKey);
      } catch (_) {}
      _status.value = _fileStatus;
      _signedOutThisRun = false;
      _clearFailed = false;
      return;
    }
    _signedOutThisRun = false;
    _clearFailed = false;
    final file = _file;
    if (await file.exists()) await file.delete();
    _status.value = const CredentialStorageStatus(CredentialStorageKind.secure);
  }

  Future<void> _writeFallback(String content) async {
    await _directory.create(recursive: true);
    final tmp = File(
      '${_directory.path}/$fallbackFileName.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await tmp.create(exclusive: true);
      // iOS and Android cannot spawn processes, and their app containers are
      // private to the app.
      if (Platform.isMacOS || Platform.isLinux) {
        final result = await _runProcess('chmod', ['600', tmp.path]);
        if (result.exitCode != 0) {
          throw FileSystemException(
            'could not restrict the credentials file to its owner',
            tmp.path,
          );
        }
      }
      await tmp.writeAsString(content, flush: true);
      await tmp.rename(_file.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Signs out. If the secure delete fails, an owner-only signed-out marker
  /// file takes its place so the old secure value can never come back; if
  /// that also fails, this throws (a reset reports it).
  Future<void> delete() async {
    _signedOutThisRun = true;
    _clearFailed = false;
    try {
      await _secure.delete(secureKey);
    } catch (e) {
      _secureFailure = _reasonOf(e);
      try {
        await _writeFallback(_signedOutMarker);
      } catch (_) {
        _clearFailed = true;
        rethrow;
      }
      return;
    }
    final file = _file;
    try {
      if (await file.exists()) await _deleteFile(file);
    } catch (_) {
      // The old sign-in must not survive in the file read first at launch.
      try {
        await _writeFallback(_signedOutMarker);
      } catch (_) {
        _clearFailed = true;
        rethrow;
      }
    }
  }

  /// Credentials go with the preferences (SC-15 wipe participant).
  @override
  int get resetPriority => ResetPriority.clearPreferences;

  /// A failure that leaves the old sign-in recoverable propagates so the
  /// reset reports it.
  @override
  Future<void> resetLocalState() => delete();

  Future<void> clearStaleAfterReinstall({
    required bool isIOS,
    required bool hasPrefs,
  }) async {
    if (!isIOS || hasPrefs) return;
    try {
      await _secure.delete(secureKey);
    } catch (e) {
      developer.log(
        'Could not clear stale keychain items: ${_reasonOf(e)}',
        name: 'CredentialStore',
      );
    }
  }
}

/// The process-wide credential store. FrontendApp overrides it with the one
/// store for the app's lifetime.
final credentialStoreProvider = Provider<CredentialStore>(
  (ref) => throw UnimplementedError(
    'credentialStoreProvider must be overridden (FrontendApp does)',
  ),
);
