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
        _trackJson(metadata: {..._minimalMetadataJson(), 'has_album_art': true}),
      );
      final dtoFalse = ClientTrackDto.fromJson(
        _trackJson(metadata: {..._minimalMetadataJson(), 'has_album_art': false}),
      );

      expect(trackmetadataCompanionFromDto(dtoTrue).hasAlbumArt, const Value(true));
      expect(trackmetadataCompanionFromDto(dtoFalse).hasAlbumArt, const Value(false));
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
      await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));

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

  group('getTrackPage', () {
    test('returns tracks joined with metadata', () async {
      await insertTrack(db, uuid: 'a', title: 'Song A', artist: 'Artist A', album: 'Album A');
      final results = await db.getTrackPage(limit: 100);
      expect(results.length, 1);
      expect(results.first.read<String>('uuid_id'), 'a');
      expect(results.first.read<String>('title'), 'Song A');
    });

    test('returns tracks sorted artist -> album -> trackNumber -> uuidId', () async {
      await insertTrack(db, uuid: '1', artist: 'B Artist', album: 'A Album', trackNumber: 2);
      await insertTrack(db, uuid: '2', artist: 'A Artist', album: 'B Album', trackNumber: 1);
      await insertTrack(db, uuid: '3', artist: 'A Artist', album: 'A Album', trackNumber: 2);
      await insertTrack(db, uuid: '4', artist: 'A Artist', album: 'A Album', trackNumber: 1);

      final results = await db.getTrackPage(limit: 100);
      final uuids = results.map((r) => r.read<String>('uuid_id')).toList();
      expect(uuids, ['4', '3', '2', '1']);
    });

    test('cursor skips rows before cursor position', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'A', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'A', album: 'A', trackNumber: 2);
      await insertTrack(db, uuid: '3', artist: 'A', album: 'A', trackNumber: 3);

      // Cursor at track 1 — should return tracks 2 and 3
      final results = await db.getTrackPage(
        limit: 100,
        cursorArtist: 'A',
        cursorAlbum: 'A',
        cursorTrackNumber: 1,
        cursorUuidId: '1',
      );
      expect(results.length, 2);
      expect(results.first.read<String>('uuid_id'), '2');
    });

    test('cursor works across different artists', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'A', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'B', album: 'A', trackNumber: 1);
      await insertTrack(db, uuid: '3', artist: 'C', album: 'A', trackNumber: 1);

      // Cursor at artist A — should return B and C
      final results = await db.getTrackPage(
        limit: 100,
        cursorArtist: 'A',
        cursorAlbum: 'A',
        cursorTrackNumber: 1,
        cursorUuidId: '1',
      );
      expect(results.length, 2);
      final uuids = results.map((r) => r.read<String>('uuid_id')).toList();
      expect(uuids, ['2', '3']);
    });

    test('cursor handles null sort key values', () async {
      await insertTrack(db, uuid: '1', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'A', album: 'A', trackNumber: 1);

      // Cursor at null artist — non-null artists come after
      final results = await db.getTrackPage(
        limit: 100,
        cursorTrackNumber: 1,
        cursorUuidId: '1',
      );
      expect(results.length, 1);
      expect(results.first.read<String>('uuid_id'), '2');
    });

    test('limit caps result count', () async {
      await insertTrack(db, uuid: '1', artist: 'A', album: 'A', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'A', album: 'A', trackNumber: 2);
      await insertTrack(db, uuid: '3', artist: 'A', album: 'A', trackNumber: 3);

      final results = await db.getTrackPage(limit: 2);
      expect(results.length, 2);
    });
  });

  group('getAlbumTrackPage', () {
    test('returns only tracks for matching artist + album', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist A', album: 'Album A', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'Artist B', album: 'Album B', trackNumber: 1);

      final results = await db.getAlbumTrackPage(
        artist: 'Artist A',
        album: 'Album A',
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

      final results = await db.getAlbumTrackPage(
        artist: 'Album Artist',
        album: 'My Album',
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

      final results = await db.getAlbumTrackPage(
        artist: 'Solo Artist',
        album: 'My Album',
        limit: 100,
      );
      expect(results.length, 1);
      expect(results.first.read<String>('uuid_id'), '1');
    });

    test('returns tracks sorted by trackNumber ASC', () async {
      await insertTrack(db, uuid: '3', artist: 'Artist', album: 'Album', trackNumber: 3);
      await insertTrack(db, uuid: '1', artist: 'Artist', album: 'Album', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'Artist', album: 'Album', trackNumber: 2);

      final results = await db.getAlbumTrackPage(
        artist: 'Artist',
        album: 'Album',
        limit: 100,
      );
      final uuids = results.map((r) => r.read<String>('uuid_id')).toList();
      expect(uuids, ['1', '2', '3']);
    });

    test('cursor skips rows before cursor position', () async {
      await insertTrack(db, uuid: '1', artist: 'Artist', album: 'Album', trackNumber: 1);
      await insertTrack(db, uuid: '2', artist: 'Artist', album: 'Album', trackNumber: 2);
      await insertTrack(db, uuid: '3', artist: 'Artist', album: 'Album', trackNumber: 3);

      final results = await db.getAlbumTrackPage(
        artist: 'Artist',
        album: 'Album',
        limit: 100,
        cursorTrackNumber: 1,
        cursorUuidId: '1',
      );
      expect(results.length, 2);
      final uuids = results.map((r) => r.read<String>('uuid_id')).toList();
      expect(uuids, ['2', '3']);
    });
  });
}
