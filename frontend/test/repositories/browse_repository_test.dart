import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';

void main() {
  late AppDatabase db;
  late BrowseRepository repo;
  late _LibraryFixture fixture;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = BrowseRepository(db);
    fixture = _LibraryFixture(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('watchAlbums returns AlbumUI list in order', () async {
    await fixture.insertAlbum(artist: 'Zed', album: 'Zebra', uuids: ['z1']);
    await fixture.insertAlbum(artist: 'Ace', album: 'Alpha', uuids: ['a1']);

    final albums = await repo
        .watchAlbums(orderBy: [AlbumOrderParameter(column: 'artist')])
        .first;

    expect(albums, hasLength(2));
    expect(albums[0].name, 'Alpha');
    expect(albums[1].name, 'Zebra');
  });

  test('getTracksForAlbum returns tracks for specific album', () async {
    await fixture.insertAlbum(
      artist: 'Artist',
      album: 'Target Album',
      uuids: ['t1', 't2'],
    );
    await fixture.insertAlbum(
      artist: 'Artist',
      album: 'Other Album',
      uuids: ['o1'],
    );

    final tracks = await repo.getTracksForAlbum(1, 1);

    expect(tracks, hasLength(2));
    expect(tracks.every((t) => t.album == 'Target Album'), isTrue);
  });

  test('getTrack returns the matching track by uuid', () async {
    await fixture.insertAlbum(
      artist: 'Artist', album: 'Target Album', uuids: ['t1', 't2'],
    );

    final track = await repo.getTrack('t2');

    expect(track != null, true);
    expect(track!.uuidId, 't2');
    expect(track.album, 'Target Album');
  });

  test('getTrack returns null for an unknown uuid', () async {
    final track = await repo.getTrack('no-such-uuid');
    expect(track, null);
  });

  test('getTracksForArtist returns tracks for specific artist', () async {
    await fixture.insertAlbum(
      artist: 'Target',
      album: 'Album 1',
      uuids: ['t1', 't2'],
    );
    await fixture.insertAlbum(
      artist: 'Other',
      album: 'Album 2',
      uuids: ['o1'],
    );

    final tracks = await repo.getTracksForArtist(1);

    expect(tracks, hasLength(2));
    expect(tracks.every((t) => t.artist == 'Target'), isTrue);
  });

  test('search returns empty results for empty query', () async {
    await fixture.insertAlbum(
      artist: 'Beatles',
      album: 'Abbey Road',
      uuids: ['ar1'],
    );

    final results = await repo.search('');

    expect(results.artists, isEmpty);
    expect(results.albums, isEmpty);
    expect(results.tracks, isEmpty);
  });

  test('search downloadedOnly filters before LIMIT, keeping a low-ranked match',
      () async {
    // 6 artists/albums/tracks all matching "Blue"; only the 6th is
    // downloaded. With limitPerType 5 a naive post-filter on the top-5 FTS
    // hits would miss the 6th — the filter must run inside the query.
    for (var i = 1; i <= 6; i++) {
      await fixture.insertAlbum(
        artist: 'Blue Artist $i',
        album: 'Blue Album $i',
        uuids: ['blue$i'],
        trackTitlePrefix: 'Blue Song',
      );
    }
    await (db.update(db.tracks)..where((t) => t.uuidId.equals('blue6')))
        .write(const TracksCompanion(filePath: Value('/tmp/blue6.m4a')));
    await _populateFts(db);

    final results =
        await repo.search('Blue', limitPerType: 5, downloadedOnly: true);

    expect(results.tracks.map((t) => t.uuidId), ['blue6']);
    expect(results.artists.map((a) => a.name), ['Blue Artist 6']);
    expect(results.albums.map((a) => a.name), ['Blue Album 6']);
  });

  test('search without downloadedOnly is still capped at limitPerType',
      () async {
    for (var i = 1; i <= 6; i++) {
      await fixture.insertAlbum(
        artist: 'Blue Artist $i',
        album: 'Blue Album $i',
        uuids: ['blue$i'],
        trackTitlePrefix: 'Blue Song',
      );
    }
    await _populateFts(db);

    final results = await repo.search('Blue', limitPerType: 5);

    expect(results.tracks, hasLength(5));
  });

  group('search types', () {
    setUp(() async {
      // "Blue" matches the artist, the album and the track.
      await fixture.insertAlbum(
        artist: 'Blue Artist',
        album: 'Blue Album',
        uuids: ['b1'],
        trackTitlePrefix: 'Blue Song',
      );
      await _populateFts(db);
    });

    test('defaults to every type', () async {
      final results = await repo.search('Blue');
      expect(results.artists, hasLength(1));
      expect(results.albums, hasLength(1));
      expect(results.tracks, hasLength(1));
    });

    test('{tracks} returns only tracks', () async {
      final results = await repo.search('Blue', types: {SearchType.tracks});
      expect(results.tracks.map((t) => t.uuidId), ['b1']);
      expect(results.artists, isEmpty);
      expect(results.albums, isEmpty);
    });

    test('{artists} returns only artists', () async {
      final results = await repo.search('Blue', types: {SearchType.artists});
      expect(results.artists.map((a) => a.name), ['Blue Artist']);
      expect(results.albums, isEmpty);
      expect(results.tracks, isEmpty);
    });

    test('{albums} returns only albums', () async {
      final results = await repo.search('Blue', types: {SearchType.albums});
      expect(results.albums.map((a) => a.name), ['Blue Album']);
      expect(results.artists, isEmpty);
      expect(results.tracks, isEmpty);
    });

    test('an empty type set returns nothing', () async {
      final results = await repo.search('Blue', types: const {});
      expect(results.artists, isEmpty);
      expect(results.albums, isEmpty);
      expect(results.tracks, isEmpty);
    });

    test('downloadedOnly still applies to a single type', () async {
      for (final type in SearchType.values) {
        final none = await repo.search(
          'Blue',
          types: {type},
          downloadedOnly: true,
        );
        expect(none.artists, isEmpty, reason: '$type: nothing downloaded');
        expect(none.albums, isEmpty, reason: '$type: nothing downloaded');
        expect(none.tracks, isEmpty, reason: '$type: nothing downloaded');
      }

      await _markDownloaded(db, 'b1');
      final artists = await repo.search(
        'Blue',
        types: {SearchType.artists},
        downloadedOnly: true,
      );
      expect(artists.artists.map((a) => a.name), ['Blue Artist']);
      final albums = await repo.search(
        'Blue',
        types: {SearchType.albums},
        downloadedOnly: true,
      );
      expect(albums.albums.map((a) => a.name), ['Blue Album']);
      final tracks = await repo.search(
        'Blue',
        types: {SearchType.tracks},
        downloadedOnly: true,
      );
      expect(tracks.tracks.map((t) => t.uuidId), ['b1']);
    });

    test('a limitPerType outside 1..998 is a programming error', () async {
      // SQLite reads a negative LIMIT as "no limit".
      for (final limit in [-1, 0, 999]) {
        expect(
          () => repo.search('Blue', limitPerType: limit),
          throwsA(isA<AssertionError>()),
          reason: '$limit',
        );
      }
    });
  });

  group('browse and search agree', () {
    // Track 1 has art but isn't downloaded; track 2 is downloaded with
    // different art. Filtered, only track 2's art resolves offline.
    setUp(() async {
      await fixture.insertAlbum(
        artist: 'Cover Artist',
        album: 'Cover Album',
        uuids: ['c1', 'c2'],
      );
      for (final (uuid, art) in [('c1', 10), ('c2', 20)]) {
        await (db.update(
          db.trackmetadata,
        )..where((t) => t.uuidId.equals(uuid))).write(
          TrackmetadataCompanion(
            hasAlbumArt: const Value(true),
            coverArtId: Value(art),
          ),
        );
      }
      await _markDownloaded(db, 'c2');
      await _populateFts(db);
    });

    for (final downloadedOnly in [false, true]) {
      test('cover art (downloadedOnly: $downloadedOnly)', () async {
        final browseArtist = (await repo
                .watchArtists(downloadedOnly: downloadedOnly)
                .first)
            .single;
        final browseAlbum = (await repo
                .watchAlbums(downloadedOnly: downloadedOnly)
                .first)
            .single;
        final found = await repo.search(
          'Cover',
          types: {SearchType.artists, SearchType.albums},
          downloadedOnly: downloadedOnly,
        );
        expect(browseArtist.coverArtId, downloadedOnly ? 20 : 10);
        expect(found.artists.single.coverArtId, browseArtist.coverArtId);
        expect(browseAlbum.coverArtId, downloadedOnly ? 20 : 10);
        expect(found.albums.single.coverArtId, browseAlbum.coverArtId);
      });
    }

    test('downloaded-only membership: a query matching everything returns '
        'exactly the filtered browse set, per type', () async {
      await fixture.insertAlbum(
        artist: 'Cover Remote',
        album: 'Cover Remote Album',
        uuids: ['r1'],
        trackTitlePrefix: 'Cover Song',
      );
      await fixture.insertAlbum(
        artist: 'Cover Late',
        album: 'Cover Late Album',
        uuids: ['l1', 'l2', 'l3'],
        trackTitlePrefix: 'Cover Song',
      );
      // Only a later track of "Cover Late" is downloaded.
      await _markDownloaded(db, 'l3');
      await _populateFts(db);

      final found = await repo.search(
        'Cover',
        limitPerType: 100,
        downloadedOnly: true,
      );
      final artists = await repo.watchArtists(downloadedOnly: true).first;
      final albums = await repo.watchAlbums(downloadedOnly: true).first;
      final tracks = await repo.watchTracks(downloadedOnly: true).first;
      expect(
        found.artists.map((a) => a.name).toSet(),
        artists.map((a) => a.name).toSet(),
      );
      expect(
        found.albums.map((a) => a.name).toSet(),
        albums.map((a) => a.name).toSet(),
      );
      expect(
        found.tracks.map((t) => t.uuidId).toSet(),
        tracks.map((t) => t.uuidId).toSet(),
      );
      expect(artists.map((a) => a.name), contains('Cover Late'));
      expect(artists.map((a) => a.name), isNot(contains('Cover Remote')));
    });
  });

  test('a single-type search at the in-page cap returns exactly the top N '
      'in FTS rank order', () async {
    for (var i = 1; i <= 120; i++) {
      await fixture.insertAlbum(
        artist: 'Artist $i',
        album: 'Album $i',
        uuids: ['t$i'],
        trackTitlePrefix: i.isEven ? 'Blue Blue Song' : 'Blue Song',
      );
    }
    await _populateFts(db);

    final results = await repo.search(
      'Blue',
      types: {SearchType.tracks},
      limitPerType: 100,
    );

    final expected = await db.customSelect(
      'SELECT tm.uuid_id FROM fts_tracks '
      'JOIN trackmetadata tm ON tm.rowid = fts_tracks.rowid '
      'WHERE fts_tracks MATCH ? ORDER BY rank LIMIT 100',
      variables: [Variable.withString(prepareFtsQuery('Blue'))],
    ).get();
    expect(results.tracks, hasLength(100));
    expect(
      results.tracks.map((t) => t.uuidId).toList(),
      expected.map((r) => r.read<String>('uuid_id')).toList(),
    );
  });

  group('in-page cap boundaries (single type, cap 100)', () {
    setUp(() async {
      // Disjoint tokens with exactly 99, 100 and 101 matching artists, each
      // a real artist with one track whose title carries the same token.
      for (final (token, n) in [
        ('alpha', 99),
        ('bravo', 100),
        ('charlie', 101),
      ]) {
        for (var i = 1; i <= n; i++) {
          await fixture.insertAlbum(
            artist: '$token Artist $i',
            album: '$token Album $i',
            uuids: ['$token$i'],
            trackTitlePrefix: '$token Song',
          );
        }
      }
      await _populateFts(db);
    });

    for (final (token, n) in [
      ('alpha', 99),
      ('bravo', 100),
      ('charlie', 100),
    ]) {
      test('"$token" → $n artists and $n tracks', () async {
        final artists = await repo.search(
          token,
          types: {SearchType.artists},
          limitPerType: 100,
        );
        final tracks = await repo.search(
          token,
          types: {SearchType.tracks},
          limitPerType: 100,
        );
        expect(artists.artists, hasLength(n));
        expect(tracks.tracks, hasLength(n));
        expect(artists.artists.map((a) => a.id).toSet(), hasLength(n));
        expect(tracks.tracks.map((t) => t.uuidId).toSet(), hasLength(n));
        expect(artists.artists.every((a) => a.name.startsWith(token)), isTrue);
      });
    }

    test('a refined query reaches a match the cap excluded', () async {
      final capped = await repo.search(
        'charlie',
        types: {SearchType.artists},
        limitPerType: 100,
      );
      final all = List.generate(101, (i) => 'charlie Artist ${i + 1}');
      final excluded = all.toSet().difference(
        capped.artists.map((a) => a.name).toSet(),
      );
      expect(excluded, hasLength(1));
      final number = excluded.single.split(' ').last;
      final refined = await repo.search(
        'charlie artist $number',
        types: {SearchType.artists},
        limitPerType: 100,
      );
      expect(refined.artists.map((a) => a.name), contains(excluded.single));
    });
  });

  test('artists: downloadedOnly applies before the cap, so a downloaded '
      'artist ranked outside the unfiltered top 100 is found', () async {
    for (var i = 1; i <= 120; i++) {
      await fixture.insertAlbum(
        artist: 'Blue $i',
        album: 'Album $i',
        uuids: ['u$i'],
      );
    }
    // Longer name → lower bm25 score → ranked below every "Blue N".
    await fixture.insertAlbum(
      artist: 'Blue with a much longer name than the others',
      album: 'Low Album',
      uuids: ['low'],
    );
    await (db.update(db.tracks)..where((t) => t.uuidId.equals('low'))).write(
      const TracksCompanion(filePath: Value('/dl/low.flac')),
    );
    await _populateFts(db);

    final unfiltered = await repo.search(
      'Blue',
      types: {SearchType.artists},
      limitPerType: 100,
    );
    expect(unfiltered.artists, hasLength(100));
    expect(
      unfiltered.artists.map((a) => a.name),
      isNot(contains(startsWith('Blue with'))),
      reason: 'precondition: the downloaded artist is outside the top 100',
    );

    final filtered = await repo.search(
      'Blue',
      types: {SearchType.artists},
      limitPerType: 100,
      downloadedOnly: true,
    );
    expect(filtered.artists.map((a) => a.name), [
      'Blue with a much longer name than the others',
    ]);
  });

  test('rank order puts the stronger matches first (independent of the '
      'query text)', () async {
    for (var i = 1; i <= 120; i++) {
      await fixture.insertAlbum(
        artist: 'Artist $i',
        album: 'Album $i',
        uuids: ['t$i'],
        trackTitlePrefix: i.isEven ? 'Blue Blue Song' : 'Blue Song',
      );
    }
    await _populateFts(db);
    final results = await repo.search(
      'Blue',
      types: {SearchType.tracks},
      limitPerType: 100,
    );
    final evens = {for (var i = 2; i <= 120; i += 2) 't$i'};
    expect(
      results.tracks.take(60).map((t) => t.uuidId).toSet(),
      evens,
      reason: 'two "Blue" tokens outrank one',
    );
  });

  test('malformed or punctuation-heavy input never throws and stays '
      'within the requested type', () async {
    await fixture.insertAlbum(
      artist: "Guns N' Roses",
      album: 'Appetite',
      uuids: ['g1'],
      trackTitlePrefix: 'Sweet Child O\' Mine',
    );
    await fixture.insertAlbum(
      artist: 'Beyoncé',
      album: 'Lemonade',
      uuids: ['b1'],
      trackTitlePrefix: 'Hold Up',
    );
    await _populateFts(db);
    const inputs = [
      '"',
      "'",
      '""',
      '-',
      '*',
      '^',
      '(',
      ')',
      ':',
      'AND',
      'OR',
      'NOT',
      'NEAR(',
      'a"b',
      'x OR',
      '-roses',
      'roses*',
      '    ',
      '\t',
      'ü',
      '😀',
    ];
    for (final q in inputs) {
      for (final type in SearchType.values) {
        final r = await repo.search(q, types: {type}, limitPerType: 100);
        if (type != SearchType.artists) expect(r.artists, isEmpty, reason: q);
        if (type != SearchType.albums) expect(r.albums, isEmpty, reason: q);
        if (type != SearchType.tracks) expect(r.tracks, isEmpty, reason: q);
      }
    }
    // Operator characters are quoted away, not dropped with their term.
    for (final q in ['-roses', 'roses*', '"roses"', 'roses:']) {
      final r = await repo.search(q, types: {SearchType.artists});
      expect(r.artists.map((a) => a.name), ["Guns N' Roses"], reason: q);
    }
    // Every term must match (AND), each as a prefix.
    final both = await repo.search('gun ros', types: {SearchType.artists});
    expect(both.artists.map((a) => a.name), ["Guns N' Roses"]);
    final oneMissing = await repo.search(
      'guns zzz',
      types: {SearchType.artists},
    );
    expect(oneMissing.artists, isEmpty);
    // Tokenizer behaviour the live run relies on (unicode61, prefix terms).
    final apostrophe = await repo.search(
      "guns n'",
      types: {SearchType.artists},
    );
    expect(apostrophe.artists.map((a) => a.name), ["Guns N' Roses"]);
    final unaccented = await repo.search(
      'beyonce',
      types: {SearchType.artists},
    );
    expect(unaccented.artists.map((a) => a.name), ['Beyoncé']);
    final mixedCase = await repo.search(
      'sWEET chi',
      types: {SearchType.tracks},
    );
    expect(mixedCase.tracks.map((t) => t.uuidId), ['g1']);
  });
  group('withFreshDownloadState', () {
    Future<List<TrackUI>> loadTracks() =>
        repo.watchTracks(orderBy: [OrderParameter(column: 'uuid_id')]).first;

    setUp(() async {
      await fixture.insertAlbum(
        artist: 'A',
        album: 'B',
        uuids: ['p1', 'p2', 'p3'],
      );
    });

    test('re-reads every download/staleness field together', () async {
      final before = await loadTracks();
      expect(before.every((t) => !t.isDownloaded), isTrue);

      await (db.update(db.tracks)..where((t) => t.uuidId.equals('p2'))).write(
        const TracksCompanion(
          filePath: Value('/dl/p2.m4a'),
          downloadedBitrateKbps: Value(256),
          fileSizeBytes: Value(4096),
          downloadedQuality: Value('high'),
          revision: Value(9),
          downloadedAtRevision: Value(8),
          downloadedCodec: Value('aac'),
          staleDismissedAtRevision: Value(7),
        ),
      );

      final after = await repo.withFreshDownloadState(before);
      final p2 = after[1];
      expect(p2.uuidId, 'p2');
      expect(p2.filePath, '/dl/p2.m4a');
      expect(p2.downloadedBitrateKbps, 256);
      expect(p2.fileSizeBytes, 4096);
      expect(p2.downloadedQuality, 'high');
      expect(p2.revision, 9);
      expect(p2.downloadedAtRevision, 8);
      expect(p2.downloadedCodec, 'aac');
      expect(p2.staleDismissedAtRevision, 7);
      expect(p2.title, before[1].title, reason: 'metadata untouched');
    });

    test('preserves order and length, matching each row by uuid', () async {
      final before = await loadTracks();
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('p1')))
          .write(const TracksCompanion(filePath: Value('/dl/p1.flac')));
      final shuffled = [before[2], before[0], before[1]];
      final after = await repo.withFreshDownloadState(shuffled);
      expect(after.map((t) => t.uuidId), ['p3', 'p1', 'p2']);
      expect(after.map((t) => t.isDownloaded), [false, true, false]);
    });

    test('reflects a cleared download', () async {
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('p1')))
          .write(const TracksCompanion(filePath: Value('/dl/p1.flac')));
      final before = await loadTracks();
      expect(before.first.isDownloaded, isTrue);

      await (db.update(db.tracks)..where((t) => t.uuidId.equals('p1')))
          .write(clearedDownloadColumns);
      final after = await repo.withFreshDownloadState(before);
      expect(after.first.filePath, equals(null));
      expect(after.first.isDownloaded, isFalse);
    });

    test('a cleared download nulls every download column on the row', () async {
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('p1'))).write(
        const TracksCompanion(
          filePath: Value('/dl/p1.m4a'),
          downloadedBitrateKbps: Value(256),
          fileSizeBytes: Value(4096),
          downloadedQuality: Value('high'),
          downloadedAtRevision: Value(8),
          downloadedCodec: Value('aac'),
          staleDismissedAtRevision: Value(7),
        ),
      );
      final before = await loadTracks();
      await (db.update(
        db.tracks,
      )..where((t) => t.uuidId.equals('p1'))).write(clearedDownloadColumns);
      final p1 = (await repo.withFreshDownloadState(before)).first;
      expect(p1.filePath, equals(null));
      expect(p1.downloadedBitrateKbps, equals(null));
      expect(p1.fileSizeBytes, equals(null));
      expect(p1.downloadedQuality, equals(null));
      expect(p1.downloadedAtRevision, equals(null));
      expect(p1.downloadedCodec, equals(null));
      expect(p1.staleDismissedAtRevision, equals(null));
      expect(p1.revision, before.first.revision, reason: 'not a download col');
    });
    test('leaves a row whose track vanished unchanged', () async {
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('p3')))
          .write(const TracksCompanion(filePath: Value('/dl/p3.flac')));
      final before = await loadTracks();
      await (db.delete(db.trackmetadata)..where((t) => t.uuidId.equals('p3')))
          .go();
      await (db.delete(db.tracks)..where((t) => t.uuidId.equals('p3'))).go();

      final after = await repo.withFreshDownloadState(before);
      expect(after, hasLength(3));
      expect(after[2].filePath, '/dl/p3.flac');
    });

    test('an empty list stays empty', () async {
      expect(await repo.withFreshDownloadState(const []), isEmpty);
    });
  });
}

/// Mirrors the FTS population the sync pipeline performs in production.
Future<void> _populateFts(AppDatabase db) => db.rebuildFtsIndexes();

Future<void> _markDownloaded(AppDatabase db, String uuid) =>
    (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid))).write(
      TracksCompanion(filePath: Value('/dl/$uuid.flac')),
    );

class _LibraryFixture {
  final AppDatabase db;
  int _nextArtistId = 1;
  int _nextAlbumId = 1;
  final Map<String, int> _artistIds = {};
  final Map<String, int> _albumIds = {};

  _LibraryFixture(this.db);

  Future<void> insertAlbum({
    required String artist,
    required String album,
    required List<String> uuids,
    String? trackTitlePrefix,
  }) async {
    final artistId = await _ensureArtist(artist);
    final albumId = await _ensureAlbum(artistId, album);
    for (var i = 0; i < uuids.length; i++) {
      await _insertTrack(
        uuid: uuids[i],
        artist: artist,
        artistId: artistId,
        album: album,
        albumId: albumId,
        trackNumber: i + 1,
        title: trackTitlePrefix != null
            ? '$trackTitlePrefix ${i + 1}'
            : 'Track ${uuids[i]}',
      );
    }
  }

  Future<int> _ensureArtist(String name) async {
    final key = name.toLowerCase();
    final existing = _artistIds[key];
    if (existing != null) return existing;

    final id = _nextArtistId++;
    await db
        .into(db.artists)
        .insert(ArtistsCompanion(id: Value(id), name: Value(name)));
    _artistIds[key] = id;
    return id;
  }

  Future<int> _ensureAlbum(int artistId, String name) async {
    final key = '$artistId:${name.toLowerCase()}';
    final existing = _albumIds[key];
    if (existing != null) return existing;

    final id = _nextAlbumId++;
    await db
        .into(db.albums)
        .insert(
          AlbumsCompanion(
            id: Value(id),
            name: Value(name),
            artistId: Value(artistId),
            year: const Value(2024),
            isSingleGrouping: const Value(false),
          ),
        );
    _albumIds[key] = id;
    return id;
  }

  Future<void> _insertTrack({
    required String uuid,
    required String artist,
    required int artistId,
    required String album,
    required int albumId,
    required int trackNumber,
    String? title,
  }) async {
    final dto = ClientTrackDto.fromJson({
      'uuid_id': uuid,
      'created_at': 1700000000 + trackNumber,
      'last_updated': 1700000100 + trackNumber,
      'revision': 1700000000 + trackNumber,
      'metadata': {
        'title': title ?? 'Track $uuid',
        'artist': artist,
        'album': album,
        'artist_id': artistId,
        'album_id': albumId,
        'track_number': trackNumber,
        'disc_number': 1,
        'duration': 180.0,
        'bitrate_kbps': 320.0,
        'sample_rate_hz': 44100,
        'channels': 2,
        'has_album_art': false,
      },
    });

    await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
    await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
  }
}
