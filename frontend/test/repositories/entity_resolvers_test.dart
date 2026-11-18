// SC-12 (6-U07): the by-ID resolvers on BrowseRepository hydrate albums,
// artists and tracks through the same projection as the browse grids, in
// the requested order, dropping IDs that don't resolve.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';

import 'catalog_seed.dart';

/// Every field a card renders, so parity compares whole rows.
Object _album(AlbumUI a) => (
  a.id,
  a.name,
  a.artist,
  a.artistId,
  a.year,
  a.isSingleGrouping,
  a.coverArtId,
);
Object _artist(ArtistUI a) => (a.id, a.name, a.coverArtId);

void main() {
  late AppDatabase db;
  late BrowseRepository repo;
  late CatalogSeed seed;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = BrowseRepository(db);
    seed = CatalogSeed(db);
    // Artist 1 "Aria": regular album 10 (art on a remote track 101 and a
    // downloaded track 201), Singles grouping 11 (year null, no art).
    // Artist 2 "Bram": album 12 (no art at all, one downloaded track).
    // Artist 3 "Cleo": album 13 (art only on a remote track, a download
    // without art) -> no local art.
    await seed.artist(1, 'Aria');
    await seed.artist(2, 'Bram');
    await seed.artist(3, 'Cleo');
    await seed.album(10, artistId: 1, name: 'First', year: 2020);
    await seed.album(11, artistId: 1, single: true);
    await seed.album(12, artistId: 2, name: 'Plain', year: 1999);
    await seed.album(13, artistId: 3, name: 'Remote Art', year: 2001);
    await seed.track('t10a', artistId: 1, albumId: 10, trackNumber: 1, art: 101);
    await seed.track(
      't10b',
      artistId: 1,
      albumId: 10,
      trackNumber: 2,
      art: 201,
      downloaded: true,
    );
    await seed.track('t11a', artistId: 1, albumId: 11, downloaded: true);
    await seed.track('t12a', artistId: 2, albumId: 12, downloaded: true);
    await seed.track('t13a', artistId: 3, albumId: 13, trackNumber: 1, art: 301);
    await seed.track(
      't13b',
      artistId: 3,
      albumId: 13,
      trackNumber: 2,
      downloaded: true,
    );
  });

  tearDown(() => db.close());

  group('getAlbumsByIds', () {
    test('returns the requested albums in the requested order and drops '
        'unknown ids', () async {
      final got = await repo.getAlbumsByIds([13, 99, 10, 11]);
      expect(got.map((a) => a.id), [13, 10, 11]);
    });

    test('an empty request returns nothing', () async {
      expect(await repo.getAlbumsByIds(const []), isEmpty);
    });

    for (final downloadedArtOnly in [false, true]) {
      test('rows equal the browse grid rows (Singles, art / no art, '
          'downloadedArtOnly: $downloadedArtOnly)', () async {
        final browse = await repo
            .watchAlbums(downloadedOnly: downloadedArtOnly)
            .first;
        final ids = browse.map((a) => a.id).toList();
        // All four albums have a usable download, so the filtered grid
        // shows all of them too: the comparison covers every album.
        expect(ids.toSet(), {10, 11, 12, 13});
        final got = await repo.getAlbumsByIds(
          ids,
          downloadedArtOnly: downloadedArtOnly,
        );
        expect(got.map(_album).toList(), browse.map(_album).toList());
      });
    }

    test('independent expectations: Singles flag, null year, artist name, '
        'remote art online and local-only art offline', () async {
      final online = {
        for (final a in await repo.getAlbumsByIds([10, 11, 12, 13])) a.id: a,
      };
      final local = {
        for (final a in await repo.getAlbumsByIds(
          [10, 11, 12, 13],
          downloadedArtOnly: true,
        ))
          a.id: a,
      };
      expect(_album(online[10]!), (10, 'First', 'Aria', 1, 2020, false, 101));
      expect(_album(online[11]!), (11, null, 'Aria', 1, null, true, null));
      expect(_album(online[12]!), (12, 'Plain', 'Bram', 2, 1999, false, null));
      expect(online[13]!.coverArtId, 301);
      // Local-art fallback: only art of a usable download qualifies.
      expect(local[10]!.coverArtId, 201);
      expect(local[13]!.coverArtId, isNull);
    });

    test('a damaged download does not supply local art', () async {
      await seed.album(14, artistId: 2, name: 'Damaged', year: 2010);
      await seed.track('t14a', artistId: 2, albumId: 14, art: 401, damaged: true);
      final local = await repo.getAlbumsByIds([14], downloadedArtOnly: true);
      expect(local.single.coverArtId, isNull);
    });
  });

  group('getArtistsByIds', () {
    test('returns the requested artists in the requested order and drops '
        'unknown ids', () async {
      final got = await repo.getArtistsByIds([3, 42, 1]);
      expect(got.map((a) => a.id), [3, 1]);
    });

    test('an empty request returns nothing', () async {
      expect(await repo.getArtistsByIds(const []), isEmpty);
    });

    for (final downloadedArtOnly in [false, true]) {
      test('rows equal the browse grid rows '
          '(downloadedArtOnly: $downloadedArtOnly)', () async {
        final browse = await repo
            .watchArtists(downloadedOnly: downloadedArtOnly)
            .first;
        final ids = browse.map((a) => a.id).toList();
        expect(ids.toSet(), {1, 2, 3});
        final got = await repo.getArtistsByIds(
          ids,
          downloadedArtOnly: downloadedArtOnly,
        );
        expect(got.map(_artist).toList(), browse.map(_artist).toList());
      });
    }

    test('independent expectations: remote art online, local-only art '
        'offline', () async {
      final online = await repo.getArtistsByIds([1, 2, 3]);
      final local = await repo.getArtistsByIds(
        [1, 2, 3],
        downloadedArtOnly: true,
      );
      expect(online.map(_artist), [(1, 'Aria', 101), (2, 'Bram', null), (3, 'Cleo', 301)]);
      expect(local.map(_artist), [(1, 'Aria', 201), (2, 'Bram', null), (3, 'Cleo', null)]);
    });
  });

  group('getTracksByUuids', () {
    test('returns the requested tracks in the requested order and drops '
        'unknown uuids', () async {
      final got = await repo.getTracksByUuids(['t13b', 'nope', 't10a']);
      expect(got.map((t) => t.uuidId), ['t13b', 't10a']);
    });

    test('rows equal the browse track rows', () async {
      final browse = await repo.watchTracks().first;
      final got = await repo.getTracksByUuids(
        browse.map((t) => t.uuidId).toList(),
      );
      expect(
        got.map((t) => (t.uuidId, t.title, t.albumId, t.artistId, t.isDownloaded)).toList(),
        browse.map((t) => (t.uuidId, t.title, t.albumId, t.artistId, t.isDownloaded)).toList(),
      );
    });
  });
}
