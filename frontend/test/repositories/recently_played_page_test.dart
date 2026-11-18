// Phase 6 §6 / 6-U06, 6-U07: hydrated recents pages. `page` is the keyset
// read 6B.3b's pager calls inside HistorySnapshotService.readPage.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/recently_played_repository.dart';

import '../helpers/server_binding.dart';
import 'catalog_seed.dart';

/// `type:id` of each hydrated entity, from the entity itself (not the ref).
String _entityKey(ResolvedRecent r) => switch (r.entity) {
  TrackUI(:final uuidId) => 'track:$uuidId',
  AlbumUI(:final id) => 'album:$id',
  ArtistUI(:final id) => 'artist:$id',
  _ => 'unexpected:${r.entity.runtimeType}',
};

List<String> _entities(List<ResolvedRecent> rs) => rs.map(_entityKey).toList();

/// Counts SELECT statements reaching SQLite.
class _SelectCounter extends QueryInterceptor {
  int selects = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    selects++;
    return super.runSelect(executor, statement, args);
  }
}

/// A resolver whose album lookups lose the given ids, as if the albums were
/// deleted between the eligibility read and hydration.
class _VanishingAlbums extends BrowseRepository {
  _VanishingAlbums(super.db, this.vanished);

  final Set<int> vanished;
  final requests = <List<int>>[];

  @override
  Future<List<AlbumUI>> getAlbumsByIds(
    List<int> ids, {
    bool downloadedArtOnly = false,
  }) async {
    requests.add(ids);
    final got = await super.getAlbumsByIds(
      ids,
      downloadedArtOnly: downloadedArtOnly,
    );
    return got.where((a) => !vanished.contains(a.id)).toList();
  }
}

void main() {
  late AppDatabase db;
  late _SelectCounter counter;
  late CatalogSeed seed;
  late RecentlyPlayedRepository repo;

  setUp(() async {
    counter = _SelectCounter();
    db = AppDatabase(NativeDatabase.memory().interceptWith(counter));
    seed = CatalogSeed(db);
    repo = RecentlyPlayedRepository(db, BrowseRepository(db));
    await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    // Artist 1: album 1 (2 tracks, 1 downloaded, art 11 remote / 12 local),
    // Singles album 2. Artist 2: album 3 (no downloads).
    await seed.artist(1, 'Aria');
    await seed.artist(2, 'Bram');
    await seed.album(1, artistId: 1, name: 'One', year: 2001);
    await seed.album(2, artistId: 1, single: true);
    await seed.album(3, artistId: 2, name: 'Three');
    await seed.track('a', artistId: 1, albumId: 1, trackNumber: 1, art: 11);
    await seed.track(
      'b',
      artistId: 1,
      albumId: 1,
      trackNumber: 2,
      art: 12,
      downloaded: true,
    );
    await seed.track('c', artistId: 1, albumId: 2);
    await seed.track('d', artistId: 2, albumId: 3, title: 'Dee');
  });

  tearDown(() => db.close());

  Future<int> boundary() async => (await db
          .customSelect('SELECT MAX(local_id) AS m FROM history_events')
          .getSingle())
      .read<int>('m');

  test('hydrates each kind with its read model, scope and counts, in '
      'recency order', () async {
    await seed.click('artist', 'srv-1:1', at: 500);
    await seed.click('track', 'd', at: 400);
    await seed.click('album', 'srv-1:1', at: 300);
    await seed.click('album', 'srv-1:3', at: 200);
    await seed.click('track', 'b', at: 100);

    final got = await repo.page(boundaryLocalId: await boundary(), limit: 10);

    expect(_entities(got), [
      'artist:1',
      'track:d',
      'album:1',
      'album:3',
      'track:b',
    ]);
    expect(got.map((r) => r.ref.occurredAt), [500, 400, 300, 200, 100]);

    final artist = got[0];
    expect((artist.entity as ArtistUI).name, 'Aria');
    expect(artist.scope, const ArtistScope(artistId: 1));
    expect((artist.downloaded, artist.total), (1, 3));

    final track = got[1];
    expect((track.entity as TrackUI).title, 'Dee');
    expect(track.scope, isA<TrackScope>());
    expect((track.scope as TrackScope).track.uuidId, 'd');
    expect((track.downloaded, track.total), (0, 1));

    final album = got[2];
    expect((album.entity as AlbumUI).artist, 'Aria');
    expect((album.entity as AlbumUI).coverArtId, 11);
    expect(album.scope, const AlbumScope(artistId: 1, albumId: 1));
    expect((album.downloaded, album.total), (1, 2));

    expect((got[3].downloaded, got[3].total), (0, 1));
    expect((got[4].downloaded, got[4].total), (1, 1));
  });

  test('downloadedOnly picks local art for collections', () async {
    await seed.click('album', 'srv-1:1', at: 300);
    final got = await repo.page(
      boundaryLocalId: await boundary(),
      limit: 10,
      downloadedOnly: true,
    );
    expect((got.single.entity as AlbumUI).coverArtId, 12);
  });

  test('keyset continuation after the last returned tuple: no duplicates '
      'or skips across a tie at the page edge', () async {
    // Four entries at the same time; tie order is by event uuid desc.
    await seed.click('track', 'a', at: 100, eventUuid: 'e1');
    await seed.click('track', 'b', at: 100, eventUuid: 'e4');
    await seed.click('track', 'c', at: 100, eventUuid: 'e2');
    await seed.click('track', 'd', at: 100, eventUuid: 'e3');
    await seed.click('album', 'srv-1:1', at: 50, eventUuid: 'e0');
    final b = await boundary();

    final first = await repo.page(boundaryLocalId: b, limit: 2);
    expect(_entities(first), ['track:b', 'track:d']);
    final second = await repo.page(
      boundaryLocalId: b,
      after: first.last.ref,
      limit: 2,
    );
    expect(_entities(second), ['track:c', 'track:a']);
    final third = await repo.page(
      boundaryLocalId: b,
      after: second.last.ref,
      limit: 2,
    );
    expect(_entities(third), ['album:1']);
    final done = await repo.page(
      boundaryLocalId: b,
      after: third.last.ref,
      limit: 2,
    );
    expect(done, isEmpty);
  });

  test('the snapshot boundary applies before dedupe: a newer click after '
      'the boundary leaves the old representative in place', () async {
    await seed.click('track', 'a', at: 100);
    await seed.click('track', 'b', at: 90);
    final b = await boundary();
    await seed.click('track', 'b', at: 200); // after the snapshot
    await seed.click('track', 'c', at: 300); // after the snapshot

    final got = await repo.page(boundaryLocalId: b, limit: 10);
    expect(_entities(got), ['track:a', 'track:b']);
    expect(got[1].ref.occurredAt, 90);
  });

  test('an old-timestamp event inside the boundary still sorts by its own '
      'time', () async {
    await seed.click('track', 'a', at: 100);
    await seed.click('track', 'b', at: 10); // pulled late, old time
    final got = await repo.page(boundaryLocalId: await boundary(), limit: 10);
    expect(_entities(got), ['track:a', 'track:b']);
  });

  test('hydration is batched: the select count does not grow with the '
      'number of cards', () async {
    Future<int> selectsFor(int perKind) async {
      await db.delete(db.historyEvents).go();
      var at = 1000;
      final tracks = ['a', 'b', 'c', 'd'];
      for (var i = 0; i < perKind; i++) {
        await seed.click('track', tracks[i % 4], at: at--);
      }
      for (var i = 0; i < perKind; i++) {
        await seed.click('album', 'srv-1:${1 + i % 3}', at: at--);
      }
      for (var i = 0; i < perKind; i++) {
        await seed.click('artist', 'srv-1:${1 + i % 2}', at: at--);
      }
      final b = await boundary();
      counter.selects = 0;
      final got = await repo.page(boundaryLocalId: b, limit: 20);
      expect(got, isNotEmpty);
      return counter.selects;
    }

    final small = await selectsFor(1); // 3 cards
    final large = await selectsFor(4); // 4 + 3 + 2 = 9 cards
    expect(large, small);
    expect(small, lessThanOrEqualTo(8));
  });

  test('page works inside a caller transaction (as readPage calls it)',
      () async {
    await seed.click('track', 'a', at: 100);
    final b = await boundary();
    final got = await db.transaction(
      () => repo.page(boundaryLocalId: b, limit: 5),
    );
    expect(_entities(got), ['track:a']);
  });

  group('an entity that vanishes before hydration', () {
    test('is dropped and the slice fills from the next eligible entries',
        () async {
      final browse = _VanishingAlbums(db, {1});
      repo = RecentlyPlayedRepository(db, browse);
      await seed.click('track', 'a', at: 500);
      await seed.click('album', 'srv-1:1', at: 400); // vanishes
      await seed.click('track', 'b', at: 300);
      await seed.click('album', 'srv-1:3', at: 200);
      await seed.click('track', 'c', at: 100);

      final got = await repo.page(boundaryLocalId: await boundary(), limit: 3);
      expect(_entities(got), ['track:a', 'track:b', 'album:3']);
    });

    test('a short slice stays short once history is exhausted', () async {
      repo = RecentlyPlayedRepository(db, _VanishingAlbums(db, {1, 3}));
      await seed.click('album', 'srv-1:1', at: 400);
      await seed.click('track', 'a', at: 300);
      await seed.click('album', 'srv-1:3', at: 200);

      final got = await repo.page(boundaryLocalId: await boundary(), limit: 3);
      expect(_entities(got), ['track:a']);
    });
  });
}
