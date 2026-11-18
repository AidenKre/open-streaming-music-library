/// The platform's system browser (spec §7.12, plan O5: `url_launcher`
/// behind a platform adapter). This interface is the one seam tests fake,
/// so no test ever opens a browser. Model code: nothing from `ui/`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

/// Opens a link in the system browser.
abstract interface class ExternalBrowser {
  /// Opens [uri] outside the app; true when the platform says it opened.
  /// Never throws.
  Future<bool> open(Uri uri);
}

/// The signature of `url_launcher`'s `launchUrl` this adapter uses.
typedef LaunchUrl = Future<bool> Function(Uri uri, launcher.LaunchMode mode);

/// [ExternalBrowser] over `url_launcher`, always in the external
/// application (the system browser), never an in-app web view.
class UrlLauncherBrowser implements ExternalBrowser {
  UrlLauncherBrowser({LaunchUrl? launch}) : _launch = launch;

  final LaunchUrl? _launch;

  @override
  Future<bool> open(Uri uri) async {
    try {
      final launch = _launch;
      if (launch != null) {
        return await launch(uri, launcher.LaunchMode.externalApplication);
      }
      return await launcher.launchUrl(
        uri,
        mode: launcher.LaunchMode.externalApplication,
      );
    } on Object {
      return false;
    }
  }
}

final externalBrowserProvider = Provider<ExternalBrowser>(
  (ref) => UrlLauncherBrowser(),
);
