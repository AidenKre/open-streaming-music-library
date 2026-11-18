// Sign-off OPEN-A-05 (alternative 2): the user types the server address, so
// the app may reach an `http://` server on Android, iOS and macOS, app-wide.
// This pins that choice in the three platform files; changing any of them
// fails here.
//
// - Android: `android:usesCleartextTraffic="true"` on the main manifest's
//   application element. A `networkSecurityConfig` would replace that
//   attribute on Android 7 and later, so none is set, and no other source
//   set's manifest (debug, profile, or any later build type or flavor,
//   merged over the main one) sets either.
// - iOS and macOS: App Transport Security holds exactly
//   `NSAllowsArbitraryLoads` = true. `NSAllowsLocalNetworking`,
//   `NSAllowsArbitraryLoadsForMedia` or `NSAllowsArbitraryLoadsInWebContent`
//   would make the system ignore it, so no other key is allowed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _androidMain = 'android/app/src/main/AndroidManifest.xml';

/// Every source set's manifest except the main one (debug, profile, and any
/// build type or flavor added later).
List<String> _androidOverlays() => [
  for (final dir in Directory('android/app/src').listSync())
    if (dir is Directory && File('${dir.path}/AndroidManifest.xml').existsSync())
      '${dir.path}/AndroidManifest.xml',
]..removeWhere((p) => p.endsWith('/main/AndroidManifest.xml'));
const _applePlists = ['ios/Runner/Info.plist', 'macos/Runner/Info.plist'];

/// The opening `<application …>` tag of [manifest], or null.
String? _applicationTag(String manifest) =>
    RegExp(r'<application\b[^>]*>').firstMatch(manifest)?.group(0);

/// The value of `android:[name]` in [tag], or null when absent.
String? _androidAttribute(String tag, String name) => RegExp(
  'android:${RegExp.escape(name)}\\s*=\\s*"([^"]*)"',
).firstMatch(tag)?.group(1);

/// The ATS dictionary as key → `true`/`false` (other value types as their
/// element name), or null when the plist has no ATS entry.
Map<String, String>? _atsEntries(String plist) {
  final dict = RegExp(
    r'<key>\s*NSAppTransportSecurity\s*</key>\s*<dict>(.*?)</dict>',
    dotAll: true,
  ).firstMatch(plist);
  if (dict == null) return null;
  return {
    for (final m in RegExp(
      r'<key>\s*([^<]+?)\s*</key>\s*<([A-Za-z]+)',
    ).allMatches(dict.group(1)!))
      m.group(1)!: m.group(2)!,
  };
}

void main() {
  group('Android', () {
    late String manifest;
    setUp(() => manifest = File(_androidMain).readAsStringSync());

    test('the main manifest allows plain HTTP app-wide', () {
      final tag = _applicationTag(manifest);
      expect(tag, isNotNull);
      expect(_androidAttribute(tag!, 'usesCleartextTraffic'), 'true');
    });

    test('no network security config replaces that setting', () {
      expect(manifest.contains('networkSecurityConfig'), isFalse);
    });

    test('the overlay manifests are found', () {
      expect(
        _androidOverlays(),
        containsAll([
          'android/app/src/debug/AndroidManifest.xml',
          'android/app/src/profile/AndroidManifest.xml',
        ]),
      );
    });

    for (final path in _androidOverlays()) {
      test('$path does not override it', () {
        final overlay = File(path).readAsStringSync();
        expect(overlay.contains('usesCleartextTraffic'), isFalse);
        expect(overlay.contains('networkSecurityConfig'), isFalse);
      });
    }
  });

  for (final path in _applePlists) {
    test('$path allows arbitrary loads and nothing that cancels it', () {
      expect(_atsEntries(File(path).readAsStringSync()), {
        'NSAllowsArbitraryLoads': 'true',
      });
    });
  }

  test('the readers see a change', () {
    expect(
      _androidAttribute(
        _applicationTag(
          '<manifest><application android:usesCleartextTraffic="false" '
          'android:label="x"></application></manifest>',
        )!,
        'usesCleartextTraffic',
      ),
      'false',
    );
    expect(
      _atsEntries(
        '<dict><key>NSAppTransportSecurity</key><dict>'
        '<key>NSAllowsArbitraryLoads</key><false/>'
        '<key>NSAllowsLocalNetworking</key><true/></dict></dict>',
      ),
      {'NSAllowsArbitraryLoads': 'false', 'NSAllowsLocalNetworking': 'true'},
    );
    expect(_atsEntries('<dict></dict>'), isNull);
  });
}
