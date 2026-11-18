// 8B.1c S10: how Manage library is reached, and where server deletion can
// NOT be reached.
//  * Spec §6 para 1: "Settings -> Library tools -> Manage library: a row
//    contributed to the Library tools section through the SC-21 registry
//    (no SettingsPage edit) that opens SessionDestination.manageLibrary
//    (SC-08)". Available when the `library_tools` block is present (SC-21).
//  * SC-18: "separated UI (Manage library, never player menus)"; exit proof
//    "a grep over the session destinations shows no server delete in any
//    ordinary menu"; review 8-U07 "no ordinary-menu server delete".
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/ui/manage_library/manage_library_controller.dart';
import 'package:frontend/ui/manage_library/manage_library_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/settings/settings_registry.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';
import 'fake_manage_library_controls.dart';

SettingsRowContribution _manageRow(ProviderContainer c) =>
    c.read(settingsRowsProvider).singleWhere(
      (r) =>
          r.sectionId == 'library_tools' &&
          r.isAvailable == libraryToolsAdvertisedProvider,
    );

void main() {
  group('the Library tools row', () {
    test('is contributed to Library tools and is available exactly when the '
        'server advertises library_tools', () {
      for (final advertised in [true, false]) {
        final c = ProviderContainer(
          overrides: [
            libraryToolsAdvertisedProvider.overrideWithValue(advertised),
          ],
        );
        final row = _manageRow(c);
        expect(c.read(row.isAvailable!), advertised);
        c.dispose();
      }
    });

    late AppDatabase db;
    late BrowseHarness h;
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      h = await BrowseHarness.create(db);
    });
    tearDown(() async {
      await h.dispose();
      await db.close();
    });

    testWidgets('opens SessionDestination.manageLibrary', (tester) async {
      final fake = FakeManageLibraryControls();
      final c = ProviderContainer();
      final row = _manageRow(c);
      c.dispose();
      await tester.pumpWidget(
        h.wrap(
          SessionHost(
            root: Scaffold(body: Builder(builder: row.build)),
          ),
          overrides: [
            sessionControlsProvider.overrideWithValue(FakeSessionControls()),
            manageLibraryControllerFactoryProvider.overrideWithValue(
              () => fake,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manage library'));
      await tester.pumpAndSettle();
      expect(find.byType(ManageLibraryPage), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(ManageLibraryPage)))!
            .settings
            .name,
        'session/manageLibrary',
      );
      await teardownTree(tester);
    });
  });

  test('the destination builds the Manage library page', () {
    expect(
      sessionDestinationPage(SessionDestination.manageLibrary),
      isA<ManageLibraryPage>(),
    );
  });

  group('no server delete anywhere else (grep)', () {
    // The only homes of server deletion: its model, its API, the Manage
    // library page, and Possible duplicates' "Delete this copy" (8B.3, which
    // opens the same single-track review).
    bool allowed(String path) =>
        path.startsWith('lib/services/deletion/') ||
        path == 'lib/api/library_tools_api.dart' ||
        path.startsWith('lib/ui/manage_library/') ||
        path.startsWith('lib/ui/duplicates/');

    final dartFiles = [
      for (final f in Directory('lib').listSync(recursive: true))
        if (f is File && f.path.endsWith('.dart')) f,
    ];

    test('only the allowed files reach the delete-jobs model, its API or '
        'the review flow', () {
      final symbols = RegExp(
        r'deleteJobsManagerProvider|DeleteJobsManager\b|libraryToolsApiProvider|'
        r'DeletionReviewControls|showDeletionReview|createJob\(|'
        r'deletion_review_sheet\.dart|delete_jobs_manager\.dart',
      );
      final offenders = [
        for (final f in dartFiles)
          if (!allowed(f.path) && symbols.hasMatch(f.readAsStringSync()))
            f.path,
      ];
      expect(offenders, isEmpty);
    });

    test('no other file says it deletes from the server', () {
      final words = RegExp(
        r'from the server permanently|Delete from server|delete from the server',
        caseSensitive: false,
      );
      final offenders = [
        for (final f in dartFiles)
          if (!allowed(f.path) && words.hasMatch(f.readAsStringSync())) f.path,
      ];
      expect(offenders, isEmpty);
    });

    test('the session destinations reach deletion only through Manage '
        'library', () {
      final host = File('lib/ui/session/session_host.dart').readAsStringSync();
      expect(host, isNot(contains('deletion_review')));
      expect(host, isNot(contains('DeleteJobs')));
      expect(
        RegExp(r'SessionDestination\.manageLibrary\s*=>\s*const ManageLibraryPage\(\)')
            .hasMatch(host),
        isTrue,
      );
    });
  });
}
