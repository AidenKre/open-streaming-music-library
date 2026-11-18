import 'package:frontend/services/quality_presets.dart';

/// Build the streaming URL for a track under [baseUrl]. When [quality] is
/// `null` or `original`, no `quality` query parameter is sent — the server
/// returns the untouched source file. Any other preset triggers server-side
/// transcoding. A non-null [mediaToken] is added as `access_token` (spec 7.3):
/// only the queue player passes one, because just_audio can't send headers
/// on every platform; the track downloader builds the URL without it. (The
/// upload preview has its own builder, [buildStagedPreviewUri].)
Uri buildTrackStreamUri(String baseUrl, String uuidId,
    {String? quality, String? mediaToken}) {
  final baseUri = Uri.parse(baseUrl);
  final basePath = baseUri.pathSegments.where((segment) => segment.isNotEmpty);
  final query = <String, String>{
    if (quality != null && quality != originalQuality) 'quality': quality,
    'access_token': ?mediaToken,
  };
  return baseUri.replace(
    pathSegments: [...basePath, 'tracks', uuidId, 'stream'],
    queryParameters: query.isEmpty ? null : query,
  );
}

/// Replaces every `access_token=<value>` in [text] with
/// `access_token=<redacted>`, so a player error that quotes a stream URL can
/// be logged or shown (spec 7.2, SC-27 Phase M). Case-insensitive, and also
/// covers the percent-encoded forms `access_token%3D` and `access_token%253D`
/// (a URL quoted inside another URL). The value ends at `&` (or `%26`),
/// whitespace, `#`, `)` or a quote.
String redactAccessToken(String text) => text.replaceAllMapped(
  RegExp(
    'access_token(=|%3D|%253D)(?:(?!%26|%2526)[^&\\s#)\'"])*',
    caseSensitive: false,
  ),
  (m) => 'access_token${m[1]}<redacted>',
);

/// The one "never log the media token" rule: [redactAccessToken], then the
/// literal [token] wherever else it appears (a plugin may quote it outside
/// a URL). A null or empty [token] only redacts the query parameter.
String redactMediaToken(String text, String? token) {
  final redacted = redactAccessToken(text);
  return token == null || token.isEmpty
      ? redacted
      : redacted.replaceAll(token, '<redacted>');
}

/// The staged upload preview URL of item [itemUuid] under [baseUrl], with
/// the media token as `access_token` (a media-token route, Phase M §5.3).
Uri buildStagedPreviewUri(String baseUrl, String itemUuid,
        {String? mediaToken}) {
  final baseUri = Uri.parse(baseUrl);
  final basePath = baseUri.pathSegments.where((segment) => segment.isNotEmpty);
  return baseUri.replace(
    pathSegments: [...basePath, 'tracks', 'uploads', 'items', itemUuid, 'preview'],
    queryParameters: mediaToken == null ? null : {'access_token': mediaToken},
  );
}
