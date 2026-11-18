// Phase 7 §7 para 3 / 7-U09 (page) / SC-26: the Uploads page renders only
// what `UploadsControls` says (counts, per-item bytes, progress, status and
// error) and forwards every input to it. Widget tests over a fake controller.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/uploads/upload_zip_children.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';
import 'package:frontend/models/server_blocked_reason.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/uploads/upload_review_controller.dart';
import 'package:frontend/ui/uploads/upload_review_page.dart';
import 'package:frontend/ui/uploads/uploads_controller.dart';
import 'package:frontend/ui/uploads/uploads_page.dart';
import 'package:frontend/ui/widgets/offline_banner.dart';
import 'package:frontend/ui/widgets/server_blocked_banner.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';
import '../fake_upload_review_controls.dart';
import '../fake_uploads_controls.dart';

Finder _row(String uuid) => find.byKey(ValueKey('upload-row-$uuid'));
Finder _inRow(String uuid, Finder f) =>
    find.descendant(of: _row(uuid), matching: f);

void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late FakeUploadsControls fake;
  late FakeSessionControls session;
  late FakeUploadReviewControls review;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
    session = FakeSessionControls();
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<void> pumpPage(
    WidgetTester tester,
    UploadsOverview? overview, {
    Size size = const Size(800, 1200),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    fake = FakeUploadsControls(overview: overview);
    review = FakeUploadReviewControls();
    await tester.pumpWidget(
      harness.wrap(
        const UploadsPage(),
        overrides: [
          uploadsControllerFactoryProvider.overrideWithValue(() => fake),
          sessionControlsProvider.overrideWithValue(session),
          uploadReviewControllerFactoryProvider.overrideWithValue(() => review),
        ],
      ),
    );
    await tester.pump();
  }

  testWidgets('a spinner until the uploads load', (tester) async {
    await pumpPage(tester, null);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Uploads'), findsOneWidget); // the app bar title
    await teardownTree(tester);
  });

  testWidgets('no uploads yet', (tester) async {
    await pumpPage(tester, fakeUploadsOverview(const []));
    expect(find.text('No uploads yet.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('overall counts and the known limits', (tester) async {
    await pumpPage(
      tester,
      fakeUploadsOverview(
        [fakeUploadRow('a')],
        limits: 'Up to 100 files at a time',
        counts: const UploadCounts(
          total: 4,
          inProgress: 1,
          readyForReview: 1,
          needsAttention: 1,
          done: 1,
          cancelled: 0,
          expired: 0,
        ),
      ),
    );
    expect(
      find.text(
        '4 files · 1 in progress · 1 ready for review · 1 needs attention '
        '· 1 done',
      ),
      findsOneWidget,
    );
    expect(find.text('Up to 100 files at a time'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('each row: name, status, size, detail', (tester) async {
    await pumpPage(
      tester,
      fakeUploadsOverview([
        fakeUploadRow('a', name: 'one.flac', status: 'Checking'),
        fakeUploadRow(
          'b',
          name: 'two.mp3',
          status: 'Failed',
          detail: 'The server could not store the file.',
          size: '3.0 MB',
          attention: true,
        ),
      ]),
    );
    expect(_inRow('a', find.text('one.flac')), findsOneWidget);
    expect(_inRow('a', find.textContaining('Checking')), findsOneWidget);
    expect(_inRow('a', find.textContaining('10.0 MB')), findsOneWidget);
    expect(_inRow('b', find.textContaining('Failed')), findsOneWidget);
    expect(_inRow('b', find.textContaining('3.0 MB')), findsOneWidget);
    expect(
      _inRow('b', find.text('The server could not store the file.')),
      findsOneWidget,
    );
    await teardownTree(tester);
  });

  testWidgets('a sending row shows its progress; unknown is indeterminate',
      (tester) async {
    await pumpPage(
      tester,
      fakeUploadsOverview([
        fakeUploadRow(
          'a',
          status: 'Uploading',
          sending: true,
          sent: 3,
          total: 10,
          size: '3.0 MB of 10.0 MB',
        ),
        fakeUploadRow('b', status: 'Uploading', sending: true),
        fakeUploadRow('c', status: 'Checking'),
      ]),
    );
    final a = tester.widget<LinearProgressIndicator>(
      _inRow('a', find.byType(LinearProgressIndicator)),
    );
    expect(a.value, closeTo(0.3, 1e-9));
    expect(_inRow('a', find.textContaining('3.0 MB of 10.0 MB')), findsOneWidget);
    final b = tester.widget<LinearProgressIndicator>(
      _inRow('b', find.byType(LinearProgressIndicator)),
    );
    expect(b.value, isNull);
    expect(_inRow('c', find.byType(LinearProgressIndicator)), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('row actions go to the controller', (tester) async {
    await pumpPage(
      tester,
      fakeUploadsOverview([
        fakeUploadRow('a', name: 'one.flac', cancel: true),
        fakeUploadRow('b', name: 'two.flac', reselect: true, cancel: true),
        fakeUploadRow('c', name: 'three.flac', reviewTags: true, cancel: true),
      ]),
    );
    await tester.tap(_inRow('a', find.byTooltip('Cancel upload')));
    await tester.tap(_inRow('b', find.text('Reselect file')));
    await tester.tap(_inRow('c', find.text('Review tags')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['cancel a', 'reselect b']);
    // Review tags opens the review of the row's batch at that file.
    expect(find.byType(UploadReviewPage), findsOneWidget);
    expect(review.calls, contains('start b-1 c'));
    await teardownTree(tester);
  });

  testWidgets('a row shows only the actions its state offers', (tester) async {
    await pumpPage(
      tester,
      fakeUploadsOverview([fakeUploadRow('a', status: 'Imported')]),
    );
    expect(_inRow('a', find.byType(IconButton)), findsNothing);
    expect(_inRow('a', find.byType(TextButton)), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('the cancel button names its file for screen readers',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpPage(
      tester,
      fakeUploadsOverview([fakeUploadRow('a', name: 'one.flac', cancel: true)]),
    );
    expect(find.bySemanticsLabel(RegExp('Cancel one.flac')), findsOneWidget);
    handle.dispose();
    await teardownTree(tester);
  });

  // ---- S9: Add files, notices, availability -------------------------------

  testWidgets('Add files goes to the controller', (tester) async {
    await pumpPage(tester, fakeUploadsOverview(const []));
    await tester.tap(find.widgetWithText(FilledButton, 'Add files'));
    await tester.pump();
    expect(fake.calls, ['addFiles']);
    await teardownTree(tester);
  });

  testWidgets('while adding, Add files is busy and cannot be tapped again',
      (tester) async {
    await pumpPage(tester, fakeUploadsOverview(const []));
    fake.set(adding: true);
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Adding files…'),
    );
    expect(button.onPressed, isNull);
    fake.set(adding: false);
    await tester.pump();
    expect(find.widgetWithText(FilledButton, 'Add files'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('left-out files are listed with their reason, dismissible',
      (tester) async {
    await pumpPage(tester, fakeUploadsOverview(const []));
    fake.set(
      notice: const UploadsNotice('2 files were left out', [
        'empty.flac: The file is empty.',
        "locked.flac: The file couldn't be read.",
      ]),
    );
    await tester.pump();
    expect(find.text('2 files were left out'), findsOneWidget);
    expect(find.text('empty.flac: The file is empty.'), findsOneWidget);
    expect(find.text("locked.flac: The file couldn't be read."), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(fake.calls, ['dismissNotice']);
    expect(find.text('2 files were left out'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('offline: cached statuses, the offline banner, network actions '
      'disabled with the reason', (tester) async {
    await pumpPage(
      tester,
      fakeUploadsOverview(
        [
          fakeUploadRow(
            'a',
            status: 'Ready for review',
            reviewTags: true,
            cancel: true,
            enabled: false,
          ),
        ],
        availability: UploadsAvailability.offline,
      ),
    );
    expect(find.byType(OfflineBanner), findsOneWidget);
    expect(_inRow('a', find.textContaining('Ready for review')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Add files'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(_inRow('a', find.widgetWithText(TextButton, 'Review tags')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(_inRow('a', find.byType(IconButton)))
          .onPressed,
      isNull,
    );
    expect(find.byTooltip('Unavailable while offline'), findsWidgets);
    await tester.tap(_inRow('a', find.text('Review tags')), warnIfMissed: false);
    await tester.tap(find.text('Add files'), warnIfMissed: false);
    await tester.pump();
    expect(fake.calls, isEmpty);
    await teardownTree(tester);
  });

  testWidgets('different server: the blocked banner, not the offline one',
      (tester) async {
    session.serverBlocked = ServerBlockedReason.differentServer;
    await pumpPage(
      tester,
      fakeUploadsOverview(
        const [],
        availability: UploadsAvailability.serverBlocked,
      ),
    );
    expect(find.byType(ServerBlockedBanner), findsOneWidget);
    expect(find.byType(OfflineBanner), findsNothing);
    expect(
      find.byTooltip('Unavailable while network features are paused'),
      findsWidgets,
    );
    await teardownTree(tester);
  });

  testWidgets('signed out: the blocked banner', (tester) async {
    session.serverBlocked = ServerBlockedReason.signedOut;
    await pumpPage(
      tester,
      fakeUploadsOverview(
        const [],
        availability: UploadsAvailability.serverBlocked,
      ),
    );
    expect(find.byType(ServerBlockedBanner), findsOneWidget);
    expect(find.textContaining('Signed out'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('a server that has not answered yet, or offers no uploads',
      (tester) async {
    await pumpPage(
      tester,
      fakeUploadsOverview(const [], availability: UploadsAvailability.cachedOnly),
    );
    expect(find.text('Waiting for the server to answer'), findsOneWidget);
    fake.set(
      overview: fakeUploadsOverview(
        const [],
        availability: UploadsAvailability.notAdvertised,
      ),
    );
    await tester.pump();
    expect(find.text("This server doesn't offer uploads"), findsOneWidget);
    expect(find.byType(OfflineBanner), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('back online: actions come back without reopening the page',
      (tester) async {
    await pumpPage(
      tester,
      fakeUploadsOverview(
        [fakeUploadRow('a', cancel: true, enabled: false)],
        availability: UploadsAvailability.offline,
      ),
    );
    fake.set(overview: fakeUploadsOverview([fakeUploadRow('a', cancel: true)]));
    await tester.pump();
    expect(find.byType(OfflineBanner), findsNothing);
    await tester.tap(_inRow('a', find.byTooltip('Cancel upload')));
    await tester.tap(find.text('Add files'));
    await tester.pump();
    expect(fake.calls, ['cancel a', 'addFiles']);
    await teardownTree(tester);
  });

  // ---- S11: an unpacked ZIP's files ---------------------------------------

  ZipChildren zip(List<UploadChildRow> children, {int? skipped}) => ZipChildren(
    children: children,
    valid: 2,
    failed: 1,
    checking: 0,
    cancelled: 0,
    skipped: skipped,
  );

  UploadChildRow child(
    String uuid, {
    String status = 'Ready for review',
    String? detail,
    bool attention = false,
  }) => UploadChildRow(
    itemUuid: uuid,
    displayName: '$uuid.flac',
    statusText: status,
    detailText: detail,
    needsAttention: attention,
  );

  Future<void> openZip(WidgetTester tester) async {
    await pumpPage(
      tester,
      fakeUploadsOverview([
        fakeUploadRow(
          'zip',
          name: 'album.zip',
          status: 'Archive unpacked',
          children: true,
        ),
      ]),
    );
    await tester.tap(_inRow('zip', find.text('Show files')));
    // The route transition; a spinner never settles, so no pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('Show files loads the archive and opens its file list',
      (tester) async {
    await openZip(tester);
    expect(fake.calls, ['loadChildren b-1/zip']);
    expect(find.widgetWithText(AppBar, 'album.zip'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    fake.setChildren('zip', const ChildListLoading());
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('the files with their counts, status and error', (tester) async {
    await openZip(tester);
    fake.setChildren(
      'zip',
      ChildListLoaded(
        zip([
          child('c1'),
          child('c2'),
          child(
            'c3',
            status: 'Failed',
            detail: "The upload couldn't be completed.",
            attention: true,
          ),
        ]),
      ),
    );
    await tester.pump();
    expect(find.text('2 valid · 1 failed'), findsOneWidget);
    Finder childRow(String uuid) =>
        find.byKey(ValueKey('upload-child-$uuid'));
    expect(
      find.descendant(of: childRow('c1'), matching: find.text('c1.flac')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: childRow('c3'),
        matching: find.text("The upload couldn't be completed."),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: childRow('c3'), matching: find.text('Failed')),
      findsOneWidget,
    );
    await teardownTree(tester);
  });

  testWidgets('a known skipped count is shown', (tester) async {
    await openZip(tester);
    fake.setChildren('zip', ChildListLoaded(zip(const [], skipped: 4)));
    await tester.pump();
    expect(find.text('2 valid · 1 failed · 4 skipped'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('a failed load says so and can be retried', (tester) async {
    await openZip(tester);
    fake.setChildren('zip', const ChildListFailed());
    await tester.pump();
    expect(find.text("Couldn't load the files in this archive."), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Try again'));
    await tester.pump();
    expect(fake.calls, ['loadChildren b-1/zip', 'loadChildren b-1/zip']);
    await teardownTree(tester);
  });

  // A7-02 (pre-merge review): a file reviewed from the list changes the
  // list; it is read again when the review closes.
  testWidgets("returning from a file's review reads the archive's files again",
      (tester) async {
    await openZip(tester);
    fake.setChildren(
      'zip',
      ChildListLoaded(
        zip([
          const UploadChildRow(
            itemUuid: 'c1',
            displayName: 'c1.flac',
            statusText: 'Ready for review',
            detailText: null,
            needsAttention: false,
            offersReviewTags: true,
          ),
          child('c2'),
        ]),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('upload-child-c1')),
        matching: find.text('Review tags'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UploadReviewPage), findsOneWidget);
    expect(review.calls, contains('start b-1 c1'));
    expect(fake.calls, ['loadChildren b-1/zip']);

    Navigator.of(tester.element(find.byType(UploadReviewPage))).pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(UploadReviewPage), findsNothing);
    // Quietly: the list stays on screen while it is read (review PMR-04).
    expect(fake.calls, ['loadChildren b-1/zip', 'loadChildren b-1/zip quiet']);
    await teardownTree(tester);
  });

  testWidgets('offline, Try again is disabled with the reason', (tester) async {
    await openZip(tester);
    fake.setChildren('zip', const ChildListFailed());
    fake.set(
      overview: fakeUploadsOverview(
        [fakeUploadRow('zip', children: true, enabled: false)],
        availability: UploadsAvailability.offline,
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Try again'))
          .onPressed,
      isNull,
    );
    expect(find.byTooltip('Unavailable while offline'), findsWidgets);
    await teardownTree(tester);
  });

  testWidgets('back returns to the uploads list', (tester) async {
    await openZip(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(_row('zip'), findsOneWidget);
    expect(fake.disposed, isFalse);
    await teardownTree(tester);
  });

  // ---- S12: long lists, long names, narrow width, text scale 2 ------------

  void largeText(WidgetTester tester) {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  final longName = '${'A very long file name that goes on and on ' * 6}.flac';

  testWidgets('hundreds of items are built lazily; the last is reachable',
      (tester) async {
    await pumpPage(
      tester,
      fakeUploadsOverview([
        for (var i = 0; i < 500; i++)
          fakeUploadRow('r$i', name: 'track $i.flac', cancel: true),
      ]),
    );
    expect(_row('r499'), findsNothing);
    await tester.scrollUntilVisible(
      _row('r499'),
      3000,
      maxScrolls: 200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(_inRow('r499', find.byTooltip('Cancel upload')));
    await tester.pump();
    expect(fake.calls, ['cancel r499']);
    await teardownTree(tester);
  });

  testWidgets('narrow window at text scale 2: no overflow, actions reachable',
      (tester) async {
    largeText(tester);
    await pumpPage(
      tester,
      fakeUploadsOverview(
        [
          fakeUploadRow(
            'a',
            name: longName,
            status: 'Uploading',
            size: '123.4 MB of 250.0 MB',
            sending: true,
            sent: 1,
            total: 2,
            cancel: true,
          ),
          fakeUploadRow(
            'b',
            name: longName,
            status: 'Reselect file to retry',
            detail:
                'This app can no longer open the file. Pick the same file '
                'again to continue.',
            attention: true,
            reselect: true,
            cancel: true,
          ),
          fakeUploadRow(
            'c',
            name: longName,
            status: 'Ready for review',
            reviewTags: true,
            cancel: true,
          ),
          fakeUploadRow('d', name: longName, children: true),
        ],
        limits: 'Up to 100 files at a time, each up to 250.0 MB',
      ),
      size: const Size(320, 640),
    );
    fake.set(
      notice: UploadsNotice('3 files were left out', [
        for (var i = 0; i < 3; i++) '$longName: The file is empty.',
      ]),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    for (final (id, action) in [
      ('a', find.byTooltip('Cancel upload')),
      ('b', find.text('Reselect file')),
      ('d', find.text('Show files')),
      ('c', find.text('Review tags')),
    ]) {
      await tester.scrollUntilVisible(
        _inRow(id, action).hitTestable(),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(_inRow(id, action));
      await tester.pump();
      await tester.tap(_inRow(id, action));
      await tester.pump();
      expect(tester.takeException(), isNull);
      if (id == 'd') {
        await tester.pump(const Duration(seconds: 1));
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
    }
    expect(fake.calls, [
      'cancel a',
      'reselect b',
      'loadChildren b-1/d',
    ]);
    // Review tags opened the review of the row's batch at that file.
    await tester.pumpAndSettle();
    expect(find.byType(UploadReviewPage), findsOneWidget);
    expect(review.calls, contains('start b-1 c'));
    await teardownTree(tester);
  });

  testWidgets('a long name ends with an ellipsis; the full name is available',
      (tester) async {
    await pumpPage(
      tester,
      fakeUploadsOverview([fakeUploadRow('a', name: longName)]),
      size: const Size(320, 640),
    );
    final text = tester.widget<Text>(_inRow('a', find.text(longName)));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(_inRow('a', find.byTooltip(longName)), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('an archive with more than 100 files, narrow at text scale 2',
      (tester) async {
    largeText(tester);
    await pumpPage(
      tester,
      fakeUploadsOverview([
        fakeUploadRow('zip', name: longName, children: true),
      ]),
      size: const Size(320, 640),
    );
    await tester.tap(_inRow('zip', find.text('Show files')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    fake.setChildren(
      'zip',
      ChildListLoaded(
        ZipChildren(
          children: [
            for (var i = 0; i < 150; i++)
              UploadChildRow(
                itemUuid: 'c$i',
                displayName: '$i $longName',
                statusText: 'Failed',
                detailText: "The upload couldn't be completed.",
                needsAttention: true,
              ),
          ],
          valid: 0,
          failed: 150,
          checking: 0,
          cancelled: 0,
          skipped: 12,
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final last = find.byKey(const ValueKey('upload-child-c149'));
    expect(last, findsNothing); // lazy
    await tester.scrollUntilVisible(
      last,
      3000,
      maxScrolls: 200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(last, findsOneWidget);
    expect(tester.takeException(), isNull);
    await teardownTree(tester);
  });

  // ---- Review r1 #5: the reused banners at a narrow width, text scale 2 ----

  for (final (name, availability, reason) in [
    ('offline', UploadsAvailability.offline, ServerBlockedReason.none),
    (
      'different server',
      UploadsAvailability.serverBlocked,
      ServerBlockedReason.differentServer,
    ),
    (
      'signed out',
      UploadsAvailability.serverBlocked,
      ServerBlockedReason.signedOut,
    ),
  ]) {
    testWidgets('$name banner: no overflow at 320 px and text scale 2',
        (tester) async {
      largeText(tester);
      session.serverBlocked = reason;
      await pumpPage(
        tester,
        fakeUploadsOverview(
          [fakeUploadRow('a', cancel: true, enabled: false)],
          availability: availability,
        ),
        size: const Size(320, 640),
      );
      expect(tester.takeException(), isNull);
      if (reason == ServerBlockedReason.differentServer) {
        expect(find.text('Reset').hitTestable(), findsOneWidget);
        expect(find.text('Disconnect').hitTestable(), findsOneWidget);
      }
      if (reason == ServerBlockedReason.signedOut) {
        expect(find.text('Log in').hitTestable(), findsOneWidget);
      }
      await teardownTree(tester);
    });
  }

  // ---- Review r1 #6: the file list while network work is off -------------

  testWidgets('a file list waiting on a paused network says why',
      (tester) async {
    await openZip(tester);
    fake.setChildren('zip', const ChildListLoading());
    fake.set(
      overview: fakeUploadsOverview(
        [fakeUploadRow('zip', children: true, enabled: false)],
        availability: UploadsAvailability.serverBlocked,
      ),
    );
    await tester.pump();
    expect(
      find.text('Unavailable while network features are paused'),
      findsOneWidget,
    );
    await teardownTree(tester);
  });

  // ---- Review r1 #9: every row action names its file ----------------------

  testWidgets('row actions and progress name their file for screen readers',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpPage(
      tester,
      fakeUploadsOverview([
        fakeUploadRow('a', name: 'one.flac', sending: true, sent: 1, total: 2),
        fakeUploadRow('b', name: 'two.flac', reselect: true),
        fakeUploadRow('c', name: 'three.flac', reviewTags: true),
        fakeUploadRow('d', name: 'album.zip', children: true),
      ]),
    );
    expect(find.bySemanticsLabel('Review tags for three.flac'), findsOneWidget);
    expect(find.bySemanticsLabel('Reselect file for two.flac'), findsOneWidget);
    expect(find.bySemanticsLabel('Show files in album.zip'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            _inRow('a', find.byType(LinearProgressIndicator)),
          )
          .semanticsLabel,
      'Upload progress for one.flac',
    );
    // The visible labels stay short.
    expect(_inRow('c', find.text('Review tags')), findsOneWidget);
    handle.dispose();
    await teardownTree(tester);
  });
}
