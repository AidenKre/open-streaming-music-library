// Phase 8 spec §3, §4 para 3, §6 (8B.1c, S7): the Manage library page renders
// what ManageLibraryControls says and forwards every input to it (SC-26).
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/deletion_text.dart';
import 'package:frontend/services/deletion/server_delete_availability.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';
import 'package:frontend/ui/manage_library/deletion_review_sheet.dart';
import 'package:frontend/ui/manage_library/manage_library_controller.dart';
import 'package:frontend/ui/manage_library/manage_library_page.dart';

import '../browse_harness.dart';
import 'fake_manage_library_controls.dart';
import '../../helpers/library_seed.dart' show SeedTrack, seedLibrary;

const _banner = Key('manage-library-banner');
const _panel = Key('selected-panel');
const _review = Key('review-deletion');

void main() {
  late AppDatabase db;
  late BrowseHarness h;
  late FakeManageLibraryControls fake;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    h = await BrowseHarness.create(db);
    fake = FakeManageLibraryControls();
  });

  tearDown(() async {
    fake.fakeSelection.dispose();
    fake.fakeReview.dispose();
    await h.dispose();
    await db.close();
  });

  /// The page is pushed from a launcher so Done has a route to pop.
  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      h.wrap(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ManageLibraryPage(),
                ),
              ),
              child: const Text('open manage'),
            ),
          ),
        ),
        overrides: [
          manageLibraryControllerFactoryProvider.overrideWithValue(() => fake),
        ],
      ),
    );
    await tester.tap(find.text('open manage'));
    await tester.pumpAndSettle();
  }

  String bannerText(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(of: find.byKey(_banner), matching: find.byType(Text)),
      )
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join(' ');

  const items = [
    SelectedItemView(
      uuid: 'u1',
      title: 'Alpha Song',
      artist: 'Alpha Artist',
      album: 'Alpha Album',
      inLocalLibrary: true,
    ),
    SelectedItemView(
      uuid: 'u2',
      title: null,
      artist: null,
      album: null,
      inLocalLibrary: false,
    ),
    SelectedItemView(
      uuid: 'u3',
      title: 'Alpha Song',
      artist: 'Alpha Artist',
      album: 'Alpha Album',
      inLocalLibrary: true,
      idHint: 'ab12',
    ),
  ];

  group('banner', () {
    testWidgets('enabled states deletion is enabled and permanent', (
      tester,
    ) async {
      await pumpPage(tester);
      expect(find.text('Manage library'), findsWidgets);
      final text = bannerText(tester);
      expect(text, contains('Server deletion is enabled on this server'));
      expect(text, contains('permanent'));
      await teardownTree(tester);
    });

    testWidgets('switched off says so and hides the action', (tester) async {
      fake.availability = ServerDeleteAvailability.switchedOff;
      fake.select(items);
      await pumpPage(tester);
      expect(
        bannerText(tester),
        unavailableText(DeleteJobsUnavailableReason.switchedOff),
      );
      expect(find.byKey(_review), findsNothing, reason: 'exit proof');
      await teardownTree(tester);
    });

    testWidgets('not offered says the server has no library tools', (
      tester,
    ) async {
      fake.availability = ServerDeleteAvailability.notOffered;
      await pumpPage(tester);
      final text = bannerText(tester);
      expect(
        text,
        unavailableText(DeleteJobsUnavailableReason.notAdvertised),
      );
      expect(
        text,
        isNot(unavailableText(DeleteJobsUnavailableReason.switchedOff)),
      );
      await teardownTree(tester);
    });

    testWidgets('unreachable mentions the connection', (tester) async {
      fake.availability = ServerDeleteAvailability.unreachable;
      await pumpPage(tester);
      expect(bannerText(tester), contains('connection'));
      await teardownTree(tester);
    });

    testWidgets('checking says it is checking', (tester) async {
      fake.availability = ServerDeleteAvailability.checking;
      await pumpPage(tester);
      expect(bannerText(tester), contains('Checking'));
      await teardownTree(tester);
    });

    testWidgets('a change of availability updates the banner', (tester) async {
      await pumpPage(tester);
      fake.availability = ServerDeleteAvailability.switchedOff;
      fake.notify();
      await tester.pumpAndSettle();
      expect(
        bannerText(tester),
        contains(unavailableText(DeleteJobsUnavailableReason.switchedOff)),
      );
      expect(find.byKey(_review), findsNothing);
      await teardownTree(tester);
    });
  });

  group('Review deletion action', () {
    // One test per availability: the harness's download manager is
    // disposed with each pumped tree.
    for (final a in ServerDeleteAvailability.values) {
      if (a == ServerDeleteAvailability.enabled) continue;
      testWidgets('is absent when ${a.name}', (tester) async {
        fake = FakeManageLibraryControls(availability: a);
        fake.select(items);
        await pumpPage(tester);
        expect(find.byKey(_review), findsNothing, reason: '$a');
        await teardownTree(tester);
      });
    }

    testWidgets('is disabled with an empty selection', (tester) async {
      await pumpPage(tester);
      final button = tester.widget<FilledButton>(find.byKey(_review));
      expect(button.onPressed, isNull);
      expect(find.text('Review deletion'), findsOne);
      await tester.tap(find.byKey(_review), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(fake.fakeReview.calls, isEmpty);
      await teardownTree(tester);
    });

    testWidgets('with a selection asks for a preview and shows the sheet', (
      tester,
    ) async {
      fake.select(items);
      fake.fakeReview.stage = ReviewStage.failed;
      fake.fakeReview.message = 'No preview today';
      await pumpPage(tester);
      final button = tester.widget<FilledButton>(find.byKey(_review));
      expect(button.onPressed, isNotNull);

      await tester.tap(find.byKey(_review));
      await tester.pumpAndSettle();
      expect(fake.fakeReview.calls, ['requestPreview']);
      expect(find.byType(DeletionReviewSheet), findsOne);
      expect(find.text('No preview today'), findsOne);
      await teardownTree(tester);
    });
  });

  group('selected panel', () {
    testWidgets('is absent with an empty selection', (tester) async {
      await pumpPage(tester);
      expect(find.byKey(_panel), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('shows the count, each item, unknowns and the id hint', (
      tester,
    ) async {
      fake.select(items);
      await pumpPage(tester);
      final panel = find.byKey(_panel);
      expect(panel, findsOne);
      Finder inPanel(String text) =>
          find.descendant(of: panel, matching: find.text(text));
      expect(inPanel('3 selected'), findsOne);
      expect(inPanel('Alpha Song'), findsNWidgets(2));
      expect(inPanel('No longer in your library on this device'), findsOne);
      expect(
        find.descendant(of: panel, matching: find.textContaining('Alpha Artist')),
        findsWidgets,
      );
      expect(
        find.descendant(of: panel, matching: find.textContaining('Alpha Album')),
        findsWidgets,
      );
      expect(
        find.descendant(of: panel, matching: find.textContaining('ab12')),
        findsOne,
      );
      await teardownTree(tester);
    });

    testWidgets('remove forwards the uuid', (tester) async {
      fake.select(items);
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('remove-selected-u2')));
      await tester.pumpAndSettle();
      expect(fake.calls, ['removeSelected u2']);
      await teardownTree(tester);
    });

    testWidgets('Clear forwards clearSelection', (tester) async {
      fake.select(items);
      await pumpPage(tester);
      await tester.tap(
        find.descendant(
          of: find.byKey(_panel),
          matching: find.widgetWithText(TextButton, 'Clear'),
        ),
      );
      await tester.pumpAndSettle();
      expect(fake.calls, ['clearSelection']);
      await teardownTree(tester);
    });

    testWidgets('follows the controller when the selection empties', (
      tester,
    ) async {
      fake.select(items);
      await pumpPage(tester);
      expect(find.byKey(_panel), findsOne);
      fake.select(const []);
      await tester.pumpAndSettle();
      expect(find.byKey(_panel), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(_review)).onPressed, isNull);
      await teardownTree(tester);
    });
  });

  testWidgets('Done pops the page, disposes its controller, sends no input', (
    tester,
  ) async {
    fake.select(items);
    await pumpPage(tester);
    expect(find.text('Done'), findsOne);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(ManageLibraryPage), findsNothing);
    expect(find.text('open manage'), findsOne);
    expect(fake.calls, contains('dispose'));
    expect(fake.fakeReview.calls, isNot(contains('requestPreview')));
    expect(fake.fakeReview.calls.where((c) => c.startsWith('confirm')), isEmpty);
    await teardownTree(tester);
  });

  testWidgets('the history icon opens Deletion history', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byTooltip('Deletion history'));
    await tester.pumpAndSettle();
    expect(find.text('Deletion history'), findsWidgets);
    expect(fake.calls, contains('loadReceipts'));
    await teardownTree(tester);
  });

  testWidgets('selecting rows toggles the selection and plays nothing', (
    tester,
  ) async {
    await seedLibrary(db, const [
      SeedTrack(
        uuid: 'd1',
        title: 'Kept Song',
        artistId: 1,
        artist: 'Artist',
        albumId: 10,
        album: 'Album',
        downloaded: true,
        revision: 4,
      ),
      SeedTrack(
        uuid: 's1',
        title: 'Remote Song',
        artistId: 1,
        artist: 'Artist',
        albumId: 10,
        album: 'Album',
        trackNumber: 2,
        revision: 7,
      ),
    ]);
    await pumpPage(tester);
    expect(find.text('Remote Song'), findsOne);

    await tester.tap(find.text('Remote Song'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kept Song'));
    await tester.pumpAndSettle();

    expect(fake.fakeSelection.calls, ['toggle s1', 'toggle d1']);
    expect(h.audio.calls, isEmpty, reason: 'no PlaybackRequests.submit');
    expect(h.audio.intents, isEmpty);
    await teardownTree(tester);
  });
}
