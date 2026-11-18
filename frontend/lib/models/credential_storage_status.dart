import 'package:flutter/foundation.dart' show immutable;

enum CredentialStorageKind { unknown, secure, fallbackFile }

@immutable
class CredentialStorageStatus {
  const CredentialStorageStatus(this.kind, {this.reason});
  final CredentialStorageKind kind;
  final String? reason;

  String get diagnosticsLine => switch (kind) {
    CredentialStorageKind.unknown => 'Sign-in storage has not been checked.',
    CredentialStorageKind.secure => 'Sign-in is stored in secure storage.',
    CredentialStorageKind.fallbackFile =>
      'Sign-in is stored in an owner-only file because secure storage is '
          'unavailable (${reason ?? 'unknown reason'}).',
  };
}
