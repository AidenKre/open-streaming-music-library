/// The Last.fm authorization URL `connect` returned, accepted only in the
/// shape spec §7.4 "Approve" allows: scheme `https`, host exactly
/// `www.last.fm`, no user-info or port, path exactly `/api/auth/`, only
/// `api_key` and `token` in the query, and no fragment.
///
/// The value carries a request token: it must never be logged or stored.
/// `toString()` is redacted.
class LastfmAuthorizationUrl {
  LastfmAuthorizationUrl._(this.uri);

  final Uri uri;

  static const _prefix = 'https://www.last.fm/api/auth/?';

  static LastfmAuthorizationUrl? tryParse(String raw) {
    if (raw.length > 2048 || !raw.startsWith(_prefix)) return null;
    for (final unit in raw.codeUnits) {
      if (unit <= 0x20 || unit == 0x7F || unit == 0x5C || unit == 0x23) {
        return null;
      }
    }
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'www.last.fm' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.path != '/api/auth/' ||
        uri.hasFragment) {
      return null;
    }
    final seen = <String>{};
    for (final pair in raw.substring(_prefix.length).split('&')) {
      final eq = pair.indexOf('=');
      if (eq < 0) return null;
      final name = pair.substring(0, eq);
      if (name != 'api_key' && name != 'token') return null;
      if (!seen.add(name)) return null;
      final String value;
      try {
        value = Uri.decodeQueryComponent(pair.substring(eq + 1));
      } on Object {
        return null;
      }
      if (value.isEmpty) return null;
    }
    if (seen.length != 2) return null;
    return LastfmAuthorizationUrl._(uri);
  }

  @override
  String toString() => 'LastfmAuthorizationUrl(<redacted>)';
}
