import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/services/credential_store.dart';

/// The signed-in account as the server describes it (spec 5.2).
class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.isAdmin,
    required this.isMasterAdmin,
  });

  final int id;
  final String username;
  final bool isAdmin;
  final bool isMasterAdmin;

  static AuthUser _parse(Object? json) {
    if (json is! Map) throw const FormatException('auth user is not an object');
    final id = json['id'];
    final username = json['username'];
    final isAdmin = json['is_admin'];
    final isMasterAdmin = json['is_master_admin'];
    if (id is! int ||
        username is! String ||
        isAdmin is! bool ||
        isMasterAdmin is! bool) {
      throw const FormatException('auth user has a missing or mistyped field');
    }
    return AuthUser(
      id: id,
      username: username,
      isAdmin: isAdmin,
      isMasterAdmin: isMasterAdmin,
    );
  }
}

/// A fresh sign-in: the credentials to store plus who and where.
class AuthSession {
  const AuthSession({
    required this.credentials,
    required this.serverInstanceId,
    required this.user,
  });

  final Credentials credentials;
  final String serverInstanceId;
  final AuthUser user;

  @override
  String toString() => 'AuthSession(user: ${user.username})';
}

class AuthMe {
  const AuthMe({required this.user, required this.serverInstanceId});

  final AuthUser user;
  final String serverInstanceId;
}

/// Revokes the scope client's own session, best effort: a 401 (already
/// revoked) or any network error is swallowed.
Future<void> revokeBestEffort(ApiClient api) async {
  try {
    await AuthApi(api).logout();
  } catch (_) {}
}

/// Register, login, logout and me (spec 5.2).
///
/// Callers choose the [ApiClient]: register/login and the cancel-time revoke
/// use the unhooked client (spec 7.2). Every call is a single attempt, and
/// server errors stay [ApiException]s (SC-22 envelope). Nothing here logs or
/// echoes a password or token.
class AuthApi {
  AuthApi(ApiClient api) : _api = api;

  final ApiClient _api;

  Future<AuthSession> login(String username, String password) =>
      _signIn('login', username, password);

  Future<AuthSession> register(String username, String password) =>
      _signIn('register', username, password);

  Future<AuthSession> _signIn(
    String action,
    String username,
    String password,
  ) async {
    final data = await _api.postJson(
      ['auth', action],
      body: {'username': username, 'password': password},
      policy: RetryPolicy.noRetry,
    );
    final token = data['token'];
    final mediaToken = data['media_token'];
    final instanceId = data['server_instance_id'];
    if (token is! String ||
        token.isEmpty ||
        mediaToken is! String ||
        mediaToken.isEmpty ||
        instanceId is! String) {
      throw const FormatException(
        'auth response has a missing or mistyped field',
      );
    }
    final user = AuthUser._parse(data['user']);
    return AuthSession(
      credentials: Credentials(
        token: token,
        mediaToken: mediaToken,
        userId: user.id,
        username: user.username,
      ),
      serverInstanceId: instanceId,
      user: user,
    );
  }

  /// Revokes the calling session (idempotent). [bearerToken] overrides the
  /// client's own header, for the cancel-time revoke. Use it only with the
  /// unhooked client: an authenticated client refuses a request that carries
  /// a different bearer.
  Future<void> logout({String? bearerToken}) async {
    await _api.postJson(
      ['auth', 'logout'],
      headers: bearerToken == null
          ? null
          : bearerAuthHeader(bearerToken),
      policy: RetryPolicy.noRetry,
    );
  }

  Future<AuthMe> me() async {
    final data = await _api.getJson([
      'auth',
      'me',
    ], policy: RetryPolicy.noRetry);
    final instanceId = data['server_instance_id'];
    if (instanceId is! String) {
      throw const FormatException('auth/me has a missing or mistyped field');
    }
    return AuthMe(
      user: AuthUser._parse(data['user']),
      serverInstanceId: instanceId,
    );
  }
}
