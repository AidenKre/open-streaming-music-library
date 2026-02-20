import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/dto/get_tracks_response_dto.dart';
import 'package:frontend/models/dto/track_metadata_dto.dart';

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

Map<String, dynamic> _trackJson(String uuid, Map<String, dynamic> metadata) => {
  'uuid_id': uuid,
  'created_at': 1700000000,
  'last_updated': 1700001000,
  'metadata': metadata,
};

void main() {
  group('TrackMetadataDto.fromJson', () {
    test('parses all fields from a full metadata JSON', () {
      final dto = TrackMetadataDto.fromJson(_fullMetadataJson());

      expect(dto.title, 'My Song');
      expect(dto.artist, 'Artist Name');
      expect(dto.album, 'Album Name');
      expect(dto.albumArtist, 'Album Artist');
      expect(dto.year, 2023);
      expect(dto.date, '2023-06-15');
      expect(dto.genre, 'Rock');
      expect(dto.trackNumber, 3);
      expect(dto.discNumber, 1);
      expect(dto.codec, 'flac');
      expect(dto.duration, 245.5);
      expect(dto.bitrateKbps, 320.0);
      expect(dto.sampleRateHz, 44100);
      expect(dto.channels, 2);
      expect(dto.hasAlbumArt, true);
    });

    test('nullable fields are null when absent', () {
      final dto = TrackMetadataDto.fromJson(_minimalMetadataJson());

      expect(dto.title, isNull);
      expect(dto.artist, isNull);
      expect(dto.album, isNull);
      expect(dto.albumArtist, isNull);
      expect(dto.year, isNull);
      expect(dto.date, isNull);
      expect(dto.genre, isNull);
      expect(dto.trackNumber, isNull);
      expect(dto.discNumber, isNull);
      expect(dto.codec, isNull);
    });

    test('required numeric fields are parsed from minimal JSON', () {
      final dto = TrackMetadataDto.fromJson(_minimalMetadataJson());

      expect(dto.duration, 100.0);
      expect(dto.bitrateKbps, 128.0);
      expect(dto.sampleRateHz, 48000);
      expect(dto.channels, 1);
      expect(dto.hasAlbumArt, false);
    });

    test('hasAlbumArt defaults to false when absent', () {
      final json = Map<String, dynamic>.from(_minimalMetadataJson())
        ..remove('has_album_art');

      final dto = TrackMetadataDto.fromJson(json);

      expect(dto.hasAlbumArt, false);
    });
  });

  group('ClientTrackDto.fromJson', () {
    test('parses top-level fields correctly', () {
      final dto = ClientTrackDto.fromJson(
        _trackJson('abc-123', _fullMetadataJson()),
      );

      expect(dto.uuidId, 'abc-123');
      expect(dto.createdAt, 1700000000);
      expect(dto.lastUpdated, 1700001000);
    });

    test('parses nested metadata', () {
      final dto = ClientTrackDto.fromJson(
        _trackJson('abc-123', _fullMetadataJson()),
      );

      expect(dto.metadata.title, 'My Song');
      expect(dto.metadata.artist, 'Artist Name');
      expect(dto.metadata.hasAlbumArt, true);
    });

    test('handles minimal metadata (all nullable fields absent)', () {
      final dto = ClientTrackDto.fromJson(
        _trackJson('xyz-789', _minimalMetadataJson()),
      );

      expect(dto.uuidId, 'xyz-789');
      expect(dto.metadata.title, isNull);
      expect(dto.metadata.artist, isNull);
      expect(dto.metadata.duration, 100.0);
    });
  });

  group('GetTracksResponseDto.fromJson', () {
    test('parses a list of tracks and nextCursor', () {
      final json = {
        'data': [
          _trackJson('uuid-1', _fullMetadataJson()),
          _trackJson('uuid-2', _minimalMetadataJson()),
        ],
        'nextCursor': 'some-cursor',
      };

      final response = GetTracksResponseDto.fromJson(json);

      expect(response.data.length, 2);
      expect(response.data[0].uuidId, 'uuid-1');
      expect(response.data[1].uuidId, 'uuid-2');
      expect(response.nextCursor, 'some-cursor');
    });

    test('nextCursor is null when absent', () {
      final json = {
        'data': [_trackJson('uuid-1', _minimalMetadataJson())],
        'nextCursor': null,
      };

      final response = GetTracksResponseDto.fromJson(json);

      expect(response.nextCursor, isNull);
    });

    test('empty data list is handled', () {
      final json = {'data': <dynamic>[], 'nextCursor': null};

      final response = GetTracksResponseDto.fromJson(json);

      expect(response.data, isEmpty);
    });
  });
}
