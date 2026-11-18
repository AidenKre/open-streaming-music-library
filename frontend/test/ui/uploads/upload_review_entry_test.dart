// Phase 7B.2c S12: where the review starts (7B.2b hand-over: the page's
// _reviewTags pushes the review route). `Review tags` on an Uploads row
// opens the review of that row's batch at that file; a ready file of an
// unpacked ZIP gets its own `Review tags` in the archive's file list (a ZIP
// child is reviewed like any item, 7A.2d), opening the same review at that
// file. Network-gated like every other review input.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/uploads/upload_zip_children.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';
import 'package:frontend/ui/preview_controller.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/uploads/upload_review_controller.dart';
import 'package:frontend/ui/uploads/upload_review_page.dart';
import 'package:frontend/ui/uploads/uploads_controller.dart';
import 'package:frontend/ui/uploads/uploads_page.dart';

import '../../helpers/fake_uploads_api.dart';
import '../browse_harness.dart';
import '../fake_session_controls.dart';
import '../fake_upload_review_controls.dart';
import '../fake_uploads_controls.dart';

class _Preview implements PreviewControls {
  @override
  Future<void> playStaged(String itemUuid) async {}
  @override
  Future<void> playLibraryTrack(String trackUuid) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> close() async {}
}

void main() {
  test('a ready file of an archive, or one that needs a duplicate decision '
      '(7B.2d), offers Review tags; others do not',
      () async {
    final api = FakeUploadsApi();
    Map<String, dynamic> child(String uuid, String state) => {
      ...itemJson(uuid, state: state, filename: '$uuid.flac'),
      'parent_item_uuid': 'zip',
      'member_order_key': '$uuid.flac',
    };
    api.onListItems = (batch, after) async => UploadItemPage.fromJson({
      'items': [
        child('c1', 'review_ready'),
        child('c2', 'validating'),
        child('c3', 'imported'),
        child('c4', 'duplicate_conflict'),
      ],
      'next_after': null,
    });

    final zip = await UploadZipChildren(api).load('b-1', 'zip');

    expect([for (final c in zip.children) c.offersReviewTags],
        [true, false, false, true]);
  });

  group('opening the review', () {
    late AppDatabase db;
    late BrowseHarness harness;
    late FakeUploadsControls uploads;
    late FakeUploadReviewControls review;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      harness = await BrowseHarness.create(db);
      review = FakeUploadReviewControls();
    });
    tearDown(() async {
      await harness.dispose();
      await db.close();
    });

    Future<void> pump(WidgetTester tester, UploadsOverview overview) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      uploads = FakeUploadsControls(overview: overview);
      await tester.pumpWidget(harness.wrap(
        const UploadsPage(),
        appInfo: defaultAppInfo(),
        overrides: [
          uploadsControllerFactoryProvider.overrideWithValue(() => uploads),
          sessionControlsProvider.overrideWithValue(FakeSessionControls()),
          uploadReviewControllerFactoryProvider.overrideWithValue(() => review),
          previewControlsProvider.overrideWithValue(_Preview()),
        ],
      ));
      await tester.pump();
    }

    testWidgets("Review tags opens the review of the row's batch at that file",
        (tester) async {
      await pump(tester, fakeUploadsOverview([
        fakeUploadRow('c', batch: 'b-7', reviewTags: true),
      ]));
      await tester.tap(find.text('Review tags'));
      await tester.pumpAndSettle();

      expect(find.byType(UploadReviewPage), findsOneWidget);
      expect(review.calls, contains('start b-7 c'));
      await teardownTree(tester);
    });

    UploadChildRow childRow(String uuid, {bool review = false}) =>
        UploadChildRow(
          itemUuid: uuid,
          displayName: '$uuid.flac',
          statusText: review ? 'Ready for review' : 'Checking',
          detailText: null,
          needsAttention: false,
          offersReviewTags: review,
        );

    ZipChildren zip(List<UploadChildRow> rows) => ZipChildren(
      children: rows,
      valid: 1,
      failed: 0,
      checking: 1,
      cancelled: 0,
      skipped: null,
    );

    Future<void> openFiles(WidgetTester tester, UploadsOverview overview) async {
      await pump(tester, overview);
      await tester.tap(find.text('Show files'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      uploads.setChildren('zip',
          ChildListLoaded(zip([childRow('c1', review: true), childRow('c2')])));
      await tester.pump();
    }

    testWidgets('a ready file of an archive opens the same review at that '
        'file', (tester) async {
      await openFiles(tester, fakeUploadsOverview([
        fakeUploadRow('zip', batch: 'b-3', name: 'album.zip', children: true),
      ]));
      final row = find.byKey(const ValueKey('upload-child-c1'));
      expect(find.descendant(of: row, matching: find.text('Review tags')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('upload-child-c2')),
              matching: find.text('Review tags')),
          findsNothing);

      await tester.tap(find.descendant(of: row, matching: find.text('Review tags')));
      await tester.pumpAndSettle();

      expect(find.byType(UploadReviewPage), findsOneWidget);
      expect(review.calls, contains('start b-3 c1'));
      await teardownTree(tester);
    });

    testWidgets("an archive file's Review tags is off without the network",
        (tester) async {
      await openFiles(
        tester,
        fakeUploadsOverview([
          fakeUploadRow('zip', batch: 'b-3', name: 'album.zip', children: true),
        ]),
      );
      uploads.set(
        overview: fakeUploadsOverview(
          [fakeUploadRow('zip', batch: 'b-3', name: 'album.zip', children: true,
              enabled: false)],
          availability: UploadsAvailability.offline,
        ),
      );
      await tester.pump();
      final button = tester.widget<TextButton>(find.ancestor(
          of: find.text('Review tags'), matching: find.byType(TextButton)));
      expect(button.onPressed, isNull);
      await teardownTree(tester);
    });
  });
}
