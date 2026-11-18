import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/api/token_permit.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';

/// Where the current connection's binding verification stands (SC-01).
sealed class BindingGateState {
  const BindingGateState();
}

/// No connection has started yet.
class BindingIdle extends BindingGateState {
  const BindingIdle();
}

/// No binding row: no session, or a reset has started.
class BindingNoSession extends BindingGateState {
  const BindingNoSession();
}

/// The identity probe for the current connection is in flight.
class BindingVerifying extends BindingGateState {
  const BindingVerifying();
}

/// The current connection talks to the bound server; network participants
/// may proceed with [token].
class BindingVerified extends BindingGateState {
  const BindingVerified({required this.token, required this.instanceId});
  final String token;

  /// Null: a legacy server without `server.instance_id`.
  final String? instanceId;
}

/// The probe failed; a retry is scheduled with backoff.
class BindingUnverified extends BindingGateState {
  const BindingUnverified(this.error);
  final Object error;
}

/// The server reports a different instance than the bound one: every runner
/// stays blocked until the confirmed local reset.
class BindingDifferentServer extends BindingGateState {
  const BindingDifferentServer({
    required this.boundInstanceId,
    required this.serverInstanceId,
  });
  final String boundInstanceId;
  final String serverInstanceId;
}

/// Signed out by a 401 (Phase M 7.7): closed until the scope is rebuilt.
class BindingSignedOut extends BindingGateState {
  const BindingSignedOut();
}

/// [ServerBindingGate.awaitVerified] was pending when the gate was disposed.
class BindingGateClosedException implements Exception {
  @override
  String toString() => 'BindingGateClosedException';
}

/// SC-01 rule 1: binding verification is a gate, not a step.
///
/// Each connection ([startConnection]: session activation, every
/// networkRecovered / appResume edge) is verified against the server's
/// identity, read directly via the injected probe (never a cached blob).
/// Network-backed participants [awaitVerified] before their first request.
/// A failed probe leaves the connection unverified and is retried with
/// [BackoffSchedule]; a different server blocks without retrying.
///
/// It also checks locally that the binding's user is the signed-in user
/// (spec 7.4). Without credentials, or when the row's user differs or is
/// unknown (NULL), the gate stays [BindingNoSession] and sends nothing.
class ServerBindingGate implements TokenPermit {
  ServerBindingGate({
    required ServerBindingRepository repository,
    required int? signedInUserId,
    required Future<ServerIdentity> Function({
      required String baseUrl,
      required bool reportOffline,
    })
    probe,
    required BackoffSchedule backoff,
    Timer Function(Duration, void Function())? timer,
    bool Function()? isOffline,
  }) : _isOffline = isOffline ?? (() => false),
       _repository = repository,
       _signedInUserId = signedInUserId,
       _probe = probe,
       _backoff = backoff,
       _timer = timer ?? Timer.new;

  final ServerBindingRepository _repository;
  final int? _signedInUserId;
  final Future<ServerIdentity> Function({
    required String baseUrl,
    required bool reportOffline,
  })
  _probe;
  final BackoffSchedule _backoff;
  final Timer Function(Duration, void Function()) _timer;
  final bool Function() _isOffline;
  final _states = StreamController<BindingGateState>.broadcast();

  BindingGateState _state = const BindingIdle();

  /// Bumped per connection (and on dispose): a probe result from an older
  /// connection is dropped instead of overwriting the newer one's state.
  int _generation = 0;
  Timer? _retryTimer;

  /// The token once the CURRENT connection is verified; null otherwise.
  String? _verifiedToken;

  /// The base URL this scope verified as the bound instance, with no failed
  /// check since. Cleared by every failed check (an error, a different
  /// server, no session), [stop], [closeSignedOut], and a connection to
  /// another URL.
  String? _verifiedBaseUrl;

  /// Awaiters waiting for the current (or a later) connection to verify.
  Completer<String>? _waiter;
  bool _closed = false;

  /// Set by [closeSignedOut]; only [dispose] (the scope rebuild) clears it.
  bool _signedOut = false;

  BindingGateState get state => _state;

  BindingGateState? _lastVerdict;

  /// The last settled verdict was a failed check. Kept through its backoff
  /// retries and a new connection's probe; cleared by any other verdict,
  /// [stop] included (sign-off OPEN-M-11 Part N review F1).
  bool get lastVerdictFailed => _lastVerdict is BindingUnverified;

  /// True from a connection start (or a retry) until its verdict is published.
  bool _verdictPending = false;

  /// The token client's rule (sign-off OPEN-M-11, 2026-11-17): the token may
  /// go to [url] only while this connection is verified, the app is online,
  /// and [url] is under the verified base URL. Synchronous.
  @override
  bool allowsTokenTo(Uri url) {
    if (_closed ||
        _signedOut ||
        _verifiedToken == null ||
        _state is! BindingVerified) {
      return false;
    }
    try {
      if (_isOffline()) return false;
    } catch (_) {
      return false;
    }
    final baseUrl = _verifiedBaseUrl;
    if (baseUrl == null) return false;
    final Uri base;
    try {
      base = Uri.parse(baseUrl);
    } catch (_) {
      return false;
    }
    if (base.scheme.toLowerCase() != url.scheme.toLowerCase() ||
        base.host.toLowerCase() != url.host.toLowerCase() ||
        base.port != url.port) {
      return false;
    }
    var basePath = base.path;
    while (basePath.endsWith('/')) {
      basePath = basePath.substring(0, basePath.length - 1);
    }
    return basePath.isEmpty ||
        url.path == basePath ||
        url.path.startsWith('$basePath/');
  }

  /// Completes at once unless a verdict is pending; otherwise after the next
  /// published state that is not [BindingVerifying], the end of the states
  /// stream, or [tokenWaitBound]. Never throws.
  @override
  Future<void> verdictSettled() {
    if (!_verdictPending || _closed) return Future.value();
    return waitWithinBound((s) => s is! BindingVerifying);
  }

  /// The gate's one bounded wait: completes when [ends] answers true for a
  /// published state, when the states stream ends (the gate was disposed),
  /// or when [tokenWaitBound] has passed, whichever comes first. One timer
  /// for the whole wait, started now on the gate's injected timer: a state
  /// that does not end the wait does not start the bound again. Never
  /// throws ([ends] must not).
  ///
  /// The two waits differ only in [ends]: [verdictSettled] ends at any
  /// verdict, a failed check included; a user's own action
  /// (`sendWhenVerified` with `BindingWait.forPendingVerdict`) keeps waiting
  /// through a failed check that is being retried.
  Future<void> waitWithinBound(bool Function(BindingGateState state) ends) {
    final done = Completer<void>();
    StreamSubscription<BindingGateState>? sub;
    Timer? bound;
    void finish() {
      if (done.isCompleted) return;
      bound?.cancel();
      unawaited(sub?.cancel());
      done.complete();
    }

    sub = _states.stream.listen(
      (s) {
        if (ends(s)) finish();
      },
      onDone: finish,
    );
    bound = _timer(tokenWaitBound, finish);
    return done.future;
  }

  /// The log-out/Disconnect revoke rule only (lenient): this scope verified
  /// the bound instance at exactly [baseUrl] and nothing failed since. True
  /// while verified, or while a re-probe of it is in flight. It differs from
  /// [allowsTokenTo] on purpose: a log-out or Disconnect may still revoke
  /// during a re-probe of the verified server, while ordinary requests wait
  /// for a fresh verdict. The offline check is the caller's
  /// (`LocalResetService`).
  bool maySendTokenTo(String baseUrl) =>
      _verifiedBaseUrl == baseUrl &&
      (_state is BindingVerified || _state is BindingVerifying);

  /// The bound of [waitWithinBound]: how long a request waits for a verdict
  /// ([verdictSettled], [whenMaySendTokenTo]) and a user's own action for a
  /// verified connection.
  static const tokenWaitBound = Duration(seconds: 10);

  /// For requests that do not go through the token client (cover art, the
  /// upload preview): the same rule as the token client (sign-off OPEN-M-11).
  /// False at once when closed or signed out; otherwise it waits only for a
  /// pending verdict ([verdictSettled]), then answers [allowsTokenTo]. Never
  /// starts a probe, never throws.
  Future<bool> whenMaySendTokenTo(String baseUrl) async {
    if (_closed || _signedOut) return false;
    await verdictSettled();
    try {
      return allowsTokenTo(Uri.parse(baseUrl));
    } catch (_) {
      return false;
    }
  }

  Stream<BindingGateState> get states => _states.stream;

  /// Starts verifying a new connection to [baseUrl]. Cancels a pending
  /// retry; until this connection verifies, [awaitVerified] waits.
  /// [reportOffline] false: a probe failure must not switch the app into
  /// offline mode (a login attempt, whose URL is not the session's yet).
  /// Retries of this connection keep the flag.
  Future<void> startConnection(String baseUrl, {bool reportOffline = true}) {
    if (_closed || _signedOut) return Future.value();
    _retryTimer?.cancel();
    _retryTimer = null;
    _verifiedToken = null;
    _verdictPending = true;
    if (_verifiedBaseUrl != baseUrl) _verifiedBaseUrl = null;
    _backoff.reset(); // a new connection: not the last outage's delay
    return _verify(++_generation, baseUrl, reportOffline);
  }

  /// Whether [awaitVerified] would answer at once: the current connection is
  /// verified now. A new connection clears this immediately, before its
  /// state is published.
  bool get isVerifiedNow => !_closed && _verifiedToken != null;

  /// Completes with the binding token once the current connection is
  /// verified. Keeps waiting through failures and a different server.
  Future<String> awaitVerified() {
    if (_closed) return Future.error(BindingGateClosedException());
    final token = _verifiedToken;
    if (token != null) return Future.value(token);
    return (_waiter ??= Completer<String>()).future;
  }

  /// Abandons the current connection attempt (a failed or cancelled login):
  /// cancels a pending retry and returns to idle. Awaiters keep waiting for
  /// a later connection.
  void stop() {
    if (_closed || _signedOut) return;
    _invalidate();
    _publish(const BindingIdle());
  }

  /// Closes the gate after a 401 (Phase M 7.7): no more probes, and awaiters
  /// keep waiting until [dispose] (the scope rebuild) ends the wait.
  void closeSignedOut() {
    if (_closed || _signedOut) return;
    _signedOut = true;
    _invalidate();
    _publish(const BindingSignedOut());
  }

  /// The current connection's id while it is verified, else null. A run
  /// captures it with its token (the token is per binding, the same for every
  /// connection) so a later report can name the connection it ran on.
  int? get verifiedConnection => _state is BindingVerified ? _generation : null;

  /// SC-01 rule 6: a run on [connection] found a page stamped by another
  /// instance ([changed]). Blocks as a different server only while that same
  /// connection is still the verified one; dropped otherwise.
  void reportDifferentInstance(
    int connection,
    ServerInstanceChangedException changed,
  ) {
    if (_closed ||
        _signedOut ||
        _state is! BindingVerified ||
        connection != _generation) {
      return;
    }
    _invalidate();
    _publish(
      BindingDifferentServer(
        boundInstanceId: changed.boundInstanceId,
        serverInstanceId: changed.servedBy,
      ),
    );
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _verdictPending = false;
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _waiter?.completeError(BindingGateClosedException());
    _waiter = null;
    unawaited(_states.close());
  }

  /// Ends the current verdict: a probe in flight is dropped (by generation),
  /// a scheduled retry is cancelled, and the verified token and base URL are
  /// forgotten, so no token is handed out until a new verdict.
  void _invalidate() {
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _verifiedToken = null;
    _verifiedBaseUrl = null;
  }

  bool _isStale(int generation) => _closed || generation != _generation;

  Future<void> _verify(
    int generation,
    String baseUrl,
    bool reportOffline,
  ) async {
    try {
      final row = await _repository.current();
      if (_isStale(generation)) return;
      // No credentials, no row, or a row for another (or an unknown) user:
      // never verify, never probe. Runners keep waiting (spec 7.4).
      if (_signedInUserId == null ||
          row == null ||
          row.userId != _signedInUserId) {
        _verifiedBaseUrl = null;
        _publish(const BindingNoSession());
        return;
      }
      _publish(const BindingVerifying());
      final identity = await _probe(
        baseUrl: baseUrl,
        reportOffline: reportOffline,
      );
      if (_isStale(generation)) return;

      final token = row.localBindingId;
      final current = await _repository.current();
      if (_isStale(generation)) return;
      if (current == null ||
          current.localBindingId != token ||
          current.userId != _signedInUserId) {
        _verifiedBaseUrl = null;
        _publish(const BindingNoSession());
        return;
      }
      final bound = current.instanceId;
      final server = identity.instanceId;
      // Exact on purpose (SC-01): this decides a reset, and both ids come from
      // the server's own answers. Only the header stamp is compared leniently.
      if (bound != null && server != null && bound != server) {
        _verifiedBaseUrl = null;
        _publish(
          BindingDifferentServer(
            boundInstanceId: bound,
            serverInstanceId: server,
          ),
        );
        return;
      }
      if (bound != null && server == null) {
        // A bound row can't prove a server without an instance id is the
        // same one: stay unverified (and keep retrying) rather than guess.
        throw StateError(
          'bound to instance $bound but the server reports no instance id',
        );
      }

      await _repository.recordVerified(
        token,
        instanceId: server,
        baseUrl: baseUrl,
      );
      if (_isStale(generation)) return;
      _backoff.reset();
      _verifiedToken = token;
      _verifiedBaseUrl = baseUrl;
      _publish(BindingVerified(token: token, instanceId: server ?? bound));
      _waiter?.complete(token);
      _waiter = null;
    } on BindingFencedException {
      // A reset deleted (or a re-bind replaced) the row mid-verification.
      if (!_isStale(generation)) {
        _verifiedBaseUrl = null;
        _publish(const BindingNoSession());
      }
    } catch (e) {
      if (_isStale(generation)) return;
      _verifiedBaseUrl = null;
      _publish(BindingUnverified(e));
      _retryTimer = _timer(_backoff.nextDelay(), () {
        _retryTimer = null;
        if (!_isStale(generation)) {
          _verdictPending = true;
          unawaited(_verify(generation, baseUrl, reportOffline));
        }
      });
    }
  }

  void _publish(BindingGateState state) {
    _state = state;
    if (state is! BindingVerifying) {
      _verdictPending = false;
      _lastVerdict = state;
    }
    if (!_states.isClosed) _states.add(state);
  }
}

/// The scope's SC-01 binding gate, shared by recovery triggers and the
/// session's sync entry points. Scope-bound: a reset builds a new one.
final Provider<ServerBindingGate> serverBindingGateProvider =
    Provider<ServerBindingGate>((ref) {
  final api = ref.read(publicApiClientProvider);
  final preSession = ref.read(unauthenticatedApiClientProvider);
  final gate = ServerBindingGate(
    repository: ref.read(serverBindingRepositoryProvider),
    signedInUserId: ref.read(credentialsProvider)?.userId,
    // The session's own URL goes through the scope's token-free client (the
    // probe is a public path), so an in-session transport failure still
    // reaches its offline listener. Any other URL (a
    // connect attempt) goes through an unhooked pre-session client.
    probe: ({required String baseUrl, required bool reportOffline}) =>
        ServerIdentityApi(
          api: baseUrl == api.baseUrl ? api : preSession(baseUrl),
        ).fetch(reportOffline: reportOffline),
    backoff: BackoffSchedule(),
    isOffline: () => ref.read(offlineModeProvider),
  );
  ref.onDispose(gate.dispose);
  return gate;
});
