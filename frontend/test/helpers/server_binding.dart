import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

/// A live session's binding row (SC-01). Every fenced writer (catalog sync,
/// edit outbox, queue writes) is a no-op without one, exactly as after a
/// reset, so tests that exercise those writers outside the real session flow
/// seed it first. Returns the binding token.
Future<String> seedTestBinding(
  AppDatabase db, {
  String baseUrl = 'http://test',
  String? instanceId,
}) async {
  final repo = ServerBindingRepository(db);
  final binding = await repo.ensureProvisional(baseUrl);
  if (instanceId != null) {
    await repo.recordVerified(
      binding.localBindingId,
      instanceId: instanceId,
      baseUrl: baseUrl,
    );
  }
  return binding.localBindingId;
}

/// A binding gate whose probe the test controls; [respond] completes the
/// oldest pending probe.
class ControlledGate {
  ControlledGate(AppDatabase db) {
    gate = ServerBindingGate(
      repository: ServerBindingRepository(db),
      probe: _probe,
      backoff: BackoffSchedule(jitter: 0),
      timer: (d, f) => Timer(const Duration(days: 1), f),
    );
  }

  final _pending = <Completer<ServerIdentity>>[];
  late final ServerBindingGate gate;

  /// The `reportOffline` flag of each probe, in order.
  final reportOfflineFlags = <bool>[];

  Future<ServerIdentity> _probe({required bool reportOffline}) {
    reportOfflineFlags.add(reportOffline);
    final c = Completer<ServerIdentity>();
    _pending.add(c);
    return c.future;
  }

  int get pendingProbes => _pending.length;

  void respond(String? instanceId) =>
      _pending.removeAt(0).complete(ServerIdentity(instanceId));

  void fail(Object error) => _pending.removeAt(0).completeError(error);

  void dispose() => gate.dispose();
}

/// Overrides the scope's binding gate with one whose probe answers
/// [instanceId] immediately. With [startOnRead] it also starts a connection
/// when first read, for tests whose subject is not the gate but which run
/// gated work (catalog sync, recovery); then the scope's binding row must
/// already exist (see [seedTestBinding]). Session tests pass false: the
/// session starts its own connections.
Override autoVerifiedGateOverride({
  String baseUrl = 'http://test',
  String instanceId = 'test-instance',
  bool startOnRead = true,
}) => serverBindingGateProvider.overrideWith((ref) {
  final gate = ServerBindingGate(
    repository: ref.read(serverBindingRepositoryProvider),
    probe: ({required bool reportOffline}) async => ServerIdentity(instanceId),
    backoff: BackoffSchedule(jitter: 0),
  );
  if (startOnRead) unawaited(gate.startConnection(baseUrl));
  ref.onDispose(gate.dispose);
  return gate;
});
