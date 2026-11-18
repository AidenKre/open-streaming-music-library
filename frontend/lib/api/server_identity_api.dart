import 'package:frontend/api/api_client.dart';

/// The server's identity as read DIRECTLY from `/app/info` (SC-01).
///
/// Phase M (decision O3) adds [authVersion] so connect can reject a pre-M
/// server. It is read here, straight from the response, because the
/// pre-session probe bypasses `appInfoProvider`'s cache; the typed SC-03
/// feature-block parser (`FeatureBlocks`) covers the other blocks, not
/// `auth`/`server`.
class ServerIdentity {
  const ServerIdentity(this.instanceId, {this.authVersion});

  /// `auth.version`; null when the server has no `auth` block (unknown,
  /// never 0).
  final int? authVersion;

  /// Null: a legacy server without the `server` block.
  final String? instanceId;
}

/// Reads the server's identity straight from `/app/info`, one attempt, for
/// binding verification (SC-01 rule 1). Unlike `AppInfoService.load()` it
/// never reads or writes the prefs-cached blob (which is not per-server):
/// HTTP and network errors propagate so the caller stays unverified.
class ServerIdentityApi {
  ServerIdentityApi({required ApiClient api}) : _api = api;

  final ApiClient _api;

  /// [reportOffline] false: a transport failure does not fire the offline
  /// hook (a login attempt).
  Future<ServerIdentity> fetch({bool reportOffline = true}) async {
    final data = await _api.getJson(
      ['app', 'info'],
      policy: RetryPolicy.noRetry,
      triggerOfflineHook: reportOffline,
    );
    final server = data['server'];
    if (server == null) return const ServerIdentity(null);
    final instanceId = server is Map ? server['instance_id'] : null;
    if (instanceId is! String) {
      throw FormatException(
        '/app/info server.instance_id is not a string: $server',
      );
    }
    final auth = data['auth'];
    int? authVersion;
    if (auth != null) {
      final version = auth is Map ? auth['version'] : null;
      if (version is! int) {
        throw const FormatException('/app/info auth.version is not an integer');
      }
      authVersion = version;
    }
    return ServerIdentity(instanceId, authVersion: authVersion);
  }
}
