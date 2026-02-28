import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';

const _track = Track(
  uuidId: 'abc-123',
  filePath: '/local/path/song.flac',
  createdAt: 1700000000,
  lastUpdated: 1700001000,
);

const _trackNoFile = Track(
  uuidId: 'abc-123',
  filePath: null,
  createdAt: 1700000000,
  lastUpdated: 1700001000,
);

const _fullMeta = TrackmetadataData(
  uuidId: 'abc-123',
  title: 'My Song',
  artist: 'Artist Name',
  album: 'Album Name',
  albumArtist: 'Album Artist',
  year: 2023,
  date: '2023-06-15',
  genre: 'Rock',
  trackNumber: 3,
  discNumber: 1,
  codec: 'flac',
  duration: 245.5,
  bitrateKbps: 320.0,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: true,
);

const _minimalMeta = TrackmetadataData(
  uuidId: 'abc-123',
  duration: 100.0,
  bitrateKbps: 128.0,
  sampleRateHz: 48000,
  channels: 1,
  hasAlbumArt: false,
);

void main() {
  group('TrackUI.fromDrift', () {
    group('Track fields', () {
      test('maps uuidId', () {
        final ui = TrackUI.fromDrift(_track, _fullMeta);
        expect(ui.uuidId, 'abc-123');
      });

      test('maps filePath', () {
        final ui = TrackUI.fromDrift(_track, _fullMeta);
        expect(ui.filePath, '/local/path/song.flac');
      });

      test('maps createdAt', () {
        final ui = TrackUI.fromDrift(_track, _fullMeta);
        expect(ui.createdAt, 1700000000);
      });

      test('maps lastUpdated', () {
        final ui = TrackUI.fromDrift(_track, _fullMeta);
        expect(ui.lastUpdated, 1700001000);
      });
    });

    group('Trackmetadata fields', () {
      test('maps all metadata fields from full meta', () {
        final ui = TrackUI.fromDrift(_track, _fullMeta);

        expect(ui.title, 'My Song');
        expect(ui.artist, 'Artist Name');
        expect(ui.album, 'Album Name');
        expect(ui.albumArtist, 'Album Artist');
        expect(ui.year, 2023);
        expect(ui.date, '2023-06-15');
        expect(ui.genre, 'Rock');
        expect(ui.trackNumber, 3);
        expect(ui.discNumber, 1);
        expect(ui.codec, 'flac');
        expect(ui.duration, 245.5);
        expect(ui.bitrateKbps, 320.0);
        expect(ui.sampleRateHz, 44100);
        expect(ui.channels, 2);
        expect(ui.hasAlbumArt, true);
      });

      test('nullable fields are null when absent', () {
        final ui = TrackUI.fromDrift(_track, _minimalMeta);

        expect(ui.title, isNull);
        expect(ui.artist, isNull);
        expect(ui.album, isNull);
        expect(ui.albumArtist, isNull);
        expect(ui.year, isNull);
        expect(ui.date, isNull);
        expect(ui.genre, isNull);
        expect(ui.trackNumber, isNull);
        expect(ui.discNumber, isNull);
        expect(ui.codec, isNull);
      });

      test('maps required fields from minimal meta', () {
        final ui = TrackUI.fromDrift(_track, _minimalMeta);

        expect(ui.duration, 100.0);
        expect(ui.bitrateKbps, 128.0);
        expect(ui.sampleRateHz, 48000);
        expect(ui.channels, 1);
        expect(ui.hasAlbumArt, false);
      });
    });
  });

  group('isDownloaded', () {
    test('returns true when filePath is non-null', () {
      final ui = TrackUI.fromDrift(_track, _fullMeta);
      expect(ui.isDownloaded, true);
    });

    test('returns false when filePath is null', () {
      final ui = TrackUI.fromDrift(_trackNoFile, _fullMeta);
      expect(ui.isDownloaded, false);
    });
  });

  group('formattedDuration', () {
    test('formats seconds only', () {
      final ui = TrackUI.fromDrift(
        _track,
        _fullMeta.copyWith(duration: 0.0),
      );
      expect(ui.formattedDuration, '0:00');
    });

    test('truncates fractional seconds', () {
      final ui = TrackUI.fromDrift(
        _track,
        _fullMeta.copyWith(duration: 59.9),
      );
      expect(ui.formattedDuration, '0:59');
    });

    test('formats minutes and seconds', () {
      final ui = TrackUI.fromDrift(
        _track,
        _fullMeta.copyWith(duration: 65.0),
      );
      expect(ui.formattedDuration, '1:05');
    });

    test('formats hours, minutes, and seconds', () {
      final ui = TrackUI.fromDrift(
        _track,
        _fullMeta.copyWith(duration: 3661.0),
      );
      expect(ui.formattedDuration, '1:01:01');
    });

    test('formats days, hours, minutes, and seconds', () {
      final ui = TrackUI.fromDrift(
        _track,
        _fullMeta.copyWith(duration: 90061.0),
      );
      expect(ui.formattedDuration, '1:01:01:01');
    });
  });

  group('TrackUI.fromQueryRow', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('maps all fields correctly via DB round-trip', () async {
      final dto = ClientTrackDto.fromJson({
        'uuid_id': 'qr-1',
        'created_at': 1700000000,
        'last_updated': 1700001000,
        'metadata': {
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
        },
      });

      await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
      await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));

      final rows = await db.getTracks(
        orderBy: [OrderParameter(column: 'uuid_id')],
      );
      expect(rows.length, 1);

      final ui = TrackUI.fromQueryRow(rows.first);
      expect(ui.uuidId, 'qr-1');
      expect(ui.filePath, isNull);
      expect(ui.createdAt, 1700000000);
      expect(ui.lastUpdated, 1700001000);
      expect(ui.title, 'My Song');
      expect(ui.artist, 'Artist Name');
      expect(ui.album, 'Album Name');
      expect(ui.albumArtist, 'Album Artist');
      expect(ui.year, 2023);
      expect(ui.date, '2023-06-15');
      expect(ui.genre, 'Rock');
      expect(ui.trackNumber, 3);
      expect(ui.discNumber, 1);
      expect(ui.codec, 'flac');
      expect(ui.duration, 245.5);
      expect(ui.bitrateKbps, 320.0);
      expect(ui.sampleRateHz, 44100);
      expect(ui.channels, 2);
      expect(ui.hasAlbumArt, true);
    });
  });
}
