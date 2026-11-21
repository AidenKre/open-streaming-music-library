import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/token_permit.dart';
import 'package:frontend/models/instance_stamp.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:http/http.dart' as http;

/// The `Authorization` header for [token]: the only place it is formatted.
Map<String, String> bearerAuthHeader(String token) => {
  'Authorization': 'Bearer $token',
};

/// Adds `Authorization: Bearer <token>` to a request (spec §7.2, SC-27
/// invariant 14) only while the [TokenPermit] allows the token to go to that
/// URL (sign-off OPEN-M-11, 2026-11-17); otherwise the request is never
/// handed to the transport and [TokenWithheldException] is thrown. The
/// credentials are fixed at construction, so a request created in this scope
/// always carries this scope's token, even if it outlives a timed-out quiesce.
///
/// [onUnauthorized] is called synchronously on a 401, before the response is
/// returned, with the answer's `X-Server-Instance-Id` stamp (null without
/// one): who sent the 401. It is a no-op once [dispose]d, and it only sets in-memory state:
/// this class never touches stored credentials.
class AuthenticatedClient extends http.BaseClient {
  AuthenticatedClient(
    http.Client inner,
    Credentials credentials, {
    required TokenPermit permit,
    void Function(String? servedBy)? onUnauthorized,
  }) : _permit = permit,
       _inner = inner,
       _credentials = credentials,
       _onUnauthorized = onUnauthorized;

  final TokenPermit _permit;
  final http.Client _inner;
  final Credentials _credentials;
  final void Function(String? servedBy)? _onUnauthorized;
  bool _disposed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final own = bearerAuthHeader(_credentials.token);
    final existing = request.headers['Authorization'];
    if (existing != null && existing != own['Authorization']) {
      // The scope's token always wins (invariant 14): a caller that sets
      // another bearer (a revoke meant for the unhooked client) fails loudly.
      throw StateError(
        'A request carrying its own Authorization header was sent through '
        "an authenticated scope's client.",
      );
    }
    // Synchronous from the answer to the send: nothing can change between.
    var allowed = false;
    try {
      allowed = _permit.allowsTokenTo(request.url);
    } catch (_) {}
    if (!allowed) throw const TokenWithheldException();
    request.headers.addAll(own);
    final response = await _inner.send(request);
    if (response.statusCode == 401 && !_disposed) {
      _onUnauthorized?.call(instanceStampFrom(response.headers));
    }
    return response;
  }

  /// Completes once the permit has no verdict pending (bounded); never
  /// throws. Called once per [ApiClient] request, before its first attempt.
  Future<void> verdictSettled() async {
    try {
      await _permit.verdictSettled();
    } catch (_) {}
  }

  /// The log-out/Disconnect revoke exemption (sign-off OPEN-M-11): a one-shot
  /// client over the same transport and credentials that sends exactly one
  /// request, a `POST` to [logoutUrl]'s scheme, host, port and path (query
  /// ignored), with the scope's token, without consulting the permit. Every
  /// other request, and any after the first matching one, throws
  /// [TokenWithheldException] without touching the transport.
  http.Client revokeExemption(Uri logoutUrl) =>
      _RevokeExemptionClient(_inner, _credentials, logoutUrl);

  /// The same shared transport with no token and no 401 hook, for public
  /// paths that must not carry the token.
  http.Client withoutToken() => UnauthenticatedClient(_inner);

  /// Ends this scope: the 401 hook becomes a no-op. Requests still carry this
  /// client's own token.
  void dispose() => _disposed = true;

  /// Deliberately leaves the shared inner client open so old-scope requests
  /// can finish (spec §7.2).
  @override
  void close() {}
}

/// Thrown by [AuthenticatedClient] when the permit refuses the token for a
/// request: the server is not verified for this connection, or the app is
/// offline (sign-off OPEN-M-11). The request was not sent. [ApiClient]
/// neither retries it nor reports it as a lost connection.
class TokenWithheldException implements Exception {
  const TokenWithheldException();

  @override
  String toString() =>
      'TokenWithheldException: the server is not verified; the request was not sent';
}

class _RevokeExemptionClient extends http.BaseClient {
  _RevokeExemptionClient(this._inner, this._credentials, this._logoutUrl);

  final http.Client _inner;
  final Credentials _credentials;
  final Uri _logoutUrl;
  bool _used = false;

  bool _matches(http.BaseRequest r) =>
      r.method == 'POST' &&
      r.url.scheme.toLowerCase() == _logoutUrl.scheme.toLowerCase() &&
      r.url.host.toLowerCase() == _logoutUrl.host.toLowerCase() &&
      r.url.port == _logoutUrl.port &&
      r.url.path == _logoutUrl.path;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final own = bearerAuthHeader(_credentials.token);
    final existing = request.headers['Authorization'];
    if (existing != null && existing != own['Authorization']) {
      throw StateError(
        'A request carrying its own Authorization header was sent through '
        "an authenticated scope's client.",
      );
    }
    if (_used || !_matches(request)) throw const TokenWithheldException();
    _used = true;
    request.headers.addAll(own);
    return _inner.send(request);
  }

  @override
  void close() {}
}

/// For pre-session calls (health check, `/app/info`, gate probe, register,
/// login, cancel-time revoke): forwards requests unchanged and has no 401
/// hook (spec §7.2).
class UnauthenticatedClient extends http.BaseClient {
  UnauthenticatedClient(http.Client inner) : _inner = inner;

  final http.Client _inner;

  static ApiClient forUrl(String url, http.Client inner) =>
      ApiClient(url, UnauthenticatedClient(inner));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  /// Leaves the shared inner client open.
  @override
  void close() {}
}
