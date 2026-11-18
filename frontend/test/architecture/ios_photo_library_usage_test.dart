// Pre-merge review H1-04 (owner, 2026-11-18): on iOS the Year in music image
// is shared as a PNG, and the share sheet offers "Save Image". iOS ends an
// app that saves to Photos without a usage description, so the iOS
// Info.plist carries `NSPhotoLibraryAddUsageDescription` with the approved
// text. macOS adds nothing: the app saves there through the save panel (the
// user-selected read-write entitlement), and its share sheet hands the file
// to the service the person picks; the app itself never writes to Photos.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _key = 'NSPhotoLibraryAddUsageDescription';
const _approved = 'Lets you save your Year in music image to Photos.';

/// The `<string>` value of [key] at the top level of [plist], or null.
String? _stringValue(String plist, String key) => RegExp(
  '<key>\\s*${RegExp.escape(key)}\\s*</key>\\s*<string>([^<]*)</string>',
).firstMatch(plist)?.group(1);

void main() {
  test('the recap image is shared as a PNG (the reason for the key)', () {
    final source =
        File('lib/services/recap_export_platform.dart').readAsStringSync();
    expect(source, contains("'image/png'"));
  });

  test('the iOS Info.plist says why the app saves to Photos, in the '
      'approved words', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(_stringValue(plist, _key), _approved);
    expect(RegExp('<key>$_key</key>').allMatches(plist), hasLength(1));
  });
}
