import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/auth_api.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/server_blocked_reason.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/dead_sign_in_records.dart';
import 'package:frontend/services/logout_losses.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_event_log.dart';
import 'package:frontend/services/session_readiness.dart';

export 'package:frontend/models/server_blocked_reason.dart';

enum SessionStartKind {
  serverAddress,

  /// A saved URL and no stored credentials (spec 7.1): the Log in screen,
  /// also offline. Nothing is sent.
  logIn,

  /// The stored credentials could not be read (unknown, not absent): a retry
  /// state, never Log in.
  credentialsUnavailable,
  online,
  offline,

  /// Launch finished a reset that had been interrupted (review major 2):
  /// local data is wiped and nothing is signed in. Like any finished reset,
  /// the provider scope is rebuilt next.
  resetFinished,
}

/// How a launch with (or without) a saved server URL starts.
class SessionStart {
  const SessionStart(this.kind, {this.error, this.serverUrl});
  final SessionStartKind kind;

  /// The saved server URL, for the Log in screen.
  final String? serverUrl;

  /// Shown on the login screen when the saved server rejected us.
  final String? error;
}

/// The result of a manual connect (login).
sealed class ConnectOutcome {
  const ConnectOutcome();
}

/// The URL passed the health and identity checks and is saved; the app goes
/// to Log in.
final class ConnectSucceeded extends ConnectOutcome {
  const ConnectSucceeded([this.url]);

  /// The saved server URL (shown on Log in).
  final String? url;
}

/// Not connected; [message] is shown on the login screen.
final class ConnectFailed extends ConnectOutcome {
  const ConnectFailed(this.message);
  final String message;
}

/// The server at [url] is a different instance from the one this library is
/// bound to (SC-01 rule 1): connecting needs a confirmed local reset first
/// ([SessionService.resetForNewServer]). Nothing was saved or changed.
final class ConnectDifferentServer extends ConnectOutcome {
  const ConnectDifferentServer(this.url);
  final String url;
}

/// The result of a login or registration (spec 7.5).
sealed class SignInOutcome {
  const SignInOutcome();
}

/// Stored, bound, and the scope rebuilt for the signed-in user.
final class SignInSucceeded extends SignInOutcome {
  const SignInSucceeded();
}

/// Nothing stored; [message] is shown (the server's SC-22 message when it
/// sent one).
final class SignInFailed extends SignInOutcome {
  const SignInFailed(this.message);
  final String message;
}

/// Same server, another user than the one this device's data belongs to:
/// the sign-in is held in memory until the user confirms the reset.
final class SignInNeedsUserSwitch extends SignInOutcome {
  const SignInNeedsUserSwitch(this.username);
  final String username;
}

/// The server at [url] is a different instance than the bound one: the
/// sign-in is held in memory until the different-server reset is confirmed.
final class SignInDifferentServer extends SignInOutcome {
  const SignInDifferentServer(this.url);
  final String url;
}

/// The session rules (SC-26 model; formerly inside StartupGate): which
/// server we use, what a health result means, and the local reset.
enum _StoredSignIn { usable, noBinding, otherUser, noUser }

class SessionService {
  SessionService(this._ref) {
    _ref.onDispose(() {
      _disposed = true;
      // A scope rebuild never drops a held sign-in unrevoked. No `ref` here:
      // the held sign-in carries the client it needs.
      final held = _pendingSignIn;
      _pendingSignIn = null;
      if (held != null) unawaited(_revokeSignIn(held));
      _gateWatch?.cancel();
      _serverBlocked.dispose();
    });
  }

  final Ref _ref;
  final _serverBlocked = ValueNotifier<ServerBlockedReason>(
    ServerBlockedReason.none,
  );
  bool _differentServer = false;
  bool _signedOut = false;
  bool _disposed = false;
  StreamSubscription<BindingGateState>? _gateWatch;
  static const serverUrlKey = 'serverUrl';

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

  /// Launch: resume the saved server, if any. A single health probe (a
  /// hanging saved URL must not hold the splash for the retry budget):
  /// healthy -> online; unreachable -> offline session (the URL is still
  /// presumed valid, downloads stay usable); an HTTP 5xx or 429 answer counts
  /// as unreachable here (sign-off OPEN-A-04, 2026-11-17); a 4xx or a non-OSML
  /// answer forgets the URL and the sign-in and returns to the server-address
  /// screen with the error (the binding row is kept, so the next connection is
  /// verified against it, SC-01 rule 3).
  ///
  /// A session URL always has a binding row (provisional until verified).
  /// Online, the connection is verified through the binding gate and the
  /// session becomes ready on its verdict; a different server leaves the app
  /// blocked: offline, with no health polling to flip it back.
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
  /// does, spec 7.4), and a row of another or an unknown user is kept as is.
  Future<_StoredSignIn> _storedSignInVerdict(Credentials credentials) async {
    final row = await _ref.read(serverBindingRepositoryProvider).current();
    if (row == null) return _StoredSignIn.noBinding;
    if (row.userId != credentials.userId) {
      return row.userId == null
          ? _StoredSignIn.noUser
          : _StoredSignIn.otherUser;
    }
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
  /// unreachable (sign-off OPEN-A-04, 2026-11-17); 4xx and non-OSML answers
  /// stay `serverError` (forget the URL and the sign-in).
  HealthStatus _launchHealth(HealthResult result) {
    final code = result.statusCode;
    if (result.status == HealthStatus.serverError &&
        code != null &&
        (code == 429 || code >= 500)) {
      return HealthStatus.unreachable;
    }
    return result.status;
  }

  Future<SessionStart> resumeSavedSession() async {
    // A reset that never finished its wipe is finished first, before the
    // saved URL creates a binding row on top of the old store (major 2).
    final pending = await _completePendingReset();
    switch (pending) {
      case null:
        break;
      case _PendingResetDone():
        return const SessionStart(SessionStartKind.resetFinished);
      case _PendingResetFailed(:final message):
        return SessionStart(SessionStartKind.serverAddress, error: message);
    }
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final url = prefs.getString(serverUrlKey);
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
        await _takeOverKeptRecords(); // a login closed before its take-over
      case _StoredSignIn.noBinding:
        return _dropStoredSignIn(url, 'no_binding');
      case _StoredSignIn.otherUser:
        return _dropStoredSignIn(url, 'binding_other_user');
      case _StoredSignIn.noUser:
        return _dropStoredSignIn(url, 'binding_without_user');
    }
    final result = await _ref.read(publicApiClientProvider).healthCheck(retry: false);
    switch (_launchHealth(result)) {
      case HealthStatus.ok:
        _watchServerBlock();
        unawaited(_verifyThenMarkReady(url));
        return const SessionStart(SessionStartKind.online);
      case HealthStatus.unreachable:
        _watchServerBlock();
        _ref.read(offlineModeProvider.notifier).enterOffline();
        _markReady();
        return const SessionStart(SessionStartKind.offline);
      case HealthStatus.serverError:
        await prefs.remove(serverUrlKey);
        await _deleteStoredSignIn();
        return SessionStart(SessionStartKind.serverAddress, error: result.message);
    }
  }

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
    await cancelPendingSignIn();
    // A reset the launch could not finish blocks every login until its
    // wipe succeeds: no server may adopt the old store (major 2).
    if (await _completePendingReset() case _PendingResetFailed(:final message)) {
      return ConnectFailed(message);
    }
    final api = _ref.read(unauthenticatedApiClientProvider)(url);
    final result = await api.healthCheck(retry: false);
    if (result.status != HealthStatus.ok) {
      return ConnectFailed(result.message ?? 'Could not reach the server.');
    }
    final ServerIdentity identity;
    try {
      identity = await ServerIdentityApi(api: api).fetch(reportOffline: false);
    } catch (e) {
      return ConnectFailed("Could not read the server's identity: $e");
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
    if (bound != null && bound != identity.instanceId) {
      return ConnectDifferentServer(url);
    }
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setString(serverUrlKey, url);
    // A prior disconnect-while-offline can leave offline mode armed; clear
    // it so the app doesn't open behind the offline banner.
    _ref.read(offlineModeProvider.notifier).exitOffline();
    return ConnectSucceeded(url);
  }

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
    final url = prefs.getString(serverUrlKey);
    if (url == null) {
      return const SignInFailed('No server is set. Enter the server address.');
    }
    if (await _completePendingReset() case _PendingResetFailed(:final message)) {
      return SignInFailed(message);
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
    final row = await _ref.read(serverBindingRepositoryProvider).current();
    final held = _HeldSignIn(session, url, authApi);
    // A NULL row instance is unknown: only a login on the URL the row was
    // created for may count as the same server (and fill it in). On another
    // URL it could be any server, so the different-server sheet (m-R2-08).
    final instanceCompatible = row?.instanceId == null
        ? row?.lastBaseUrl == url
        : row!.instanceId == session.serverInstanceId;
    if (row == null ||
        (instanceCompatible &&
            row.userId != null &&
            row.userId == session.user.id)) {
      try {
        await _persistSignIn(held);
      } catch (_) {
        await _revokeSignIn(held);
        return const SignInFailed(SignInNotSavedFailure.message);
      }
      // The same (instance, user) pair as the binding row: records kept by a
      // log-out that kept unsent work continue under this sign-in.
      if (row != null) await _takeOverKeptRecords();
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
  Future<void> _takeOverKeptRecords() async {
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
  Future<void> _persistSignIn(_HeldSignIn h) async {
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
      await prefs.setString(serverUrlKey, h.url);
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
  Future<void> _revokeSignIn(_HeldSignIn h) async {
    if (h.revoked) return;
    h.revoked = true;
    try {
      await h.api.logout(bearerToken: h.session.credentials.token);
    } catch (_) {}
  }

  /// The user confirmed the held sign-in's reset sheet: run the SC-15 reset,
  /// then persist the held credentials only if no wipe step failed (quiesce
  /// failures do not count). The rebuild is the finished-reset path's, not
  /// this method's. When nothing is persisted the held session is revoked.
  /// Null failure when nothing was held or the reset was clean.
  Future<LocalResetException?> confirmPendingSignIn() async {
    final held = _pendingSignIn;
    if (held == null) return null;
    _pendingSignIn = null;
    final (:failure, :aborted) = await _reset();
    if (!aborted &&
        (failure == null || failure.failures.every((f) => f.quiesce))) {
      try {
        await _persistSignIn(held);
      } catch (e, st) {
        await _revokeSignIn(held);
        return LocalResetException([
          ...?failure?.failures,
          SignInNotSavedFailure(e, st),
        ]);
      }
    } else {
      await _revokeSignIn(held);
    }
    return failure;
  }

  /// Re-reads the saved URL and the stored credentials and rebuilds the
  /// scope: the retry for unreadable credentials.
  Future<void> reloadSession() async =>
      await _ref.read(onSessionChangedProvider)?.call();

  /// The user's explicit choice to drop an unreadable stored sign-in. Clears
  /// it through logout's credential delete (a signed-out marker when the
  /// secure delete fails; this run then reads signed out), then rebuilds the
  /// scope, which opens at Log in for the kept URL.
  Future<void> forgetStoredSignIn() async {
    try {
      await _ref.read(credentialStoreProvider).delete();
    } catch (e) {
      developer.log(
        'Could not clear the stored sign-in: ${e.runtimeType}',
        name: 'SessionService',
      );
    }
    await reloadSession();
  }

  /// [keepUnsent]: see [LocalResetService.signOut].
  Future<void> logout({bool keepUnsent = false}) async {
    try {
      await _ref.read(localResetServiceProvider).signOut(keepUnsent: keepUnsent);
    } finally {
      await _ref.read(onSessionChangedProvider)?.call();
    }
  }

  /// The user cancelled the sheet: revoke the held session (best effort),
  /// discard it, and change nothing else. A no-op when nothing is held.
  Future<void> cancelPendingSignIn() async {
    final held = _pendingSignIn;
    if (held == null) return;
    _pendingSignIn = null;
    await _revokeSignIn(held);
  }

  /// A session is live with its offline state decided: playback may now
  /// restore the saved queue (SC-27 session-ready signal).
  void _markReady() => _ref.read(sessionReadinessProvider).markReady();

  /// Starts verifying a connection to [url] and returns the first state
  /// matching [isVerdict], or null if the gate closes first.
  Future<BindingGateState?> _connectionVerdict(
    String url,
    bool Function(BindingGateState) isVerdict, {
    bool reportOffline = true,
  }) async {
    final gate = _ref.read(serverBindingGateProvider);
    // Subscribe before starting so the verdict can't be missed.
    final verdict = gate.states
        .firstWhere(isVerdict)
        .then<BindingGateState?>((s) => s, onError: (Object _) => null);
    unawaited(gate.startConnection(url, reportOffline: reportOffline));
    return verdict;
  }

  /// Online start: ready once the binding gate has a verdict (a different
  /// server blocks, see [_watchServerBlock]; local playback keeps working),
  /// or once the session went offline while waiting (an offline restore
  /// needs no binding). A server that answers but can't be verified keeps
  /// network-backed playback waiting.
  Future<void> _verifyThenMarkReady(String url) async {
    final wentOffline = Completer<bool>();
    final offlineWatch = _ref.listen<bool>(offlineModeProvider, (_, offline) {
      if (offline && !wentOffline.isCompleted) wentOffline.complete(true);
    });
    try {
      final verdict = _connectionVerdict(
        url,
        (s) => s is BindingVerified || s is BindingDifferentServer,
      );
      final ready = await Future.any<bool>([
        verdict.then((v) => v != null),
        wentOffline.future,
      ]);
      if (ready) _markReady();
    } finally {
      offlineWatch.close();
    }
  }

  /// The one place "blocked: different server" is decided (SC-01 rule 1),
  /// for a live session's every connection (launch, networkRecovered,
  /// appResume). A different server blocks: offline, with health polling
  /// cancelled so the healthy server can't flip it back online. The bound
  /// server answering again clears it (D14). Subscribed once, before the
  /// session's first connection starts.
  void _watchServerBlock() {
    if (_gateWatch != null) return;
    _gateWatch = _ref.read(serverBindingGateProvider).states.listen((state) {
      final offline = _ref.read(offlineModeProvider.notifier);
      if (state is BindingDifferentServer) {
        _differentServer = true;
        _publishBlocked();
        offline.enterOffline();
        offline.cancelOfflinePolling();
      } else if (state is BindingVerified && _differentServer) {
        _differentServer = false;
        _publishBlocked();
        if (!_signedOut) offline.exitOffline();
      }
    });
  }

  /// The authenticated client got a 401 (Phase M 7.7): signed out. Closes
  /// the binding gate and turns offline on with polling stopped. Memory
  /// only (stored credentials stay); cleared only by a scope rebuild.
  /// Idempotent, and a no-op once this scope is disposed.
  void onUnauthorized() {
    if (_disposed || _signedOut) return;
    _signedOut = true;
    _publishBlocked();
    _ref.read(serverBindingGateProvider).closeSignedOut();
    final offline = _ref.read(offlineModeProvider.notifier);
    offline.enterOffline();
    offline.cancelOfflinePolling();
  }

  /// A different server wins over signed out when both apply.
  void _publishBlocked() {
    _serverBlocked.value = _differentServer
        ? ServerBlockedReason.differentServer
        : _signedOut
        ? ServerBlockedReason.signedOut
        : ServerBlockedReason.none;
  }

  bool _activated = false;

  /// The live session's UI exists (the session host mounted): run the one
  /// initial catalog sync, on first login and on saved-session startup
  /// alike (Home and Search need the mirror without visiting a browse page;
  /// recovery triggers keep covering resume/reconnect). Once per session:
  /// a reset rebuilds the scope, and with it this service. The sync itself
  /// awaits the SC-01 binding gate before its first request.
  Future<void> onSessionActivated() async {
    if (_activated) return;
    _activated = true;
    await _ref.read(trackSyncProvider.notifier).sync();
  }

  /// A user-requested catalog sync (Retry after a failed one). Unlike
  /// [onSessionActivated], runs every time it is asked.
  Future<void> syncLibrary() => _ref.read(trackSyncProvider.notifier).sync();

  /// Why the session is blocked: the saved server is a different library
  /// (SC-01 rule 1) or a 401 signed us out. Network runners wait on the
  /// binding gate; the app behaves as offline.
  ValueListenable<ServerBlockedReason> get serverBlocked => _serverBlocked;

  /// The user chose Reset on the blocked banner: reset local data and keep
  /// the saved URL so the rebuilt session binds to the server there.
  Future<LocalResetException?> resetForBlockedServer() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final url = prefs.getString(serverUrlKey);
    return url == null ? resetLocalData() : resetForNewServer(url);
  }

  /// The Disconnect / reset confirmation's "will be lost" lines (SC-15).
  Future<List<String>> pendingLossSummaries() =>
      _ref.read(localResetServiceProvider).pendingLossSummaries();

  /// Never throws: a counter that cannot be built or read is unknown.
  Future<LogoutLosses> pendingLogoutLosses() async {
    try {
      return await _ref.read(logoutLossCounterProvider).count();
    } catch (_) {
      return LogoutLosses.unknown;
    }
  }

  /// The user confirmed connecting to the different server at [url]: reset
  /// local data, then save [url] (after the prefs wipe) so the rebuilt
  /// session binds to it and syncs (SC-15). The URL is kept after a partial
  /// wipe too (the fence held), unless the database wipe failed; an aborted
  /// reset saves nothing.
  Future<LocalResetException?> resetForNewServer(String url) async {
    // A sign-in held for this URL is the different-server sheet's confirm.
    if (_pendingSignIn?.url == url) return confirmPendingSignIn();
    final (:failure, :aborted) = await _reset();
    // A failed database wipe leaves the old catalog and cursors behind:
    // binding the next server to them would mix libraries, so back to login.
    final databaseKept =
        failure?.failures.any((f) => f.participant is AppDatabase) ?? false;
    if (!aborted && !databaseKept) {
      final prefs = await _ref.read(sharedPreferencesProvider.future);
      await prefs.setString(serverUrlKey, url);
    }
    return failure;
  }

  /// Wipes local state. A partial reset is reported, never hidden; every
  /// step still runs (see [LocalResetService]).
  Future<LocalResetException?> resetLocalData() async =>
      (await _reset()).failure;

  /// Finishes an interrupted reset (major 2), if there is one: null when
  /// none was pending.
  Future<_PendingReset?> _completePendingReset() async {
    final resets = _ref.read(localResetServiceProvider);
    try {
      if (!await resets.hasPendingReset()) return null;
      await resets.completePendingReset();
      return const _PendingResetDone();
    } catch (e) {
      return _PendingResetFailed(
          'An earlier reset could not finish clearing local data, so no '
          'server can be connected yet ($e). Connecting tries again.');
    }
  }

  /// Runs the local reset. [aborted]: the fence did not hold (or the reset
  /// failed unexpectedly), so nothing may be assumed wiped.
  Future<({LocalResetException? failure, bool aborted})> _reset() async {
    try {
      await _ref.read(localResetServiceProvider).reset();
      return (failure: null, aborted: false);
    } on LocalResetException catch (e) {
      return (failure: e, aborted: false);
    } catch (e, st) {
      return (
        failure: LocalResetException([
          LocalResetFailure(LocalResetService, e, st),
        ]),
        aborted: true,
      );
    }
  }
}

final sessionServiceProvider = Provider<SessionService>(SessionService.new);

/// Where session events are written, one line per event (no secrets): the
/// developer log and, when the app gives one, the session log file (never
/// awaited; it never throws). Tests override it to capture the lines.
final sessionEventLogProvider = Provider<void Function(String message)>((ref) {
  final file = ref.read(sessionEventLogFileProvider);
  return (message) {
    developer.log(message, name: 'SessionService');
    if (file != null) unawaited(file.append(message));
  };
});

/// A held sign-in that could not be saved after its confirmed reset: its own
/// failure, never a wipe step's.
final class SignInNotSavedFailure extends LocalResetFailure {
  SignInNotSavedFailure(Object error, StackTrace stackTrace)
      : super(SessionService, error, stackTrace);

  /// The one sentence shown when the sign-in could not be saved.
  static const message = 'Could not save the sign-in on this device.';

  /// The sentence shown instead of "Reset incomplete" when the only failure
  /// that is not a quiesce failure is a sign-in that could not be saved; null
  /// otherwise.
  static String? noticeFor(LocalResetException? failure) {
    if (failure == null) return null;
    final wipe = failure.failures.where((f) => !f.quiesce);
    if (wipe.isEmpty) return null;
    return wipe.every((f) => f is SignInNotSavedFailure) ? message : null;
  }

  @override
  String toString() => message;
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

sealed class _PendingReset {
  const _PendingReset();
}

final class _PendingResetDone extends _PendingReset {
  const _PendingResetDone();
}

final class _PendingResetFailed extends _PendingReset {
  const _PendingResetFailed(this.message);
  final String message;
}

/// Rebuilds the provider scope after re-reading the session URL. Overridden
/// by `FrontendApp`; null means no rebuild hook (tests).
final onSessionChangedProvider = Provider<Future<void> Function()?>(
  (ref) => null,
);
