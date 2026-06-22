import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/services/app_info_service.dart';

void main() {
  group('AppInfo.fromJson', () {
    test('parses entities, fields, and actions', () {
      final info = AppInfo.fromJson({
        'entities': {
          'track': {
            'fields': [
              {'key': 'title', 'label': 'Title', 'valueType': 'text',
                'editable': true},
              {'key': 'year', 'label': 'Year', 'valueType': 'year',
                'editable': true},
            ],
            'actions': [],
          },
        },
      });

      final track = info.entity('track')!;
      expect(track.fields.map((f) => f.key), ['title', 'year']);
      expect(track.fields[1].valueType, 'year');
      expect(track.actions, isEmpty);
    });

    test('round-trips through toJson', () {
      final info = defaultAppInfo();
      final back = AppInfo.fromJson(info.toJson());
      expect(back.entity('track')!.fields.map((f) => f.key),
          info.entity('track')!.fields.map((f) => f.key));
    });
  });

  group('editableFieldsFor', () {
    test('default advertises the nine track tag fields', () {
      final fields = editableFieldsFor(defaultAppInfo(), 'track');
      expect(fields.map((f) => f.key), [
        'title', 'artist', 'album', 'album_artist', 'year', 'date',
        'genre', 'track_number', 'disc_number',
      ]);
    });

    test('intrinsic audio fields are locked even if advertised editable', () {
      // A (hypothetical) server that advertises bitrate_kbps as editable must
      // still not surface it — the client safety lock wins.
      final info = AppInfo.fromJson({
        'entities': {
          'track': {
            'fields': [
              {'key': 'title', 'label': 'Title', 'valueType': 'text',
                'editable': true},
              {'key': 'bitrate_kbps', 'label': 'Bitrate', 'valueType': 'int',
                'editable': true},
            ],
            'actions': [],
          },
        },
      });
      expect(editableFieldsFor(info, 'track').map((f) => f.key), ['title']);
    });

    test('non-editable advertised fields are excluded', () {
      final info = AppInfo.fromJson({
        'entities': {
          'track': {
            'fields': [
              {'key': 'title', 'label': 'Title', 'valueType': 'text',
                'editable': false},
            ],
            'actions': [],
          },
        },
      });
      expect(editableFieldsFor(info, 'track'), isEmpty);
    });

    test('unknown entity yields no fields', () {
      expect(editableFieldsFor(defaultAppInfo(), 'album'), isEmpty);
    });
  });
}
