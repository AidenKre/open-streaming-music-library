// Phase 9D.2e S9: source checks for the Last.fm terms and the layering.
//  * Spec §7.12: "No Last.fm logo or artwork. Clause 7.1 requires written
//    approval for its marks." Exit proof: no asset whose name or content
//    matches Last.fm marks.
//  * Spec §7.12 / plan O5: URLs open through a platform adapter
//    (`url_launcher`); the model owns it. Brief: no URL other than the
//    validated authorization URL and the fixed and profile links reaches the
//    launcher, so the adapter has exactly one caller.
//  * SC-26: the view imports no API or launcher; the model imports nothing
//    from ui/.
// Runs from the `frontend/` folder (flutter test's working directory).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _marks = RegExp(r'last[\W_]?fm|audioscrobbler|scrobbl', caseSensitive: false);

const _assetExtensions = {
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.ico', '.icns', '.bmp',
  '.pdf', '.ttf', '.otf', '.woff', '.woff2', '.riv', '.json',
};

const _skipDirs = {'build', '.dart_tool', 'Pods', '.git', '.symlinks',
  'ephemeral', 'test'};

Iterable<File> _files(Directory root) sync* {
  for (final e in root.listSync(followLinks: false)) {
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (e is Directory) {
      if (_skipDirs.contains(name)) continue;
      yield* _files(e);
    } else if (e is File) {
      yield e;
    }
  }
}

String _ext(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot).toLowerCase();
}

List<String> _dartFiles(String dir) => [
  for (final f in _files(Directory(dir)))
    if (f.path.endsWith('.dart')) f.path,
];

List<String> _importing(String needle) => [
  for (final p in _dartFiles('lib'))
    if (File(p).readAsLinesSync().any(
      (l) => l.trimLeft().startsWith('import') && l.contains(needle),
    ))
      p,
];

void main() {
  test('no asset of the app is named after or contains a Last.fm mark', () {
    final offenders = <String>[];
    var checked = 0;
    for (final f in _files(Directory('.'))) {
      if (!_assetExtensions.contains(_ext(f.path))) continue;
      checked++;
      final name = f.uri.pathSegments.last;
      if (_marks.hasMatch(name)) offenders.add(f.path);
      final ext = _ext(f.path);
      if (ext == '.svg' || ext == '.json' || ext == '.pdf') {
        final text = String.fromCharCodes(f.readAsBytesSync());
        if (_marks.hasMatch(text)) offenders.add('${f.path} (content)');
      }
    }
    expect(checked, greaterThan(0), reason: 'the scan found the app icons');
    expect(offenders, isEmpty);
  });

  test('pubspec declares no Last.fm asset or font', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(_marks.hasMatch(pubspec), isFalse);
  });

  test('url_launcher is imported only by the platform adapter', () {
    expect(_importing('package:url_launcher'),
        ['lib/services/external_browser.dart']);
  });

  test('the adapter is used only by the Last.fm links', () {
    expect(_importing('services/external_browser.dart'),
        ['lib/services/lastfm/lastfm_links.dart']);
  });

  test('the Integrations view and controller import no API and no '
      'launcher', () {
    for (final p in _dartFiles('lib/ui/integrations')) {
      final imports = File(p)
          .readAsLinesSync()
          .where((l) => l.trimLeft().startsWith('import'))
          .join('\n');
      expect(imports, isNot(contains('package:frontend/api/')), reason: p);
      expect(imports, isNot(contains('url_launcher')), reason: p);
      expect(imports, isNot(contains('external_browser')), reason: p);
    }
  });

  test('the views do not call the model or open links themselves', () {
    for (final p in _dartFiles('lib/ui/integrations')) {
      if (p.endsWith('_controller.dart')) continue;
      final src = File(p).readAsStringSync();
      expect(src, isNot(contains('lastfmServiceProvider')), reason: p);
      expect(src, isNot(contains('lastfmLinksProvider')), reason: p);
      expect(src, isNot(contains('lastfmApiProvider')), reason: p);
    }
  });

  test('the Last.fm model imports nothing from ui/', () {
    for (final p in [
      ..._dartFiles('lib/services/lastfm'),
      'lib/services/external_browser.dart',
    ]) {
      expect(File(p).readAsStringSync(),
          isNot(contains('package:frontend/ui/')), reason: p);
    }
  });
}
