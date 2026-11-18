// The Last.fm links the app opens (spec §7.4 "Approve", §7.5 point 2,
// §7.12 "Credit and links"). This is the only path by which a URL reaches
// the system browser: the fixed credit, terms and privacy links, the
// profile link built here with the name percent-encoded, and the
// authorization URL only as a value 9D.2d's validator accepted. No ui/
// import; logs nothing.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/models/lastfm_authorization_url.dart';
import 'package:frontend/services/external_browser.dart';

/// "Scrobbling powered by Last.fm" links here (§7.12).
final Uri lastfmCreditUri = Uri.parse('https://www.last.fm/');

/// Last.fm's terms of use (§7.5 point 2).
final Uri lastfmTermsUri = Uri.parse('https://www.last.fm/legal/terms');

/// Last.fm's privacy policy (§7.5 point 2).
final Uri lastfmPrivacyUri = Uri.parse('https://www.last.fm/legal/privacy');

/// `https://www.last.fm/user/<name>` with the name percent-encoded; null
/// when the name is not a plausible account name, or is `.` or `..`.
Uri? lastfmProfileUri(String accountName) {
  if (plausibleLastfmAccountName(accountName) == null ||
      accountName == '.' ||
      accountName == '..') {
    return null;
  }
  return Uri.parse('https://www.last.fm/user/${Uri.encodeComponent(accountName)}');
}

class LastfmLinks {
  LastfmLinks(this._browser);

  final ExternalBrowser _browser;

  Future<bool> _open(Uri uri) async {
    try {
      return await _browser.open(uri);
    } on Object {
      return false;
    }
  }

  Future<bool> openCredit() => _open(lastfmCreditUri);

  Future<bool> openTerms() => _open(lastfmTermsUri);

  Future<bool> openPrivacy() => _open(lastfmPrivacyUri);

  /// False, opening nothing, when [accountName] gives no profile link.
  Future<bool> openProfile(String accountName) async {
    final uri = lastfmProfileUri(accountName);
    return uri == null ? false : _open(uri);
  }

  Future<bool> openAuthorization(LastfmAuthorizationUrl url) => _open(url.uri);
}

final lastfmLinksProvider = Provider<LastfmLinks>(
  (ref) => LastfmLinks(ref.watch(externalBrowserProvider)),
);
