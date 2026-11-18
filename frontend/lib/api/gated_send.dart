import 'dart:async';

import 'package:frontend/api/authenticated_client.dart';
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

/// How [sendWhenVerified] treats a binding that is not verified now.
enum BindingWait {
  /// Throw [BindingNotVerified] unless verified now (reads, Now Playing).
  failFast,

  /// A user's own action: wait up to [ServerBindingGate.tokenWaitBound] (the
  /// one bound, about 10 s, DEV-9-13) for a pending verdict (9-R2-03). A
  /// settled negative verdict or a closed gate still fails at once.
  forPendingVerdict,

  /// Wait without a limit until the gate verifies (uploads, deletions, pair
  /// actions): through failed checks and a different server. Only the gate
  /// closing or the call's abort trigger ends the wait.
  untilVerified,
}

bool _allowedNow(ServerBindingGate gate, Uri? url) =>
    gate.isVerifiedNow && (url == null || gate.allowsTokenTo(url));

/// Waits, within the gate's one bound ([ServerBindingGate.waitWithinBound],
/// [ServerBindingGate.tokenWaitBound]), until the gate is verified now (and allowed for
/// the url), publishes a settled negative state (different server, no
/// session, signed out) or closes. A failed probe that is retried
/// ([BindingUnverified]) keeps the wait going, inside the same bound.
Future<void> _awaitPendingVerdict(ServerBindingGate gate, Uri? url) =>
    gate.waitWithinBound(
      (s) =>
          _allowedNow(gate, url) ||
          s is BindingDifferentServer ||
          s is BindingNoSession ||
          s is BindingSignedOut,
    );

/// Runs [send] once the binding gate allows it, per [wait]. An answer
/// stamped by another server instance is reported to the gate, with the
/// connection captured right after the gate verified, and then rethrown.
/// [send] runs at most once: no call is retried here.
///
/// The one form of "wait for the server check, then send": `UploadsApi`,
/// `LibraryToolsApi` and `LastfmApi` all send through it.
///
/// [url] (the server's address) adds the token client's own rule to the
/// [BindingWait.failFast] and [BindingWait.forPendingVerdict] checks.
///
/// [abortTrigger] (completing, with or without an error) ends the wait for
/// the gate with [abortError] and sends nothing. It is watched once [wait]'s
/// own check has passed: the bounded wait of [BindingWait.forPendingVerdict]
/// has no caller with a trigger and does not watch it. Once [send] is under
/// way the trigger no longer matters here. Each caller passes its own
/// [abortError] type: its manager catches it by type.
///
/// [withheldAsNotVerified]: a request the token client refused at the send
/// (not verified any more, or offline: [TokenWithheldException], nothing
/// sent) is thrown as [BindingNotVerified], for a page read whose page
/// shows "not connected" and reloads by itself. Every other call keeps the
/// raw exception (sign-off OPEN-M-11, E8).
Future<T> sendWhenVerified<T>(
  ServerBindingGate gate,
  Future<T> Function() send, {
  required BindingWait wait,
  Uri? url,
  Future<void>? abortTrigger,
  Object? abortError,
  bool withheldAsNotVerified = false,
}) async {
  assert(abortTrigger == null || abortError != null);
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
    case BindingWait.untilVerified:
      break;
  }
  var aborted = false;
  final signal = Completer<void>();
  void fire() {
    aborted = true;
    if (!signal.isCompleted) signal.complete();
  }

  abortTrigger?.then((_) => fire(), onError: (Object _) => fire());
  final verified = gate.awaitVerified();
  if (abortTrigger == null) {
    await verified;
  } else {
    // Future.any keeps listening to both, so a later error of either is
    // handled.
    await Future.any<Object?>([
      verified,
      signal.future.then<Object?>((_) => throw abortError!),
    ]);
  }
  final connection = gate.verifiedConnection;
  if (aborted) throw abortError!;
  try {
    return await send();
  } on ServerInstanceChangedException catch (e) {
    if (connection != null) gate.reportDifferentInstance(connection, e);
    rethrow;
  } on TokenWithheldException {
    if (withheldAsNotVerified) throw const BindingNotVerified();
    rethrow;
  }
}
