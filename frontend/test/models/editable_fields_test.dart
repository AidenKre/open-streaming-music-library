// B.8 (U23-FE-SYNC-A-03): every editable field resolves in Get info's
// pre-filled values and in the server values the edit outbox compares a 409
// against; the fields that offer suggestions are one exported set.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/track_metadata_dto.dart';
import 'package:frontend/models/editable_fields.dart';
import 'package:frontend/models/ui/track_ui.dart';

/// One distinct value per editable field (an independent fixture).
const _values = <String, Object>{
  'title': 'T',
  'artist': 'Ar',
  'album': 'Al',
  'album_artist': 'AA',
  'year': 1999,
  'date': '1999-05-01',
  'genre': 'G',
  'track_number': 3,
  'disc_number': 2,
};

void main() {
  test('the fixture names every editable field', () {
    expect(
      {for (final f in defaultEditableTrackFields) f.key},
      _values.keys.toSet(),
    );
  });

  test("every editable field resolves in Get info's values", () {
    final track = TrackUI(
      uuidId: 'u',
      createdAt: 0,
      lastUpdated: 0,
      title: 'T',
      artist: 'Ar',
      album: 'Al',
      albumArtist: 'AA',
      year: 1999,
      date: '1999-05-01',
      genre: 'G',
      trackNumber: 3,
      discNumber: 2,
      duration: 1.0,
      bitrateKbps: 320.0,
      sampleRateHz: 44100,
      channels: 2,
      hasAlbumArt: false,
    );
    for (final f in defaultEditableTrackFields) {
      expect(track.editableValue(f.key), _values[f.key], reason: f.key);
    }
    expect(track.editableValue('composer'), isNull);
  });

  test("every editable field resolves in the server's track values", () {
    const meta = TrackMetadataDto(
      title: 'T',
      artist: 'Ar',
      album: 'Al',
      albumArtist: 'AA',
      year: 1999,
      date: '1999-05-01',
      genre: 'G',
      trackNumber: 3,
      discNumber: 2,
      duration: 1.0,
      bitrateKbps: 320.0,
      sampleRateHz: 44100,
      channels: 2,
      hasAlbumArt: false,
    );
    for (final f in defaultEditableTrackFields) {
      expect(meta.editableValue(f.key), _values[f.key],
          reason: f.key);
    }
    expect(meta.editableValue('composer'), isNull);
  });

  test('the fields with suggestions are editable text fields', () {
    expect(suggestedEditableFields, {'artist', 'album_artist', 'album', 'genre'});
    final text = {
      for (final f in defaultEditableTrackFields)
        if (f.valueType == 'text') f.key,
    };
    expect(text.containsAll(suggestedEditableFields), isTrue);
  });
}
