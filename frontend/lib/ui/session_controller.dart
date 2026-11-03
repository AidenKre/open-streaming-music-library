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

  /// Reset local data and disconnect (confirmed by the caller's view).
  Future<void> disconnect();

  /// The view showed the finished reset; return to the login screen.
  void acknowledgeReset();
}

final sessionControlsProvider = Provider<SessionControls>((ref) {
  final controller = SessionController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

class SessionController extends ChangeNotifier implements SessionControls {
  SessionController(this._ref);

  final Ref _ref;
  SessionPhase _phase = SessionPhase.starting;
  String? _connectError;
  LocalResetException? _resetFailure;
  bool _started = false;
  bool _disposed = false;

  SessionService get _service => _ref.read(sessionServiceProvider);

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
    final error = await _service.connect(url);
    if (_disposed) return;
    _connectError = error;
    _set(error == null ? SessionPhase.live : SessionPhase.signedOut);
  }

  @override
  Future<void> disconnect() async {
    if (_phase == SessionPhase.resetting) return;
    _connectError = null;
    _set(SessionPhase.resetting);
    final failure = await _service.resetLocalData();
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
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
