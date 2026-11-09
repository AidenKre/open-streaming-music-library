import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/session_service.dart';

enum SessionPhase { starting, signedOut, live, resetting, resetComplete }

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

  /// Blocked: the server at the saved URL is a different library (SC-01
  /// rule 1). Network work waits; local playback and browsing keep working.
  bool get serverBlocked;

  /// Blocked banner's Reset (confirmed by the view): reset local data, keep
  /// the URL, and bind to the server there.
  Future<void> resetBlockedServer();

  /// Reset local data and disconnect (confirmed by the caller's view).
  Future<void> disconnect();

  /// The view showed the finished reset; return to the login screen.
  void acknowledgeReset();

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

class SessionController extends ChangeNotifier implements SessionControls {
  SessionController(this._ref) {
    _blocked = _service.serverBlocked..addListener(_onBlockedChanged);
  }

  final Ref _ref;
  SessionPhase _phase = SessionPhase.starting;
  String? _connectError;
  LocalResetException? _resetFailure;
  String? _pendingServerSwitch;
  bool _started = false;
  bool _disposed = false;

  SessionService get _service => _ref.read(sessionServiceProvider);
  late final ValueListenable<bool> _blocked;

  void _onBlockedChanged() {
    if (!_disposed) notifyListeners();
  }

  @override
  SessionPhase get phase => _phase;
  @override
  String? get connectError => _connectError;
  @override
  LocalResetException? get resetFailure => _resetFailure;

  void _set(SessionPhase phase) {
    _phase = phase;
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final start = await _service.resumeSavedSession();
    if (_disposed) return;
    _connectError = start.error;
    _set(
      start.kind == SessionStartKind.signedOut
          ? SessionPhase.signedOut
          : SessionPhase.live,
    );
  }

  @override
  Future<void> connect(String url) async {
    final outcome = await _service.connect(url);
    if (_disposed) return;
    switch (outcome) {
      case ConnectSucceeded():
        _connectError = null;
        _set(SessionPhase.live);
      case ConnectFailed(:final message):
        _connectError = message;
        _set(SessionPhase.signedOut);
      case ConnectDifferentServer(:final url):
        _connectError = null;
        _pendingServerSwitch = url;
        _set(SessionPhase.signedOut);
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
    if (!_disposed) notifyListeners();
  }

  @override
  Future<List<String>> pendingLossSummaries() =>
      _service.pendingLossSummaries();

  @override
  Future<void> disconnect() => _runReset(_service.resetLocalData);

  @override
  bool get serverBlocked => _blocked.value;

  @override
  Future<void> resetBlockedServer() =>
      _runReset(_service.resetForBlockedServer);

  /// resetting -> resetComplete around one model reset; a second reset
  /// while one runs is ignored.
  Future<void> _runReset(
    Future<LocalResetException?> Function() reset,
  ) async {
    if (_phase == SessionPhase.resetting) return;
    _connectError = null;
    _set(SessionPhase.resetting);
    final failure = await reset();
    if (_disposed) return;
    _resetFailure = failure;
    _set(SessionPhase.resetComplete);
  }

  @override
  void acknowledgeReset() {
    _resetFailure = null;
    _set(SessionPhase.signedOut);
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
