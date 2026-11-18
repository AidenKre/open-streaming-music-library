// Phase 6 §3 "Recent album/artist tap" (6-R03 unit half): tapping a
// collection recent opens its detail page and records nothing: no playback
// request, no clicked event, no recency bump. Real `HomeController` and
// `RecentlyPlayedRepository` over in-memory Drift.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/tracks_page.dart';

import '../../helpers/server_binding.dart';
import '../../repositories/catalog_seed.dart';
import '../browse_harness.dart';

void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
    await seedLibrary(db, const [
      SeedTrack(uuid: 'a', title: 'Song a', artistId: 1, artist: 'Ann',
          albumId: 2, album: 'Second'),
    ]);
    await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    final seed = CatalogSeed(db);
    await seed.click('album', 'srv-1:2', at: 300);
    await seed.click('artist', 'srv-1:1', at: 200);
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<List<String>> clicks() async {
    final rows = await (db.select(db.historyEvents)
          ..where((e) => e.kind.equals('clicked'))
          ..orderBy([(e) => OrderingTerm(expression: e.localId)]))
        .get();
    return [for (final r in rows) '${r.entityType}:${r.entityRef}'];
  }

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness.wrap(const HomePage()));
    // The live recents read runs on the real database.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  for (final (label, key, page) in [
    ('album', 'album:2', TracksPage),
    ('artist', 'artist:1', AlbumsPage),
  ]) {
    testWidgets('an $label tap opens its page and records nothing',
        (tester) async {
      await pumpHome(tester);
      expect(find.byKey(ValueKey(key)), findsOneWidget);

      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      expect(find.byType(page), findsOneWidget);
      expect(harness.audio.calls, isEmpty);
      expect(
        await tester.runAsync(clicks),
        ['album:srv-1:2', 'artist:srv-1:1'],
      );
      await teardownTree(tester);
    });
  }
}
