part of '../session_service.dart';

enum _StoredSignIn { usable, noBinding, otherUser }

/// The saved-session launch: what the app does at start with the saved
/// server address and the stored sign-in. It asks the pending-reset question
/// first, uses stored credentials only with a binding row of the same user,
/// and hands a live session to [_ServerBlockWatch]. No state of its own.
class _SessionLaunch {
  _SessionLaunch(this._ref, this._resetCheck, this._signInFlow, this._block);

  final Ref _ref;
  final _PendingResetCheck _resetCheck;
  final _SignInFlow _signInFlow;
  final _ServerBlockWatch _block;

  /// The stored sign-in survives until the next successful save or delete,
  /// so the next launch may resume it (m-R2-10): say so, promise nothing.
  static const _signInNotRemovedNotice =
      'You are logged out, but your sign-in could not be removed from this '
      "device's storage. The next time the app starts, it may find it and "
      'sign you in again; if it does, log out again.';

  /// True when a logout could not clear the stored sign-in. An unset store
  /// override must not break launch, so a throw reads as false.
  bool _signInClearFailed() {
    try {
      return _ref.read(credentialStoreProvider).clearFailed;
    } catch (_) {
      return false;
    }
  }

  /// One notice for every stored sign-in dropped at launch, wherever the app
  /// lands (sign-off DEV-M-13, 2026-11-17); the reason goes to the log.
  static const _loggedOutNotice = 'You have been logged out.';

  void _logSignInDropped(String reason) =>
      _ref.read(sessionEventLogProvider)(
        'Stored sign-in dropped at launch: reason=$reason',
      );

  /// Whether stored credentials may be used at launch (m-R1-18, m-R1-36):
  /// only with a binding row whose user is theirs. Never attach credentials
  /// to requests for a binding they don't match. Launch creates no row (login
  /// does, spec 7.4), and a row of another user is kept as is. (A row
  /// without a user is never written: its one writer, the sign-in, stores
  /// the user's id; it would count as another user's.)
  Future<_StoredSignIn> _storedSignInVerdict(Credentials credentials) async {
    final row = await _ref.read(serverBindingRepositoryProvider).current();
    if (row == null) return _StoredSignIn.noBinding;
    if (row.userId != credentials.userId) return _StoredSignIn.otherUser;
    return _StoredSignIn.usable;
  }

  /// Best-effort delete of the stored sign-in; a failure is logged by type.
  Future<void> _deleteStoredSignIn() async {
    try {
      await _ref.read(credentialStoreProvider).delete();
    } catch (e) {
      developer.log(
        'Could not delete the stored sign-in: ${e.runtimeType}',
        name: 'SessionService',
      );
    }
  }

  Future<SessionStart> _dropStoredSignIn(String url, String reason) async {
    _logSignInDropped(reason);
    await _deleteStoredSignIn();
    return SessionStart(
      SessionStartKind.logIn,
      serverUrl: url,
      error: _loggedOutNotice,
    );
  }

  /// Launch reading of a health result: a 5xx or 429 answer counts as
  /// unreachable (sign-off OPEN-A-04, 2026-11-17), and so does a 2xx answer
  /// whose body is not JSON (a Wi-Fi sign-in page or another web page in
  /// front of the server; pre-merge review A5-02, owner 2026-11-18) or is
  /// empty; 4xx and non-OSML JSON answers stay `serverError`
  /// (forget the URL and the sign-in).
  HealthStatus _launchHealth(HealthResult result) {
    final code = result.statusCode;
    if (result.status == HealthStatus.serverError &&
        (result.bodyNotJson ||
            (code != null && (code == 429 || code >= 500)))) {
      return HealthStatus.unreachable;
    }
    return result.status;
  }

  /// Launch: resume the saved server, if any. A single health probe (a
  /// hanging saved URL must not hold the splash for the retry budget):
  /// healthy -> online; unreachable -> offline session (the URL is still
  /// presumed valid, downloads stay usable); an HTTP 5xx or 429 answer, or a
  /// 2xx answer that is not JSON or is empty (a bare `{}` included), counts
  /// as unreachable here ([_launchHealth]); a 4xx or another non-OSML JSON
  /// answer forgets the URL and the sign-in and returns to the server-address
  /// screen with the error (the binding row is kept, so the next connection is
  /// verified against it, SC-01 rule 3).
  ///
  /// A session URL always has a binding row (provisional until verified).
  /// Online, the connection is verified through the binding gate and the
  /// session becomes ready on its verdict; a different server leaves the app
  /// blocked: offline, with no health polling to flip it back.
  Future<SessionStart> resumeSavedSession() async {
    // A reset that never finished its wipe is finished first, before the
    // saved URL creates a binding row on top of the old store (major 2).
    final pending = await _resetCheck.completePendingReset();
    switch (pending) {
      case null:
        break;
      case _PendingResetDone():
        return const SessionStart(SessionStartKind.resetFinished);
      case _PendingResetFailed(:final message):
        return SessionStart(SessionStartKind.serverAddress, error: message);
      case _PendingResetUnknown():
        throw _PendingResetUnreadable();
    }
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final url = prefs.getString(SessionService.serverUrlKey);
    if (url == null) {
      // Stored credentials without a saved server are never usable.
      if (_ref.read(credentialsProvider) == null) {
        return const SessionStart(SessionStartKind.serverAddress);
      }
      _logSignInDropped('no_saved_address');
      await _deleteStoredSignIn();
      return const SessionStart(
        SessionStartKind.serverAddress,
        error: _loggedOutNotice,
      );
    }
    // Credentials decide the route before anything is sent or created
    // (spec 7.1/7.4): unreadable is unknown, never Log in; absent is Log in.
    if (_ref.read(credentialsUnavailableProvider)) {
      return SessionStart(SessionStartKind.credentialsUnavailable,
          serverUrl: url);
    }
    final credentials = _ref.read(credentialsProvider);
    if (credentials == null) {
      return SessionStart(
        SessionStartKind.logIn,
        serverUrl: url,
        error: _signInClearFailed() ? _signInNotRemovedNotice : null,
      );
    }
    switch (await _storedSignInVerdict(credentials)) {
      case _StoredSignIn.usable:
        await _signInFlow.takeOverKeptRecords(); // a login closed before its take-over
      case _StoredSignIn.noBinding:
        return _dropStoredSignIn(url, 'no_binding');
      case _StoredSignIn.otherUser:
        return _dropStoredSignIn(url, 'binding_other_user');
    }
    final result = await _ref.read(publicApiClientProvider).healthCheck(retry: false);
    switch (_launchHealth(result)) {
      case HealthStatus.ok:
        _block.watchServerBlock();
        unawaited(_block.verifyThenMarkReady(url));
        return const SessionStart(SessionStartKind.online);
      case HealthStatus.unreachable:
        _block.watchServerBlock();
        _ref.read(offlineModeProvider.notifier).enterOffline();
        _block.markReady();
        return const SessionStart(SessionStartKind.offline);
      case HealthStatus.serverError:
        // The scope still holds the sign-in deleted below: close its gate as
        // log-out does, so no later edge (an app resume) verifies the
        // forgotten address and sends with it (pre-merge review A5-01).
        _ref.read(localResetServiceProvider).closeGateForGood();
        await prefs.remove(SessionService.serverUrlKey);
        await _deleteStoredSignIn();
        return SessionStart(SessionStartKind.serverAddress, error: result.message);
    }
  }
}
