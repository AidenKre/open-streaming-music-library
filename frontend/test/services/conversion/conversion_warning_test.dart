import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/services/conversion/conversion_warning.dart';

void main() {
  group('conversionWarning (pure)', () {
    ConversionWarning warn({
      required String? source,
      double? sourceBitrate,
      String target = 'aac',
      bool lossless = false,
      int? targetBitrate = 192,
    }) => conversionWarning(
      sourceCodec: source,
      sourceBitrateKbps: sourceBitrate,
      targetCodec: target,
      targetIsLossless: lossless,
      targetBitrateKbps: lossless ? null : targetBitrate,
    );

    test('unknown / null source codec -> lossy target: cautious + severe', () {
      for (final source in [null, 'weirdcodec']) {
        final w = warn(source: source);
        expect(w.title, 'This replaces the original file');
        expect(w.body, contains('may permanently lose audio quality'));
        expect(w.severe, isTrue);
      }
    });

    test('unknown / null source codec -> lossless target: neutral', () {
      for (final source in [null, 'weirdcodec']) {
        final w = warn(source: source, target: 'flac', lossless: true);
        expect(w.title, 'This replaces the original file');
        expect(w.body, isNot(contains('lose audio quality')));
        expect(w.body, contains('cannot be restored'));
        expect(w.severe, isFalse);
      }
    });

    test('same lossy codec, unknown source bitrate: no "lower bitrate" claim',
        () {
      final w = warn(source: 'aac', sourceBitrate: null, targetBitrate: 320);
      expect(w.title, 'Additional quality loss');
      expect(w.body, isNot(contains('lower bitrate')));
      expect(w.body, isNot(contains('shrinks')));
      expect(w.body, contains('generation loss'));
      expect(w.severe, isTrue);
    });

    test('same lossy codec, known higher source bitrate: "lower bitrate"', () {
      final w = warn(source: 'aac', sourceBitrate: 320, targetBitrate: 128);
      expect(w.body, contains('at a lower bitrate shrinks the file'));
    });

    test('wav and pcm_* sources are lossless', () {
      for (final source in ['wav', 'WAV', 'pcm_s16le', 'pcm_s24le']) {
        expect(warn(source: source).title, 'Permanent quality loss',
            reason: '$source -> lossy');
        expect(
          warn(source: source, target: 'flac', lossless: true).title,
          'Lossless to lossless',
          reason: '$source -> lossless',
        );
      }
    });
  });
}
