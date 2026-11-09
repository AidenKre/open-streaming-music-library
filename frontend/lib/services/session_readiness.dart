import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The session-ready signal (SC-27): set when a live session is entered
/// with the offline state already determined (the health probe ran). The
/// playback model waits for it before restoring the saved queue or doing
/// any network-backed playback work, so an offline cold start never
/// restores onto streaming sources. `SessionService` marks it ready on a
/// binding verdict (Verified or DifferentServer) for an online start, on an
/// offline start, or when the session goes offline while waiting for the
/// verdict; a server that answers but can't be verified keeps it waiting.
/// Scope-bound: a reset builds a new scope and a fresh, unready signal.
class SessionReadiness {
  final _ready = Completer<void>();

  bool get isReady => _ready.isCompleted;

  Future<void> get ready => _ready.future;

  void markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }
}

final sessionReadinessProvider = Provider<SessionReadiness>(
  (ref) => SessionReadiness(),
);
