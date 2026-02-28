import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';

Map<String, dynamic> _trackJson({
  String uuid = 'abc-123',
  Map<String, dynamic>? metadata,
}) => {
  'uuid_id': uuid,
  'created_at': 1700000000,
  'last_updated': 1700001000,
  'metadata': metadata ?? _fullMetadataJson(),
};

Map<String, dynamic> _fullMetadataJson() => {
  'title': 'My Song',
  'artist': 'Artist Name',
  'album': 'Album Name',
  'album_artist': 'Album Artist',
  'year': 2023,
  'date': '2023-06-15',
  'genre': 'Rock',
  'track_number': 3,
  'disc_number': 1,
  'codec': 'flac',
  'duration': 245.5,
  'bitrate_kbps': 320.0,
  'sample_rate_hz': 44100,
  'channels': 2,
  'has_album_art': true,
};

Map<String, dynamic> _minimalMetadataJson() => {
  'duration': 100.0,
  'bitrate_kbps': 128.0,
  'sample_rate_hz': 48000,
  'channels': 1,
  'has_album_art': false,
};

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('tracksCompanionFromDto', () {
    test('parses a ClientTrackDto correctly', () {
      final dto = ClientTrackDto.fromJson(_trackJson());

      final companion = tracksCompanionFromDto(dto);

      expect(companion.uuidId, const Value('abc-123'));
      expect(companion.createdAt, const Value(1700000000));
      expect(companion.lastUpdated, const Value(1700001000));
    });

    test('filePath is absent (not set from API data)', () {
      final dto = ClientTrackDto.fromJson(_trackJson());

      final companion = tracksCompanionFromDto(dto);

      expect(companion.filePath, const Value.absent());
    });
  });

  group('trackmetadataCompanionFromDto', () {
    test('parses a full metadata DTO correctly', () {
      final dto = ClientTrackDto.fromJson(_trackJson());

      final companion = trackmetadataCompanionFromDto(dto);

      expect(companion.uuidId, const Value('abc-123'));
      expect(companion.title, const Value('My Song'));
      expect(companion.artist, const Value('Artist Name'));
      expect(companion.album, const Value('Album Name'));
      expect(companion.albumArtist, const Value('Album Artist'));
      expect(companion.year, const Value(2023));
      expect(companion.date, const Value('2023-06-15'));
      expect(companion.genre, const Value('Rock'));
      expect(companion.trackNumber, const Value(3));
      expect(companion.discNumber, const Value(1));
      expect(companion.codec, const Value('flac'));
      expect(companion.duration, const Value(245.5));
      expect(companion.bitrateKbps, const Value(320.0));
      expect(companion.sampleRateHz, const Value(44100));
      expect(companion.channels, const Value(2));
      expect(companion.hasAlbumArt, const Value(true));
    });

    test('handles nullable fields when absent', () {
      final dto = ClientTrackDto.fromJson(
        _trackJson(uuid: 'xyz-789', metadata: _minimalMetadataJson()),
      );

      final companion = trackmetadataCompanionFromDto(dto);

      expect(companion.uuidId, const Value('xyz-789'));
      expect(companion.title, const Value<String?>(null));
      expect(companion.artist, const Value<String?>(null));
      expect(companion.album, const Value<String?>(null));
      expect(companion.albumArtist, const Value<String?>(null));
      expect(companion.year, const Value<int?>(null));
      expect(companion.date, const Value<String?>(null));
      expect(companion.genre, const Value<String?>(null));
      expect(companion.trackNumber, const Value<int?>(null));
      expect(companion.discNumber, const Value<int?>(null));
      expect(companion.codec, const Value<String?>(null));
      expect(companion.duration, const Value(100.0));
      expect(companion.bitrateKbps, const Value(128.0));
      expect(companion.sampleRateHz, const Value(48000));
      expect(companion.channels, const Value(1));
      expect(companion.hasAlbumArt, const Value(false));
    });

    test('hasAlbumArt bool conversion works', () {
      final dtoTrue = ClientTrackDto.fromJson(
        _trackJson(
          metadata: {..._minimalMetadataJson(), 'has_album_art': true},
        ),
      );
      final dtoFalse = ClientTrackDto.fromJson(
        _trackJson(
          metadata: {..._minimalMetadataJson(), 'has_album_art': false},
        ),
      );

      expect(
        trackmetadataCompanionFromDto(dtoTrue).hasAlbumArt,
        const Value(true),
      );
      expect(
        trackmetadataCompanionFromDto(dtoFalse).hasAlbumArt,
        const Value(false),
      );
    });
  });

  group('database round-trip', () {
    test('insert and read back a track with metadata', () async {
      final dto = ClientTrackDto.fromJson({
        'uuid_id': 'round-trip-1',
        'created_at': 1700000000,
        'last_updated': 1700001000,
        'metadata': {
          'title': 'Test Song',
          'artist': 'Test Artist',
          'duration': 180.0,
          'bitrate_kbps': 256.0,
          'sample_rate_hz': 44100,
          'channels': 2,
          'has_album_art': true,
        },
      });

      await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
      await db
          .into(db.trackmetadata)
          .insert(trackmetadataCompanionFromDto(dto));

      final tracks = await db.select(db.tracks).get();
      expect(tracks.length, 1);
      expect(tracks.first.uuidId, 'round-trip-1');

      final metas = await db.select(db.trackmetadata).get();
      expect(metas.length, 1);
      expect(metas.first.title, 'Test Song');
      expect(metas.first.hasAlbumArt, true);
    });
  });

  Future<void> insertTrack(
    AppDatabase db, {
    required String uuid,
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    int? trackNumber,
    int? year,
  }) async {
    final dto = ClientTrackDto.fromJson({
      'uuid_id': uuid,
      'created_at': 1700000000,
      'last_updated': 1700001000,
      'metadata': {
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (albumArtist != null) 'album_artist': albumArtist,
        if (trackNumber != null) 'track_number': trackNumber,
        if (year != null) 'year': year,
        'duration': 180.0,
        'bitrate_kbps': 256.0,
        'sample_rate_hz': 44100,
        'channels': 2,
        'has_album_art': false,
      },
    });
    await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
    await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
  }

  // Standard all-tracks sort order: artist, album, track_number, uuid_id
  final allTracksOrder = [
    OrderParameter(column: 'artist'),
    OrderParameter(column: 'album'),
    OrderParameter(column: 'track_number'),
    OrderParameter(column: 'uuid_id'),
  ];

  // Album sort order: track_number, uuid_id
  final albumOrder = [
    OrderParameter(column: 'track_number'),
    OrderParameter(column: 'uuid_id'),
  ];

  group('getTracks', () {
    test('returns tracks joined with metadata', () async {
      await insertTrack(
        db,
        uuid: 'a',
        title: 'Song A',
        artist: 'Artist A',
        album: 'Album A',
      );
      final results = await db.getTracks(orderBy: allTracksOrder, limit: 100);
      expect(results.length, 1);
      expect(results.first.read<String>('uuid_id'), 'a');
      expect(results.first.read<String>('title'), 'Song A');
    });

    test(
      'returns tracks sorted artist -> album -> trackNumber -> uuidId',
      () async {
        await insertTrack(
          db,
          uuid: '1',
          artist: 'B Artist',
          album: 'A Album',
          trackNumber: 2,
        );
        await insertTrack(
          db,
          uuid: '2',
          artist: 'A Artist',
          album: 'B Album',
          trackNumber: 1,
        );
        await insertTrack(
          db,
          uuid: '3',
          artist: 'A Artist',
          album: 'A Album',
          trackNumber: 2,
        );
        await insertTrack(
          db,
          uuid: '4',
          artist: 'A Artist',
          album: 'A Album',
          trackNumber: 1,
        );

        final results = await db.getTracks(orderBy: allTracksOrder, limit: 100);
        final uuids = results.map((r) => r.read<String>('uuid_id')).toList();
        expect(uuids, ['4', '3', '2', '1']);
      },
    );

    test('cursor skips rows before cursor position', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'A', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'A', album: 'A', trackNumber: 2);
      await insertTrack(db, uuid: '3', artist: 'A', album: 'A', trackNumber: 3);

      final results = await db.getTracks(
        orderBy: allTracksOrder,
        cursorFilters: [
          RowFilterParameter(column: 'artist', value: 'A'),
          RowFilterParameter(column: 'album', value: 'A'),
          RowFilterParameter(column: 'track_number', value: 1),
          RowFilterParameter(column: 'uuid_id', value: '1'),
        ],
        limit: 100,
      );
      expect(results.length, 2);
      expect(results.first.read<String>('uuid_id'), '2');
    });

    test('cursor works across different artists', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'A', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'B', album: 'A', trackNumber: 1);
      await insertTrack(db, uuid: '3', artist: 'C', album: 'A', trackNumber: 1);

      final results = await db.getTracks(
        orderBy: allTracksOrder,
        cursorFilters: [
          RowFilterParameter(column: 'artist', value: 'A'),
          RowFilterParameter(column: 'album', value: 'A'),
          RowFilterParameter(column: 'track_number', value: 1),
          RowFilterParameter(column: 'uuid_id', value: '1'),
        ],
        limit: 100,
      );
      expect(results.length, 2);
      final uuids = results.map((r) => r.read<String>('uuid_id')).toList();
      expect(uuids, ['2', '3']);
    });

    test('cursor handles null sort key values', () async {
      await insertTrack(db, uuid: '1', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'A', album: 'A', trackNumber: 1);

      final results = await db.getTracks(
        orderBy: allTracksOrder,
        cursorFilters: [
          RowFilterParameter(column: 'artist', value: null),
          RowFilterParameter(column: 'album', value: null),
          RowFilterParameter(column: 'track_number', value: 1),
          RowFilterParameter(column: 'uuid_id', value: '1'),
        ],
        limit: 100,
      );
      expect(results.length, 1);
      expect(results.first.read<String>('uuid_id'), '2');
    });

    test('limit caps result count', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'A', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'A', album: 'A', trackNumber: 2);
      await insertTrack(db, uuid: '3', artist: 'A', album: 'A', trackNumber: 3);

      final results = await db.getTracks(orderBy: allTracksOrder, limit: 2);
      expect(results.length, 2);
    });

    test('returns only tracks for matching artist + album', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist A',
        album: 'Album A',
        trackNumber: 1,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist B',
        album: 'Album B',
        trackNumber: 1,
      );

      final results = await db.getTracks(
        artist: 'Artist A',
        album: 'Album A',
        orderBy: albumOrder,
        limit: 100,
      );
      expect(results.length, 1);
      expect(results.first.read<String>('uuid_id'), '1');
    });

    test('uses albumArtist when present', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Different Artist',
        albumArtist: 'Album Artist',
        album: 'My Album',
        trackNumber: 1,
      );

      final results = await db.getTracks(
        artist: 'Album Artist',
        album: 'My Album',
        orderBy: albumOrder,
        limit: 100,
      );
      expect(results.length, 1);
      expect(results.first.read<String>('uuid_id'), '1');
    });

    test('falls back to artist when albumArtist is null', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Solo Artist',
        album: 'My Album',
        trackNumber: 1,
      );

      final results = await db.getTracks(
        artist: 'Solo Artist',
        album: 'My Album',
        orderBy: albumOrder,
        limit: 100,
      );
      expect(results.length, 1);
      expect(results.first.read<String>('uuid_id'), '1');
    });

    test('orders album tracks by trackNumber ASC', () async {
      await insertTrack(
        db,
        uuid: '3',
        artist: 'Artist',
        album: 'Album',
        trackNumber: 3,
      );
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'Album',
        trackNumber: 1,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist',
        album: 'Album',
        trackNumber: 2,
      );

      final results = await db.getTracks(
        artist: 'Artist',
        album: 'Album',
        orderBy: albumOrder,
        limit: 100,
      );
      final uuids = results.map((r) => r.read<String>('uuid_id')).toList();
      expect(uuids, ['1', '2', '3']);
    });

    test('artist-only filtering returns tracks with null album', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'X',
        album: null,
        trackNumber: 1,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'X',
        album: 'Some Album',
        trackNumber: 1,
      );
      await insertTrack(
        db,
        uuid: '3',
        artist: 'Y',
        album: null,
        trackNumber: 1,
      );

      final results = await db.getTracks(
        artist: 'X',
        orderBy: allTracksOrder,
        limit: 100,
      );
      expect(results.length, 1);
      expect(results.first.read<String>('uuid_id'), '1');
    });

    test('throws when album is provided without artist', () async {
      expect(
        () => db.getTracks(album: 'Album A', orderBy: albumOrder, limit: 100),
        throwsArgumentError,
      );
    });

    test('cursor pagination within album', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'Album',
        trackNumber: 1,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist',
        album: 'Album',
        trackNumber: 2,
      );
      await insertTrack(
        db,
        uuid: '3',
        artist: 'Artist',
        album: 'Album',
        trackNumber: 3,
      );

      final results = await db.getTracks(
        artist: 'Artist',
        album: 'Album',
        orderBy: albumOrder,
        cursorFilters: [
          RowFilterParameter(column: 'track_number', value: 1),
          RowFilterParameter(column: 'uuid_id', value: '1'),
        ],
        limit: 100,
      );
      expect(results.length, 2);
      final uuids = results.map((r) => r.read<String>('uuid_id')).toList();
      expect(uuids, ['2', '3']);
    });
  });

  group('watchTrackCount', () {
    test('emits count of all tracks when no cursor', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'A', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'B', album: 'B', trackNumber: 1);

      final count = await db.watchTrackCount().first;
      expect(count, 2);
    });

    test('emits count of tracks at or before cursor position', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'A', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'A', album: 'A', trackNumber: 2);
      await insertTrack(db, uuid: '3', artist: 'B', album: 'B', trackNumber: 1);

      // Cursor after track '2' — NOT(after '2') means tracks at or before '2'
      final count = await db
          .watchTrackCount(
            orderBy: allTracksOrder,
            cursorFilters: [
              RowFilterParameter(column: 'artist', value: 'A'),
              RowFilterParameter(column: 'album', value: 'A'),
              RowFilterParameter(column: 'track_number', value: 2),
              RowFilterParameter(column: 'uuid_id', value: '2'),
            ],
          )
          .first;
      expect(count, 2);
    });

    test('emits updated count when new track inserted before cursor', () async {
      await insertTrack(db, uuid: '2', artist: 'B', album: 'B', trackNumber: 1);

      final stream = db.watchTrackCount(
        orderBy: allTracksOrder,
        cursorFilters: [
          RowFilterParameter(column: 'artist', value: 'B'),
          RowFilterParameter(column: 'album', value: 'B'),
          RowFilterParameter(column: 'track_number', value: 1),
          RowFilterParameter(column: 'uuid_id', value: '2'),
        ],
      );

      // First emission: 1 track (the cursor track itself)
      expect(await stream.first, 1);

      // Insert a track that sorts before the cursor
      await insertTrack(db, uuid: '1', artist: 'A', album: 'A', trackNumber: 1);

      // Next emission should be 2
      expect(await stream.first, 2);
    });

    test('returns 0 when no tracks match', () async {
      final count = await db.watchTrackCount().first;
      expect(count, 0);
    });

    test('respects artist/album filter', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist A',
        album: 'Album A',
        trackNumber: 1,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist B',
        album: 'Album B',
        trackNumber: 1,
      );

      final count = await db
          .watchTrackCount(artist: 'Artist A', album: 'Album A')
          .first;
      expect(count, 1);
    });
  });

  group('getArtists', () {
    test('returns distinct artists sorted alphabetically', () async {
      await insertTrack(db, uuid: '1', artist: 'Charlie');
      await insertTrack(db, uuid: '2', artist: 'Alice');
      await insertTrack(db, uuid: '3', artist: 'Bob');

      final artists = await db.getArtists();
      expect(artists, ['Alice', 'Bob', 'Charlie']);
    });

    test('deduplicates by case-insensitive match', () async {
      await insertTrack(db, uuid: '1', artist: 'alice');
      await insertTrack(db, uuid: '2', artist: 'Alice');
      await insertTrack(db, uuid: '3', artist: 'ALICE');

      final artists = await db.getArtists();
      expect(artists.length, 1);
      // Should return one of the casing variants
      expect(artists.first.toLowerCase(), 'alice');
    });

    test('prefers albumArtist over artist when albumArtist is set', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Track Artist',
        albumArtist: 'Album Artist',
      );

      final artists = await db.getArtists();
      expect(artists, ['Album Artist']);
    });

    test('falls back to artist when albumArtist is null', () async {
      await insertTrack(db, uuid: '1', artist: 'Solo Artist');

      final artists = await db.getArtists();
      expect(artists, ['Solo Artist']);
    });

    test('excludes tracks with no artist and no albumArtist', () async {
      await insertTrack(db, uuid: '1');

      final artists = await db.getArtists();
      expect(artists, isEmpty);
    });

    test('respects limit', () async {
      await insertTrack(db, uuid: '1', artist: 'A');
      await insertTrack(db, uuid: '2', artist: 'B');
      await insertTrack(db, uuid: '3', artist: 'C');

      final artists = await db.getArtists(limit: 2);
      expect(artists.length, 2);
      expect(artists, ['A', 'B']);
    });

    test('respects limit and offset', () async {
      await insertTrack(db, uuid: '1', artist: 'A');
      await insertTrack(db, uuid: '2', artist: 'B');
      await insertTrack(db, uuid: '3', artist: 'C');

      final artists = await db.getArtists(limit: 2, offset: 1);
      expect(artists, ['B', 'C']);
    });
  });

  group('getAlbums', () {
    test('returns albums for an artist', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'Album A',
        year: 2020,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist',
        album: 'Album B',
        year: 2021,
      );

      final albums = await db.getAlbums(artist: 'Artist');
      expect(albums, ['Album A', 'Album B']);
    });

    test('orders albums by year ascending', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'Newer',
        year: 2023,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist',
        album: 'Older',
        year: 2019,
      );

      final albums = await db.getAlbums(artist: 'Artist');
      expect(albums, ['Older', 'Newer']);
    });

    test('matches by albumArtist', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Feat Artist',
        albumArtist: 'Main Artist',
        album: 'Collab Album',
        year: 2020,
      );

      final albums = await db.getAlbums(artist: 'Main Artist');
      expect(albums, ['Collab Album']);
    });

    test('excludes tracks with null or empty album', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist', album: null);
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist',
        album: 'Real Album',
        year: 2020,
      );

      final albums = await db.getAlbums(artist: 'Artist');
      expect(albums, ['Real Album']);
    });

    test('deduplicates albums by case-insensitive match', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'my album',
        year: 2020,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist',
        album: 'My Album',
        year: 2020,
      );

      final albums = await db.getAlbums(artist: 'Artist');
      expect(albums.length, 1);
    });

    test('does not return albums from other artists', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist A',
        album: 'Album A',
        year: 2020,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist B',
        album: 'Album B',
        year: 2020,
      );

      final albums = await db.getAlbums(artist: 'Artist A');
      expect(albums, ['Album A']);
    });

    test('respects limit', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'A',
        year: 2020,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist',
        album: 'B',
        year: 2021,
      );
      await insertTrack(
        db,
        uuid: '3',
        artist: 'Artist',
        album: 'C',
        year: 2022,
      );

      final albums = await db.getAlbums(artist: 'Artist', limit: 2);
      expect(albums.length, 2);
      expect(albums, ['A', 'B']);
    });

    test('respects limit and offset', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'A',
        year: 2020,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist',
        album: 'B',
        year: 2021,
      );
      await insertTrack(
        db,
        uuid: '3',
        artist: 'Artist',
        album: 'C',
        year: 2022,
      );

      final albums = await db.getAlbums(artist: 'Artist', limit: 2, offset: 1);
      expect(albums, ['B', 'C']);
    });

    test('returns all albums when artist is null', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist A',
        album: 'Album X',
        year: 2020,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist B',
        album: 'Album Y',
        year: 2021,
      );
      await insertTrack(
        db,
        uuid: '3',
        artist: 'Feat',
        albumArtist: 'Main',
        album: 'Album Z',
        year: 2019,
      );

      final albums = await db.getAlbums(artist: null);
      expect(albums.toSet(), {'Album X', 'Album Y', 'Album Z'});
    });

    test('orders alphabetically when orderBy is alphabetical', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'Zebra', year: 2020);
      await insertTrack(db, uuid: '2', artist: 'B', album: 'apple', year: 2021);
      await insertTrack(db, uuid: '3', artist: 'C', album: 'Mango', year: 2019);

      final albums = await db.getAlbums(artist: null, orderBy: 'alphabetical');
      expect(albums, ['apple', 'Mango', 'Zebra']);
    });

    test('orders by year when orderBy is year', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'Late',
        year: 2023,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist',
        album: 'Early',
        year: 2018,
      );
      await insertTrack(
        db,
        uuid: '3',
        artist: 'Artist',
        album: 'Mid',
        year: 2020,
      );

      final albums = await db.getAlbums(artist: 'Artist', orderBy: 'year');
      expect(albums, ['Early', 'Mid', 'Late']);
    });
  });

  group('watchArtistCount', () {
    test('returns count of distinct artists', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist A');
      await insertTrack(db, uuid: '2', artist: 'Artist B');
      await insertTrack(db, uuid: '3', artist: 'Artist C');

      final count = await db.watchArtistCount().first;
      expect(count, 3);
    });

    test('returns 0 when no artists exist', () async {
      final count = await db.watchArtistCount().first;
      expect(count, 0);
    });

    test('deduplicates case-insensitively', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist');
      await insertTrack(db, uuid: '2', artist: 'artist');
      await insertTrack(db, uuid: '3', artist: 'ARTIST');

      final count = await db.watchArtistCount().first;
      expect(count, 1);
    });

    test('counts albumArtist as artist', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Feat',
        albumArtist: 'Main Artist',
      );

      final count = await db.watchArtistCount().first;
      // 'Main Artist' counted (via albumArtist), 'Feat' excluded (has albumArtist)
      expect(count, 1);
    });

    test('excludes tracks with no artist', () async {
      await insertTrack(db, uuid: '1');
      await insertTrack(db, uuid: '2', artist: 'Real Artist');

      final count = await db.watchArtistCount().first;
      expect(count, 1);
    });

    test('emits updated count when track inserted', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist A');

      final stream = db.watchArtistCount();
      final first = await stream.first;
      expect(first, 1);

      await insertTrack(db, uuid: '2', artist: 'Artist B');

      final second = await stream.first;
      expect(second, 2);
    });
  });

  group('watchAlbumsCount', () {
    test('returns count of distinct albums when artist is null', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist A', album: 'Album A');
      await insertTrack(db, uuid: '2', artist: 'Artist B', album: 'album a');
      await insertTrack(db, uuid: '3', artist: 'Artist C', album: 'Album B');

      final count = await db.watchAlbumsCount().first;
      expect(count, 2);
    });

    test('returns 0 when no albums exist', () async {
      final count = await db.watchAlbumsCount().first;
      expect(count, 0);
    });

    test('respects artist filter with albumArtist precedence', () async {
      await insertTrack(db, uuid: '1', artist: 'Main', album: 'Main Album');
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Feat',
        albumArtist: 'Main',
        album: 'Collab Album',
      );
      await insertTrack(
        db,
        uuid: '3',
        artist: 'Main',
        albumArtist: 'Other',
        album: 'Excluded Album',
      );

      final count = await db.watchAlbumsCount(artist: 'Main').first;
      expect(count, 2);
    });

    test('excludes null and empty albums', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist', album: null);
      await insertTrack(db, uuid: '2', artist: 'Artist', album: '');
      await insertTrack(db, uuid: '3', artist: 'Artist', album: 'Real Album');

      final count = await db.watchAlbumsCount().first;
      expect(count, 1);
    });

    test('emits updated count when new album inserted', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist', album: 'Album A');

      final stream = db.watchAlbumsCount();
      expect(await stream.first, 1);

      await insertTrack(db, uuid: '2', artist: 'Artist', album: 'Album B');

      expect(await stream.first, 2);
    });
  });
}
