import 'dart:async';

import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/server_binding_gate.dart';

/// The server binding is not verified now, so nothing was sent
/// (9-R1-38, U33-B-02). Thrown instead of waiting at the gate.
class BindingNotVerified implements Exception {
  const BindingNotVerified([this.reason = BindingRefusal.notYet]);

  /// Why, from the gate's state at the refusal (9-R2-04).
  final BindingRefusal reason;

  @override
  String toString() => 'BindingNotVerified';
}

/// Why a call was refused without being sent (9-R2-04).
enum BindingRefusal {
  /// No verdict yet, or a failed probe that is retried: it may still verify.
  notYet,

  /// A different server instance answers: retrying alone does not fix it (a
  /// later connection verifies only if the bound server answers again).
  differentServer,

  /// No session for this binding, or signed out: retrying alone does not fix
  /// it (a later connection verifies only after signing in again).
  noSession,
}

/// The one fast-fail rule: throws [BindingNotVerified] unless [gate] is
/// verified right now and, when a [url] is given, the token client's own rule
/// allows the token to go there (a verified gate while offline is not
/// allowed: `notYet`; sign-off OPEN-M-11, E9).
void requireVerifiedNow(ServerBindingGate gate, {Uri? url}) {
  if (gate.isVerifiedNow && (url == null || gate.allowsTokenTo(url))) return;
  final s = gate.state;
  throw BindingNotVerified(switch (s) {
    BindingDifferentServer() => BindingRefusal.differentServer,
    BindingNoSession() || BindingSignedOut() => BindingRefusal.noSession,
    _ => BindingRefusal.notYet,
  });
}

/// How long a user's own action waits for a pending verdict: the one bound,
/// about 10 s (DEV-9-13).
const userActionVerdictWait = ServerBindingGate.tokenWaitBound;

/// How [sendWhenVerified] treats a binding that is not verified now.
enum BindingWait {
  /// Throw [BindingNotVerified] unless verified now (reads, Now Playing).
  failFast,

  /// A user's own action: wait up to [userActionVerdictWait] for a pending
  /// verdict (9-R2-03). A settled negative verdict or a closed gate still
  /// fails at once.
  forPendingVerdict,
}

bool _allowedNow(ServerBindingGate gate, Uri? url) =>
    gate.isVerifiedNow && (url == null || gate.allowsTokenTo(url));

/// Waits (bounded) until the gate is verified now (and allowed for the url), publishes a settled
/// negative state (different server, no session, signed out), closes, or
/// [userActionVerdictWait] passes. A failed probe that is retried
/// ([BindingUnverified]) keeps the wait going.
Future<void> _awaitPendingVerdict(ServerBindingGate gate, Uri? url) {
  final settled = Completer<void>();
  late final StreamSubscription<BindingGateState> sub;
  late final Timer timer;
  void finish() {
    if (settled.isCompleted) return;
    timer.cancel();
    sub.cancel();
    settled.complete();
  }

  timer = Timer(userActionVerdictWait, finish);
  sub = gate.states.listen(
    (s) {
      if (_allowedNow(gate, url) ||
          s is BindingDifferentServer ||
          s is BindingNoSession ||
          s is BindingSignedOut) {
        finish();
      }
    },
    onDone: finish,
  );
  return settled.future;
}

/// Runs [send] once the binding gate allows it, per [wait]. An answer
/// stamped by another server instance is reported to the gate, with the
/// connection captured right after the gate verified, and then rethrown.
///
/// The shared form of the pattern in `UploadsApi` and `LibraryToolsApi`,
/// without their abort trigger.
Future<T> sendWhenVerified<T>(
  ServerBindingGate gate,
  Future<T> Function() send, {
  required BindingWait wait,
  Uri? url,
}) async {
  switch (wait) {
    case BindingWait.failFast:
      requireVerifiedNow(gate, url: url);
    case BindingWait.forPendingVerdict:
      if (!_allowedNow(gate, url)) {
        final s = gate.state;
        if (s is BindingDifferentServer ||
            s is BindingNoSession ||
            s is BindingSignedOut ||
            gate.isVerifiedNow) {
          // Settled negative, or verified but not allowed (offline): no
          // verdict is coming.
          requireVerifiedNow(gate, url: url);
        }
        await _awaitPendingVerdict(gate, url);
        requireVerifiedNow(gate, url: url);
      }
  }
  await gate.awaitVerified();
  final connection = gate.verifiedConnection;
  try {
    return await send();
  } on ServerInstanceChangedException catch (e) {
    if (connection != null) gate.reportDifferentInstance(connection, e);
    rethrow;
  }
}
