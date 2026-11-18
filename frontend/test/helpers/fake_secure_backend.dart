import 'package:flutter/services.dart';
import 'package:frontend/services/credential_store.dart';

/// An in-memory stand-in for the platform secure storage. Tests never touch
/// the real keychain (rules §10).
class FakeSecureBackend implements SecureCredentialBackend {
  final Map<String, String> values = {};

  /// When set, the matching operation throws it (for example the macOS
  /// `-34018` "missing entitlement" error of an unsigned build).
  Object? readError;
  Object? writeError;
  Object? deleteError;

  final List<String> calls = [];

  /// Fails every operation like a keychain an ad-hoc build may not use.
  void makeUnusable() {
    final e = PlatformException(
      code: 'Unexpected security result code',
      message: 'Code: -34018, Message: A required entitlement isn\'t present.',
    );
    readError = e;
    writeError = e;
    deleteError = e;
  }

  @override
  Future<String?> read(String key) async {
    calls.add('read $key');
    if (readError != null) throw readError!;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    calls.add('write $key');
    if (writeError != null) throw writeError!;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    calls.add('delete $key');
    if (deleteError != null) throw deleteError!;
    values.remove(key);
  }
}
