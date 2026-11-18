import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

/// The signed-in user of test sessions: `testCredentials.userId`. Seeded
/// rows and test gates use it, so the gate's local user check (Phase M
/// 7.4) passes as in a real signed-in session.
const testUserId = 1;

/// A live session's binding row (SC-01). Every fenced writer (catalog sync,
/// edit outbox, queue writes) is a no-op without one, exactly as after a
/// reset, so tests that exercise those writers outside the real session flow
/// seed it first. Returns the binding token. With [reconciled] the row also
/// carries `catalog_reconciled_at_binding` (SC-04 readiness), as after the
/// first full catalog sync.
Future<String> seedTestBinding(
  AppDatabase db, {
  String baseUrl = 'http://test',
  String? instanceId,
  int? userId = testUserId,
  bool reconciled = false,
}) async {
  final repo = ServerBindingRepository(db);
  final binding = await repo.ensureProvisional(baseUrl, userId: userId);
  if (instanceId != null) {
    await repo.recordVerified(
      binding.localBindingId,
      instanceId: instanceId,
      baseUrl: baseUrl,
    );
  }
  if (reconciled) {
    await repo.runFenced(
        binding.localBindingId, repo.markCatalogReconciledInTransaction);
  }
  return binding.localBindingId;
}

/// A binding gate whose probe the test controls; [respond] completes the
/// oldest pending probe.
///
/// The gate's own timers (a failed check's retry, the wait bound) never fire
/// by default. [timer] replaces that: [boundOnlyGateTimer] lets the wait
/// bound run on the test's (fake) time.
class ControlledGate {
  ControlledGate(
    AppDatabase db, {
    int? signedInUserId = testUserId,
    Timer Function(Duration, void Function())? timer,
  }) {
    gate = ServerBindingGate(
      repository: ServerBindingRepository(db),
      signedInUserId: signedInUserId,
      probe: _probe,
      backoff: BackoffSchedule(jitter: 0),
      timer: timer ?? (d, f) => Timer(const Duration(days: 1), f),
    );
  }

  final _pending = <Completer<ServerIdentity>>[];
  late final ServerBindingGate gate;

  /// The `reportOffline` flag of each probe, in order.
  final reportOfflineFlags = <bool>[];

  /// The base URL each probe was asked to read, in order.
  final probedUrls = <String>[];

  Future<ServerIdentity> _probe({
    required String baseUrl,
    required bool reportOffline,
  }) {
    probedUrls.add(baseUrl);
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

/// A gate timer for fake-time tests of the wait bound
/// ([ServerBindingGate.tokenWaitBound]): the bound runs as asked; every other
/// gate timer (a failed check's retry) never fires.
Timer boundOnlyGateTimer(Duration delay, void Function() fire) => Timer(
  delay == ServerBindingGate.tokenWaitBound ? delay : const Duration(days: 1),
  fire,
);

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
    signedInUserId: testUserId,
    probe: ({required String baseUrl, required bool reportOffline}) async => ServerIdentity(instanceId),
    backoff: BackoffSchedule(jitter: 0),
  );
  if (startOnRead) unawaited(gate.startConnection(baseUrl));
  ref.onDispose(gate.dispose);
  return gate;
});
