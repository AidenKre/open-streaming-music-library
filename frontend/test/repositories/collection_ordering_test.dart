import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/collection_ordering.dart';
import 'package:frontend/repositories/queue_repository.dart';

import '../ui/browse_harness.dart';

/// Ordering primitives shared by the browse watch queries and the queue
/// insert (real in-memory SQLite). Expected orders are written out by hand,
/// never derived from the SQL under test.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('track ORDER BY: nullsAs and caseInsensitive', () {
    // Album 1. Keys under (disc ?? 0, track ?? 0, title nocase, uuid):
    //   t3 (0,0,'zed')  t2 (0,1,'alpha')  t1 (0,1,'beta')
    //   u-a (1,1,'same')  u-b (1,1,'Same')  -> tie on title, uuid decides
    const seed = [
      SeedTrack(uuid: 't1', title: 'beta', artistId: 1, artist: 'A',
          albumId: 1, album: 'X', discNumber: null, trackNumber: 1),
      SeedTrack(uuid: 't2', title: 'alpha', artistId: 1, artist: 'A',
          albumId: 1, album: 'X', discNumber: 0, trackNumber: 1),
      SeedTrack(uuid: 't3', title: 'Zed', artistId: 1, artist: 'A',
          albumId: 1, album: 'X', discNumber: 0, trackNumber: null),
      SeedTrack(uuid: 'u-b', title: 'Same', artistId: 1, artist: 'A',
          albumId: 1, album: 'X', discNumber: 1, trackNumber: 1),
      SeedTrack(uuid: 'u-a', title: 'same', artistId: 1, artist: 'A',
          albumId: 1, album: 'X', discNumber: 1, trackNumber: 1),
    ];
    const expected = ['t3', 't2', 't1', 'u-a', 'u-b'];

    List<OrderParameter> order() => [
      OrderParameter(column: 'disc_number', nullsAs: 0),
      OrderParameter(column: 'track_number', nullsAs: 0),
      OrderParameter(column: 'title', caseInsensitive: true),
      OrderParameter(column: 'uuid_id'),
    ];

    setUp(() => seedLibrary(db, seed));

    test('watchTracks applies the keys', () async {
      final rows = await db
          .watchTracks(orderBy: order(), artistId: 1, albumId: 1)
          .first;
      expect(rows.map((r) => r.read<String>('uuid_id')), expected);
    });

    test('getTrackUuids applies the same keys', () async {
      expect(
        await db.getTrackUuids(orderBy: order(), artistId: 1, albumId: 1),
        expected,
      );
    });

    test('a queue built from the query has the same order', () async {
      final repo = QueueRepository(db);
      final sessionId = await repo.createSessionFromQuery(
        sourceType: 'album',
        sourceArtistId: 1,
        sourceAlbumId: 1,
        currentUuid: 't1',
        orderBy: order(),
      );
      final entries = await repo.getPlaybackEntries(sessionId);
      expect(entries.map((e) => e.uuidId), expected);
    });

    test('nullsAs/caseInsensitive cannot be combined with a cursor', () {
      expect(
        () => db.getTracks(
          orderBy: [OrderParameter(column: 'disc_number', nullsAs: 0)],
          cursorFilters: [RowFilterParameter(column: 'disc_number', value: 1)],
        ),
        throwsArgumentError,
      );
    });
  });

  group('CollectionOrdering.albumTracks via BrowseRepository', () {
    test('album detail orders by disc, track (missing = 0), title, uuid',
        () async {
      // Same keys as above; the order is a model rule now, not a view list.
      await seedLibrary(db, const [
        SeedTrack(uuid: 't1', title: 'beta', artistId: 1, artist: 'A',
            albumId: 1, album: 'X', discNumber: null, trackNumber: 1),
        SeedTrack(uuid: 't2', title: 'alpha', artistId: 1, artist: 'A',
            albumId: 1, album: 'X', discNumber: 0, trackNumber: 1),
        SeedTrack(uuid: 't3', title: 'Zed', artistId: 1, artist: 'A',
            albumId: 1, album: 'X', discNumber: 0, trackNumber: null),
        SeedTrack(uuid: 'u-b', title: 'Same', artistId: 1, artist: 'A',
            albumId: 1, album: 'X', discNumber: 1, trackNumber: 1),
        SeedTrack(uuid: 'u-a', title: 'same', artistId: 1, artist: 'A',
            albumId: 1, album: 'X', discNumber: 1, trackNumber: 1),
      ]);
      final tracks = await BrowseRepository(db)
          .watchTracks(album: const AlbumScope(artistId: 1, albumId: 1))
          .first;
      expect(tracks.map((t) => t.uuidId), ['t3', 't2', 't1', 'u-a', 'u-b']);
    });

    test('a compilation follows track numbers, not track artists', () async {
      // Album 5 by "Various" (artist 9); the track artists differ. The old
      // view order (artist, album, disc, track) put Amy's track 2 first.
      // Inserted out of order, and uuids sort against the track numbers, so
      // neither insertion order nor a uuid fallback can pass this.
      await seedLibrary(db, const [
        SeedTrack(uuid: 'a-second', title: 'Second', artistId: 9,
            artist: 'Amy', albumId: 5, album: 'Hits', trackNumber: 2),
        SeedTrack(uuid: 'm-third', title: 'Third', artistId: 9, artist: 'Moe',
            albumId: 5, album: 'Hits', trackNumber: 3),
        SeedTrack(uuid: 'z-first', title: 'First', artistId: 9, artist: 'Zed',
            albumId: 5, album: 'Hits', trackNumber: 1),
      ]);
      final tracks = await BrowseRepository(db)
          .watchTracks(album: const AlbumScope(artistId: 9, albumId: 5))
          .first;
      expect(tracks.map((t) => t.uuidId), ['z-first', 'a-second', 'm-third']);
    });

    test('a queue built with the album ordering matches the album page',
        () async {
      await seedLibrary(db, const [
        SeedTrack(uuid: 'a-second', title: 'Second', artistId: 9,
            artist: 'Amy', albumId: 5, album: 'Hits', trackNumber: 2),
        SeedTrack(uuid: 'z-first', title: 'First', artistId: 9, artist: 'Zed',
            albumId: 5, album: 'Hits', trackNumber: 1),
      ]);
      final repo = QueueRepository(db);
      final sessionId = await repo.createSessionFromQuery(
        sourceType: 'album',
        sourceArtistId: 9,
        sourceAlbumId: 5,
        currentUuid: 'a-second',
        orderBy: CollectionOrdering.albumTracks,
      );
      final entries = await repo.getPlaybackEntries(sessionId);
      expect(entries.map((e) => e.uuidId), ['z-first', 'a-second']);
    });

    test('the whole library keeps artist, album, disc, track, uuid', () async {
      await seedLibrary(db, const [
        SeedTrack(uuid: 'b2', title: 'x', artistId: 2, artist: 'Bea',
            albumId: 2, album: 'B', trackNumber: 2),
        SeedTrack(uuid: 'a1', title: 'y', artistId: 1, artist: 'Ace',
            albumId: 1, album: 'Z', trackNumber: 1),
        SeedTrack(uuid: 'b1', title: 'z', artistId: 2, artist: 'Bea',
            albumId: 2, album: 'B', trackNumber: 1),
      ]);
      final tracks = await BrowseRepository(db).watchTracks().first;
      expect(tracks.map((t) => t.uuidId), ['a1', 'b1', 'b2']);
    });
  });

  group('album and artist grid order via BrowseRepository', () {
    // Artist 1's albums, inserted in id order. Grid order: year newest first
    // (unknown last), then Singles last, then name (case-insensitive), then
    // album id.
    const seed = [
      SeedTrack(uuid: 'a', title: 'a', artistId: 1, artist: 'Ann',
          albumId: 1, album: 'Old', albumYear: 2001),
      SeedTrack(uuid: 'b', title: 'b', artistId: 1, artist: 'Ann',
          albumId: 2, album: 'Beta', albumYear: 2010),
      SeedTrack(uuid: 'c', title: 'c', artistId: 1, artist: 'Ann',
          albumId: 3, album: 'Undated'),
      SeedTrack(uuid: 's', title: 's', artistId: 1, artist: 'Ann',
          albumId: 4, album: 'Ann - Singles', albumIsSingles: true),
      SeedTrack(uuid: 'd', title: 'd', artistId: 1, artist: 'Ann',
          albumId: 5, album: 'alpha', albumYear: 2010),
    ];

    setUp(() => seedLibrary(db, seed));

    test("an artist's albums follow the grid order", () async {
      final albums = await BrowseRepository(db).watchAlbums(artistId: 1).first;
      expect(albums.map((a) => a.id), [5, 2, 1, 3, 4]);
    });

    test('all albums order by artist name first', () async {
      await seedLibrary(db, const [
        SeedTrack(uuid: 'z', title: 'z', artistId: 2, artist: 'Aaron',
            albumId: 9, album: 'Zed', albumYear: 1990),
      ]);
      final albums = await BrowseRepository(db).watchAlbums().first;
      expect(albums.map((a) => a.id), [9, 5, 2, 1, 3, 4]);
    });

    // Characterization: the artist list order is unchanged by Phase 4.
    test('artists order by name, case-insensitively', () async {
      await seedLibrary(db, const [
        SeedTrack(uuid: 'x', title: 'x', artistId: 3, artist: 'adele'),
        SeedTrack(uuid: 'y', title: 'y', artistId: 4, artist: 'Bob'),
      ]);
      final artists = await BrowseRepository(db).watchArtists().first;
      expect(artists.map((a) => a.name), ['adele', 'Ann', 'Bob']);
    });
  });

  group('getTracksForScope (the one membership query)', () {
    late BrowseRepository repo;

    // Artist 1: album 2 (2010; tracks out of order), album 1 (2001), album 3
    // (Singles). Artist 2 owns album 4. Inserted out of display order.
    const seed = [
      SeedTrack(uuid: 'a1', title: 'a1', artistId: 1, artist: 'Ann',
          albumId: 1, album: 'Old', albumYear: 2001, trackNumber: 1),
      SeedTrack(uuid: 's1', title: 's1', artistId: 1, artist: 'Ann',
          albumId: 3, album: 'Ann - Singles', albumIsSingles: true),
      SeedTrack(uuid: 'n2', title: 'n2', artistId: 1, artist: 'Ann',
          albumId: 2, album: 'New', albumYear: 2010, trackNumber: 2),
      SeedTrack(uuid: 'n1', title: 'n1', artistId: 1, artist: 'Ann',
          albumId: 2, album: 'New', albumYear: 2010, trackNumber: 1),
      SeedTrack(uuid: 'o1', title: 'o1', artistId: 2, artist: 'Other',
          albumId: 4, album: 'Else', albumYear: 2020),
    ];

    setUp(() async {
      await seedLibrary(db, seed);
      repo = BrowseRepository(db);
    });

    Future<List<String>> uuids(LibraryScope scope, {bool offline = false}) =>
        repo
            .getTracksForScope(scope, offline: offline)
            .then((t) => t.map((x) => x.uuidId).toList());

    test('an album plays in its detail order', () async {
      expect(await uuids(const AlbumScope(artistId: 1, albumId: 2)),
          ['n1', 'n2']);
    });

    test("an artist plays its grid's albums in order, each in album order",
        () async {
      expect(await uuids(const ArtistScope(artistId: 1)),
          ['n1', 'n2', 'a1', 's1']);
    });

    test('track scopes are their own membership, in order', () async {
      final tracks = await repo.watchTracks().first;
      final byUuid = {for (final t in tracks) t.uuidId: t};
      expect(await uuids(TrackScope(byUuid['o1']!)), ['o1']);
      expect(
        await uuids(TracksScope([byUuid['s1']!, byUuid['a1']!])),
        ['s1', 'a1'],
      );
    });

    test('Phase 4: offline does not change membership (Phase 6 will)',
        () async {
      await markDownloaded(db, 'n1');
      expect(await uuids(const AlbumScope(artistId: 1, albumId: 2),
          offline: true), ['n1', 'n2']);
      expect(await uuids(const ArtistScope(artistId: 1), offline: true),
          ['n1', 'n2', 'a1', 's1']);
    });

    test('an unknown album or artist has no members', () async {
      expect(await uuids(const AlbumScope(artistId: 1, albumId: 99)), isEmpty);
      expect(await uuids(const ArtistScope(artistId: 99)), isEmpty);
    });
  });

  group('offline membership of chip-less grids (model rule)', () {
    setUp(() async {
      await seedLibrary(db, const [
        SeedTrack(uuid: 'd', title: 'd', artistId: 1, artist: 'Ann',
            albumId: 1, album: 'Kept', downloaded: true),
        SeedTrack(uuid: 'r', title: 'r', artistId: 1, artist: 'Ann',
            albumId: 2, album: 'Remote'),
        SeedTrack(uuid: 'x', title: 'x', artistId: 2, artist: 'Bo',
            albumId: 3, album: 'Far'),
      ]);
    });

    test('offline, an artist grid keeps only albums with a download',
        () async {
      final repo = BrowseRepository(db);
      expect((await repo.watchAlbums(artistId: 1).first).map((a) => a.id),
          [1, 2]);
      expect(
        (await repo.watchAlbums(artistId: 1, offline: true).first)
            .map((a) => a.id),
        [1],
      );
    });

    test('offline, the artist list keeps only artists with a download',
        () async {
      final repo = BrowseRepository(db);
      expect(
        (await repo.watchArtists(offline: true).first).map((a) => a.id),
        [1],
      );
    });
  });

  test('getTracksForScope: a compilation album plays in track order', () async {
    // Artist, title and uuid orders all disagree with track numbers here.
    await seedLibrary(db, const [
      SeedTrack(uuid: 'a-second', title: 'Alpha', artistId: 9,
          artist: 'Amy', albumId: 5, album: 'Hits', trackNumber: 2),
      SeedTrack(uuid: 'm-third', title: 'Beta', artistId: 9, artist: 'Moe',
          albumId: 5, album: 'Hits', trackNumber: 3),
      SeedTrack(uuid: 'z-first', title: 'Zulu', artistId: 9, artist: 'Zed',
          albumId: 5, album: 'Hits', trackNumber: 1),
    ]);
    final tracks = await BrowseRepository(db).getTracksForScope(
      const AlbumScope(artistId: 9, albumId: 5),
      offline: false,
    );
    expect(tracks.map((t) => t.uuidId), ['z-first', 'a-second', 'm-third']);
  });
}
