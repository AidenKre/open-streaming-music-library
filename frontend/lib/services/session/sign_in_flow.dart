part of '../session_service.dart';

/// Signing in, and the one sign-in that may be held in memory while the user
/// decides about a reset. This class is the only owner of the held sign-in:
/// the resets take it through [takeHeld], and nothing else reads or clears
/// it.
class _SignInFlow {
  _SignInFlow(this._ref, this._resetCheck);

  final Ref _ref;
  final _PendingResetCheck _resetCheck;

  /// Log in to the saved server (spec 7.5). See [_signIn].
  Future<SignInOutcome> login(String username, String password) =>
      _signIn((api) => api.login(username, password));

  /// Create an account on the saved server and sign in (spec 7.5).
  Future<SignInOutcome> register(String username, String password) =>
      _signIn((api) => api.register(username, password));

  /// The sign-in awaiting the user's confirmed reset (a user switch or a
  /// different server). Memory only: never persisted until the reset
  /// succeeds.
  _HeldSignIn? _pendingSignIn;

  /// The URL the held sign-in was made on; null when nothing is held.
  String? get heldUrl => _pendingSignIn?.url;

  /// Hands the held sign-in over and forgets it, in one step. Null when
  /// nothing is held.
  _HeldSignIn? takeHeld() {
    final held = _pendingSignIn;
    _pendingSignIn = null;
    return held;
  }

  /// The scope is being disposed: a held sign-in is never dropped unrevoked.
  /// Reads no `ref`: the held sign-in carries the client it needs.
  void revokeHeldAtDispose() {
    final held = takeHeld();
    if (held != null) unawaited(revokeSignIn(held));
  }

  /// The shared login/register flow, in the spec 7.5 order: the saved URL,
  /// any pending reset finished first, authentication through the unhooked
  /// client, then the (instance, user) pair compared with the binding row
  /// BEFORE the credentials are stored or any scope uses them.
  ///
  /// - no row, or the same pair: store, bind with both IDs, rebuild;
  /// - same instance (or an unknown one on the row's own URL), another (or
  ///   unknown) user: held, [SignInNeedsUserSwitch];
  /// - a different instance, or an unknown one on another URL: held,
  ///   [SignInDifferentServer].
  Future<SignInOutcome> _signIn(
    Future<AuthSession> Function(AuthApi api) authenticate,
  ) async {
    // A sign-in still held from an earlier attempt is revoked and dropped.
    await cancelPendingSignIn();
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final url = prefs.getString(SessionService.serverUrlKey);
    if (url == null) {
      return const SignInFailed('No server is set. Enter the server address.');
    }
    switch (await _resetCheck.completePendingReset()) {
      case _PendingResetFailed(:final message):
        return SignInFailed(message);
      case _PendingResetUnknown():
        return const SignInFailed(_PendingResetCheck.settingsUnreadable);
      case null:
      case _PendingResetDone():
        break;
    }
    final AuthSession session;
    final authApi = AuthApi(_ref.read(unauthenticatedApiClientProvider)(url));
    try {
      session = await authenticate(authApi);
    } on ApiException catch (e) {
      return SignInFailed(e.detailMessage ?? 'Could not sign in.');
    } on FormatException {
      return const SignInFailed('The server sent an unexpected answer.');
    } catch (_) {
      return const SignInFailed('Could not reach the server.');
    }
    final held = _HeldSignIn(session, url, authApi);
    final ServerBindingRecord? row;
    try {
      row = await _ref.read(serverBindingRepositoryProvider).current();
    } catch (e) {
      // The server issued a session this device cannot use: revoke it, so it
      // does not stay valid unused; nothing was stored (pre-merge review
      // A5-03). Revoked first: the revoke reads no `ref`.
      await revokeSignIn(held);
      developer.log(
        'Sign-in not finished: the binding row could not be read '
        '(${e.runtimeType})',
        name: 'SessionService',
      );
      _logDatabaseRefusal(_ref, e);
      // A database of another version is its own screen (D3-01).
      if (isDatabaseRefusal(e)) rethrow;
      return const SignInFailed(SignInNotSavedFailure.message);
    }
    // A NULL row instance is unknown: only a login on the URL the row was
    // created for may count as the same server (and fill it in). On another
    // URL it could be any server, so the different-server sheet (m-R2-08).
    // Exact on purpose (SC-01): this decides a reset, and both ids come from
    // the server's own answers. Only the header stamp is compared leniently.
    final instanceCompatible = row?.instanceId == null
        ? row?.lastBaseUrl == url
        : row!.instanceId == session.serverInstanceId;
    if (row == null ||
        (instanceCompatible &&
            row.userId != null &&
            row.userId == session.user.id)) {
      try {
        await persistSignIn(held);
      } catch (_) {
        await revokeSignIn(held);
        return const SignInFailed(SignInNotSavedFailure.message);
      }
      // The same (instance, user) pair as the binding row: records kept by a
      // log-out that kept unsent work continue under this sign-in.
      if (row != null) await takeOverKeptRecords();
      await _ref.read(onSessionChangedProvider)?.call();
      return const SignInSucceeded();
    }
    await cancelPendingSignIn();
    _pendingSignIn = held;
    if (instanceCompatible) {
      return SignInNeedsUserSwitch(session.user.username);
    }
    return SignInDifferentServer(url);
  }

  /// The same-user take-over of kept upload and deletion records, best
  /// effort (idempotent).
  Future<void> takeOverKeptRecords() async {
    try {
      final row = await _ref.read(serverBindingRepositoryProvider).current();
      if (row != null) {
        await _ref.read(deadSignInRecordsProvider).takeOver(row.localBindingId);
      }
    } catch (e) {
      developer.log(
        'kept records not taken over: ${e.runtimeType}',
        name: 'SessionService',
      );
    }
  }

  /// Stores the credentials, the URL (idempotent; a reset may have wiped
  /// it) and the binding row with both IDs.
  /// Credentials go first; if a later step fails they are deleted (best
  /// effort) so a half-persisted sign-in never stays, and the error rethrows.
  Future<void> persistSignIn(_HeldSignIn h) async {
    final store = _ref.read(credentialStoreProvider);
    await store.save(h.session.credentials);
    try {
      final prefs = await _ref.read(sharedPreferencesProvider.future);
      final repo = _ref.read(serverBindingRepositoryProvider);
      final row = await repo.ensureProvisional(
        h.url,
        userId: h.session.user.id,
        instanceId: h.session.serverInstanceId,
      );
      // An existing row is returned unchanged: fill an unknown instance in.
      if (row.instanceId == null) {
        await repo.recordVerified(
          row.localBindingId,
          instanceId: h.session.serverInstanceId,
          baseUrl: h.url,
        );
      }
      await prefs.setString(SessionService.serverUrlKey, h.url);
    } catch (_) {
      try {
        await store.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// The one revoke path, also used at dispose (so it never reads `_ref`):
  /// best effort, at most once per held sign-in. A 401 means already revoked,
  /// an outage is not retried.
  Future<void> revokeSignIn(_HeldSignIn h) async {
    if (h.revoked) return;
    h.revoked = true;
    try {
      await h.api.logout(bearerToken: h.session.credentials.token);
    } catch (_) {}
  }

  /// The user cancelled the sheet: revoke the held session (best effort),
  /// discard it, and change nothing else. A no-op when nothing is held.
  Future<void> cancelPendingSignIn() async {
    final held = _pendingSignIn;
    if (held == null) return;
    _pendingSignIn = null;
    await revokeSignIn(held);
  }
}

/// A sign-in awaiting a confirmed reset.
class _HeldSignIn {
  _HeldSignIn(this.session, this.url, this.api);
  final AuthSession session;
  final String url;

  /// The unauthenticated client the sign-in came through, kept for the revoke.
  final AuthApi api;
  bool revoked = false;
}
