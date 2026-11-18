// Phase 6 §3 (See all) / §7 ("When closing/reopening the route, take a fresh
// snapshot") / 6-U09: the Home rail header's "See all" opens the grid with
// Home's current chip value; it is offered only when the rail has content to
// see (Ready) or was emptied by the chip (filtered empty).
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/see_all_recents_controller.dart';
import 'package:frontend/ui/home/home_controller.dart';
import 'package:frontend/ui/home/home_page.dart';

import '../browse_harness.dart';
import '../fake_see_all_recents_controls.dart';
import '../../helpers/fake_home_controls.dart' show FakeHomeControls;

TrackUI _track(String uuid) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: 'Song $uuid',
  artist: 'Ann',
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

final _seeAll = find.widgetWithText(TextButton, 'See all');

void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late List<bool> opened;
  late List<FakeSeeAllRecentsControls> controls;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
    opened = [];
    controls = [];
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<void> pumpHome(WidgetTester tester, FakeHomeControls fake) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      harness.wrap(
        const HomePage(),
        overrides: [
          homeControlsProvider.overrideWithValue(fake),
          seeAllRecentsControllerFactoryProvider.overrideWithValue(({
            required initialDownloaded,
          }) {
            opened.add(initialDownloaded);
            // Settled (not loading), so route transitions can settle.
            final c = FakeSeeAllRecentsControls(
              initialDownloaded: initialDownloaded,
            )..show(entities: const []);
            controls.add(c);
            return c;
          }),
        ],
      ),
    );
    await tester.pump();
  }

  testWidgets('offered in Ready and filtered empty only', (tester) async {
    final fake = FakeHomeControls(const HomeRecentsLoading());
    await pumpHome(tester, fake);
    expect(_seeAll, findsNothing, reason: 'loading');
    fake.recentsState = const HomeRecentsFailed();
    await tester.pump();
    expect(_seeAll, findsNothing, reason: 'error');
    fake.recentsState = const HomeRecentsEmpty(filtered: false);
    await tester.pump();
    expect(_seeAll, findsNothing, reason: 'no history at all');
    fake.recentsState = const HomeRecentsEmpty(filtered: true);
    await tester.pump();
    expect(_seeAll, findsOneWidget, reason: 'filtered empty');
    fake.recentsState = HomeRecentsReady([TrackEntity(_track('a'))]);
    await tester.pump();
    expect(_seeAll, findsOneWidget, reason: 'ready');
    await teardownTree(tester);
  });

  testWidgets('sits in the rail title row', (tester) async {
    final fake = FakeHomeControls(HomeRecentsReady([TrackEntity(_track('a'))]));
    await pumpHome(tester, fake);
    final title = tester.getRect(find.text('Recently played'));
    final action = tester.getRect(_seeAll);
    expect(action.left, greaterThan(title.right));
    expect(action.center.dy, closeTo(title.center.dy, 12));
    await teardownTree(tester);
  });

  testWidgets('opens See all with Home\'s current chip value; closing and '
      'reopening creates a new controller (a fresh snapshot)', (tester) async {
    final fake = FakeHomeControls(HomeRecentsReady([TrackEntity(_track('a'))]));
    await pumpHome(tester, fake);
    fake.setDownloaded(true);
    await tester.pump();
    await tester.tap(_seeAll);
    await tester.pumpAndSettle();
    expect(opened, [true]);
    expect(find.byType(BackButton), findsOneWidget);

    // See all's chip is its own: changing it leaves Home's alone.
    controls.single.setDownloaded(false);
    expect(fake.filters.downloaded, isTrue);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(controls.single.disposed, isTrue);

    fake.setDownloaded(false);
    await tester.pump();
    await tester.tap(_seeAll);
    await tester.pumpAndSettle();
    expect(opened, [true, false]);
    expect(controls, hasLength(2));
    await teardownTree(tester);
  });
}
