// B.13 (U16-FE-API-B-04): the catalog-sync message types read their fields
// with typed readers. A malformed answer is a FormatException (it was a
// TypeError from a cast); unknown stays null, never 0; a whole float is
// still accepted where an integer is read.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/change_entry_dto.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/dto/get_changes_response_dto.dart';
import 'package:frontend/models/dto/json_fields.dart';
import 'package:frontend/models/dto/track_metadata_dto.dart';

Map<String, dynamic> _meta([Map<String, dynamic> extra = const {}]) => {
  'duration': 180.0,
  'bitrate_kbps': 320.0,
  'sample_rate_hz': 44100,
  'channels': 2,
  'has_album_art': false,
  ...extra,
};

Map<String, dynamic> _track([Map<String, dynamic> extra = const {}]) => {
  'uuid_id': 'u1',
  'created_at': 1000,
  'last_updated': 2000,
  'revision': 3,
  'metadata': _meta(),
  ...extra,
};

Map<String, dynamic> _without(Map<String, dynamic> m, String key) =>
    Map.of(m)..remove(key);

final _malformed = throwsA(isA<FormatException>());

void main() {
  group('jsonWholeInt / jsonWholeIntOrNull (the lenient integer reader)', () {
    test('an int and a whole float are read as the integer', () {
      expect(jsonWholeInt({'n': 7}, 'n'), 7);
      expect(jsonWholeInt({'n': 7.0}, 'n'), 7);
      expect(jsonWholeIntOrNull({'n': -2.0}, 'n'), -2);
      expect(jsonWholeIntOrNull({'n': 0}, 'n'), 0);
    });

    test('missing or null: required is malformed, optional is unknown (null), '
        'never 0', () {
      expect(() => jsonWholeInt({}, 'n'), _malformed);
      expect(() => jsonWholeInt({'n': null}, 'n'), _malformed);
      expect(jsonWholeIntOrNull({}, 'n'), isNull);
      expect(jsonWholeIntOrNull({'n': null}, 'n'), isNull);
    });

    for (final bad in <Object>[7.5, '7', true, <int>[7], <String, int>{}]) {
      test('$bad (${bad.runtimeType}) is malformed', () {
        expect(() => jsonWholeInt({'n': bad}, 'n'), _malformed);
        expect(() => jsonWholeIntOrNull({'n': bad}, 'n'), _malformed);
      });
    }
  });

  group('TrackMetadataDto.fromJson', () {
    for (final key in [
      'title',
      'artist',
      'album',
      'album_artist',
      'date',
      'genre',
      'codec',
    ]) {
      test('$key: a non-string is malformed; missing is unknown', () {
        expect(() => TrackMetadataDto.fromJson(_meta({key: 5})), _malformed);
        expect(() => TrackMetadataDto.fromJson(_meta({key: 5.0})), _malformed);
        final missing = TrackMetadataDto.fromJson(_meta());
        expect(
          [
            missing.title,
            missing.artist,
            missing.album,
            missing.albumArtist,
            missing.date,
            missing.genre,
            missing.codec,
          ],
          everyElement(isNull),
        );
      });
    }

    for (final key in [
      'year',
      'track_number',
      'disc_number',
      'cover_art_id',
      'artist_id',
      'album_id',
    ]) {
      test('$key: a whole float is read; a fraction or a string is '
          'malformed; null is unknown', () {
        TrackMetadataDto read(Object? v) =>
            TrackMetadataDto.fromJson(_meta({key: v}));
        int? field(TrackMetadataDto m) => switch (key) {
          'year' => m.year,
          'track_number' => m.trackNumber,
          'disc_number' => m.discNumber,
          'cover_art_id' => m.coverArtId,
          'artist_id' => m.artistId,
          _ => m.albumId,
        };
        expect(field(read(4)), 4);
        expect(field(read(4.0)), 4);
        expect(field(read(null)), isNull);
        expect(() => read(4.5), _malformed);
        expect(() => read('4'), _malformed);
        expect(() => read(true), _malformed);
      });
    }

    test('bitrate_kbps: a number is read (0 too); a string is malformed', () {
      expect(TrackMetadataDto.fromJson(_meta({'bitrate_kbps': 0})).bitrateKbps,
          0.0);
      expect(
        TrackMetadataDto.fromJson(_meta({'bitrate_kbps': null})).bitrateKbps,
        isNull,
      );
      expect(
        () => TrackMetadataDto.fromJson(_meta({'bitrate_kbps': '320'})),
        _malformed,
      );
    });

    test('has_album_art: a non-boolean is malformed; missing or null reads '
        'false as before', () {
      expect(
        () => TrackMetadataDto.fromJson(_meta({'has_album_art': 'yes'})),
        _malformed,
      );
      expect(
        () => TrackMetadataDto.fromJson(_meta({'has_album_art': 1})),
        _malformed,
      );
      expect(
        TrackMetadataDto.fromJson(_meta({'has_album_art': null})).hasAlbumArt,
        isFalse,
      );
      expect(
        TrackMetadataDto.fromJson(_without(_meta(), 'has_album_art'))
            .hasAlbumArt,
        isFalse,
      );
    });

    test('duration, sample_rate_hz, channels: anything but a positive number '
        'stays unknown (null), as before (SC-16l)', () {
      final m = TrackMetadataDto.fromJson(_meta({
        'duration': '180',
        'sample_rate_hz': 0,
        'channels': -1,
      }));
      expect(m.duration, isNull);
      expect(m.sampleRateHz, isNull);
      expect(m.channels, isNull);
    });
  });

  group('ClientTrackDto.fromJson', () {
    test('a whole float is read where an integer is', () {
      final dto = ClientTrackDto.fromJson(
        _track({'created_at': 1000.0, 'last_updated': 2000.0, 'revision': 3.0}),
      );
      expect(dto.createdAt, 1000);
      expect(dto.lastUpdated, 2000);
      expect(dto.revision, 3);
    });

    for (final (label, json) in <(String, Map<String, dynamic>)>[
      ('uuid_id missing', _without(_track(), 'uuid_id')),
      ('uuid_id not a string', _track({'uuid_id': 1})),
      ('metadata missing', _without(_track(), 'metadata')),
      ('metadata not an object', _track({'metadata': []})),
      ('created_at missing', _without(_track(), 'created_at')),
      ('last_updated a string', _track({'last_updated': '2000'})),
      ('revision missing', _without(_track(), 'revision')),
      ('revision null', _track({'revision': null})),
      ('revision a fraction', _track({'revision': 3.5})),
      ('a metadata field malformed', _track({'metadata': _meta({'year': 'x'})})),
    ]) {
      test('$label is malformed', () {
        expect(() => ClientTrackDto.fromJson(json), _malformed);
      });
    }
  });

  group('ChangeEntryDto.fromJson', () {
    Map<String, dynamic> upsert([Map<String, dynamic> extra = const {}]) => {
      'type': 'upsert',
      'revision': 7,
      'uuid_id': 'u1',
      'track': _track(),
      ...extra,
    };

    test('a whole float revision is read', () {
      expect(ChangeEntryDto.fromJson(upsert({'revision': 7.0})).revision, 7);
    });

    for (final (label, json) in <(String, Map<String, dynamic>)>[
      ('uuid_id missing', _without(upsert(), 'uuid_id')),
      ('uuid_id not a string', upsert({'uuid_id': 7})),
      ('revision missing', _without(upsert(), 'revision')),
      ('revision a string', upsert({'revision': '7'})),
      ('a delete without a uuid', {'type': 'delete', 'revision': 8}),
      ('a malformed track', upsert({'track': _track({'revision': 'x'})})),
    ]) {
      test('$label is malformed', () {
        expect(() => ChangeEntryDto.fromJson(json), _malformed);
      });
    }
  });

  group('GetChangesResponseDto.fromJson', () {
    Map<String, dynamic> page([Map<String, dynamic> extra = const {}]) => {
      'changes': [
        {'type': 'delete', 'revision': 4, 'uuid_id': 'gone'},
      ],
      'nextCursor': null,
      'latestRevision': 9,
      ...extra,
    };

    test('whole floats are read; a null nextCursor is the last page', () {
      final dto = GetChangesResponseDto.fromJson(
        page({'latestRevision': 9.0, 'nextCursor': 4.0}),
      );
      expect(dto.latestRevision, 9);
      expect(dto.nextCursor, 4);
      expect(GetChangesResponseDto.fromJson(page()).nextCursor, isNull);
      expect(
        GetChangesResponseDto.fromJson(_without(page(), 'nextCursor'))
            .nextCursor,
        isNull,
      );
    });

    for (final (label, json) in <(String, Map<String, dynamic>)>[
      ('changes missing', _without(page(), 'changes')),
      ('changes not a list', page({'changes': {}})),
      ('a change not an object', page({'changes': [1]})),
      ('latestRevision missing', _without(page(), 'latestRevision')),
      ('latestRevision a string', page({'latestRevision': '9'})),
      ('nextCursor a string', page({'nextCursor': '4'})),
      ('nextCursor a fraction', page({'nextCursor': 4.5})),
    ]) {
      test('$label is malformed', () {
        expect(() => GetChangesResponseDto.fromJson(json), _malformed);
      });
    }
  });
}
