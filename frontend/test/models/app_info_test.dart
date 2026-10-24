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

    test('parses the conversion block', () {
      final info = AppInfo.fromJson({
        'entities': {'track': {'fields': [], 'actions': ['convert']}},
        'conversion': {
          'targets': [
            {'codec': 'aac', 'is_lossless': false},
            {'codec': 'flac', 'is_lossless': true},
          ],
          'bitrate_presets': [320, 256, 192, 128],
        },
      });

      expect(info.conversion.targets.map((t) => t.codec), ['aac', 'flac']);
      expect(info.conversion.targets[1].isLossless, isTrue);
      expect(info.conversion.bitratePresets, [320, 256, 192, 128]);
      expect(info.entity('track')!.actions, ['convert']);
    });

    test('missing conversion block defaults to empty capabilities', () {
      final info = AppInfo.fromJson({'entities': {}});
      expect(info.conversion.targets, isEmpty);
      expect(info.conversion.bitratePresets, isEmpty);
    });

    test('conversion block round-trips through toJson', () {
      const original = ConversionCapabilities(
        targets: [
          ConversionTargetInfo(codec: 'mp3', isLossless: false),
          ConversionTargetInfo(codec: 'alac', isLossless: true),
        ],
        bitratePresets: [320, 192],
      );
      final back = ConversionCapabilities.fromJson(original.toJson());
      expect(back.targets.map((t) => t.codec), ['mp3', 'alac']);
      expect(back.bitratePresets, [320, 192]);
    });
  });

  group('ConversionCapabilities.allowedFor', () {
    const capabilities = ConversionCapabilities(
      targets: [
        ConversionTargetInfo(codec: 'aac', isLossless: false),
        ConversionTargetInfo(codec: 'alac', isLossless: true),
        ConversionTargetInfo(codec: 'flac', isLossless: true),
        ConversionTargetInfo(codec: 'mp3', isLossless: false),
      ],
      bitratePresets: [320, 256, 192, 128],
    );

    test('excludes only the lossless-same-codec no-op', () {
      final allowed = capabilities.allowedFor('flac');
      expect(allowed.map((t) => t.codec), ['aac', 'alac', 'mp3']);
    });

    test('lossy same-codec is NOT excluded (warn-only, not blocked)', () {
      final allowed = capabilities.allowedFor('mp3');
      expect(allowed.map((t) => t.codec), contains('mp3'));
    });

    test('a source codec outside the target list excludes nothing', () {
      final allowed = capabilities.allowedFor('wav');
      expect(allowed.length, capabilities.targets.length);
    });

    test('a null source codec returns every target', () {
      final allowed = capabilities.allowedFor(null);
      expect(allowed.length, capabilities.targets.length);
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
