import 'dart:async';

/// When the history runner is asked to run (Phase 5 §5): a 1 s debounced
/// flush after a local insert, and a 30 s poll while the app is in the
/// foreground and online (other devices' events). Recovery edges request
/// directly. Offline suspends the poll without touching any data.
class HistorySyncTriggers {
  HistorySyncTriggers({
    required void Function(String reason) request,
    Timer Function(Duration, void Function()) timer = Timer.new,
    this.debounce = const Duration(seconds: 1),
    this.pollInterval = const Duration(seconds: 30),
  }) : _request = request,
       _timer = timer;

  final Duration debounce;
  final Duration pollInterval;
  final void Function(String reason) _request;
  final Timer Function(Duration, void Function()) _timer;

  Timer? _debounceTimer;
  Timer? _pollTimer;
  bool _foreground = false;
  bool _online = false;
  bool _disposed = false;

  /// A local history event was inserted: (re)arms the debounce.
  void localInsert() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = _timer(debounce, () {
      _debounceTimer = null;
      if (!_disposed) _request('localInsert');
    });
  }

  /// The app is in the foreground ([value] true) or backgrounded.
  void setForeground(bool value) {
    _foreground = value;
    _updatePoll();
  }

  /// The session is online ([value] true) or offline.
  void setOnline(bool value) {
    _online = value;
    _updatePoll();
  }

  /// Whether the foreground poll is scheduled.
  bool get isPolling => _pollTimer?.isActive ?? false;

  /// Cancels every timer; later calls do nothing.
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  bool get _shouldPoll => !_disposed && _foreground && _online;

  void _updatePoll() {
    if (!_shouldPoll) {
      _pollTimer?.cancel();
      _pollTimer = null;
    } else if (!isPolling) {
      _armPoll();
    }
  }

  /// A one-shot, re-armed after each fire.
  void _armPoll() {
    _pollTimer = _timer(pollInterval, () {
      // A stale callback (offline or backgrounded since) requests nothing.
      if (!_shouldPoll) return;
      _request('poll');
      _armPoll();
    });
  }
}
