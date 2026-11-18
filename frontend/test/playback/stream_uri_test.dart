// Phase M §7.2 / SC-27 Phase M amendment (M-U20): the stream URI takes the
// base URL explicitly; there is no process-wide base URL to read.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/playback/stream_uris.dart';
import 'package:frontend/services/quality_presets.dart';

void main() {
  test('builds on the given base URL, keeping its path', () {
    expect(
      buildTrackStreamUri('http://scope:9/api/v2', 'xyz', quality: '256')
          .toString(),
      'http://scope:9/api/v2/tracks/xyz/stream?quality=256',
    );
  });

  test('the original preset sends no quality', () {
    expect(
      buildTrackStreamUri('http://a:1', 'abc', quality: originalQuality)
          .toString(),
      'http://a:1/tracks/abc/stream',
    );
  });

  // Phase M §7.3 (M-U20): the media token rides as access_token only when
  // the caller passes one (JustAudioEngine is the only caller that does).
  test('a media token is sent as access_token', () {
    final uri = buildTrackStreamUri('http://a:1', 'abc',
        quality: '256', mediaToken: 'media-token-A');
    expect(uri.path, '/tracks/abc/stream');
    expect(uri.queryParameters,
        {'quality': '256', 'access_token': 'media-token-A'});
  });

  test('no media token, no access_token', () {
    expect(
      buildTrackStreamUri('http://a:1', 'abc', quality: '256').toString(),
      'http://a:1/tracks/abc/stream?quality=256',
    );
  });

  test('redactAccessToken hides the value but keeps the rest', () {
    expect(
      redactAccessToken('GET http://a:1/tracks/x/stream?quality=256'
          '&access_token=media-token-A failed; access_token=t2&x=1'),
      'GET http://a:1/tracks/x/stream?quality=256'
      '&access_token=<redacted> failed; access_token=<redacted>&x=1',
    );
    expect(redactAccessToken('no token here'), 'no token here');
    // Review r1 finding 7: percent-encoded and other-cased forms too.
    for (final leaky in [
      'url=http%3A%2F%2Fh%2Ftracks%2Fx%2Fstream%3Faccess_token%3DSECRET1',
      'url=http%253A%252F%252Fh%253Faccess_token%253DSECRET1',
      'ACCESS_TOKEN=SECRET1&x=1',
    ]) {
      expect(redactAccessToken(leaky), isNot(contains('SECRET1')),
          reason: leaky);
    }
  });
}
