// The upload manager's and the deletion manager's "wait for the server check
// unless we are closing". Model code: nothing from ui/.
import 'dart:async';

import 'package:frontend/services/server_binding_gate.dart';

/// A manager's wait for the binding gate at the start of a pass.
///
/// [token] answers the binding token once the gate has verified the current
/// connection (at once when it already has), or null when [closing]
/// completes first: the manager is being quiesced, its pass ends and nothing
/// is sent. The gate closing ends the wait with its own error
/// ([BindingGateClosedException]).
///
/// [waiting] and [nextWaitBegins] exist for the managers' `idle()`, which
/// only tests call: a pass that waits for the check counts as idle, because
/// only the gate or a quiesce ends that wait.
class GateWait {
  GateWait({required ServerBindingGate gate, required Future<void> closing})
    : _gate = gate,
      _closing = closing;

  final ServerBindingGate _gate;
  final Future<void> _closing;
  Completer<void> _began = Completer<void>();
  bool _waiting = false;

  /// A pass is waiting for the gate right now.
  bool get waiting => _waiting;

  /// Completes the next time a wait begins.
  Future<void> get nextWaitBegins => _began.future;

  /// The verified binding token; null when [closing] completed while
  /// waiting.
  Future<String?> token() async {
    if (_gate.state is! BindingVerified) {
      _waiting = true;
      _began.complete();
      _began = Completer<void>();
    }
    final verified = _gate.awaitVerified()..ignore();
    try {
      return await Future.any<String?>([
        verified,
        _closing.then((_) => null),
      ]);
    } finally {
      _waiting = false;
    }
  }
}
