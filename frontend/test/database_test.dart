import 'package:drift/drift.dart' hide isNull, isNotNull;
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
  'revision': 1,
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

  // ID counters for artists and albums tables
  var nextArtistId = 1;
  var nextAlbumId = 1;

  // Maps to deduplicate artists/albums by lowercase name (per artist for albums)
  final artistIds = <String, int>{}; // lowercased name -> id
  final albumIds = <String, int>{}; // "artistId:lowercasedAlbumName" -> id
  // Track single-grouping albums per (artistId, year)
  final singleGroupingIds = <String, int>{}; // "artistId:year" -> id

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    nextArtistId = 1;
    nextAlbumId = 1;
    artistIds.clear();
    albumIds.clear();
    singleGroupingIds.clear();
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
        'revision': 1,
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

  /// Ensures an artist row exists and returns its id.
  Future<int> ensureArtist(AppDatabase db, String name) async {
    final key = name.toLowerCase();
    if (artistIds.containsKey(key)) return artistIds[key]!;
    final id = nextArtistId++;
    await db
        .into(db.artists)
        .insert(ArtistsCompanion(id: Value(id), name: Value(name)));
    artistIds[key] = id;
    return id;
  }

  /// Ensures an album row exists and returns its id.
  Future<int> ensureAlbum(
    AppDatabase db, {
    required int artistId,
    required String name,
    int? year,
  }) async {
    final key = '$artistId:${name.toLowerCase()}';
    if (albumIds.containsKey(key)) return albumIds[key]!;
    final id = nextAlbumId++;
    await db
        .into(db.albums)
        .insert(
          AlbumsCompanion(
            id: Value(id),
            name: Value(name),
            artistId: Value(artistId),
            year: Value(year),
            isSingleGrouping: const Value(false),
          ),
        );
    albumIds[key] = id;
    return id;
  }

  /// Ensures a single-grouping album row exists and returns its id.
  Future<int> ensureSingleGrouping(
    AppDatabase db, {
    required int artistId,
    int? year,
  }) async {
    final key = '$artistId:${year ?? 'null'}';
    if (singleGroupingIds.containsKey(key)) {
      return singleGroupingIds[key]!;
    }
    final id = nextAlbumId++;
    await db
        .into(db.albums)
        .insert(
          AlbumsCompanion(
            id: Value(id),
            name: const Value(null),
            artistId: Value(artistId),
            year: Value(year),
            isSingleGrouping: const Value(true),
          ),
        );
    singleGroupingIds[key] = id;
    return id;
  }

  /// Rebuilds all FTS tables from current data.
  Future<void> rebuildFts(AppDatabase db) => db.rebuildFtsIndexes();

  /// Inserts a track with its metadata, creating artist/album rows as needed.
  /// Returns (artistId, albumId) where albumId may be null.
  Future<(int?, int?)> insertTrack(
    AppDatabase db, {
    required String uuid,
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    int? trackNumber,
    int? year,
  }) async {
    // Determine effective artist for grouping (albumArtist takes precedence)
    final effectiveArtist = albumArtist ?? artist;

    int? artistId;
    int? albumId;

    if (effectiveArtist != null) {
      artistId = await ensureArtist(db, effectiveArtist);
      if (album != null) {
        albumId = await ensureAlbum(
          db,
          artistId: artistId,
          name: album,
          year: year,
        );
      } else {
        albumId = await ensureSingleGrouping(
          db,
          artistId: artistId,
          year: year,
        );
      }
    }

    final dto = ClientTrackDto.fromJson({
      'uuid_id': uuid,
      'created_at': 1700000000,
      'last_updated': 1700001000,
      'revision': 1,
      'metadata': {
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (albumArtist != null) 'album_artist': albumArtist,
        if (trackNumber != null) 'track_number': trackNumber,
        if (year != null) 'year': year,
        if (artistId != null) 'artist_id': artistId,
        if (albumId != null) 'album_id': albumId,
        'duration': 180.0,
        'bitrate_kbps': 256.0,
        'sample_rate_hz': 44100,
        'channels': 2,
        'has_album_art': false,
      },
    });
    await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
    await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
    return (artistId, albumId);
  }

  // Helper to look up an artist ID by name (case-insensitive)
  int? artistIdFor(String name) => artistIds[name.toLowerCase()];

  // Helper to look up an album ID by artist name + album name
  int? albumIdFor(String artistName, String albumName) {
    final aId = artistIdFor(artistName);
    if (aId == null) return null;
    return albumIds['$aId:${albumName.toLowerCase()}'];
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

  group('download counts', () {
    Future<void> markDownloaded(String uuid) async {
      await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid)))
          .write(TracksCompanion(filePath: Value('/local/$uuid')));
    }

    test('getAllAlbumDownloadCounts groups every album in one query', () async {
      final (_, albumA) =
          await insertTrack(db, uuid: 'a1', artist: 'A', album: 'AL');
      await insertTrack(db, uuid: 'a2', artist: 'A', album: 'AL');
      final (_, albumB) =
          await insertTrack(db, uuid: 'b1', artist: 'B', album: 'BL');
      await markDownloaded('a1');

      final counts = await db.getAllAlbumDownloadCounts();
      expect(counts[albumA!]!.total, 2);
      expect(counts[albumA]!.downloaded, 1);
      expect(counts[albumB!]!.total, 1);
      expect(counts[albumB]!.downloaded, 0);
    });

    test('getAllAlbumDownloadCounts matches the per-id query', () async {
      final (_, albumA) =
          await insertTrack(db, uuid: 'a1', artist: 'A', album: 'AL');
      await markDownloaded('a1');

      final all = await db.getAllAlbumDownloadCounts();
      final scoped = await db.getAlbumDownloadCounts([albumA!]);
      expect(all[albumA], scoped[albumA]);
    });

    test('getAllArtistDownloadCounts groups every artist', () async {
      final (artistA, _) =
          await insertTrack(db, uuid: 'a1', artist: 'A', album: 'AL');
      await insertTrack(db, uuid: 'a2', artist: 'A', album: 'AL');
      await markDownloaded('a1');
      await markDownloaded('a2');

      final counts = await db.getAllArtistDownloadCounts();
      expect(counts[artistA!]!.total, 2);
      expect(counts[artistA]!.downloaded, 2);
    });
  });

  group('getTracks', () {
    test('getTracksByUuids preserves caller order', () async {
      await insertTrack(
        db,
        uuid: 'a',
        title: 'Track A',
        artist: 'Artist',
        album: 'Album',
        trackNumber: 1,
      );
      await insertTrack(
        db,
        uuid: 'b',
        title: 'Track B',
        artist: 'Artist',
        album: 'Album',
        trackNumber: 2,
      );
      await insertTrack(
        db,
        uuid: 'c',
        title: 'Track C',
        artist: 'Artist',
        album: 'Album',
        trackNumber: 3,
      );

      final rows = await db.getTracksByUuids(const ['c', 'a', 'b']);

      expect(rows.map((row) => row.read<String>('uuid_id')), ['c', 'a', 'b']);
    });

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
        artistId: artistIdFor('Artist A'),
        albumId: albumIdFor('Artist A', 'Album A'),
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
        artistId: artistIdFor('Album Artist'),
        albumId: albumIdFor('Album Artist', 'My Album'),
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
        artistId: artistIdFor('Solo Artist'),
        albumId: albumIdFor('Solo Artist', 'My Album'),
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
        artistId: artistIdFor('Artist'),
        albumId: albumIdFor('Artist', 'Album'),
        orderBy: albumOrder,
        limit: 100,
      );
      final uuids = results.map((r) => r.read<String>('uuid_id')).toList();
      expect(uuids, ['1', '2', '3']);
    });

    test('artist-only filtering returns all tracks for that artist', () async {
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
        artistId: artistIdFor('X'),
        orderBy: allTracksOrder,
        limit: 100,
      );
      expect(results.length, 2);
      final uuids = results.map((r) => r.read<String>('uuid_id')).toSet();
      expect(uuids, {'1', '2'});
    });

    test('throws when albumId is provided without artistId', () async {
      expect(
        () => db.getTracks(albumId: 1, orderBy: albumOrder, limit: 100),
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
        artistId: artistIdFor('Artist'),
        albumId: albumIdFor('Artist', 'Album'),
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

  group('getArtists', () {
    test('returns distinct artists sorted alphabetically', () async {
      await insertTrack(db, uuid: '1', artist: 'Charlie');
      await insertTrack(db, uuid: '2', artist: 'Alice');
      await insertTrack(db, uuid: '3', artist: 'Bob');

      final rows = await db.getArtists();
      final artists = rows.map((r) => r.read<String>('name')).toList();
      expect(artists, ['Alice', 'Bob', 'Charlie']);
    });

    test('deduplicates by case-insensitive match', () async {
      await insertTrack(db, uuid: '1', artist: 'alice');
      await insertTrack(db, uuid: '2', artist: 'Alice');
      await insertTrack(db, uuid: '3', artist: 'ALICE');

      final rows = await db.getArtists();
      expect(rows.length, 1);
      // Should return one of the casing variants
      expect(rows.first.read<String>('name').toLowerCase(), 'alice');
    });

    test('prefers albumArtist over artist when albumArtist is set', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Track Artist',
        albumArtist: 'Album Artist',
      );

      final rows = await db.getArtists();
      final artists = rows.map((r) => r.read<String>('name')).toList();
      expect(artists, ['Album Artist']);
    });

    test('falls back to artist when albumArtist is null', () async {
      await insertTrack(db, uuid: '1', artist: 'Solo Artist');

      final rows = await db.getArtists();
      final artists = rows.map((r) => r.read<String>('name')).toList();
      expect(artists, ['Solo Artist']);
    });

    test('excludes tracks with no artist and no albumArtist', () async {
      await insertTrack(db, uuid: '1');

      final rows = await db.getArtists();
      expect(rows, isEmpty);
    });

    test('respects limit', () async {
      await insertTrack(db, uuid: '1', artist: 'A');
      await insertTrack(db, uuid: '2', artist: 'B');
      await insertTrack(db, uuid: '3', artist: 'C');

      final rows = await db.getArtists(limit: 2);
      final artists = rows.map((r) => r.read<String>('name')).toList();
      expect(artists.length, 2);
      expect(artists, ['A', 'B']);
    });

    test('respects limit and offset', () async {
      await insertTrack(db, uuid: '1', artist: 'A');
      await insertTrack(db, uuid: '2', artist: 'B');
      await insertTrack(db, uuid: '3', artist: 'C');

      final rows = await db.getArtists(limit: 2, offset: 1);
      final artists = rows.map((r) => r.read<String>('name')).toList();
      expect(artists, ['B', 'C']);
    });
  });

  final defaultArtistOrder = [ArtistOrderParameter(column: 'name')];

  group('getArtists with cursor', () {
    test('cursor pagination skips artists before cursor', () async {
      await insertTrack(db, uuid: '1', artist: 'Alice');
      await insertTrack(db, uuid: '2', artist: 'Bob');
      await insertTrack(db, uuid: '3', artist: 'Charlie');

      final rows = await db.getArtists(
        orderBy: defaultArtistOrder,
        cursorFilters: [ArtistRowFilterParameter(column: 'name', value: 'Bob')],
      );
      final artists = rows.map((r) => r.read<String>('name')).toList();
      expect(artists, ['Charlie']);
    });

    test('cursor works across pages', () async {
      await insertTrack(db, uuid: '1', artist: 'Alice');
      await insertTrack(db, uuid: '2', artist: 'Bob');
      await insertTrack(db, uuid: '3', artist: 'Charlie');
      await insertTrack(db, uuid: '4', artist: 'Dave');
      await insertTrack(db, uuid: '5', artist: 'Eve');

      // First page
      final page1 = await db.getArtists(orderBy: defaultArtistOrder, limit: 2);
      final page1Names = page1.map((r) => r.read<String>('name')).toList();
      expect(page1Names, ['Alice', 'Bob']);

      // Second page via cursor
      final page2 = await db.getArtists(
        orderBy: defaultArtistOrder,
        cursorFilters: [ArtistRowFilterParameter(column: 'name', value: 'Bob')],
        limit: 2,
      );
      final page2Names = page2.map((r) => r.read<String>('name')).toList();
      expect(page2Names, ['Charlie', 'Dave']);

      // Third page
      final page3 = await db.getArtists(
        orderBy: defaultArtistOrder,
        cursorFilters: [
          ArtistRowFilterParameter(column: 'name', value: 'Dave'),
        ],
        limit: 2,
      );
      final page3Names = page3.map((r) => r.read<String>('name')).toList();
      expect(page3Names, ['Eve']);
    });

    test('with orderBy and no cursor returns all sorted', () async {
      await insertTrack(db, uuid: '1', artist: 'Charlie');
      await insertTrack(db, uuid: '2', artist: 'Alice');
      await insertTrack(db, uuid: '3', artist: 'Bob');

      final rows = await db.getArtists(orderBy: defaultArtistOrder);
      final artists = rows.map((r) => r.read<String>('name')).toList();
      expect(artists, ['Alice', 'Bob', 'Charlie']);
    });
  });

  // Standard album sort order: album, artist, year, is_single_grouping
  final defaultAlbumOrder = [
    AlbumOrderParameter(column: 'name', nullsLast: true),
    AlbumOrderParameter(column: 'artist'),
    AlbumOrderParameter(column: 'year'),
    AlbumOrderParameter(column: 'is_single_grouping'),
  ];

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

      final rows = await db.getAlbums(
        artistId: artistIdFor('Artist'),
        orderBy: defaultAlbumOrder,
      );
      final albums = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .map((r) => r.read<String>('name'))
          .toList();
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

      final yearOrder = [
        AlbumOrderParameter(column: 'year'),
        AlbumOrderParameter(column: 'name'),
        AlbumOrderParameter(column: 'artist'),
        AlbumOrderParameter(column: 'is_single_grouping'),
      ];
      final rows = await db.getAlbums(
        artistId: artistIdFor('Artist'),
        orderBy: yearOrder,
      );
      final albums = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .map((r) => r.read<String>('name'))
          .toList();
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

      final rows = await db.getAlbums(artistId: artistIdFor('Main Artist'));
      final albums = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .map((r) => r.read<String>('name'))
          .toList();
      expect(albums, ['Collab Album']);
    });

    test(
      'excludes tracks with null or empty album from regular albums',
      () async {
        await insertTrack(db, uuid: '1', artist: 'Artist', album: null);
        await insertTrack(
          db,
          uuid: '2',
          artist: 'Artist',
          album: 'Real Album',
          year: 2020,
        );

        final rows = await db.getAlbums(artistId: artistIdFor('Artist'));
        final regularAlbums = rows
            .where((r) => r.read<int>('is_single_grouping') == 0)
            .map((r) => r.read<String>('name'))
            .toList();
        expect(regularAlbums, ['Real Album']);
      },
    );

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

      final rows = await db.getAlbums(artistId: artistIdFor('Artist'));
      final regularAlbums = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .toList();
      expect(regularAlbums.length, 1);
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

      final rows = await db.getAlbums(artistId: artistIdFor('Artist A'));
      final regularAlbums = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .map((r) => r.read<String>('name'))
          .toList();
      expect(regularAlbums, ['Album A']);
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

      final rows = await db.getAlbums(
        artistId: artistIdFor('Artist'),
        orderBy: defaultAlbumOrder,
        limit: 2,
      );
      expect(rows.length, 2);
    });

    test('returns all albums when artistId is null', () async {
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

      final rows = await db.getAlbums(artistId: null);
      final albums = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .map((r) => r.read<String>('name'))
          .toSet();
      expect(albums, {'Album X', 'Album Y', 'Album Z'});
    });

    test('orders alphabetically with COLLATE NOCASE', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'Zebra', year: 2020);
      await insertTrack(db, uuid: '2', artist: 'B', album: 'apple', year: 2021);
      await insertTrack(db, uuid: '3', artist: 'C', album: 'Mango', year: 2019);

      final alphaOrder = [
        AlbumOrderParameter(column: 'name', nullsLast: true),
        AlbumOrderParameter(column: 'artist'),
        AlbumOrderParameter(column: 'year'),
        AlbumOrderParameter(column: 'is_single_grouping'),
      ];
      final rows = await db.getAlbums(artistId: null, orderBy: alphaOrder);
      final albums = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .map((r) => r.read<String>('name'))
          .toList();
      expect(albums, ['apple', 'Mango', 'Zebra']);
    });

    test('returns correct artist field for plain artist', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Solo Artist',
        album: 'Solo Album',
        year: 2020,
      );

      final rows = await db.getAlbums(artistId: artistIdFor('Solo Artist'));
      final regular = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .toList();
      expect(regular.length, 1);
      expect(regular.first.read<String>('name'), 'Solo Album');
      expect(regular.first.read<String>('artist'), 'Solo Artist');
    });

    test('returns correct artist field for album_artist', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Feat',
        albumArtist: 'Main Artist',
        album: 'Collab',
        year: 2020,
      );

      final rows = await db.getAlbums(artistId: artistIdFor('Main Artist'));
      final regular = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .toList();
      expect(regular.length, 1);
      expect(regular.first.read<String>('name'), 'Collab');
      expect(regular.first.read<String>('artist'), 'Main Artist');
    });

    test('same album name from different artists returns both', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist A',
        album: 'Greatest Hits',
        year: 2020,
      );
      await insertTrack(
        db,
        uuid: '2',
        artist: 'Artist B',
        album: 'Greatest Hits',
        year: 2021,
      );

      final rows = await db.getAlbums(
        artistId: null,
        orderBy: defaultAlbumOrder,
      );
      final regular = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .toList();
      expect(regular.length, 2);
      final pairs = regular
          .map((r) => (r.read<String>('name'), r.read<String>('artist')))
          .toSet();
      expect(pairs, {
        ('Greatest Hits', 'Artist A'),
        ('Greatest Hits', 'Artist B'),
      });
    });

    test('returns is_single_grouping and year columns', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'My Album',
        year: 2022,
      );

      final rows = await db.getAlbums(artistId: artistIdFor('Artist'));
      final regular = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .toList();
      expect(regular.length, 1);
      expect(regular.first.read<int>('is_single_grouping'), 0);
      expect(regular.first.read<int>('year'), 2022);
    });

    test('includes single groupings for tracks without album', () async {
      // Track with album
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'My Album',
        year: 2022,
      );
      // Track without album (becomes single grouping)
      await insertTrack(db, uuid: '2', artist: 'Artist', year: 2023);

      final rows = await db.getAlbums(artistId: artistIdFor('Artist'));
      final singles = rows
          .where((r) => r.read<int>('is_single_grouping') == 1)
          .toList();
      expect(singles.length, 1);
      expect(singles.first.readNullable<String>('name'), equals(null));
      expect(singles.first.read<String>('artist'), 'Artist');
    });

    test('single groupings group by artist and year', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist', year: 2020);
      await insertTrack(db, uuid: '2', artist: 'Artist', year: 2020);
      await insertTrack(db, uuid: '3', artist: 'Artist', year: 2021);

      final rows = await db.getAlbums(artistId: artistIdFor('Artist'));
      final singles = rows
          .where((r) => r.read<int>('is_single_grouping') == 1)
          .toList();
      // Two groups: 2020 and 2021
      expect(singles.length, 2);
    });

    test(
      'single groupings appear for all artists when artistId is null',
      () async {
        await insertTrack(db, uuid: '1', artist: 'A');
        await insertTrack(db, uuid: '2', artist: 'B');

        final rows = await db.getAlbums(artistId: null);
        final singles = rows
            .where((r) => r.read<int>('is_single_grouping') == 1)
            .toList();
        expect(singles.length, 2);
      },
    );

    test('cursor pagination skips rows before cursor', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'Alpha', year: 2020);
      await insertTrack(db, uuid: '2', artist: 'A', album: 'Beta', year: 2021);
      await insertTrack(db, uuid: '3', artist: 'A', album: 'Gamma', year: 2022);

      final rows = await db.getAlbums(
        artistId: null,
        orderBy: defaultAlbumOrder,
        cursorFilters: [
          AlbumRowFilterParameter(column: 'name', value: 'Alpha'),
          AlbumRowFilterParameter(column: 'artist', value: 'A'),
          AlbumRowFilterParameter(column: 'year', value: 2020),
          AlbumRowFilterParameter(column: 'is_single_grouping', value: 0),
        ],
      );
      final albums = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .map((r) => r.read<String>('name'))
          .toList();
      expect(albums, ['Beta', 'Gamma']);
    });

    test('nullsLast puts null album after non-null', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'Zebra',
        year: 2020,
      );
      await insertTrack(db, uuid: '2', artist: 'Artist', year: 2020);

      final rows = await db.getAlbums(
        artistId: artistIdFor('Artist'),
        orderBy: defaultAlbumOrder,
      );
      // Regular album first, single grouping (null album) last
      expect(rows.length, 2);
      expect(rows.first.read<int>('is_single_grouping'), 0);
      expect(rows.last.read<int>('is_single_grouping'), 1);
    });
  });

  group('getAlbums cover_art_id subquery', () {
    test('returns null cover_art_id when no tracks have art', () async {
      await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'Album',
        year: 2020,
      );

      final rows = await db.getAlbums(artistId: artistIdFor('Artist'));
      final regular = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .toList();
      expect(regular.length, 1);
      expect(regular.first.readNullable<int>('cover_art_id'), equals(null));
    });

    test('returns cover_art_id from track with art', () async {
      final (artistId, _) = await insertTrack(
        db,
        uuid: '1',
        artist: 'Artist',
        album: 'Album',
        year: 2020,
      );

      // Manually set has_album_art and cover_art_id
      await db.customUpdate(
        'UPDATE trackmetadata SET has_album_art = 1, cover_art_id = 42 '
        'WHERE uuid_id = ?',
        variables: [Variable.withString('1')],
        updates: {db.trackmetadata},
      );

      final rows = await db.getAlbums(artistId: artistId);
      final regular = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .toList();
      expect(regular.length, 1);
      expect(regular.first.readNullable<int>('cover_art_id'), 42);
    });

    test('returns cover_art_id from lowest track_number', () async {
      await insertTrack(
        db,
        uuid: 'tr-2',
        artist: 'Artist',
        album: 'Album',
        year: 2020,
        trackNumber: 2,
      );
      await insertTrack(
        db,
        uuid: 'tr-1',
        artist: 'Artist',
        album: 'Album',
        year: 2020,
        trackNumber: 1,
      );

      // Track 2 gets cover_art_id 99, Track 1 gets cover_art_id 42
      await db.customUpdate(
        'UPDATE trackmetadata SET has_album_art = 1, cover_art_id = 99 '
        'WHERE uuid_id = ?',
        variables: [Variable.withString('tr-2')],
        updates: {db.trackmetadata},
      );
      await db.customUpdate(
        'UPDATE trackmetadata SET has_album_art = 1, cover_art_id = 42 '
        'WHERE uuid_id = ?',
        variables: [Variable.withString('tr-1')],
        updates: {db.trackmetadata},
      );

      final rows = await db.getAlbums(artistId: artistIdFor('Artist'));
      final regular = rows
          .where((r) => r.read<int>('is_single_grouping') == 0)
          .toList();
      expect(regular.length, 1);
      // Should pick track 1's art (lowest track_number)
      expect(regular.first.readNullable<int>('cover_art_id'), 42);
    });

    test(
      'downloadedOnly restricts cover_art_id to downloaded tracks',
      () async {
        // Track 1 has the lowest track_number and has cover art, but is NOT
        // downloaded. Track 2 has higher track_number, has different cover
        // art, IS downloaded. Without the downloaded-only constraint on the
        // cover-art subquery, an offline list would surface art belonging
        // to a streaming-only track — and resolving that would require
        // hitting the network.
        await insertTrack(
          db, uuid: 'tr-1', artist: 'Artist', album: 'Album',
          year: 2020, trackNumber: 1,
        );
        await insertTrack(
          db, uuid: 'tr-2', artist: 'Artist', album: 'Album',
          year: 2020, trackNumber: 2,
        );
        await db.customUpdate(
          'UPDATE trackmetadata SET has_album_art = 1, cover_art_id = 11 '
          'WHERE uuid_id = ?',
          variables: [Variable.withString('tr-1')],
          updates: {db.trackmetadata},
        );
        await db.customUpdate(
          'UPDATE trackmetadata SET has_album_art = 1, cover_art_id = 22 '
          'WHERE uuid_id = ?',
          variables: [Variable.withString('tr-2')],
          updates: {db.trackmetadata},
        );
        // Only track 2 is downloaded.
        await db.customUpdate(
          "UPDATE tracks SET file_path = '/tmp/tr-2.audio' WHERE uuid_id = ?",
          variables: [Variable.withString('tr-2')],
          updates: {db.tracks},
        );

        final unfiltered = await db.getAlbums(
          artistId: artistIdFor('Artist'),
        );
        final unfilteredRegular = unfiltered
            .where((r) => r.read<int>('is_single_grouping') == 0)
            .toList();
        // Without the filter, lowest track_number (tr-1) wins → 11.
        expect(unfilteredRegular.first.readNullable<int>('cover_art_id'), 11);

        final downloadedOnly = await db.getAlbums(
          artistId: artistIdFor('Artist'),
          downloadedOnly: true,
        );
        final downloadedRegular = downloadedOnly
            .where((r) => r.read<int>('is_single_grouping') == 0)
            .toList();
        // With the filter, tr-1 is ineligible (not downloaded) → tr-2's 22.
        expect(downloadedRegular.first.readNullable<int>('cover_art_id'), 22);
      },
    );

    test(
      'ignores tracks with has_album_art=false even if cover_art_id set',
      () async {
        await insertTrack(
          db,
          uuid: '1',
          artist: 'Artist',
          album: 'Album',
          year: 2020,
        );

        // Set cover_art_id but leave has_album_art = false
        await db.customUpdate(
          'UPDATE trackmetadata SET cover_art_id = 42 '
          'WHERE uuid_id = ?',
          variables: [Variable.withString('1')],
          updates: {db.trackmetadata},
        );

        final rows = await db.getAlbums(artistId: artistIdFor('Artist'));
        final regular = rows
            .where((r) => r.read<int>('is_single_grouping') == 0)
            .toList();
        expect(regular.first.readNullable<int>('cover_art_id'), equals(null));
      },
    );
  });

  group('getArtists cover_art_id subquery', () {
    test('returns null cover_art_id when no tracks have art', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist');

      final rows = await db.getArtists();
      expect(rows.length, 1);
      expect(rows.first.readNullable<int>('cover_art_id'), equals(null));
    });

    test('returns cover_art_id from track with art', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist');

      await db.customUpdate(
        'UPDATE trackmetadata SET has_album_art = 1, cover_art_id = 7 '
        'WHERE uuid_id = ?',
        variables: [Variable.withString('1')],
        updates: {db.trackmetadata},
      );

      final rows = await db.getArtists();
      expect(rows.length, 1);
      expect(rows.first.readNullable<int>('cover_art_id'), 7);
    });
  });

  group('getSearchResults', () {
    test('returns matching tracks by title', () async {
      await insertTrack(
        db,
        uuid: '1',
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
        album: 'A Night at the Opera',
      );
      await insertTrack(
        db,
        uuid: '2',
        title: 'Other Song',
        artist: 'Other',
        album: 'Other Album',
      );
      await rebuildFts(db);

      final results = await db.getSearchResults('Bohemian');
      expect(results.tracks.length, 1);
      expect(results.tracks.first.read<String>('title'), 'Bohemian Rhapsody');
    });

    test('returns matching artists', () async {
      await insertTrack(
        db,
        uuid: '1',
        title: 'Song',
        artist: 'Radiohead',
        album: 'OK Computer',
      );
      await rebuildFts(db);

      final results = await db.getSearchResults(
        'Radiohead',
        searchTracks: false,
        searchAlbums: false,
      );
      expect(results.artists.length, 1);
      expect(results.artists.first.read<String>('name'), 'Radiohead');
      expect(results.tracks, isEmpty);
      expect(results.albums, isEmpty);
    });

    test('searchTracks false excludes tracks', () async {
      await insertTrack(
        db,
        uuid: '1',
        title: 'TestSong',
        artist: 'TestArtist',
        album: 'TestAlbum',
      );
      await rebuildFts(db);

      final results = await db.getSearchResults('Test', searchTracks: false);
      expect(results.tracks, isEmpty);
      expect(results.artists.length, greaterThanOrEqualTo(1));
    });

    test('empty query returns empty results', () async {
      await insertTrack(db, uuid: '1', title: 'Song', artist: 'Artist');
      await rebuildFts(db);

      final results = await db.getSearchResults('');
      expect(results.tracks, isEmpty);
      expect(results.artists, isEmpty);
      expect(results.albums, isEmpty);
    });

    test('prefix matching works', () async {
      await insertTrack(db, uuid: '1', title: 'Song', artist: 'ArtistName');
      await rebuildFts(db);

      final results = await db.getSearchResults(
        'Art',
        searchTracks: false,
        searchAlbums: false,
      );
      expect(results.artists.length, greaterThanOrEqualTo(1));
      expect(results.artists.first.read<String>('name'), 'ArtistName');
    });
  });

  group('SearchParameter validation', () {
    test('accepts valid metadata columns', () {
      expect(
        () => SearchParameter(column: 'title', operator: '=', value: 'x'),
        returnsNormally,
      );
      expect(
        () => SearchParameter(column: 'year', operator: '>=', value: 2020),
        returnsNormally,
      );
    });

    test('accepts valid track columns', () {
      expect(
        () => SearchParameter(column: 'uuid_id', operator: '=', value: 'abc'),
        returnsNormally,
      );
    });

    test('rejects artist_id as a metadata column', () {
      expect(
        () => SearchParameter(column: 'artist_id', operator: '=', value: 1),
        throwsArgumentError,
      );
    });

    test('rejects album_id as a metadata column', () {
      expect(
        () => SearchParameter(column: 'album_id', operator: '=', value: 1),
        throwsArgumentError,
      );
    });

    test('rejects invalid operator', () {
      expect(
        () => SearchParameter(column: 'title', operator: '!=', value: 'x'),
        throwsArgumentError,
      );
    });
  });

  group('cover_art_id', () {
    test('trackmetadataCompanionFromDto includes coverArtId when present', () {
      final dto = ClientTrackDto.fromJson(
        _trackJson(metadata: {..._fullMetadataJson(), 'cover_art_id': 42}),
      );

      final companion = trackmetadataCompanionFromDto(dto);

      expect(companion.coverArtId, const Value<int?>(42));
    });

    test('trackmetadataCompanionFromDto has null coverArtId when absent', () {
      final dto = ClientTrackDto.fromJson(_trackJson());

      final companion = trackmetadataCompanionFromDto(dto);

      expect(companion.coverArtId, const Value<int?>(null));
    });

    test('coverArtId round-trips through database', () async {
      final dto = ClientTrackDto.fromJson({
        'uuid_id': 'cover-art-test-1',
        'created_at': 1700000000,
        'last_updated': 1700001000,
        'revision': 1,
        'metadata': {..._fullMetadataJson(), 'cover_art_id': 7},
      });

      await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
      await db
          .into(db.trackmetadata)
          .insert(trackmetadataCompanionFromDto(dto));

      final metas = await db.select(db.trackmetadata).get();
      expect(metas.length, 1);
      expect(metas.first.coverArtId, 7);
    });

    test('coverArtId is null when not set', () async {
      final dto = ClientTrackDto.fromJson({
        'uuid_id': 'no-cover-art-1',
        'created_at': 1700000000,
        'last_updated': 1700001000,
        'revision': 1,
        'metadata': _minimalMetadataJson(),
      });

      await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
      await db
          .into(db.trackmetadata)
          .insert(trackmetadataCompanionFromDto(dto));

      final metas = await db.select(db.trackmetadata).get();
      expect(metas.length, 1);
      expect(metas.first.coverArtId, null);
    });

    test('coverArtId is included in track SELECT queries', () async {
      final artistId = await ensureArtist(db, 'Cover Art Artist');
      final albumId = await ensureAlbum(
        db,
        artistId: artistId,
        name: 'Cover Album',
      );

      final dto = ClientTrackDto.fromJson({
        'uuid_id': 'cover-select-1',
        'created_at': 1700000000,
        'last_updated': 1700001000,
        'revision': 1,
        'metadata': {
          ..._fullMetadataJson(),
          'artist_id': artistId,
          'album_id': albumId,
          'cover_art_id': 99,
        },
      });

      await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
      await db
          .into(db.trackmetadata)
          .insert(trackmetadataCompanionFromDto(dto));

      final rows = await db.getTracks();
      expect(rows.length, 1);
      expect(rows.first.readNullable<int>('cover_art_id'), 99);
    });

    test('coverArtId is null in track SELECT when not set', () async {
      final dto = ClientTrackDto.fromJson({
        'uuid_id': 'cover-select-null-1',
        'created_at': 1700000000,
        'last_updated': 1700001000,
        'revision': 1,
        'metadata': _minimalMetadataJson(),
      });

      await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
      await db
          .into(db.trackmetadata)
          .insert(trackmetadataCompanionFromDto(dto));

      final rows = await db.getTracks();
      expect(rows.length, 1);
      expect(rows.first.readNullable<int>('cover_art_id'), null);
    });

    test('cover_art_id is accepted in allowedMetadataColumns', () {
      expect(allowedMetadataColumns.contains('cover_art_id'), isTrue);
    });
  });

  group('resetLocalData', () {
    test(
      'clears all app tables and FTS rows while leaving DB writable',
      () async {
        await db.customStatement(
          "INSERT INTO artists (id, name) VALUES (1, 'Reset Artist')",
        );
        await db.customStatement(
          "INSERT INTO albums "
          "(id, name, artist_id, year, is_single_grouping) "
          "VALUES (1, 'Reset Album', 1, 2024, 0)",
        );
        await db.customStatement(
          "INSERT INTO tracks "
          "(uuid_id, created_at, last_updated, file_path) "
          "VALUES ('reset-track', 1, 2, '/tmp/reset-track.m4a')",
        );
        await db.customStatement(
          "INSERT INTO trackmetadata "
          "(uuid_id, title, artist, album, artist_id, album_id, duration, "
          "bitrate_kbps, sample_rate_hz, channels, has_album_art) "
          "VALUES ('reset-track', 'Reset Song', 'Reset Artist', "
          "'Reset Album', 1, 1, 120, 320, 44100, 2, 0)",
        );
        await db.customStatement(
          "INSERT INTO queue_sessions "
          "(id, is_active, created_at, updated_at, source_type) "
          "VALUES (1, 1, 1, 1, 'library')",
        );
        await db.customStatement(
          "INSERT INTO queue_session_items "
          "(item_id, session_id, queue_type, position, uuid_id) "
          "VALUES (1, 1, 'main', 0, 'reset-track')",
        );
        await db.customStatement(
          "INSERT INTO queue_session_play_order "
          "(session_id, play_position, item_id) VALUES (1, 0, 1)",
        );
        await db.customStatement(
          "INSERT INTO fts_tracks "
          "(rowid, title, artist_name, album_name) "
          "VALUES (1, 'Reset Song', 'Reset Artist', 'Reset Album')",
        );
        await db.customStatement(
          "INSERT INTO fts_artists (rowid, name) VALUES (1, 'Reset Artist')",
        );
        await db.customStatement(
          "INSERT INTO fts_albums "
          "(rowid, name, artist_name) VALUES (1, 'Reset Album', 'Reset Artist')",
        );

        await db.resetLocalData();

        expect(await db.select(db.queueSessionPlayOrder).get(), isEmpty);
        expect(await db.select(db.queueSessionItems).get(), isEmpty);
        expect(await db.select(db.queueSessions).get(), isEmpty);
        expect(await db.select(db.trackmetadata).get(), isEmpty);
        expect(await db.select(db.tracks).get(), isEmpty);
        expect(await db.select(db.albums).get(), isEmpty);
        expect(await db.select(db.artists).get(), isEmpty);

        final ftsRows = await db
            .customSelect(
              "SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH '\"Reset\"*'",
            )
            .get();
        expect(ftsRows, isEmpty);

        await db.customStatement(
          "INSERT INTO artists (id, name) VALUES (2, 'After Reset')",
        );
        expect(await db.select(db.artists).get(), hasLength(1));
      },
    );
  });

  group('schema', () {
    // Schema history was reset during beta: the current definitions are v1 and
    // onCreate is the only creation path. This sanity check pins the reset —
    // user_version lands at 1 and the newest columns exist from day one. When
    // the first real migration is added, follow the ground rules documented on
    // AppDatabase.migration (test it by opening a REAL previous-version file).
    test('fresh database is created at version 1 with the full current shape',
        () async {
      final version = await db
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 1);

      for (final col in ['original_values_json', 'rejection_reason']) {
        final hit = await db
            .customSelect(
              "SELECT name FROM pragma_table_info('pending_edits') "
              'WHERE name = ?',
              variables: [Variable.withString(col)],
            )
            .get();
        expect(hit, hasLength(1), reason: 'pending_edits is missing $col');
      }
      final revision = await db
          .customSelect(
            "SELECT name FROM pragma_table_info('tracks') "
            "WHERE name = 'revision'",
          )
          .get();
      expect(revision, hasLength(1));
    });
  });

  group('watchPendingEditCounts', () {
    test('take_server resolution markers are not counted as pending edits',
        () async {
      // One row per status. `take_server` is a resolution marker in the
      // retry pipeline (the user already discarded that edit), not an
      // outstanding edit — it must not surface in any banner bucket.
      await db.customStatement(
        'INSERT INTO pending_edits '
        '(uuid_id, values_json, write_mode, base_revision, status, updated_at) '
        "VALUES "
        "('u1', '{\"title\":\"a\"}', 'db_only', 5, 'pending', 0), "
        "('u2', '{\"title\":\"b\"}', 'db_only', 5, 'conflicted', 0), "
        "('u3', '{\"title\":\"c\"}', 'db_only', 5, 'rejected', 0), "
        "('u4', '{\"title\":\"d\"}', 'db_only', 5, 'take_server', 0)",
      );

      final counts = await db.watchPendingEditCounts().first;
      expect(counts.conflicted, 1);
      expect(counts.rejected, 1);
      expect(counts.pending, 1,
          reason: "a 'take_server' marker was counted as a pending edit — "
              'the banner would show a phantom row with no Review affordance');
    });
  });

  group('reactive browse', () {
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

    test('watchTracks re-emits an optimistic edit without a refresh', () async {
      await db.customStatement(
        "INSERT INTO tracks (uuid_id, created_at, last_updated) VALUES ('u1',0,0)",
      );
      await db.customStatement(
        'INSERT INTO trackmetadata (uuid_id, title, artist, album, duration, '
        'bitrate_kbps, sample_rate_hz, channels, has_album_art) '
        "VALUES ('u1','Old','A','Alb',1,1,1,2,0)",
      );
      final rowid = (await db
              .customSelect("SELECT rowid AS r FROM trackmetadata WHERE uuid_id='u1'")
              .getSingle())
          .read<int>('r');
      await db.customStatement(
        "INSERT INTO fts_tracks(rowid, title, artist_name, album_name) "
        "VALUES (?, 'Old', 'A', 'Alb')",
        [rowid],
      );

      final titles = <String?>[];
      final sub = db.watchTracks(limit: 50).listen(
        (rows) =>
            titles.add(rows.isEmpty ? null : rows.first.read<String?>('title')),
      );
      addTearDown(sub.cancel);
      await settle();
      expect(titles.last, 'Old');

      // The real optimistic-write path (customUpdate) must notify watchers.
      await db.applyOptimisticTrackEdit('u1', {'title': 'New'});
      await settle();
      expect(titles.last, 'New');
    });

    test('watchArtists re-emits when an artist row is removed', () async {
      await db.customStatement(
        "INSERT INTO artists (id, name) VALUES (1,'A'),(2,'B')",
      );
      final counts = <int>[];
      final sub =
          db.watchArtists(limit: 50).listen((rows) => counts.add(rows.length));
      addTearDown(sub.cancel);
      await settle();
      expect(counts.last, 2);

      // A typed delete (as the orphan sweep's sibling writes do) notifies the
      // artists stream so the removed card disappears with no manual refresh.
      await (db.delete(db.artists)..where((a) => a.id.equals(2))).go();
      await settle();
      expect(counts.last, 1);
    });
  });

  group('metadata autocomplete', () {
    Future<void> seed() async {
      await db.customStatement(
        "INSERT INTO artists (id, name) VALUES "
        "(1, 'Radiohead'), (2, 'radio star'), (3, 'Beatles')",
      );
      await db.customStatement(
        "INSERT INTO albums (id, name, artist_id, is_single_grouping) VALUES "
        "(1, 'OK Computer', 1, 0), (2, 'Okay', 1, 0), (3, 'Abbey Road', 3, 0)",
      );
      await db.customStatement(
        "INSERT INTO tracks (uuid_id, created_at, last_updated) VALUES "
        "('u1', 0, 0), ('u2', 0, 0), ('u3', 0, 0)",
      );
      await db.customStatement(
        "INSERT INTO trackmetadata "
        "(uuid_id, genre, duration, bitrate_kbps, sample_rate_hz, channels, "
        "has_album_art) VALUES "
        "('u1', 'Rock', 1, 1, 1, 2, 0), "
        "('u2', 'rock and roll', 1, 1, 1, 2, 0), "
        "('u3', 'Jazz', 1, 1, 1, 2, 0)",
      );
    }

    test('artistSuggestions is a case-insensitive prefix match', () async {
      await seed();
      expect(await db.artistSuggestions('rad'), ['Radiohead', 'radio star']);
      expect(await db.artistSuggestions('BEAT'), ['Beatles']);
      expect(await db.artistSuggestions('zzz'), isEmpty);
    });

    test('empty prefix yields no suggestions', () async {
      await seed();
      expect(await db.artistSuggestions('   '), isEmpty);
    });

    test('albumSuggestions matches album names', () async {
      await seed();
      expect(await db.albumSuggestions('ok'), ['OK Computer', 'Okay']);
    });

    test('genreSuggestions is distinct, case-insensitive, limited', () async {
      await seed();
      expect(await db.genreSuggestions('ro'), ['Rock', 'rock and roll']);
      expect(await db.genreSuggestions('ja'), ['Jazz']);
      expect(await db.artistSuggestions('rad', limit: 1), hasLength(1));
    });

    test('a typed % is a literal, not a wildcard', () async {
      await db.customStatement(
        "INSERT INTO artists (id, name) VALUES (1, '100% Pure')",
      );
      expect(await db.artistSuggestions('100%'), ['100% Pure']);
      expect(await db.artistSuggestions('200'), isEmpty);
    });
  });
}
