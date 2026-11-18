import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/account_rules.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/logout_losses.dart';
import 'package:frontend/services/session_service.dart';

enum SessionPhase {
  starting,
  serverAddress,

  /// Log in to the saved server (spec 7.1).
  logIn,

  /// Create an account on the saved server (spec 7.1).
  createAccount,

  /// The stored sign-in could not be read: retry, not Log in.
  credentialsUnavailable,

  /// Log out is running (quiesce and a best-effort revoke can take seconds).
  signingOut,
  live,
  resetting,
  resetComplete,
}

/// Session input (SC-26 `SessionControls`; absorbs the old
/// DisconnectController): launch, connect, and disconnect/reset. Holds only
/// presentation state (phase, the login error, a reset failure to show);
/// every rule lives in the model `SessionService`.
abstract interface class SessionControls implements Listenable {
  SessionPhase get phase;

  /// The login screen's error (a rejected saved server or failed connect).
  String? get connectError;

  /// Set when a reset completed only partially, until acknowledged.
  LocalResetException? get resetFailure;

  /// The sentence to show instead of "Reset incomplete" when the only part
  /// of [resetFailure] that is not a quiesce failure is a sign-in that could
  /// not be saved; null otherwise.
  String? get signInNotSavedNotice;

  /// True when the launch itself failed (a fault thrown while resuming the
  /// saved session), not when the stored sign-in could not be read: the
  /// [SessionPhase.credentialsUnavailable] screen then names the saved
  /// session.
  bool get launchFailed;

  /// The saved server's URL, shown on the Log in screen.
  String? get serverUrl;

  /// The Log in / Create account screens' error: a client-side check or
  /// the server's SC-22 message.
  String? get authError;

  Future<void> login(String username, String password);

  Future<void> register(String username, String password, String confirmation);

  /// Log out (spec 7.6): local data is kept; the app opens at Log in.
  Future<void> logout();

  /// The signed-out banner's Log in: logs out and keeps the unsent uploads
  /// and deletions for the same user's next login.
  Future<void> logOutKeepingUnsent();

  /// Set when a login found another user's data on this device: the new
  /// user's name, for the confirmation. Nothing was stored yet.
  String? get pendingUserSwitch;

  Future<void> confirmUserSwitch();

  Future<void> cancelUserSwitch();

  void showCreateAccount();

  void showLogIn();

  /// Log in's "Change server": back to the server-address screen.
  void changeServer();

  /// The stored sign-in could not be read: read it again.
  Future<void> retryCredentials();

  /// The user chose to drop an unreadable stored sign-in and log in again.
  Future<void> logInAgain();

  /// Launch once: resume the saved session, if any.
  Future<void> start();

  Future<void> connect(String url);

  /// Set when a login found a different server than the one this library
  /// is bound to: the URL awaiting the user's confirmed reset (SC-01 rule
  /// 1). The view asks; nothing was saved yet.
  String? get pendingServerSwitch;

  /// The user confirmed: reset local data, keep the new URL, and rebind.
  Future<void> confirmServerSwitch();

  /// The user cancelled: back to the login screen, the URL not saved.
  void cancelServerSwitch();

  /// What a reset would lose, for the confirmation copy (SC-15).
  Future<List<String>> pendingLossSummaries();

  /// What logging out would drop for this sign-in (DEV-7-22, DEV-8-14).
  Future<LogoutLosses> pendingLogoutLosses();

  /// Why the session is blocked (different server, SC-01 rule 1, or signed
  /// out by a 401), or none. Network work waits; local playback and browsing
  /// keep working.
  ServerBlockedReason get serverBlocked;

  /// Blocked banner's Reset (confirmed by the view): reset local data, keep
  /// the URL, and bind to the server there.
  Future<void> resetBlockedServer();

  /// Reset local data and disconnect (confirmed by the caller's view).
  Future<void> disconnect();

  /// The view showed the finished reset; return to the login screen.
  Future<void> acknowledgeReset();

  /// The session host mounted (the live session's UI exists).
  Future<void> onSessionActivated();

  /// The user's Retry after the library sync failed.
  Future<void> retryLibrarySync();
}

final sessionControlsProvider = Provider<SessionControls>((ref) {
  final controller = SessionController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

/// Presentation state only (SC-26): phase, the error to show, the held user
/// or server switch. Input rules and every decision live in the model
/// (`account_rules.dart`, `SessionService`); this calls them and maps the
/// outcome.
class SessionController extends ChangeNotifier implements SessionControls {
  SessionController(this._ref) {
    _blocked = _service.serverBlocked..addListener(_onBlockedChanged);
  }

  final Ref _ref;
  SessionPhase _phase = SessionPhase.starting;
  String? _connectError;
  String? _serverUrl;
  String? _authError;
  String? _pendingUserSwitch;
  bool _signingIn = false;
  bool _loggingOut = false;
  LocalResetException? _resetFailure;
  String? _pendingServerSwitch;
  bool _started = false;
  bool _disposed = false;
  bool _launchFailed = false;

  /// Shown on the server-address screen when connecting threw (the address
  /// could not be saved on this device).
  static const connectSaveFailedMessage =
      'This device could not save the server address.';

  SessionService get _service => _ref.read(sessionServiceProvider);
  late final ValueListenable<ServerBlockedReason> _blocked;

  void _onBlockedChanged() {
    if (!_disposed) notifyListeners();
  }

  @override
  SessionPhase get phase => _phase;
  @override
  String? get serverUrl => _serverUrl;
  @override
  String? get authError => _authError;
  @override
  String? get pendingUserSwitch => _pendingUserSwitch;

  @override
  Future<void> login(String username, String password) async {
    final problem = signInInputProblem(username, password);
    if (problem != null) {
      _authError = problem;
      if (!_disposed) notifyListeners();
      return;
    }
    await _guardSignIn(() => _service.login(username, password));
  }

  @override
  Future<void> register(
    String username,
    String password,
    String confirmation,
  ) async {
    final problem = newAccountInputProblem(username, password, confirmation);
    if (problem != null) {
      _authError = problem;
      if (!_disposed) notifyListeners();
      return;
    }
    await _guardSignIn(() => _service.register(username, password));
  }

  /// One sign-in at a time: the screen can't change under it.
  Future<void> _guardSignIn(Future<SignInOutcome> Function() run) async {
    if (_signingIn) return;
    _signingIn = true;
    _authError = null;
    try {
      final outcome = await run();
      await _applySignIn(outcome);
    } finally {
      _signingIn = false;
    }
  }

  Future<void> _applySignIn(SignInOutcome outcome) async {
    if (_disposed) return;
    switch (outcome) {
      case SignInSucceeded():
        break; // the model rebuilt the scope
      case SignInFailed(:final message):
        _authError = message;
      case SignInNeedsUserSwitch(:final username):
        _pendingUserSwitch = username;
      case SignInDifferentServer(:final url):
        _pendingServerSwitch = url;
    }
    notifyListeners();
  }

  @override
  Future<void> logOutKeepingUnsent() => _logout(keepUnsent: true);

  @override
  Future<void> logout() => _logout(keepUnsent: false);

  Future<void> _logout({required bool keepUnsent}) async {
    if (_loggingOut ||
        _phase == SessionPhase.resetting ||
        _phase == SessionPhase.resetComplete) {
      return;
    }
    _loggingOut = true;
    _set(SessionPhase.signingOut);
    try {
      await _service.logout(keepUnsent: keepUnsent);
    } catch (e) {
      developer.log(
        'Sign-out did not finish cleanly: ${e.runtimeType}',
        name: 'SessionController',
      );
    } finally {
      _loggingOut = false;
    }
    // Without a rebuild hook (tests) nothing disposes this controller.
    if (!_disposed) _set(SessionPhase.logIn);
  }

  @override
  Future<void> confirmUserSwitch() async {
    _pendingUserSwitch = null;
    await _runReset(_service.confirmPendingSignIn);
  }

  @override
  Future<void> cancelUserSwitch() async {
    _pendingUserSwitch = null;
    if (!_disposed) notifyListeners();
    await _service.cancelPendingSignIn();
  }

  @override
  void showCreateAccount() {
    if (_signingIn) return;
    _authError = null;
    _set(SessionPhase.createAccount);
  }

  @override
  void showLogIn() {
    if (_signingIn) return;
    _authError = null;
    _set(SessionPhase.logIn);
  }

  @override
  void changeServer() {
    if (_signingIn) return;
    _authError = null;
    _connectError = null;
    _set(SessionPhase.serverAddress);
  }

  @override
  Future<void> retryCredentials() => _service.reloadSession();
  @override
  Future<void> logInAgain() async {
    await _service.forgetStoredSignIn();
    if (_disposed) return;
    _authError = null;
    _set(SessionPhase.logIn);
  }
  @override
  String? get connectError => _connectError;
  @override
  LocalResetException? get resetFailure => _resetFailure;
  @override
  String? get signInNotSavedNotice =>
      SignInNotSavedFailure.noticeFor(_resetFailure);
  @override
  bool get launchFailed => _launchFailed;

  void _set(SessionPhase phase) {
    _phase = phase;
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final SessionStart start;
    try {
      start = await _service.resumeSavedSession();
    } catch (e) {
      developer.log(
        'Resuming the saved session failed: ${e.runtimeType}',
        name: 'SessionController',
      );
      _launchFailed = true;
      if (!_disposed) _set(SessionPhase.credentialsUnavailable);
      return;
    }
    if (_disposed) return;
    _connectError = start.error;
    // Log in shows the launch notice where its own errors appear.
    if (start.kind == SessionStartKind.logIn) _authError = start.error;
    _serverUrl = start.serverUrl;
    _set(switch (start.kind) {
      SessionStartKind.serverAddress => SessionPhase.serverAddress,
      SessionStartKind.logIn => SessionPhase.logIn,
      SessionStartKind.credentialsUnavailable =>
        SessionPhase.credentialsUnavailable,
      // An interrupted reset was finished: rebuild like any finished reset.
      SessionStartKind.resetFinished => SessionPhase.resetComplete,
      SessionStartKind.online || SessionStartKind.offline => SessionPhase.live,
    });
  }

  @override
  Future<void> connect(String url) async {
    final ConnectOutcome outcome;
    try {
      outcome = await _service.connect(url);
    } catch (e) {
      developer.log(
        'Connecting failed: ${e.runtimeType}',
        name: 'SessionController',
      );
      _connectError = connectSaveFailedMessage;
      if (!_disposed) _set(SessionPhase.serverAddress);
      return;
    }
    if (_disposed) return;
    switch (outcome) {
      case ConnectSucceeded(:final url):
        _connectError = null;
        _serverUrl = url;
        _set(SessionPhase.logIn);
      case ConnectFailed(:final message):
        _connectError = message;
        _set(SessionPhase.serverAddress);
      case ConnectDifferentServer(:final url):
        _connectError = null;
        _pendingServerSwitch = url;
        _set(SessionPhase.serverAddress);
    }
  }

  @override
  String? get pendingServerSwitch => _pendingServerSwitch;

  @override
  Future<void> confirmServerSwitch() async {
    final url = _pendingServerSwitch;
    if (url == null) return;
    _pendingServerSwitch = null;
    await _runReset(() => _service.resetForNewServer(url));
  }

  @override
  void cancelServerSwitch() {
    _pendingServerSwitch = null;
    unawaited(_service.cancelPendingSignIn());
    if (!_disposed) notifyListeners();
  }

  @override
  Future<List<String>> pendingLossSummaries() =>
      _service.pendingLossSummaries();

  @override
  Future<LogoutLosses> pendingLogoutLosses() =>
      _service.pendingLogoutLosses();

  @override
  Future<void> disconnect() => _runReset(_service.resetLocalData);

  @override
  ServerBlockedReason get serverBlocked => _blocked.value;

  @override
  Future<void> resetBlockedServer() =>
      _runReset(_service.resetForBlockedServer);

  /// resetting -> resetComplete around one model reset; a second reset
  /// while one runs, or while signing out, is ignored.
  Future<void> _runReset(
    Future<LocalResetException?> Function() reset,
  ) async {
    if (_phase == SessionPhase.resetting || _phase == SessionPhase.signingOut) {
      return;
    }
    _connectError = null;
    _set(SessionPhase.resetting);
    LocalResetException? failure;
    try {
      failure = await reset();
    } catch (e, st) {
      // Nothing may be assumed wiped.
      failure = LocalResetException([LocalResetFailure(SessionService, e, st)]);
    }
    if (_disposed) return;
    _resetFailure = failure;
    _set(SessionPhase.resetComplete);
  }

  @override
  Future<void> acknowledgeReset() async {
    _resetFailure = null;
    await _service.reloadSession();
    if (_disposed) return;
    _set(SessionPhase.serverAddress);
  }

  @override
  Future<void> onSessionActivated() => _service.onSessionActivated();

  @override
  Future<void> retryLibrarySync() => _service.syncLibrary();

  @override
  void dispose() {
    _disposed = true;
    _blocked.removeListener(_onBlockedChanged);
    super.dispose();
  }
}
