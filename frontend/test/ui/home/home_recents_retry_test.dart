// 6-R2-11c (6-R07 injected repository failure, then Retry): the real
// HomeController and the real Home view together, over a recents
// repository whose first query fails. The error section is shown, Retry
// re-subscribes through the controller, and the rail appears.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/recently_played_repository.dart';
import 'package:frontend/ui/home/home_page.dart';

import '../../helpers/server_binding.dart';
import '../../repositories/catalog_seed.dart';
import '../browse_harness.dart';

/// The first recents query fails; every later one reads the database.
class _FailFirstRecents extends RecentlyPlayedRepository {
  _FailFirstRecents(AppDatabase db) : super(db, BrowseRepository(db));
  int queries = 0;

  @override
  Stream<List<ResolvedRecent>> watchRecent({
    int limit = 20,
    bool downloadedOnly = false,
  }) {
    if (queries++ == 0) {
      return Stream.error(StateError('recents query failed'));
    }
    return super.watchRecent(limit: limit, downloadedOnly: downloadedOnly);
  }
}

void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(uuid: 'a', title: 'Alpha Song', artistId: 1, artist: 'Ann',
          albumId: 1, album: 'One'),
    ]);
    await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    await CatalogSeed(db).click('track', 'a', at: 1000);
    harness = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  testWidgets('a failed recents query shows Retry; Retry shows the rail',
      (tester) async {
    final repo = _FailFirstRecents(db);
    await tester.pumpWidget(harness.wrap(
      const HomePage(),
      overrides: [recentlyPlayedRepositoryProvider.overrideWithValue(repo)],
    ));
    await tester.runAsync(() => pumpEventQueue(times: 20));
    await tester.pump();
    expect(find.text('Recently played'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Alpha Song'), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.runAsync(() => pumpEventQueue(times: 20));
    await tester.pump();
    expect(repo.queries, 2);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Alpha Song'), findsOneWidget);
    await teardownTree(tester);
  });
}
