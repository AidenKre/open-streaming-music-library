import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/scope_token_route.dart';
import 'package:frontend/api/token_permit.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:http/http.dart' as http;

/// The signed-in session's credentials, null when signed out. FrontendApp
/// overrides it when it builds the keyed scope; immutable for the scope's
/// life (spec 7.2).
final credentialsProvider = Provider<Credentials?>((ref) => null);

/// True when the stored credentials could not be read (M.3b
/// `CredentialsUnavailableException`): unknown, not absent. FrontendApp
/// overrides it; [credentialsProvider] is then null.
final credentialsUnavailableProvider = Provider<bool>((ref) => false);

/// The seam the 401 hook calls (spec 7.2). M.3d implements it to set the
/// signed-out reason. It must only set in-memory state and never delete
/// stored credentials.
final onUnauthorizedProvider = Provider<void Function()>((ref) => () {});

/// The scope's API client (SC-27 invariant 14, spec 7.2).
///
/// Created inside the keyed provider scope from the session URL
/// ([sessionUrlProvider]) over the shared transport ([httpClientProvider]);
/// immutable for the scope's life. With credentials it carries that scope's
/// token on every request and reports a 401 through [onUnauthorizedProvider]
/// (a no-op once the scope is disposed); without, it is unauthenticated. The
/// token goes only while the binding gate says this connection is verified
/// and the app is online; otherwise the request is withheld (sign-off
/// OPEN-M-11, 2026-11-17).
/// Disposing it drops its network-failure listeners but never closes the
/// shared transport.
final Provider<ApiClient> apiClientProvider = Provider<ApiClient>((ref) {
  final inner = ref.watch(httpClientProvider);
  final credentials = ref.watch(credentialsProvider);
  final http.Client transport;
  if (credentials == null) {
    transport = UnauthenticatedClient(inner);
  } else {
    final auth = AuthenticatedClient(
      inner,
      credentials,
      permit: _ScopeTokenPermit(ref),
      onUnauthorized: () => ref.read(onUnauthorizedProvider)(),
    );
    final route = ref.read(scopeTokenRouteProvider);
    route.attach(auth);
    ref.onDispose(() {
      route.detach(auth);
      auth.dispose();
    });
    transport = auth;
  }
  final client = ApiClient(ref.watch(sessionUrlProvider) ?? '', transport);
  ref.onDispose(client.dispose);
  return client;
});

/// Asks the scope's binding gate at call time (it is read lazily, so the
/// client and the gate may be built in any order).
class _ScopeTokenPermit implements TokenPermit {
  _ScopeTokenPermit(this._ref);
  final Ref _ref;

  @override
  bool allowsTokenTo(Uri url) {
    try {
      return _ref.read(serverBindingGateProvider).allowsTokenTo(url);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> verdictSettled() async {
    try {
      await _ref.read(serverBindingGateProvider).verdictSettled();
    } catch (_) {}
  }
}

/// A token-free client for the session's URL: the public paths (`GET /`,
/// `/app/info`) must never carry a token before the scope's verification of
/// the server stands. Same lifetime and transport rules as [apiClientProvider],
/// no 401 hook; its network failures reach [apiClientProvider]'s listeners.
final Provider<ApiClient> publicApiClientProvider = Provider<ApiClient>(
  (ref) => ref.watch(apiClientProvider).withoutToken(),
);

/// Has stored credentials and a session URL (spec `hasCredentials`).
/// Credentials without a URL are no session: runners would send requests to
/// '' and flip the app offline.
final hasSessionProvider = Provider<bool>(
  (ref) =>
      ref.watch(credentialsProvider) != null &&
      (ref.watch(sessionUrlProvider)?.isNotEmpty ?? false),
);

/// The session's server URL, loaded by `FrontendApp` before the scope is
/// built; null means no session.
final sessionUrlProvider = Provider<String?>((ref) => null);

/// The process-lifetime transport shared by every scope's clients.
/// FrontendApp overrides it with one client for the app's lifetime, so a
/// scope's disposal never closes it.
final httpClientProvider = Provider<http.Client>((ref) {
  final c = http.Client();
  ref.onDispose(c.close);
  return c;
});

/// An unhooked client (no 401 hook, no network-failure listeners) for a URL
/// that is not the session's yet: connect's health check, the gate probe of
/// another URL, register/login and the cancel-time revoke.
final unauthenticatedApiClientProvider =
    Provider<ApiClient Function(String url)>(
      (ref) =>
          (url) => UnauthenticatedClient.forUrl(url, ref.read(httpClientProvider)),
    );
