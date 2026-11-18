// Phase 9D.2d (spec §7.4 "Approve", 9-U12): the client parses the
// authorization URL `connect` returns and accepts it only with scheme
// https, host exactly `www.last.fm`, no user-info or port, path exactly
// `/api/auth/`, only `api_key` and `token` in the query, and no fragment
// (`…/api/auth/../x` is refused). It never logs or stores it: the value's
// toString() is redacted.
//
// Every key and token below is made up.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/lastfm_authorization_url.dart';

const _key = '0123456789abcdef0123456789abcdef';
const _token = 'Tk-made-up_0123456789';
const _ok = 'https://www.last.fm/api/auth/?api_key=$_key&token=$_token';

void main() {
  test('the URL the 9D.1d server builds is accepted', () {
    final url = LastfmAuthorizationUrl.tryParse(_ok);
    expect(url, isNotNull);
    expect(url!.uri.scheme, 'https');
    expect(url.uri.host, 'www.last.fm');
    expect(url.uri.path, '/api/auth/');
    expect(url.uri.queryParameters, {'api_key': _key, 'token': _token});
  });

  test('parameter order does not matter; percent-encoded values are kept',
      () {
    expect(
      LastfmAuthorizationUrl.tryParse(
          'https://www.last.fm/api/auth/?token=$_token&api_key=$_key'),
      isNotNull,
    );
    final encoded = LastfmAuthorizationUrl.tryParse(
        'https://www.last.fm/api/auth/?api_key=$_key&token=a%2Bb%3Dc');
    expect(encoded, isNotNull);
    expect(encoded!.uri.queryParameters['token'], 'a+b=c');
  });

  // One row per rule; each differs from the accepted URL in one way.
  const refused = <String, String>{
    // scheme
    'http': 'http://www.last.fm/api/auth/?api_key=$_key&token=$_token',
    'uppercase scheme':
        'HTTPS://www.last.fm/api/auth/?api_key=$_key&token=$_token',
    'javascript': 'javascript:alert(1)//www.last.fm/api/auth/',
    'no scheme': '//www.last.fm/api/auth/?api_key=$_key&token=$_token',
    'relative': '/api/auth/?api_key=$_key&token=$_token',
    // host
    'bare last.fm': 'https://last.fm/api/auth/?api_key=$_key&token=$_token',
    'other host': 'https://evil.example/api/auth/?api_key=$_key&token=$_token',
    'suffix host':
        'https://www.last.fm.evil.example/api/auth/?api_key=$_key&token=$_token',
    'prefix host':
        'https://evil.www.last.fm/api/auth/?api_key=$_key&token=$_token',
    'uppercase host':
        'https://WWW.LAST.FM/api/auth/?api_key=$_key&token=$_token',
    'trailing dot host':
        'https://www.last.fm./api/auth/?api_key=$_key&token=$_token',
    'ip host': 'https://127.0.0.1/api/auth/?api_key=$_key&token=$_token',
    // user-info and port
    'user-info': 'https://user@www.last.fm/api/auth/?api_key=$_key&token=$_token',
    'user-info disguise':
        'https://www.last.fm@evil.example/api/auth/?api_key=$_key&token=$_token',
    'user and password':
        'https://a:b@www.last.fm/api/auth/?api_key=$_key&token=$_token',
    'port 443': 'https://www.last.fm:443/api/auth/?api_key=$_key&token=$_token',
    'port 8443':
        'https://www.last.fm:8443/api/auth/?api_key=$_key&token=$_token',
    'empty port': 'https://www.last.fm:/api/auth/?api_key=$_key&token=$_token',
    // path
    'dot-dot after auth': 'https://www.last.fm/api/auth/../x',
    'dot-dot after auth with query':
        'https://www.last.fm/api/auth/../x?api_key=$_key&token=$_token',
    'dot-dot that normalizes back to auth':
        'https://www.last.fm/api/x/../auth/?api_key=$_key&token=$_token',
    'dot segment': 'https://www.last.fm/api/./auth/?api_key=$_key&token=$_token',
    'encoded dot-dot':
        'https://www.last.fm/api/auth/%2e%2e/x?api_key=$_key&token=$_token',
    'no trailing slash':
        'https://www.last.fm/api/auth?api_key=$_key&token=$_token',
    'extra segment':
        'https://www.last.fm/api/auth/x?api_key=$_key&token=$_token',
    'double slash':
        'https://www.last.fm/api/auth//?api_key=$_key&token=$_token',
    'leading double slash':
        'https://www.last.fm//api/auth/?api_key=$_key&token=$_token',
    'uppercase path':
        'https://www.last.fm/API/auth/?api_key=$_key&token=$_token',
    'encoded slash':
        'https://www.last.fm/api%2Fauth/?api_key=$_key&token=$_token',
    'other path': 'https://www.last.fm/user/x?api_key=$_key&token=$_token',
    'backslash':
        'https://www.last.fm\\@evil.example/api/auth/?api_key=$_key&token=$_token',
    'backslash in path':
        'https://www.last.fm/api\\auth/?api_key=$_key&token=$_token',
    // query
    'no query': 'https://www.last.fm/api/auth/',
    'empty query': 'https://www.last.fm/api/auth/?',
    'token missing': 'https://www.last.fm/api/auth/?api_key=$_key',
    'api_key missing': 'https://www.last.fm/api/auth/?token=$_token',
    'extra cb parameter':
        'https://www.last.fm/api/auth/?api_key=$_key&token=$_token&cb=https://evil.example',
    'extra parameter':
        'https://www.last.fm/api/auth/?api_key=$_key&token=$_token&x=1',
    'duplicate token':
        'https://www.last.fm/api/auth/?api_key=$_key&token=$_token&token=other',
    'duplicate api_key':
        'https://www.last.fm/api/auth/?api_key=$_key&api_key=$_key&token=$_token',
    'empty token': 'https://www.last.fm/api/auth/?api_key=$_key&token=',
    'empty api_key': 'https://www.last.fm/api/auth/?api_key=&token=$_token',
    'token without value': 'https://www.last.fm/api/auth/?api_key=$_key&token',
    'uppercase parameter name':
        'https://www.last.fm/api/auth/?API_KEY=$_key&token=$_token',
    'empty pair':
        'https://www.last.fm/api/auth/?api_key=$_key&&token=$_token',
    // fragment
    'fragment': '$_ok#x',
    'empty fragment': '$_ok#',
    'fragment hiding the host': 'https://evil.example#https://www.last.fm/api/auth/',
    // whitespace and controls
    'leading space': ' $_ok',
    'trailing space': '$_ok ',
    'trailing newline': '$_ok\n',
    'tab inside': 'https://www.last.fm/api/auth/?api_key=$_key&\ttoken=$_token',
    'control character': 'https://www.last.fm/api/auth/?api_key=$_key&token=a\u0000b',
    'space in token': 'https://www.last.fm/api/auth/?api_key=$_key&token=a b',
    // garbage
    'empty': '',
    'not a URL': 'www.last.fm',
  };

  for (final entry in refused.entries) {
    test('refused: ${entry.key}', () {
      expect(LastfmAuthorizationUrl.tryParse(entry.value), isNull,
          reason: entry.key);
    });
  }

  test('refused: an absurdly long URL', () {
    final long =
        'https://www.last.fm/api/auth/?api_key=$_key&token=${'a' * 5000}';
    expect(LastfmAuthorizationUrl.tryParse(long), isNull);
  });

  test('the value never prints the URL, its key or its token', () {
    final url = LastfmAuthorizationUrl.tryParse(_ok)!;
    for (final text in [url.toString(), '$url', [url].toString()]) {
      expect(text.contains(_key), isFalse);
      expect(text.contains(_token), isFalse);
      expect(text.contains('last.fm'), isFalse);
    }
  });
}
