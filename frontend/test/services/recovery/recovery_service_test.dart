import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';

/// Records every trigger it recovers for, in order. Used to assert the
/// priority-sorted, trigger-filtered invocation contract.
class _Recording implements RecoverableService {
  _Recording(this.label, this.priority, this.triggers, this.log);

  final String label;
  final int priority;
  @override
  final Set<RecoveryTrigger> triggers;
  final List<String> log;

  @override
  int get recoveryPriority => priority;

  @override
  Future<void> recover(RecoveryTrigger trigger) async {
    log.add(label);
  }
}

/// Throws on recover to verify per-member try/catch isolation.
class _Throwing implements RecoverableService {
  _Throwing(this.priority, this.triggers, this.log);

  final int priority;
  @override
  final Set<RecoveryTrigger> triggers;
  final List<String> log;

  @override
  int get recoveryPriority => priority;

  @override
  Future<void> recover(RecoveryTrigger trigger) async {
    log.add('threw');
    throw StateError('boom');
  }
}

/// Blocks inside [recover] until [release] is completed, so a test can hold a
/// run open and fire a second [RecoveryService.runFor] against it.
class _Blocking implements RecoverableService {
  _Blocking(this.triggers, this.log);

  @override
  final Set<RecoveryTrigger> triggers;
  final List<String> log;
  final Completer<void> release = Completer<void>();
  int calls = 0;

  @override
  int get recoveryPriority => 0;

  @override
  Future<void> recover(RecoveryTrigger trigger) async {
    calls++;
    log.add('start');
    await release.future;
    log.add('end');
  }
}

ProviderContainer _containerWith(List<RecoverableService> registry) {
  final container = ProviderContainer(
    overrides: [recoverablesProvider.overrideWithValue(registry)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('RecoveryService trigger filtering + ordering', () {
    test(
      'runs only members registered for the trigger, in descending priority',
      () async {
        final log = <String>[];
        final container = _containerWith([
          _Recording('sync', RecoveryPriority.sync,
              const {RecoveryTrigger.networkRecovered}, log),
          _Recording('resume', RecoveryPriority.resumeDownloads,
              const {RecoveryTrigger.networkRecovered}, log),
          // Different trigger — must be skipped on networkRecovered.
          _Recording('reconcile', RecoveryPriority.reconcileDownloads,
              const {RecoveryTrigger.coldStart, RecoveryTrigger.appResume}, log),
        ]);

        await container
            .read(recoveryServiceProvider)
            .runFor(RecoveryTrigger.networkRecovered);

        // sync (100) before resume (80); reconcile excluded.
        expect(log, ['sync', 'resume']);
      },
    );

    test('priority sort is independent of registration order', () async {
      final log = <String>[];
      const t = {RecoveryTrigger.networkRecovered};
      final container = _containerWith([
        _Recording('low', 10, t, log),
        _Recording('high', 100, t, log),
        _Recording('mid', 50, t, log),
      ]);

      await container
          .read(recoveryServiceProvider)
          .runFor(RecoveryTrigger.networkRecovered);

      expect(log, ['high', 'mid', 'low']);
    });

    test('a member firing on multiple triggers runs on each', () async {
      final log = <String>[];
      final container = _containerWith([
        _Recording('reconcile', RecoveryPriority.reconcileDownloads,
            const {RecoveryTrigger.coldStart, RecoveryTrigger.appResume}, log),
      ]);
      final service = container.read(recoveryServiceProvider);

      await service.runFor(RecoveryTrigger.coldStart);
      await service.runFor(RecoveryTrigger.appResume);
      // Not registered for networkRecovered — no-op.
      await service.runFor(RecoveryTrigger.networkRecovered);

      expect(log, ['reconcile', 'reconcile']);
    });
  });

  group('RecoveryService failure isolation', () {
    test('a throwing member does not abort the rest and never throws', () async {
      final log = <String>[];
      const t = {RecoveryTrigger.networkRecovered};
      final container = _containerWith([
        _Recording('first', 100, t, log),
        _Throwing(50, t, log),
        _Recording('last', 10, t, log),
      ]);

      // Must complete normally — recovery is fire-and-forget and never
      // surfaces failure to the caller.
      await expectLater(
        container
            .read(recoveryServiceProvider)
            .runFor(RecoveryTrigger.networkRecovered),
        completes,
      );

      expect(log, ['first', 'threw', 'last']);
    });
  });

  group('RecoveryService per-trigger re-entrancy', () {
    test('a second run for an in-flight trigger dedupes onto it', () async {
      final log = <String>[];
      final blocking =
          _Blocking(const {RecoveryTrigger.networkRecovered}, log);
      final container = _containerWith([blocking]);
      final service = container.read(recoveryServiceProvider);

      final first = service.runFor(RecoveryTrigger.networkRecovered);
      final second = service.runFor(RecoveryTrigger.networkRecovered);

      // Same in-flight run handed back — the flap did not start a 2nd pass.
      expect(identical(first, second), isTrue);

      blocking.release.complete();
      await Future.wait([first, second]);

      expect(blocking.calls, 1);
      expect(log, ['start', 'end']);

      // After completion the guard must clear: a later edge on the SAME
      // service re-runs the body. `release` is already completed, so this run
      // finishes immediately and bumps `calls` to 2. If `_inFlight.remove`
      // were dropped, this `runFor` would dedupe onto the finished first run
      // and `calls` would stay 1 — so this asserts the entry was cleared.
      final third = service.runFor(RecoveryTrigger.networkRecovered);
      expect(identical(third, first), isFalse);
      await third;
      expect(blocking.calls, 2);
    });

    test('different triggers run concurrently, not blocked by each other',
        () async {
      final log = <String>[];
      final coldBlocking = _Blocking(const {RecoveryTrigger.coldStart}, log);
      final netBlocking =
          _Blocking(const {RecoveryTrigger.networkRecovered}, log);
      final container = _containerWith([coldBlocking, netBlocking]);
      final service = container.read(recoveryServiceProvider);

      final cold = service.runFor(RecoveryTrigger.coldStart);
      final net = service.runFor(RecoveryTrigger.networkRecovered);

      // Both bodies entered before either released — distinct triggers do not
      // serialize against one another.
      await Future<void>.delayed(Duration.zero);
      expect(coldBlocking.calls, 1);
      expect(netBlocking.calls, 1);

      coldBlocking.release.complete();
      netBlocking.release.complete();
      await Future.wait([cold, net]);
    });
  });

  group('recoverablesProvider default registration', () {
    test(
      'advertises sync, app-info, resume-downloads, resume-conversions, and '
      'reconcile adapters',
      () {
        // No member overrides — exercises the real default list. The adapters
        // are private, so assert by count + trigger coverage rather than type.
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final registered = container.read(recoverablesProvider);
        expect(registered, hasLength(5));

        final networkMembers = registered
            .where((r) => r.triggers.contains(RecoveryTrigger.networkRecovered))
            .toList();
        expect(networkMembers, hasLength(4),
            reason: 'sync + app-info + resume-downloads + resume-conversions '
                'fire on network recovery');

        final coldMembers = registered
            .where((r) => r.triggers.contains(RecoveryTrigger.coldStart))
            .toList();
        expect(coldMembers, hasLength(2),
            reason: 'reconcile + resume-conversions fire on cold start');

        final conversionMembers = registered
            .where((r) =>
                r.recoveryPriority == RecoveryPriority.resumeConversions)
            .toList();
        expect(conversionMembers, hasLength(1));
        expect(
          conversionMembers.single.triggers,
          containsAll(<RecoveryTrigger>{
            RecoveryTrigger.networkRecovered,
            RecoveryTrigger.coldStart,
            RecoveryTrigger.appResume,
          }),
          reason: 'conversion polling restarts on reconnect and catches up '
              'on cold start and resume',
        );

        final reconcileMembers = coldMembers
            .where((r) => r.recoveryPriority == RecoveryPriority.reconcileDownloads)
            .toList();
        expect(reconcileMembers, hasLength(1));
        expect(
          reconcileMembers.single.triggers,
          contains(RecoveryTrigger.appResume),
          reason: 'reconcile also fires on resume',
        );
      },
    );

    test('network recovery re-fetches app capabilities', () async {
      // After an offline cold start appInfoProvider holds the cached/default
      // capabilities (no `convert` action); it must reload once the server is
      // reachable or the Convert entry stays hidden all session.
      var loads = 0;
      final container = ProviderContainer(
        overrides: [
          appInfoProvider.overrideWith((ref) async {
            loads++;
            return defaultAppInfo();
          }),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appInfoProvider.future);
      expect(loads, 1);

      final member = container
          .read(recoverablesProvider)
          .where((r) => r.recoveryPriority == RecoveryPriority.appInfo)
          .single;
      expect(member.triggers, {RecoveryTrigger.networkRecovered});

      await member.recover(RecoveryTrigger.networkRecovered);
      expect(loads, 2, reason: 'invalidated and re-loaded');
    });

    test('sync also fires on app resume', () {
      // A server-side change made while the app was backgrounded (an edit
      // from this device or another, an artist rename that orphans a local
      // card, etc.) is only ever caught up by a `/changes` pull. Resume is
      // the ordinary "picked the phone back up" edge — the same rationale
      // `_ReconcileDownloadsRecoverable` already uses for reconcile above —
      // so sync should run there too, not only on `networkRecovered`.
      //
      // It currently doesn't: `_SyncRecoverable.triggers` is just
      // `{networkRecovered}`. Until a resync happens to be triggered by some
      // other page mounting (Artists/Albums/Tracks `initState`), a plain
      // background-then-foreground cycle leaves stale/orphaned local state
      // (e.g. an artist card with zero remaining tracks) on screen
      // indefinitely.
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final syncMembers = container
          .read(recoverablesProvider)
          .where((r) => r.triggers.contains(RecoveryTrigger.networkRecovered))
          .where((r) => r.recoveryPriority == RecoveryPriority.sync)
          .toList();
      expect(syncMembers, hasLength(1), reason: 'the sync adapter exists');
      expect(
        syncMembers.single.triggers,
        contains(RecoveryTrigger.appResume),
        reason:
            'sync only runs on networkRecovered — resuming the app from '
            'the background never re-pulls `/changes`, so server-side '
            'changes (like an artist rename that orphans a local card) '
            'are not reconciled just by foregrounding the app',
      );
    });
  });
}
