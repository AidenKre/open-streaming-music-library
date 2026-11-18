// Live gate m-L-04: the macOS project signs ad-hoc (no development team), and
// Xcode refuses to build an app whose entitlements need a development
// certificate. Keychain sharing (`keychain-access-groups`) and every
// `com.apple.developer.*` key are such entitlements. Without them the app
// still builds; secure storage then reports -34018 and the credential store
// uses its owner-only fallback file (README, "Building the app").
//
// Review r2 m-R2-14: a team can also be set in an xcconfig, and once a team
// is set the guard still checks something: every keychain group must be one
// of the team's own (`$(AppIdentifierPrefix)…` or `$(TeamIdentifierPrefix)…`),
// the form the README gives; any other group fails signing.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _entitlementFiles = [
  'macos/Runner/DebugProfile.entitlements',
  'macos/Runner/Release.entitlements',
];

final _keyPattern = RegExp(r'<key>\s*([^<]+?)\s*</key>');

List<String> _entitlementKeys(String plist) => [
  for (final m in _keyPattern.allMatches(plist)) m.group(1)!,
];

/// The `<string>` values of the `keychain-access-groups` array.
List<String> _keychainGroups(String plist) {
  final array = RegExp(
    r'<key>\s*keychain-access-groups\s*</key>\s*<array>(.*?)</array>',
    dotAll: true,
  ).firstMatch(plist);
  if (array == null) return const [];
  return [
    for (final m in RegExp(r'<string>\s*([^<]*?)\s*</string>')
        .allMatches(array.group(1)!))
      m.group(1)!,
  ];
}

bool _needsDevelopmentCertificate(String key) =>
    key == 'keychain-access-groups' || key.startsWith('com.apple.developer.');

bool _isTeamGroup(String group) =>
    group.startsWith(r'$(AppIdentifierPrefix)') ||
    group.startsWith(r'$(TeamIdentifierPrefix)');

/// True when a build setting text (the project file or an xcconfig) names a
/// non-empty development team.
bool _namesTeam(String settings) => RegExp(
  r'^\s*DEVELOPMENT_TEAM\s*=\s*"?([^";\n]*)"?\s*;?\s*$',
  multiLine: true,
).allMatches(settings).any((m) => m.group(1)!.trim().isNotEmpty);

/// The macOS project file plus every xcconfig of the Runner target.
List<String> _macosBuildSettings() => [
  File('macos/Runner.xcodeproj/project.pbxproj').readAsStringSync(),
  for (final f in Directory('macos/Runner/Configs').listSync())
    if (f is File && f.path.endsWith('.xcconfig')) f.readAsStringSync(),
];

/// What would fail signing: with no team, any entitlement that needs a
/// development certificate; with a team, a keychain group not the team's.
List<String> _signingOffenders({
  required bool teamSigned,
  required Map<String, String> entitlements,
}) => [
  for (final MapEntry(key: path, value: plist) in entitlements.entries)
    ...teamSigned
        ? [
            for (final group in _keychainGroups(plist))
              if (!_isTeamGroup(group)) '$path: $group',
          ]
        : [
            for (final key in _entitlementKeys(plist))
              if (_needsDevelopmentCertificate(key)) '$path: $key',
          ],
];

void main() {
  test('the entitlements parser reads the sandbox key from each file', () {
    for (final path in _entitlementFiles) {
      expect(
        _entitlementKeys(File(path).readAsStringSync()),
        contains('com.apple.security.app-sandbox'),
        reason: path,
      );
    }
  });

  test('a team is found in the project file and in an xcconfig', () {
    expect(_namesTeam('\t\t\t\tDEVELOPMENT_TEAM = AB12CD34EF;'), isTrue);
    expect(_namesTeam('\t\t\t\tDEVELOPMENT_TEAM = "";'), isFalse);
    expect(
      _namesTeam('#include "Warnings.xcconfig"\nDEVELOPMENT_TEAM = AB12CD34EF\n'),
      isTrue,
    );
    expect(_namesTeam('// DEVELOPMENT_TEAM is set in Xcode\n'), isFalse);
  });

  group('the signing rule', () {
    const keychain = '<dict><key>keychain-access-groups</key><array>'
        r'<string>$(AppIdentifierPrefix)com.example.app</string>'
        '</array></dict>';
    const foreignGroup = '<dict><key>keychain-access-groups</key><array>'
        '<string>shared.group</string></array></dict>';

    test('ad-hoc: a keychain group is refused', () {
      expect(
        _signingOffenders(teamSigned: false, entitlements: {'a': keychain}),
        ['a: keychain-access-groups'],
      );
    });

    test("team-signed: the team's own group passes, any other is refused", () {
      expect(
        _signingOffenders(teamSigned: true, entitlements: {'a': keychain}),
        isEmpty,
      );
      expect(
        _signingOffenders(teamSigned: true, entitlements: {'b': foreignGroup}),
        ['b: shared.group'],
      );
    });
  });

  test('the macOS project passes the signing rule', () {
    expect(
      _signingOffenders(
        teamSigned: _macosBuildSettings().any(_namesTeam),
        entitlements: {
          for (final path in _entitlementFiles)
            path: File(path).readAsStringSync(),
        },
      ),
      isEmpty,
    );
  });
}
