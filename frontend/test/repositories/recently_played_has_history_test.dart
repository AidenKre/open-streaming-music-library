// 6-R1-07: Home's "is there any eligible history at all" question is a cheap
// live stream over the same eligibility rule (no hydration), so the chip ON
// state needs no second hydrating `watchRecent`.


import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/recently_played_repository.dart';

import '../helpers/server_binding.dart';
import 'catalog_seed.dart';

void main() {
  late AppDatabase db;
  late CatalogSeed seed;
  late RecentlyPlayedRepository repo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    seed = CatalogSeed(db);
    repo = RecentlyPlayedRepository(db, BrowseRepository(db));
    await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    await seed.artist(1, 'Aria');
    await seed.album(1, artistId: 1, name: 'One');
    await seed.track('a', artistId: 1, albumId: 1);
  });

  tearDown(() => db.close());

  Future<List<bool>> watching() async {
    final seen = <bool>[];
    final sub = repo.watchHasEligibleHistory().listen(seen.add);
    addTearDown(sub.cancel);
    await pumpEventQueue();
    return seen;
  }

  test('no history: false', () async {
    expect(await watching(), [false]);
  });

  test('only ineligible history (deleted, foreign, non-canonical, other '
      'kinds): false', () async {
    await seed.click('track', 'gone', at: 10);
    await seed.click('album', 'other:1', at: 9);
    await seed.click('album', 'srv-1:01', at: 8);
    await seed.click('track', 'a', at: 7, kind: 'play');
    expect(await watching(), [false]);
  });

  test('an eligible click, even with nothing downloaded: true', () async {
    await seed.click('track', 'a', at: 10);
    expect(await watching(), [true]);
  });

  test('follows history and catalog changes, distinct values only', () async {
    final seen = await watching();
    await seed.click('track', 'a', at: 10);
    await pumpEventQueue();
    await seed.click('track', 'a', at: 20);
    await pumpEventQueue();
    expect(seen, [false, true]);
    // The track leaves the catalog: its click is no longer eligible.
    await db.customUpdate("DELETE FROM trackmetadata WHERE uuid_id = 'a'",
        updates: {db.trackmetadata});
    await db.customUpdate("DELETE FROM tracks WHERE uuid_id = 'a'",
        updates: {db.tracks});
    await pumpEventQueue();
    expect(seen, [false, true, false]);
  });

  test('a collection click counts only while the catalog is reconciled',
      () async {
    await seed.click('album', 'srv-1:1', at: 10);
    final seen = await watching();
    await db.customUpdate(
        'UPDATE server_binding SET catalog_reconciled_at_binding = 0',
        updates: {db.serverBinding});
    await pumpEventQueue();
    expect(seen, [true, false]);
  });
}
