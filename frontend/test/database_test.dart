import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('tracksCompanionFromJson', () {
    test('parses a ClientTrack JSON correctly', () {
      final json = <String, dynamic>{
        'uuid_id': 'abc-123',
        'created_at': 1700000000,
        'last_updated': 1700001000,
        'metadata': <String, dynamic>{},
      };

      final companion = tracksCompanionFromJson(json);

      expect(companion.uuidId, const Value('abc-123'));
      expect(companion.createdAt, const Value(1700000000));
      expect(companion.lastUpdated, const Value(1700001000));
    });

    test('filePath is absent (not set from backend JSON)', () {
      final json = <String, dynamic>{
        'uuid_id': 'abc-123',
        'created_at': 1700000000,
        'last_updated': 1700001000,
        'metadata': <String, dynamic>{},
      };

      final companion = tracksCompanionFromJson(json);

      expect(companion.filePath, const Value.absent());
    });
  });

  group('trackmetadataCompanionFromJson', () {
    test('parses a full metadata JSON correctly', () {
      final json = <String, dynamic>{
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

      final companion = trackmetadataCompanionFromJson('abc-123', json);

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
      final json = <String, dynamic>{
        'duration': 100.0,
        'bitrate_kbps': 128.0,
        'sample_rate_hz': 48000,
        'channels': 1,
        'has_album_art': false,
      };

      final companion = trackmetadataCompanionFromJson('xyz-789', json);

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
      final jsonTrue = <String, dynamic>{
        'duration': 0.0,
        'bitrate_kbps': 0.0,
        'sample_rate_hz': 0,
        'channels': 0,
        'has_album_art': true,
      };
      final jsonFalse = <String, dynamic>{
        'duration': 0.0,
        'bitrate_kbps': 0.0,
        'sample_rate_hz': 0,
        'channels': 0,
        'has_album_art': false,
      };

      expect(
        trackmetadataCompanionFromJson('a', jsonTrue).hasAlbumArt,
        const Value(true),
      );
      expect(
        trackmetadataCompanionFromJson('b', jsonFalse).hasAlbumArt,
        const Value(false),
      );
    });
  });

  group('database round-trip', () {
    test('insert and read back a track with metadata', () async {
      final trackJson = <String, dynamic>{
        'uuid_id': 'round-trip-1',
        'created_at': 1700000000,
        'last_updated': 1700001000,
        'metadata': <String, dynamic>{
          'title': 'Test Song',
          'artist': 'Test Artist',
          'duration': 180.0,
          'bitrate_kbps': 256.0,
          'sample_rate_hz': 44100,
          'channels': 2,
          'has_album_art': true,
        },
      };

      final trackCompanion = tracksCompanionFromJson(trackJson);
      final metaCompanion = trackmetadataCompanionFromJson(
        'round-trip-1',
        trackJson['metadata'] as Map<String, dynamic>,
      );

      await db.into(db.tracks).insert(trackCompanion);
      await db.into(db.trackmetadata).insert(metaCompanion);

      final tracks = await db.select(db.tracks).get();
      expect(tracks.length, 1);
      expect(tracks.first.uuidId, 'round-trip-1');

      final metas = await db.select(db.trackmetadata).get();
      expect(metas.length, 1);
      expect(metas.first.title, 'Test Song');
      expect(metas.first.hasAlbumArt, true);
    });
  });
}

