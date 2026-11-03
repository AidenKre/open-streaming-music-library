import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
import 'package:frontend/ui/widgets/track_card.dart';

import '../browse_harness.dart';

TrackUI _track(String uuid, String title) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: title,
  artist: 'Seven',
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

final _mixed = <FeedEntity>[
  const ArtistEntity(ArtistUI(id: 7, name: 'Seven')),
  const AlbumEntity(AlbumUI(id: 7, artistId: 7, name: 'Seven Album', artist: 'Seven')),
  TrackEntity(_track('t7', 'Seven Song')),
];

void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<void> pumpFeed(WidgetTester tester, List<FeedSection> sections,
      {double textScale = 1, Key? key}) async {
    await tester.pumpWidget(harness.wrap(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: SectionedFeedView(key: key, sections: sections)),
      ),
    ));
    await tester.pump();
  }

  test('entity keys include the type: artist 7 and album 7 never collide', () {
    final keys = _mixed.map((e) => e.key).toSet();
    expect(keys, hasLength(3));
    expect(_mixed[0].key == _mixed[1].key, isFalse);
  });

  testWidgets('a mixed rail renders each type and taps report the entity',
      (tester) async {
    final tapped = <String>[];
    await pumpFeed(tester, [
      EntityRailSection(
        id: 'mixed',
        title: 'Mixed',
        entities: _mixed,
        onTap: (e, i) => tapped.add('${e.runtimeType}#$i'),
      ),
    ]);
    expect(find.text('Mixed'), findsOneWidget);
    expect(find.byType(ArtistCard), findsOneWidget);
    expect(find.byType(AlbumCard), findsOneWidget);
    expect(find.byType(TrackCard), findsOneWidget);
    await tester.tap(find.text('Seven Album'));
    await tester.tap(find.text('Seven Song'));
    expect(tapped, ['AlbumEntity#1', 'TrackEntity#2']);
    await teardownTree(tester);
  });

  testWidgets('no overflow at text scale 2; cards share one extent',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpFeed(tester, [
      EntityRailSection(id: 'mixed', title: 'Mixed', entities: _mixed, onTap: (_, _) {}),
    ], textScale: 2);
    expect(tester.takeException(), isNull);
    final heights = {
      for (final t in [ArtistCard, AlbumCard, TrackCard])
        tester.getSize(find.byType(t)).height,
    };
    expect(heights, hasLength(1), reason: 'uniform extent');
    final widths = {
      for (final t in [ArtistCard, AlbumCard, TrackCard])
        tester.getSize(find.byType(t)).width,
    };
    expect(widths.single, greaterThanOrEqualTo(160));
    await teardownTree(tester);
  });

  testWidgets('a loading rail reserves its normal extent; error offers retry',
      (tester) async {
    var retries = 0;
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpFeed(tester, [
      EntityRailSection(id: 'a', title: 'Ready', entities: _mixed, onTap: (_, _) {}),
      const EntityRailSection(id: 'b', title: 'Loading', entities: [], state: RailState.loading),
      EntityRailSection(id: 'c', title: 'Broken', entities: const [],
          state: RailState.error, onRetry: () => retries++),
    ]);
    final ready = tester.getSize(find.byKey(const ValueKey('feed.rail.a.body'))).height;
    final loading = tester.getSize(find.byKey(const ValueKey('feed.rail.b.body'))).height;
    final error = tester.getSize(find.byKey(const ValueKey('feed.rail.c.body'))).height;
    expect(loading, ready);
    expect(error, ready);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
    await teardownTree(tester);
  });

  testWidgets('an empty ready rail disappears with its title', (tester) async {
    await pumpFeed(tester, [
      const EntityRailSection(id: 'e', title: 'Empty', entities: []),
    ]);
    expect(find.text('Empty'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('reordering sections keeps each rail\'s own scroll position',
      (tester) async {
    final many = [
      for (var i = 0; i < 12; i++) TrackEntity(_track('t$i', 'Song $i')),
    ];
    final a = EntityRailSection(id: 'a', title: 'A', entities: many, onTap: (_, _) {});
    final b = EntityRailSection(id: 'b', title: 'B', entities: many, onTap: (_, _) {});
    await pumpFeed(tester, [a, b]);
    await tester.drag(find.byKey(const ValueKey('feed.rail.a.body')), const Offset(-500, 0));
    await tester.pumpAndSettle();
    double offsetOf(String id) => tester
        .state<ScrollableState>(find.descendant(
          of: find.byKey(ValueKey('feed.rail.$id.body')),
          matching: find.byType(Scrollable),
        ))
        .position
        .pixels;
    final aOffset = offsetOf('a');
    expect(aOffset, greaterThan(0));
    await pumpFeed(tester, [b, a]);
    await tester.pumpAndSettle();
    expect(offsetOf('a'), aOffset);
    expect(offsetOf('b'), 0);
    await teardownTree(tester);
  });

  testWidgets('one vertical scroll view; scrollToTop returns to the top',
      (tester) async {
    final key = GlobalKey<SectionedFeedViewState>();
    await pumpFeed(tester, [
      for (var i = 0; i < 8; i++)
        EntityRailSection(id: 'r$i', title: 'Rail $i', entities: _mixed, onTap: (_, _) {}),
    ], key: key);
    expect(find.byType(CustomScrollView), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(find.text('Rail 0'), findsNothing);
    key.currentState!.scrollToTop();
    await tester.pumpAndSettle();
    expect(find.text('Rail 0'), findsOneWidget);
    await teardownTree(tester);
  });
}
