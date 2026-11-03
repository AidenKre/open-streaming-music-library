import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/get_info_page.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/widgets/library_card.dart';
import 'package:frontend/ui/widgets/track_card.dart';

import '../browse_harness.dart';
import '../fake_library_actions.dart';

void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late FakeLibraryActions actions;
  late Map<String, TrackUI> tracks;

  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(uuid: 'r', title: 'Remote Song', artistId: 1, artist: 'Ann',
          albumId: 1, album: 'X'),
      SeedTrack(uuid: 'd', title: 'Local Song', artistId: 1, artist: 'Ann',
          albumId: 1, album: 'X', trackNumber: 2, downloaded: true),
    ]);
    harness = await BrowseHarness.create(db);
    actions = FakeLibraryActions();
    tracks = {
      for (final t in await BrowseRepository(db).watchTracks().first) t.uuidId: t,
    };
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await harness.dispose();
    await db.close();
  });

  Widget host(Widget card, {bool offline = false}) => harness.wrap(
    Scaffold(body: Center(child: SizedBox(width: 160, height: 260, child: card))),
    offline: offline,
    overrides: [libraryActionsProvider.overrideWithValue(actions)],
  );

  testWidgets('shows title and artist; the surface supplies the tap',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(TrackCard(track: tracks['r']!, onTap: () => taps++)));
    await tester.pump();
    expect(find.text('Remote Song'), findsOneWidget);
    expect(find.text('Ann'), findsOneWidget);
    await tester.tap(find.byType(TrackCard));
    expect(taps, 1);
    await teardownTree(tester);
  });

  testWidgets('menu acts on the track uuid and offers Get info',
      (tester) async {
    await tester.pumpWidget(host(TrackCard(track: tracks['r']!, onTap: () {})));
    await tester.pump();
    await tester.longPress(find.byType(TrackCard));
    await tester.pumpAndSettle();
    expect(find.text('Get Info'), findsOneWidget);
    await tester.tap(find.text('Play Next'));
    await tester.pumpAndSettle();
    expect(actions.calls, ['playNext track(r)']);
    await teardownTree(tester);
  });

  testWidgets('offline remote: dimmed, tap blocked, Get info still available',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(
      TrackCard(track: tracks['r']!, onTap: () => taps++),
      offline: true,
    ));
    await tester.pump();
    expect(tester.widget<LibraryCard>(find.byType(LibraryCard)).dimmed, isTrue);
    await tester.tap(find.byType(TrackCard));
    expect(taps, 0);
    await tester.longPress(find.byType(TrackCard));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Play Next')).enabled,
      isFalse,
    );
    await tester.tap(find.text('Get Info'));
    await tester.pumpAndSettle();
    expect(find.byType(GetInfoPage), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('offline downloaded track plays', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(
      TrackCard(track: tracks['d']!, onTap: () => taps++),
      offline: true,
    ));
    await tester.pump();
    await tester.tap(find.byType(TrackCard));
    expect(taps, 1);
    await teardownTree(tester);
  });

  testWidgets('desktop: a visible overflow button opens the same menu',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(host(TrackCard(track: tracks['r']!, onTap: () {})));
    await tester.pump();
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('Get Info'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
    await teardownTree(tester);
  });

  testWidgets('touch: no overflow button (long-press menu)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(host(TrackCard(track: tracks['r']!, onTap: () {})));
    await tester.pump();
    expect(find.byTooltip('More actions'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    await teardownTree(tester);
  });

  testWidgets('semantics name the type, title and artist', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(TrackCard(track: tracks['r']!, onTap: () {})));
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp(r'^Song, Remote Song, by Ann')), findsOneWidget);
    handle.dispose();
    await teardownTree(tester);
  });
}
