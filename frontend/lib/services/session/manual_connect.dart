part of '../session_service.dart';

/// The manual connect: which entered server address may be saved. No state
/// of its own.
class _ManualConnect {
  _ManualConnect(this._ref, this._resetCheck, this._signInFlow);

  final Ref _ref;
  final _PendingResetCheck _resetCheck;
  final _SignInFlow _signInFlow;

  /// The server-address screen's sentences when the address cannot be used
  /// (other-issues row 66: fixed sentences; the detail goes to the session
  /// log).
  static const _unreachable = 'Could not reach the server.';
  static const _identityUnreadable = "Could not read the server's identity.";

  void _log(String line) => _ref.read(sessionEventLogProvider)(line);

  /// Manual connect (spec 7.4, decision O1): an entered host is not trusted
  /// yet, so it is saved only after a passing health check and an identity
  /// probe through the unauthenticated client. The server must report
  /// `server.instance_id` and `auth.version == 1` (a pre-accounts server is
  /// rejected). The binding gate is not run and no row is created: a kept
  /// binding is compared by server instance only. A different instance than
  /// the bound one changes nothing: the user decides whether to reset
  /// ([ConnectDifferentServer]). Success saves the URL and routes to Log in
  /// ([ConnectSucceeded.url]); the session itself starts after login.
  Future<ConnectOutcome> connect(String url) async {
    // A held sign-in belongs to the old server choice: revoke and drop it.
    await _signInFlow.cancelPendingSignIn();
    // A reset the launch could not finish blocks every login until its
    // wipe succeeds: no server may adopt the old store (major 2).
    switch (await _resetCheck.completePendingReset()) {
      case _PendingResetFailed(:final message):
        return ConnectFailed(message);
      case _PendingResetUnknown():
        return const ConnectFailed(_PendingResetCheck.settingsUnreadable);
      case null:
      case _PendingResetDone():
        break;
    }
    final api = _ref.read(unauthenticatedApiClientProvider)(url);
    final result = await api.healthCheck(retry: false);
    if (result.status == HealthStatus.unreachable) {
      // The transport's own text (a socket error) goes to no screen.
      _log('Connect failed: reason=unreachable');
      return const ConnectFailed(_unreachable);
    }
    if (result.status != HealthStatus.ok) {
      // A server error's message is the app's fixed text with its status.
      return ConnectFailed(result.message ?? _unreachable);
    }
    final ServerIdentity identity;
    try {
      identity = await ServerIdentityApi(api: api).fetch(reportOffline: false);
    } catch (e) {
      _log('Connect failed: reason=identity_unreadable error=${e.runtimeType}');
      return const ConnectFailed(_identityUnreadable);
    }
    if (identity.instanceId == null) {
      return const ConnectFailed("The server did not report an identity.");
    }
    final authVersion = identity.authVersion;
    if (authVersion == null) {
      return const ConnectFailed(
        'This server is too old for this app: it does not support accounts. '
        'Update the server first.',
      );
    }
    if (authVersion != 1) {
      return ConnectFailed(
        'This server uses an unsupported sign-in version ($authVersion). '
        'Update the app.',
      );
    }
    final bound = (await _ref.read(serverBindingRepositoryProvider).current())
        ?.instanceId;
    // Exact on purpose (SC-01): this decides a reset, and both ids come from
    // the server's own answers. Only the header stamp is compared leniently.
    if (bound != null && bound != identity.instanceId) {
      return ConnectDifferentServer(url);
    }
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setString(SessionService.serverUrlKey, url);
    // A prior disconnect-while-offline can leave offline mode armed; clear
    // it so the app doesn't open behind the offline banner.
    _ref.read(offlineModeProvider.notifier).exitOffline();
    return ConnectSucceeded(url);
  }
}
