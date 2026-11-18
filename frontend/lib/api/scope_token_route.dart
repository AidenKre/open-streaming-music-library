import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:http/http.dart' as http;

/// A process-wide route to the live scope's token client (review F2, sign-off
/// OPEN-M-11). The cover-art disk cache queues downloads process-wide and
/// sends them later, so the token decision must be made at the real send: its
/// HTTP goes through [client], which hands every request to the currently
/// attached [AuthenticatedClient] (it asks the permit at that moment). With no
/// scope attached, a request is withheld.
class ScopeTokenRoute {
  AuthenticatedClient? _current;
  late final http.Client _client = _RouteClient(this);

  /// Makes [c] the live scope's token client.
  void attach(AuthenticatedClient c) => _current = c;

  /// Clears the route, only if [c] is still the attached client.
  void detach(AuthenticatedClient c) {
    if (identical(_current, c)) _current = null;
  }

  /// One client per route; it sends through the attached token client.
  http.Client get client => _client;
}

class _RouteClient extends http.BaseClient {
  _RouteClient(this._route);
  final ScopeTokenRoute _route;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final current = _route._current;
    if (current == null) throw const TokenWithheldException();
    return current.send(request);
  }

  @override
  void close() {}
}

/// The route for this container. The app overrides it with the process-wide
/// one that the cover-art disk cache uses.
final scopeTokenRouteProvider = Provider<ScopeTokenRoute>(
  (ref) => ScopeTokenRoute(),
);
