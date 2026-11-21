// SC-26 strict MVC, enforced on the source: views observe model state and
// send input to their feature controller; they never drive model notifiers
// themselves. Model code never imports ui/.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'));

void main() {
  _boundaryTests();

  test('views do not drive the sync or conversion-job notifiers', () {
    const forbidden = [
      'trackSyncProvider.notifier',
      'conversionJobsProvider.notifier',
    ];
    _expectNamedThingsExist(forbidden);
    final offenders = [
      for (final file in _dartFiles('lib/ui'))
        for (final pattern in forbidden)
          if (file.readAsStringSync().contains(pattern))
            '${file.path}: $pattern',
    ];
    expect(offenders, isEmpty);
  });

  // U34-A-07: every import and export form (package or relative, single or
  // double quotes), through the same directive parser as the view checks.
  // Pre-merge review D5-06: every file under lib/ outside lib/ui/ is model
  // code, found on disk (a new folder is scanned without being listed);
  // only the deliberate exceptions are named.
  test('model code never imports ui/', () {
    final offenders = [
      for (final file in _modelFiles())
        if (!_mayImportUi.containsKey(_libPath(file)))
          for (final target
              in _targets(_libPath(file), file.readAsStringSync()))
            if (target.startsWith('ui/')) '${file.path}: $target',
    ];
    expect(offenders, isEmpty);
  });

  test('the ui/ import exceptions exist and still import ui/', () {
    for (final path in _mayImportUi.keys) {
      final file = File('lib/$path');
      expect(file.existsSync(), isTrue, reason: path);
      expect(
        _targets(path, file.readAsStringSync()).any((t) => t.startsWith('ui/')),
        isTrue,
        reason: '$path no longer imports ui/: drop it from _mayImportUi',
      );
    }
  });

  test('the model scan reaches every folder under lib/ except ui/', () {
    final folders = {
      for (final d in Directory('lib').listSync().whereType<Directory>())
        d.path.substring('lib/'.length),
    }..remove('ui');
    final scanned = {
      for (final f in _modelFiles()) _libPath(f).split('/').first,
    };
    expect(folders, isNotEmpty);
    // A folder with Dart files in it is scanned (an empty one has nothing
    // to scan).
    expect(
      scanned,
      containsAll([
        for (final d in folders)
          if (_dartFiles('lib/$d').isNotEmpty) d,
      ]),
    );
    expect(scanned, isNot(contains('ui')));
  });

  // The test above compares folder names the scan helper itself produces; this
  // one checks the helper against a walk of its own, file by file, so a scan
  // that skipped nested folders or some files would be seen.
  test('the model scan holds every Dart file under lib/ outside ui/, at any '
      'depth', () {
    final expected = <String>{};
    void walk(Directory dir) {
      for (final entry in dir.listSync()) {
        final rel = entry.path.substring('lib/'.length);
        if (entry is Directory) {
          if (rel != 'ui') walk(entry);
        } else if (entry is File &&
            rel.endsWith('.dart') &&
            !rel.endsWith('.g.dart')) {
          expected.add(rel);
        }
      }
    }

    walk(Directory('lib'));
    final scanned = {for (final f in _modelFiles()) _libPath(f)};
    expect(scanned, expected);
    // Files in nested folders, so the walk itself is not shallow.
    expect(expected.where((p) => p.split('/').length > 2), isNotEmpty);
  });

  test('the session controller does no I/O of its own', () {
    final source = File('lib/ui/session_controller.dart').readAsStringSync();
    const names = [
      'AuthApi(',
      'credentialStoreProvider',
      'sharedPreferencesProvider',
      'apiClientProvider',
      'serverBindingRepositoryProvider',
    ];
    _expectNamedThingsExist(names);
    for (final forbidden in names) {
      expect(source.contains(forbidden), isFalse, reason: forbidden);
    }
  });
}

// ---------------------------------------------------------------------------
// Review r1 m-R1-17: the boundary is checked on EVERY view (every file under
// lib/ui/ that is not a controller), whatever the directive style (package or
// relative, single or double quotes, import or export), and on direct
// references to model providers, not only on import strings.
// ---------------------------------------------------------------------------

/// A controller by SC-26's file-and-role rule: `*_controller.dart`, or a file
/// whose class implements a controller interface (`…Controls`).
bool _isController(File file) =>
    file.path.endsWith('_controller.dart') ||
    RegExp(r'implements\s+\w*Controls\b').hasMatch(file.readAsStringSync());

Iterable<File> _views() => _dartFiles('lib/ui').where((f) => !_isController(f));

final _directive = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// The lib-relative targets of every import and export in [source], a file
/// at lib-relative [path]. Relative URIs are resolved; `package:frontend/`
/// is stripped; other packages and `dart:` are dropped.
List<String> _targets(String path, String source) {
  final base = Uri.file('/lib/$path');
  return [
    for (final m in _directive.allMatches(source))
      if (m.group(1)!.startsWith('package:frontend/'))
        m.group(1)!.substring('package:frontend/'.length)
      else if (!m.group(1)!.contains(':'))
        base.resolve(m.group(1)!).path.substring('/lib/'.length),
  ];
}

String _libPath(File f) => f.path.substring('lib/'.length);

/// Every Dart file under lib/ that is not under lib/ui/: the model side.
Iterable<File> _modelFiles() =>
    _dartFiles('lib').where((f) => !_libPath(f).startsWith('ui/'));

/// Model-side files that may import ui/, with the reason. Each must exist
/// and still import ui/ (tested), so the list cannot go stale.
const _mayImportUi = {
  'main.dart': 'the composition root: it starts the app with its root views',
};

/// The things a "never names X" check lists still exist in lib/ (a renamed
/// one would let the check pass without checking anything): a provider is
/// still declared, `Type(` and `Type.member` still name a class (and its
/// member). Import strings are not names and are not checked.
void _expectNamedThingsExist(List<String> patterns) {
  final sources = [for (final f in _dartFiles('lib')) f.readAsStringSync()];
  for (final pattern in patterns) {
    if (pattern.startsWith('import ')) continue;
    final name = pattern.replaceAll(RegExp(r'(\.notifier|\()$'), '');
    if (name.endsWith('Provider')) {
      expect(_declaredInLib(name), isTrue, reason: pattern);
      continue;
    }
    final parts = name.split('.');
    final type = RegExp('\\bclass ${parts.first}\\b');
    final member = parts.length > 1 ? RegExp('\\b${parts[1]}\\(') : null;
    expect(
      sources.any((s) =>
          type.hasMatch(s) && (member == null || member.hasMatch(s))),
      isTrue,
      reason: pattern,
    );
  }
}

/// Whether a top-level `final` or `const` named [name] is declared in lib/.
bool _declaredInLib(String name) {
  final declaration =
      RegExp('^(?:final|const)\\b[^=;]*\\b$name\\s*=', multiLine: true);
  return _dartFiles('lib')
      .any((f) => declaration.hasMatch(f.readAsStringSync()));
}

/// The model's command side: its services, I/O providers and the scope's
/// rebuild hook. A view never names them (SC-26 review greps, Phase M).
const _modelCommandProviders = [
  'databaseProvider',
  'apiClientProvider',
  'unauthenticatedApiClientProvider',
  'credentialsProvider',
  'credentialStoreProvider',
  'sharedPreferencesProvider',
  'sessionServiceProvider',
  'localResetServiceProvider',
  'onSessionChangedProvider',
  'serverBindingRepositoryProvider',
  'serverBindingGateProvider',
];

/// Files that hold model commands; a view importing one is a violation.
const _modelCommandFiles = [
  'services/session_service.dart',
  'services/local_reset_service.dart',
  'services/credential_store.dart',
  'services/server_binding_gate.dart',
  'api/auth_api.dart',
  'api/api_client_provider.dart',
  'repositories/server_binding_repository.dart',
];

/// Views that may import the database library only for a row type they
/// observe through a `watch*` stream (allowed by SC-26). None today: the
/// pending-edits banner observes its controller's view type since
/// APP-OTHER-1 D4.
const _databaseTypeImports = <String>{};

void _boundaryTests() {
  test('the directive parser sees relative, double-quoted and export forms',
      () {
    const source = '''
import "../../services/session_service.dart";
export 'package:frontend/api/auth_api.dart';
import '../session_controller.dart' show SessionControls;
import 'package:flutter/material.dart';
import 'dart:io';
''';
    expect(_targets('ui/widgets/x.dart', source), [
      'services/session_service.dart',
      'api/auth_api.dart',
      'ui/session_controller.dart',
    ]);
  });

  // U34-A-07: a renamed provider or file would silently void a check that
  // names it, so every name on the lists must still exist.
  test('every provider and file the checks name still exists', () {
    final missingProviders = [
      for (final name in _modelCommandProviders)
        if (!_declaredInLib(name)) name,
    ];
    expect(missingProviders, isEmpty);
    final missingFiles = [
      for (final path in [
        ..._modelCommandFiles,
        for (final view in _databaseTypeImports) 'ui/$view',
      ])
        if (!File('lib/$path').existsSync()) path,
    ];
    expect(missingFiles, isEmpty);
  });

  test('every view is found, and the controllers are not views', () {
    final views = _views().map(_libPath).toSet();
    expect(views, containsAll(['ui/startup_gate.dart', 'ui/login_page.dart']));
    expect(views, isNot(contains('ui/session_controller.dart')));
    expect(views, isNot(contains('ui/library_actions.dart')));
  });

  test('no view names a model-command provider or the rebuild hook', () {
    final offenders = [
      for (final file in _views())
        for (final name in _modelCommandProviders)
          if (RegExp('\\b$name\\b').hasMatch(file.readAsStringSync()))
            '${file.path}: $name',
    ];
    expect(offenders, isEmpty);
  });

  test('no view imports or exports a model-command file, in any form', () {
    final offenders = [
      for (final file in _views())
        for (final target
            in _targets(_libPath(file), file.readAsStringSync()))
          if (_modelCommandFiles.contains(target) ||
              (target == 'database/database.dart' &&
                  !_databaseTypeImports.contains(
                      _libPath(file).substring('ui/'.length))))
            '${file.path}: $target',
    ];
    expect(offenders, isEmpty);
  });

  // M-U18: the session views reach the model only through SessionControls
  // (value types from models/ are fine).
  test('the session views import no services, API, repositories or database',
      () {
    const sessionViews = [
      'lib/ui/server_address_page.dart',
      'lib/ui/login_page.dart',
      'lib/ui/create_account_page.dart',
      'lib/ui/startup_gate.dart',
      'lib/ui/session/session_host.dart',
      'lib/ui/widgets/server_blocked_banner.dart',
      'lib/ui/settings/credential_storage_diagnostics_view.dart',
    ];
    final offenders = [
      for (final path in sessionViews)
        for (final target in _targets(
            path.substring('lib/'.length), File(path).readAsStringSync()))
          if (RegExp(r'^(services|api|repositories|database)/')
              .hasMatch(target))
            '$path: $target',
    ];
    expect(offenders, isEmpty);
  });

  // Phase 7B.2b (exit proof): the Uploads views reach the model only for
  // its read-only value types; every input goes through UploadsControls.
  // No view imports a repository, the API, Drift or the upload manager.
  test('the uploads views import no repository, API, database or manager',
      () {
    final views = [
      for (final f in _views())
        if (_libPath(f).startsWith('ui/uploads/')) f,
    ];
    expect(views.map(_libPath), contains('ui/uploads/uploads_page.dart'));
    const valueTypes = {
      'services/uploads/uploads_overview.dart',
      'services/uploads/upload_zip_children.dart',
      // 7B.2d: the duplicate banners and the review item view are pure
      // computed values (no provider, no I/O).
      'services/uploads/upload_duplicate_banners.dart',
      'services/uploads/upload_review_rules.dart',
    };
    const modelProviders = [
      'uploadManagerProvider',
      'uploadsApiProvider',
      'uploadSourcePickerProvider',
      'uploadsVisibilityProvider',
      'uploadIntentsProvider',
      'uploadIntentStoreProvider',
      'uploadZipChildrenProvider',
      'uploadsOverviewProvider',
      'uploadOtherDeviceSendingProvider',
    ];
    // U34-A-07: a stale name on either list would void its check.
    for (final path in valueTypes) {
      expect(File('lib/$path').existsSync(), isTrue, reason: path);
    }
    for (final name in modelProviders) {
      expect(_declaredInLib(name), isTrue, reason: name);
    }
    final offenders = [
      for (final file in views) ...[
        for (final target
            in _targets(_libPath(file), file.readAsStringSync()))
          if (RegExp(r'^(services|api|repositories|database)/')
                  .hasMatch(target) &&
              !valueTypes.contains(target))
            '${file.path}: $target',
        for (final name in modelProviders)
          if (RegExp('\\b$name\\b').hasMatch(file.readAsStringSync()))
            '${file.path}: $name',
      ],
    ];
    expect(offenders, isEmpty);
  });

  test('the uploads controller does no I/O of its own', () {
    final source =
        File('lib/ui/uploads/uploads_controller.dart').readAsStringSync();
    const names = [
      "import 'dart:io'",
      'uploadsApiProvider',
      'apiClientProvider',
      'databaseProvider',
      'uploadIntentStoreProvider',
      'FileUploadSource.open',
    ];
    _expectNamedThingsExist(names);
    for (final forbidden in names) {
      expect(source.contains(forbidden), isFalse, reason: forbidden);
    }
  });

  // 7B.2c: the review controller reaches the model only through the review
  // model, the preview controller and observed providers; the review page is
  // a view under ui/uploads/ and is covered by the uploads view check above.
  test('the review controller does no I/O of its own', () {
    final source = File('lib/ui/uploads/upload_review_controller.dart')
        .readAsStringSync();
    const names = [
      "import 'dart:io'",
      'uploadsApiProvider',
      'apiClientProvider',
      'databaseProvider',
      'uploadIntentStoreProvider',
      'uploadManagerProvider',
      'browseRepositoryProvider',
      'trackSyncProvider',
      'editOutboxProvider',
    ];
    _expectNamedThingsExist(names);
    for (final forbidden in names) {
      expect(source.contains(forbidden), isFalse, reason: forbidden);
    }
    expect(
      _views().map(_libPath),
      contains('ui/uploads/upload_review_page.dart'),
    );
  });

  // Review r1 m-R1-55: the process-wide client is gone for good (SC-27
  // invariant 14); only scope-bound clients exist.
  test('no code uses ApiClient.instance or ApiClient.init', () {
    final offenders = [
      for (final file in _dartFiles('lib'))
        if (RegExp(r'ApiClient\s*\.\s*(instance|init)\b')
            .hasMatch(file.readAsStringSync()))
          file.path,
    ];
    expect(offenders, isEmpty);
  });
}
