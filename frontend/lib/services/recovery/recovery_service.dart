import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/recovery/recoverable.dart';

/// Drives best-effort "catch up after a gap" work across the app.
///
/// The service reads [recoverablesProvider] for the registered set, keeps only
/// the members that opted into the firing [RecoveryTrigger], sorts by
/// descending [RecoverableService.recoveryPriority], and invokes each inside
/// its own try/catch so a failure in one subsystem cannot strand the rest.
///
/// Unlike [LocalResetService] this **never throws**: recovery is background
/// catch-up reached through fire-and-forget call sites, so failures are logged
/// and swallowed rather than surfaced to the user. New work joins the flow by
/// implementing [RecoverableService] (or adding a thin adapter) and adding
/// itself to [recoverablesProvider] — no edits to this class required.
class RecoveryService {
  RecoveryService(this._ref);

  final Ref _ref;

  /// One in-flight run per trigger. A second [runFor] for a trigger that is
  /// still running dedupes onto the live run instead of starting a parallel
  /// one — this absorbs the offline↔online *flap* (and back-to-back
  /// cold-start/resume) without dropping a different trigger's work, since
  /// distinct triggers keep independent entries.
  final Map<RecoveryTrigger, Future<void>> _inFlight = {};

  /// Runs every member registered for [trigger], in priority order. Safe to
  /// fire-and-forget: the returned future always completes normally.
  Future<void> runFor(RecoveryTrigger trigger) {
    // NB: the `whenComplete` callback must be a statement body, not an arrow.
    // `Map.remove` returns the removed value — here the in-flight future
    // itself — and an arrow callback would hand that back to `whenComplete`,
    // which then waits on the very future it is completing (self-deadlock).
    return _inFlight[trigger] ??= _run(trigger).whenComplete(() {
      _inFlight.remove(trigger);
    });
  }

  Future<void> _run(RecoveryTrigger trigger) async {
    final members =
        _ref
            .read(recoverablesProvider)
            .where((r) => r.triggers.contains(trigger))
            .toList()
          ..sort((a, b) => b.recoveryPriority.compareTo(a.recoveryPriority));

    final failures = <RecoveryFailure>[];
    for (final member in members) {
      try {
        await member.recover(trigger);
      } catch (e, st) {
        // Continue — one broken subsystem must not stop the others catching
        // up. Failures are aggregated and logged below; recovery is
        // best-effort so there is nothing to surface to the caller.
        failures.add(RecoveryFailure(member.runtimeType, e, st));
      }
    }

    if (failures.isNotEmpty) {
      final ex = RecoveryException(trigger, failures);
      developer.log(
        ex.toString(),
        name: 'recovery',
        error: ex,
      );
    }
  }
}

/// One subsystem's failure during a [RecoveryService.runFor] pass. Kept as a
/// distinct type (mirroring `LocalResetFailure`) so the aggregate log can
/// name which steps failed without string-parsing.
class RecoveryFailure {
  RecoveryFailure(this.subsystem, this.error, this.stackTrace);

  final Type subsystem;
  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => '$subsystem: $error';
}

/// Aggregates the failures from a single recovery pass. Built and logged
/// internally — never thrown to callers — but kept as a type so the log line
/// is structured and a future surface (e.g. a debug panel) can reuse it.
class RecoveryException implements Exception {
  RecoveryException(this.trigger, this.failures);

  final RecoveryTrigger trigger;
  final List<RecoveryFailure> failures;

  @override
  String toString() =>
      'RecoveryException(${trigger.name}): ${failures.length} subsystem(s) '
      'failed to recover (${failures.join('; ')})';
}

final recoveryServiceProvider = Provider<RecoveryService>((ref) {
  return RecoveryService(ref);
});

/// Subsystems registered for the recovery flow. Each entry is a small adapter
/// over a `Ref`-driven notifier or service. Order does not matter —
/// [RecoveryService] sorts by priority. Keeping the list flat (vs. scattering
/// registration across providers) makes the full set of catch-up steps
/// greppable from one place, exactly like `localResettablesProvider`.
final recoverablesProvider = Provider<List<RecoverableService>>((ref) {
  return <RecoverableService>[
    _SyncRecoverable(ref),
    _ResumeDownloadsRecoverable(ref),
    _ReconcileDownloadsRecoverable(ref),
  ];
});

// ── Adapters ────────────────────────────────────────────────────────────
//
// Adapters wrap recovery steps whose owning class is reached through [Ref]
// (Riverpod notifiers/services) rather than implementing [RecoverableService]
// on the subsystem directly.

/// Pulls `/changes` when the network returns. The notifier already no-ops
/// while offline and self-guards against overlapping syncs via `isSyncing`.
class _SyncRecoverable implements RecoverableService {
  _SyncRecoverable(this._ref);
  final Ref _ref;

  @override
  int get recoveryPriority => RecoveryPriority.sync;

  @override
  Set<RecoveryTrigger> get triggers => const {RecoveryTrigger.networkRecovered};

  @override
  Future<void> recover(RecoveryTrigger trigger) =>
      _ref.read(trackSyncProvider.notifier).sync();
}

/// Re-dispatches downloads that were left queued while offline. Runs after
/// [_SyncRecoverable] so resumed workers see the just-synced rows.
class _ResumeDownloadsRecoverable implements RecoverableService {
  _ResumeDownloadsRecoverable(this._ref);
  final Ref _ref;

  @override
  int get recoveryPriority => RecoveryPriority.resumeDownloads;

  @override
  Set<RecoveryTrigger> get triggers => const {RecoveryTrigger.networkRecovered};

  @override
  Future<void> recover(RecoveryTrigger trigger) async {
    _ref.read(downloadManagerProvider).resumeIfPaused();
  }
}

/// Clears `tracks.file_path` rows whose file vanished outside the app. Fires
/// on cold start and resume (filesystem can change while backgrounded) — not
/// on network recovery. `reconcile()` already dedupes concurrent runs itself;
/// the registry's per-trigger guard is belt-and-suspenders on top.
class _ReconcileDownloadsRecoverable implements RecoverableService {
  _ReconcileDownloadsRecoverable(this._ref);
  final Ref _ref;

  @override
  int get recoveryPriority => RecoveryPriority.reconcileDownloads;

  @override
  Set<RecoveryTrigger> get triggers =>
      const {RecoveryTrigger.coldStart, RecoveryTrigger.appResume};

  @override
  Future<void> recover(RecoveryTrigger trigger) =>
      _ref.read(downloadReconciliationServiceProvider).reconcile();
}
