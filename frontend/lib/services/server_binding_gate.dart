import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/server_identity_api.dart';
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
class ServerBindingGate {
  ServerBindingGate({
    required ServerBindingRepository repository,
    required Future<ServerIdentity> Function({required bool reportOffline})
    probe,
    required BackoffSchedule backoff,
    Timer Function(Duration, void Function())? timer,
  }) : _repository = repository,
       _probe = probe,
       _backoff = backoff,
       _timer = timer ?? Timer.new;

  final ServerBindingRepository _repository;
  final Future<ServerIdentity> Function({required bool reportOffline}) _probe;
  final BackoffSchedule _backoff;
  final Timer Function(Duration, void Function()) _timer;
  final _states = StreamController<BindingGateState>.broadcast();

  BindingGateState _state = const BindingIdle();

  /// Bumped per connection (and on dispose): a probe result from an older
  /// connection is dropped instead of overwriting the newer one's state.
  int _generation = 0;
  Timer? _retryTimer;

  /// The token once the CURRENT connection is verified; null otherwise.
  String? _verifiedToken;

  /// Awaiters waiting for the current (or a later) connection to verify.
  Completer<String>? _waiter;
  bool _closed = false;

  BindingGateState get state => _state;
  Stream<BindingGateState> get states => _states.stream;

  /// Starts verifying a new connection to [baseUrl]. Cancels a pending
  /// retry; until this connection verifies, [awaitVerified] waits.
  /// [reportOffline] false: a probe failure must not switch the app into
  /// offline mode (a login attempt, whose URL is not the session's yet).
  /// Retries of this connection keep the flag.
  Future<void> startConnection(String baseUrl, {bool reportOffline = true}) {
    if (_closed) return Future.value();
    _retryTimer?.cancel();
    _retryTimer = null;
    _verifiedToken = null;
    _backoff.reset(); // a new connection: not the last outage's delay
    return _verify(++_generation, baseUrl, reportOffline);
  }

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
    if (_closed) return;
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _verifiedToken = null;
    _publish(const BindingIdle());
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _waiter?.completeError(BindingGateClosedException());
    _waiter = null;
    unawaited(_states.close());
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
      if (row == null) {
        _publish(const BindingNoSession());
        return;
      }
      _publish(const BindingVerifying());
      final identity = await _probe(reportOffline: reportOffline);
      if (_isStale(generation)) return;

      final token = row.localBindingId;
      final current = await _repository.current();
      if (_isStale(generation)) return;
      if (current == null || current.localBindingId != token) {
        _publish(const BindingNoSession());
        return;
      }
      final bound = current.instanceId;
      final server = identity.instanceId;
      if (bound != null && server != null && bound != server) {
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
      _publish(BindingVerified(token: token, instanceId: server ?? bound));
      _waiter?.complete(token);
      _waiter = null;
    } on BindingFencedException {
      // A reset deleted (or a re-bind replaced) the row mid-verification.
      if (!_isStale(generation)) _publish(const BindingNoSession());
    } catch (e) {
      if (_isStale(generation)) return;
      _publish(BindingUnverified(e));
      _retryTimer = _timer(_backoff.nextDelay(), () {
        _retryTimer = null;
        if (!_isStale(generation)) {
          unawaited(_verify(generation, baseUrl, reportOffline));
        }
      });
    }
  }

  void _publish(BindingGateState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }
}

/// The scope's SC-01 binding gate, shared by recovery triggers and the
/// session's sync entry points. Scope-bound: a reset builds a new one.
final serverBindingGateProvider = Provider<ServerBindingGate>((ref) {
  final gate = ServerBindingGate(
    repository: ref.read(serverBindingRepositoryProvider),
    probe: ({required bool reportOffline}) =>
        ServerIdentityApi().fetch(reportOffline: reportOffline),
    backoff: BackoffSchedule(),
  );
  ref.onDispose(gate.dispose);
  return gate;
});
