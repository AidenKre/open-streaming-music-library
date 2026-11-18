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
    final offenders = [
      for (final file in _dartFiles('lib/ui'))
        for (final pattern in forbidden)
          if (file.readAsStringSync().contains(pattern))
            '${file.path}: $pattern',
    ];
    expect(offenders, isEmpty);
  });

  test('model code never imports ui/', () {
    final offenders = [
      for (final dir in [
        'lib/api',
        'lib/database',
        'lib/models',
        'lib/playback',
        'lib/providers',
        'lib/repositories',
        'lib/services',
      ])
        for (final file in _dartFiles(dir))
          if (file.readAsStringSync().contains("import 'package:frontend/ui/"))
            file.path,
    ];
    expect(offenders, isEmpty);
  });

  // Phase M §7.1 / M-U18: the session screens are views over SessionControls.
  // They import no model layer (no services, API, repositories or database),
  // so they can neither authenticate nor read credentials themselves.
  test('the session screens import no model code', () {
    const views = [
      'lib/ui/server_address_page.dart',
      'lib/ui/login_page.dart',
      'lib/ui/create_account_page.dart',
    ];
    const modelImports = [
      "import 'package:frontend/services/",
      "import 'package:frontend/api/",
      "import 'package:frontend/repositories/",
      "import 'package:frontend/database/",
    ];
    final offenders = [
      for (final path in views)
        for (final pattern in modelImports)
          if (File(path).readAsStringSync().contains(pattern)) '$path: $pattern',
    ];
    expect(offenders, isEmpty);
  });

  test('the session controller does no I/O of its own', () {
    final source = File('lib/ui/session_controller.dart').readAsStringSync();
    for (final forbidden in [
      'AuthApi(',
      'credentialStoreProvider',
      'sharedPreferencesProvider',
      'apiClientProvider',
      'serverBindingRepositoryProvider',
    ]) {
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

/// Existing views that import the database library only for a row type
/// they observe through a `watch*` stream (allowed by SC-26).
const _databaseTypeImports = {'widgets/pending_edits_banner.dart'};

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
    for (final forbidden in [
      "import 'dart:io'",
      'uploadsApiProvider',
      'apiClientProvider',
      'databaseProvider',
      'uploadIntentStoreProvider',
      'FileUploadSource.open',
    ]) {
      expect(source.contains(forbidden), isFalse, reason: forbidden);
    }
  });

  // 7B.2c: the review controller reaches the model only through the review
  // model, the preview controller and observed providers; the review page is
  // a view under ui/uploads/ and is covered by the uploads view check above.
  test('the review controller does no I/O of its own', () {
    final source = File('lib/ui/uploads/upload_review_controller.dart')
        .readAsStringSync();
    for (final forbidden in [
      "import 'dart:io'",
      'uploadsApiProvider',
      'apiClientProvider',
      'databaseProvider',
      'uploadIntentStoreProvider',
      'uploadManagerProvider',
      'browseRepositoryProvider',
      'trackSyncProvider',
      'editOutboxProvider',
    ]) {
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
