import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/audio/track_cache_manager.dart';
import 'package:frontend/services/quality_presets.dart';

void main() {
  group('isValidQuality', () {
    test('accepts every preset', () {
      for (final q in qualityPresets) {
        expect(isValidQuality(q), isTrue, reason: 'expected $q to be valid');
      }
    });

    test('rejects null and unknown values', () {
      expect(isValidQuality(null), isFalse);
      expect(isValidQuality(''), isFalse);
      expect(isValidQuality('384'), isFalse);
      expect(isValidQuality('original-hifi'), isFalse);
    });
  });

  group('buildTrackStreamUri', () {
    setUp(() {
      ApiClient.init('http://test.local:9000');
    });

    test('omits the quality query param for the original preset', () {
      final uri = buildTrackStreamUri('abc', quality: originalQuality);
      expect(uri.queryParameters, isEmpty);
      expect(uri.pathSegments, ['tracks', 'abc', 'stream']);
    });

    test('omits the quality query param when quality is null', () {
      final uri = buildTrackStreamUri('abc');
      expect(uri.queryParameters, isEmpty);
    });

    test('adds quality query param for transcode presets', () {
      for (final preset in qualityPresets.where((q) => q != originalQuality)) {
        final uri = buildTrackStreamUri('abc', quality: preset);
        expect(uri.queryParameters['quality'], preset,
            reason: 'expected quality=$preset in query');
      }
    });

    test('preserves any base path on the API URL', () {
      ApiClient.init('http://test.local:9000/api/v2');
      final uri = buildTrackStreamUri('xyz', quality: '256');
      expect(uri.pathSegments, ['api', 'v2', 'tracks', 'xyz', 'stream']);
      expect(uri.queryParameters['quality'], '256');
    });
  });
}
