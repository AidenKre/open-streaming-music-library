import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
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

  test('getAlbums returns AlbumUI list in order', () async {
    await fixture.insertAlbum(artist: 'Zed', album: 'Zebra', uuids: ['z1']);
    await fixture.insertAlbum(artist: 'Ace', album: 'Alpha', uuids: ['a1']);

    final albums = await repo.getAlbums(
      orderBy: [AlbumOrderParameter(column: 'artist')],
    );

    expect(albums, hasLength(2));
    expect(albums[0].name, 'Alpha');
    expect(albums[1].name, 'Zebra');
  });

  test('getAlbums cursor pagination returns next page', () async {
    await fixture.insertAlbum(artist: 'A', album: 'Album A', uuids: ['a1']);
    await fixture.insertAlbum(artist: 'B', album: 'Album B', uuids: ['b1']);
    await fixture.insertAlbum(artist: 'C', album: 'Album C', uuids: ['c1']);

    final firstPage = await repo.getAlbums(
      orderBy: [AlbumOrderParameter(column: 'artist')],
      limit: 2,
    );
    expect(firstPage, hasLength(2));

    final lastAlbum = firstPage.last;
    final secondPage = await repo.getAlbums(
      orderBy: [AlbumOrderParameter(column: 'artist')],
      cursorFilters: [
        AlbumRowFilterParameter(
          column: 'artist',
          value: lastAlbum.artist,
        ),
      ],
      limit: 2,
    );

    expect(secondPage, hasLength(1));
    expect(secondPage[0].name, 'Album C');
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
}

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
