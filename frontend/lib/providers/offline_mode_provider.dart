import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';

/// Global "local-only mode" flag.
///
/// `true` means: *the backend cannot currently be used for normal app work*,
/// so the UI shows downloaded content only, disables network-only actions,
/// and pauses sync/downloads/queue-warmup.
///
/// Entered on a request transport failure (via [ApiClient.onNetworkFailure])
/// or on a startup health-check failure for a saved server URL. It is exited
/// by a passing `/` health check — never by an arbitrary HTTP response, since
/// a 4xx/5xx proves the server is reachable but not that it is healthy enough
/// to resume normal work — or explicitly via [OfflineModeNotifier.exitOffline]
/// on disconnect. While offline we poll the health endpoint every
/// [_pollInterval] so recovery is detected without user input.
final offlineModeProvider =
    NotifierProvider<OfflineModeNotifier, bool>(OfflineModeNotifier.new);

class OfflineModeNotifier extends Notifier<bool> {
  /// Health-poll cadence while offline. Mutable so tests can run fast and
  /// deterministically; production always uses 5s.
  @visibleForTesting
  static Duration pollInterval = const Duration(seconds: 5);

  Timer? _pollTimer;
  bool _pollInFlight = false;
  bool _disposed = false;

  @override
  bool build() {
    ref.onDispose(() {
      _disposed = true;
      _pollTimer?.cancel();
      _pollTimer = null;
    });
    return false;
  }

  /// Enter local-only mode. Called by the [ApiClient] transport-failure hook,
  /// by the download manager on a mid-stream network failure, and by the
  /// startup gate when a saved server URL is unreachable. No-op if already
  /// offline. Exit happens only via [_poll] on a passing health check.
  void enterOffline() {
    if (state) return;
    state = true;
    _scheduleNextPoll();
  }

  /// Leave local-only mode and stop health polling. Unlike the [_poll]-driven
  /// exit, this is an explicit lifecycle call: used on disconnect, when there
  /// is no trusted server URL left to poll. Safe to call when already online.
  void exitOffline() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (state) state = false;
  }

  void _scheduleNextPoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer(pollInterval, _poll);
  }

  /// One health poll. Self-reschedules: the next poll is queued only after
  /// this one finishes, so polls can never overlap or stack up. The
  /// [_pollInFlight] guard is belt-and-suspenders against re-entrancy.
  Future<void> _poll() async {
    if (_disposed || !state || _pollInFlight) return;
    _pollInFlight = true;
    var recovered = false;
    try {
      // Single attempt — polling is itself the retry loop.
      final result = await ApiClient.instance.healthCheck(retry: false);
      recovered = result.isOk;
    } finally {
      _pollInFlight = false;
    }
    if (_disposed) return;
    if (recovered) {
      state = false;
      _pollTimer?.cancel();
      _pollTimer = null;
    } else if (state) {
      _scheduleNextPoll();
    }
  }
}
