// SC-01 rule 1 consumers: every network-backed RecoveryService member awaits
// the binding gate before its first request, including the coldStart run that
// main.dart fires before StartupGate has health-checked. networkRecovered and
// appResume are connection edges: each starts a NEW verification. Local-only
// members (reconcile downloads) never wait.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Member implements RecoverableService {
  _Member(this.label, this.log, {required this.requiresBinding});
  final String label;
  final List<String> log;
  @override
  final bool requiresBinding;
  @override
  int get recoveryPriority => 0;
  @override
  Set<RecoveryTrigger> get triggers => RecoveryTrigger.values.toSet();
  @override
  Future<void> recover(RecoveryTrigger trigger) async =>
      log.add('$label:${trigger.name}');
}

void main() {
  late AppDatabase db;
  late ProviderContainer c;
  late List<Completer<ServerIdentity>> probes;
  late List<String> log;
  late ServerBindingGate gate;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.init('http://a');
    db = AppDatabase(NativeDatabase.memory());
    await ServerBindingRepository(db).ensureProvisional('http://a');
    probes = [];
    log = [];
    gate = ServerBindingGate(
      repository: ServerBindingRepository(db),
      probe: ({required bool reportOffline}) {
        final p = Completer<ServerIdentity>();
        probes.add(p);
        return p.future;
      },
      backoff: BackoffSchedule(jitter: 0),
      timer: (d, f) => Timer(const Duration(days: 1), f),
    );
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        serverBindingGateProvider.overrideWithValue(gate),
        recoverablesProvider.overrideWithValue([
          _Member('net', log, requiresBinding: true),
          _Member('local', log, requiresBinding: false),
        ]),
      ],
    );
  });

  tearDown(() async {
    gate.dispose();
    c.dispose();
    await db.close();
  });

  RecoveryService recovery() => c.read(recoveryServiceProvider);

  test('coldStart: local members run now, network members wait for the gate',
      () async {
    final run = recovery().runFor(RecoveryTrigger.coldStart);
    await pumpEventQueue();
    expect(log, ['local:coldStart']);
    expect(probes, isEmpty, reason: 'coldStart is not a connection edge');

    unawaited(gate.startConnection('http://a')); // the session starts
    await pumpEventQueue();
    probes.single.complete(const ServerIdentity('inst-1'));
    await run;
    expect(log, ['local:coldStart', 'net:coldStart']);
  });

  for (final trigger in [
    RecoveryTrigger.networkRecovered,
    RecoveryTrigger.appResume,
  ]) {
    test('${trigger.name} starts a new verification and waits for it',
        () async {
      // Already verified on an earlier connection.
      unawaited(gate.startConnection('http://a'));
      await pumpEventQueue();
      probes.single.complete(const ServerIdentity('inst-1'));
      await gate.awaitVerified();

      final run = recovery().runFor(trigger);
      await pumpEventQueue();
      expect(probes, hasLength(2), reason: 'the edge re-verifies');
      expect(log, ['local:${trigger.name}']);
      probes[1].complete(const ServerIdentity('inst-1'));
      await run;
      expect(log, ['local:${trigger.name}', 'net:${trigger.name}']);
    });
  }

  test('a different server blocks network members; local ones still run',
      () async {
    final repo = ServerBindingRepository(db);
    final token = (await repo.current())!.localBindingId;
    await repo.recordVerified(token, instanceId: 'inst-1', baseUrl: 'http://a');
    unawaited(recovery().runFor(RecoveryTrigger.appResume));
    await pumpEventQueue();
    probes.single.complete(const ServerIdentity('inst-2'));
    await pumpEventQueue();
    expect(gate.state, isA<BindingDifferentServer>());
    expect(log, ['local:appResume']);
  });

  // Audit 5A.0(a) #1: a run waiting on the gate must not swallow later edges.
  test('every edge re-verifies and runs local members, even while an earlier '
      'run still waits on the gate', () async {
    final repo = ServerBindingRepository(db);
    final token = (await repo.current())!.localBindingId;
    await repo.recordVerified(token, instanceId: 'inst-1', baseUrl: 'http://a');
    final first = recovery().runFor(RecoveryTrigger.appResume);
    await pumpEventQueue();
    probes.single.complete(const ServerIdentity('inst-2')); // blocked
    await pumpEventQueue();
    expect(gate.state, isA<BindingDifferentServer>());

    final second = recovery().runFor(RecoveryTrigger.appResume);
    await pumpEventQueue();
    expect(probes, hasLength(2), reason: 'the second edge re-verifies');
    expect(log, ['local:appResume', 'local:appResume']);

    probes[1].complete(const ServerIdentity('inst-1')); // the bound server
    await first;
    await second;
    // Later edges join the waiting network phase: it runs exactly once.
    expect(log.where((l) => l == 'net:appResume'), hasLength(1));
  });

  test('when already verified, coldStart network members run promptly',
      () async {
    unawaited(gate.startConnection('http://a'));
    await pumpEventQueue();
    probes.single.complete(const ServerIdentity('inst-1'));
    await gate.awaitVerified();
    await recovery().runFor(RecoveryTrigger.coldStart);
    expect(log, ['local:coldStart', 'net:coldStart']);
    expect(probes, hasLength(1));
  });

  test('the real members declare which need the binding', () {
    final real = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(real.dispose);
    final byPriority = {
      for (final m in real.read(recoverablesProvider))
        m.recoveryPriority: m.requiresBinding,
    };
    expect(byPriority, {
      RecoveryPriority.sync: true,
      RecoveryPriority.appInfo: true,
      RecoveryPriority.resumeDownloads: true,
      RecoveryPriority.resumeConversions: true,
      RecoveryPriority.reconcileDownloads: false,
    });
  });
}
