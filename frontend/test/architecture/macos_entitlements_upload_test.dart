// Phase 7 (DEV-7-03, plan O6): a sandboxed macOS app can read a file the
// user picked only with a `com.apple.security.files.user-selected.*`
// entitlement. Phase 9 (decision O5, DEV-9-02) moved it from read-only to
// read-write: the recap's Save panel writes the file the user chose, and
// read-write includes read, so the upload picker keeps working. The
// read-only key is gone so the two never disagree. Both entitlement files
// carry the same rule.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _entitlementFiles = [
  'macos/Runner/DebugProfile.entitlements',
  'macos/Runner/Release.entitlements',
];

/// The value element right after `<key>[key]</key>`, or null when absent.
String? _valueOf(String plist, String key) {
  final match = RegExp(
    '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<(true|false)\\s*/>',
  ).firstMatch(plist);
  return match?.group(1);
}

/// Sign-off OPEN-A-10: every entitlement each file may hold, so no
/// permission is added without changing this list. The microphone
/// (`com.apple.security.audio-input`) was removed: no feature records audio.
/// JIT and the incoming-network server are debug/profile only (Flutter's
/// tooling and Dart VM service).
const _allowedEntitlements = {
  'macos/Runner/DebugProfile.entitlements': {
    'com.apple.security.app-sandbox',
    'com.apple.security.cs.allow-jit',
    'com.apple.security.network.server',
    'com.apple.security.network.client',
    'com.apple.security.files.user-selected.read-write',
  },
  'macos/Runner/Release.entitlements': {
    'com.apple.security.app-sandbox',
    'com.apple.security.network.client',
    'com.apple.security.files.user-selected.read-write',
  },
};

/// The one key a file may add beyond its list: the README's documented way
/// to turn the Keychain on for a team-signed build. macos_signing_test.dart
/// polices it (refused while the project has no team).
const _optionalEntitlement = 'keychain-access-groups';

/// Every `<key>` in [plist], in order.
List<String> _keysOf(String plist) => [
  for (final m in RegExp(r'<key>\s*([^<]+?)\s*</key>').allMatches(plist))
    m.group(1)!,
];

void main() {
  for (final path in _entitlementFiles) {
    group(path, () {
      late String plist;
      setUp(() => plist = File(path).readAsStringSync());

      test('grants read-write access to user-selected files', () {
        expect(
          _valueOf(plist, 'com.apple.security.files.user-selected.read-write'),
          'true',
        );
      });

      test('carries no separate read-only key', () {
        expect(
          plist.contains('com.apple.security.files.user-selected.read-only'),
          isFalse,
        );
      });

      test('keeps the app sandbox on', () {
        expect(_valueOf(plist, 'com.apple.security.app-sandbox'), 'true');
      });

      test('holds exactly its listed entitlements, each granted', () {
        final keys = _keysOf(plist)
            .where((k) => k != _optionalEntitlement)
            .toList();
        expect(keys.toSet(), _allowedEntitlements[path]);
        expect(keys, hasLength(_allowedEntitlements[path]!.length));
        for (final key in keys) {
          expect(_valueOf(plist, key), 'true', reason: key);
        }
      });

      test('never asks for the microphone', () {
        expect(plist.contains('com.apple.security.audio-input'), isFalse);
        expect(plist.contains('com.apple.security.device.audio-input'),
            isFalse);
        expect(plist.contains('com.apple.security.device.microphone'),
            isFalse);
      });
    });
  }

  test('the key reader sees an added permission', () {
    expect(
      _keysOf(
        '<dict><key>com.apple.security.app-sandbox</key><true/>'
        '<key> com.apple.security.device.camera </key><true/></dict>',
      ),
      ['com.apple.security.app-sandbox', 'com.apple.security.device.camera'],
    );
  });
}
