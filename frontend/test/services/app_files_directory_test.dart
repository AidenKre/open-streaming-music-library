// The downloads (`tracks/`) and stored covers (`cover_art/`) live in
// the app's own folder. On Linux and Windows the documents folder is the
// person's own Documents folder, which a reset would empty, so
// there the app uses its support folder (where the database already is).
// macOS (sandboxed), iOS and Android keep the documents folder.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/app_files_directory.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _selector = 'lib/services/app_files_directory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the folder for downloads and stored covers', () {
    for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
      test('is the support folder on ${platform.name}', () {
        expect(appFilesDirectoryFor(platform),
            equals(getApplicationSupportDirectory));
      });
    }

    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      test('is the documents folder on ${platform.name}, as before', () {
        expect(appFilesDirectoryFor(platform),
            equals(getApplicationDocumentsDirectory));
      });
    }
  });

  // The app's own lookup follows the platform it runs on.
  group('appFilesDirectory on this device', () {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final asked = <String>[];

    setUp(() {
      asked.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        asked.add(call.method);
        return '/no-such-folder/${call.method}';
      });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    for (final (platform, method) in [
      (TargetPlatform.linux, 'getApplicationSupportDirectory'),
      (TargetPlatform.windows, 'getApplicationSupportDirectory'),
      (TargetPlatform.android, 'getApplicationDocumentsDirectory'),
    ]) {
      test('asks for $method on ${platform.name}', () async {
        debugDefaultTargetPlatformOverride = platform;
        await appFilesDirectory();
        expect(asked, [method]);
      });
    }
  });

  // Where the downloads and stored covers are kept is decided in one place,
  // the selector. This reads every `.dart` file under lib/ (comment lines
  // skipped) for the path_provider getters that could be that place, as
  // whole words (a call, a tear-off or a prefixed `pp.` use), and counts
  // them per file:
  //  * getApplicationDocumentsDirectory, getLibraryDirectory,
  //    getDownloadsDirectory, getExternalStorageDirectory and
  //    getExternalStorageDirectories: only in the selector;
  //  * getApplicationSupportDirectory (the selector's answer on Linux and
  //    Windows): in the selector and once each in the two files that keep
  //    other things there, lib/main.dart (the credential fallback file and
  //    the session log) and lib/database/database.dart (the database file);
  //  * the platform interface's own `get…Path` methods for the same folders:
  //    nowhere.
  // Not matched: getTemporaryDirectory, getApplicationCacheDirectory and
  // getExternalCacheDirectories (scratch and cache folders, as the recap
  // export uses). A new use of a matched getter is added here on purpose.
  test('no file under lib/ other than the selector asks path_provider for a '
      'folder downloads or covers could be kept in', () {
    const getters = [
      'getApplicationDocumentsDirectory',
      'getApplicationSupportDirectory',
      'getLibraryDirectory',
      'getDownloadsDirectory',
      'getExternalStorageDirectory',
      'getExternalStorageDirectories',
      'getApplicationDocumentsPath',
      'getApplicationSupportPath',
      'getLibraryPath',
      'getDownloadsPath',
      'getExternalStoragePath',
      'getExternalStoragePaths',
    ];
    final word = RegExp('\\b(${getters.join('|')})\\b');
    final found = <String, Map<String, int>>{};
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      for (final line in f.readAsLinesSync()) {
        if (line.trimLeft().startsWith('//')) continue;
        for (final m in word.allMatches(line)) {
          found
              .putIfAbsent(m.group(1)!, () => {})
              .update(p.posix.joinAll(p.split(f.path)), (n) => n + 1,
                  ifAbsent: () => 1);
        }
      }
    }
    expect(found, {
      'getApplicationDocumentsDirectory': {_selector: 1},
      'getApplicationSupportDirectory': {
        _selector: 1,
        'lib/main.dart': 1,
        'lib/database/database.dart': 1,
      },
    });
  });
}
