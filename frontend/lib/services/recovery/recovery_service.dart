import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/server_binding_gate.dart';

/// Drives best-effort "catch up after a gap" work across the app.
///
/// The service reads [recoverablesProvider] for the registered set, keeps only
/// the members that opted into the firing [RecoveryTrigger], sorts by
/// descending [RecoverableService.recoveryPriority], and invokes each inside
/// its own try/catch so a failure in one subsystem cannot strand the rest.
///
/// SC-01 rule 1: members that need no network ([RecoverableService.
/// requiresBinding] false) run right away; the network-backed ones run only
/// once the binding gate has verified the current connection.
/// `networkRecovered` and `appResume` are connection edges, so each starts a
/// new verification first. A different server keeps the network-backed
/// members waiting (blocked); the gate closing with the scope ends the run.
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
  /// still running its members dedupes onto the live run instead of
  /// starting a parallel one — this absorbs the offline↔online *flap* (and
  /// back-to-back cold-start/resume) without dropping a different trigger's
  /// work, since distinct triggers keep independent entries. A run that is
  /// only WAITING on the binding gate releases its entry, so a later edge
  /// still re-verifies and runs its local members (D12, D14).
  final Map<RecoveryTrigger, Future<void>> _inFlight = {};

  /// The network-backed phase per trigger, waiting on the binding gate or
  /// running: later runs of the trigger join it instead of duplicating it.
  final Map<RecoveryTrigger, Future<void>> _networkPhase = {};

  /// Runs every member registered for [trigger], in priority order. Safe to
  /// fire-and-forget: the returned future always completes normally.
  Future<void> runFor(RecoveryTrigger trigger) {
    final running = _inFlight[trigger];
    if (running != null) return running;
    final done = Completer<void>();
    _inFlight[trigger] = done.future;
    void release() {
      if (identical(_inFlight[trigger], done.future)) {
        _inFlight.remove(trigger);
      }
    }

    _run(trigger, release)
        .catchError((Object e, StackTrace st) {
          developer.log('recovery run failed', name: 'recovery', error: e);
        })
        .whenComplete(() {
          release();
          done.complete();
        });
    return done.future;
  }

  Future<void> _run(RecoveryTrigger trigger, void Function() release) async {
    final members =
        _ref
            .read(recoverablesProvider)
            .where((r) => r.triggers.contains(trigger))
            .toList()
          ..sort((a, b) => b.recoveryPriority.compareTo(a.recoveryPriority));

    // A connection edge re-verifies the binding, for the network-backed
    // members (the only ones that need it).
    final networked = members.where((m) => m.requiresBinding).toList();
    final gate = networked.isEmpty
        ? null
        : _ref.read(serverBindingGateProvider);
    if (gate != null &&
        (trigger == RecoveryTrigger.networkRecovered ||
            trigger == RecoveryTrigger.appResume)) {
      unawaited(gate.startConnection(ApiClient.instance.baseUrl));
    }

    await _runAll(trigger, members.where((m) => !m.requiresBinding));
    if (gate == null) return;
    // Waiting on the gate can take arbitrarily long (offline, a different
    // server): don't let it swallow later edges of this trigger.
    release();
    // NB: a statement body, not an arrow — `Map.remove` returns the phase
    // future itself, and whenComplete would then wait on it (self-deadlock).
    await (_networkPhase[trigger] ??= _runNetworked(
      trigger,
      gate,
      networked,
    ).whenComplete(() {
      _networkPhase.remove(trigger);
    }));
  }

  Future<void> _runNetworked(
    RecoveryTrigger trigger,
    ServerBindingGate gate,
    List<RecoverableService> networked,
  ) async {
    try {
      await gate.awaitVerified();
    } on BindingGateClosedException {
      // The scope was disposed (reset/disconnect): nothing left to catch up.
      return;
    }
    await _runAll(trigger, networked);
  }

  /// Invokes each of [group] in order, isolating failures (one broken
  /// subsystem must not stop the others catching up); failures are logged,
  /// never surfaced — recovery is best-effort.
  Future<void> _runAll(
    RecoveryTrigger trigger,
    Iterable<RecoverableService> group,
  ) async {
    final failures = <RecoveryFailure>[];
    for (final member in group) {
      try {
        await member.recover(trigger);
      } catch (e, st) {
        failures.add(RecoveryFailure(member.runtimeType, e, st));
      }
    }
    if (failures.isNotEmpty) {
      final ex = RecoveryException(trigger, failures);
      developer.log(ex.toString(), name: 'recovery', error: ex);
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
    _AppInfoRecoverable(ref),
    _ResumeDownloadsRecoverable(ref),
    _ResumeConversionsRecoverable(ref),
    _ReconcileDownloadsRecoverable(ref),
    _HistoryRecoverable(ref),
  ];
});

// ── Adapters ────────────────────────────────────────────────────────────
//
// Adapters wrap recovery steps whose owning class is reached through [Ref]
// (Riverpod notifiers/services) rather than implementing [RecoverableService]
// on the subsystem directly.

/// Pulls `/changes` when the network returns, and on every app resume — a
/// server-side change made while backgrounded (an edit from another device,
/// a rename that orphans a local card) is otherwise only caught up by
/// whichever page happens to call `sync()` itself next. The notifier
/// already no-ops while offline and self-guards against overlapping syncs
/// via `isSyncing`.
class _SyncRecoverable implements RecoverableService {
  _SyncRecoverable(this._ref);
  final Ref _ref;

  @override
  bool get requiresBinding => true;

  @override
  int get recoveryPriority => RecoveryPriority.sync;

  @override
  Set<RecoveryTrigger> get triggers =>
      const {RecoveryTrigger.networkRecovered, RecoveryTrigger.appResume};

  @override
  Future<void> recover(RecoveryTrigger trigger) =>
      _ref.read(trackSyncProvider.notifier).sync();
}

/// Refreshes [appInfoProvider] when the network returns. Its value is only
/// fetched from the server while online; after an offline cold start it holds
/// the cached/default capabilities, which (by design) never advertise the
/// `convert` action -- without this the Convert entry would stay hidden for
/// the rest of the session.
class _AppInfoRecoverable implements RecoverableService {
  _AppInfoRecoverable(this._ref);
  final Ref _ref;

  @override
  bool get requiresBinding => true;

  @override
  int get recoveryPriority => RecoveryPriority.appInfo;

  @override
  Set<RecoveryTrigger> get triggers => const {RecoveryTrigger.networkRecovered};

  @override
  Future<void> recover(RecoveryTrigger trigger) async {
    _ref.invalidate(appInfoProvider);
    await _ref.read(appInfoProvider.future);
  }
}

/// Re-dispatches downloads that were left queued while offline. Runs after
/// [_SyncRecoverable] so resumed workers see the just-synced rows.
class _ResumeDownloadsRecoverable implements RecoverableService {
  _ResumeDownloadsRecoverable(this._ref);
  final Ref _ref;

  @override
  bool get requiresBinding => true;

  @override
  int get recoveryPriority => RecoveryPriority.resumeDownloads;

  @override
  Set<RecoveryTrigger> get triggers => const {RecoveryTrigger.networkRecovered};

  @override
  Future<void> recover(RecoveryTrigger trigger) async {
    _ref.read(downloadManagerProvider).resumeIfPaused();
  }
}

/// Resumes polling any conversion job still queued/running server-side --
/// across a reconnect (polling is gated on online, so it stops while
/// offline and must be restarted here), an app restart (no poll timer
/// survives a process restart, but the backend job can still be mid-flight),
/// or an app resume (a job may have finished while backgrounded). Each run
/// also settles tracked jobs that finished during the gap.
class _ResumeConversionsRecoverable implements RecoverableService {
  _ResumeConversionsRecoverable(this._ref);
  final Ref _ref;

  @override
  bool get requiresBinding => true;

  @override
  int get recoveryPriority => RecoveryPriority.resumeConversions;

  @override
  Set<RecoveryTrigger> get triggers => const {
    RecoveryTrigger.networkRecovered,
    RecoveryTrigger.coldStart,
    RecoveryTrigger.appResume,
  };

  @override
  Future<void> recover(RecoveryTrigger trigger) =>
      _ref.read(conversionJobsProvider.notifier).refreshAll();
}

/// Clears `tracks.file_path` rows whose file vanished outside the app. Fires
/// on cold start and resume (filesystem can change while backgrounded) — not
/// on network recovery. `reconcile()` already dedupes concurrent runs itself;
/// the registry's per-trigger guard is belt-and-suspenders on top.
class _ReconcileDownloadsRecoverable implements RecoverableService {
  _ReconcileDownloadsRecoverable(this._ref);
  final Ref _ref;

  @override
  bool get requiresBinding => false;

  @override
  int get recoveryPriority => RecoveryPriority.reconcileDownloads;

  @override
  Set<RecoveryTrigger> get triggers =>
      const {RecoveryTrigger.coldStart, RecoveryTrigger.appResume};

  @override
  Future<void> recover(RecoveryTrigger trigger) =>
      _ref.read(downloadReconciliationServiceProvider).reconcile();
}

/// Requests a history pass (upload, then pull) on every edge. Never runs the
/// pass body itself; recovery edges (not cold start) bypass a pending
/// backoff so a reconnect syncs now.
class _HistoryRecoverable implements RecoverableService {
  _HistoryRecoverable(this._ref);
  final Ref _ref;

  @override
  bool get requiresBinding => true;

  @override
  int get recoveryPriority => RecoveryPriority.history;

  @override
  Set<RecoveryTrigger> get triggers => RecoveryTrigger.values.toSet();

  @override
  Future<void> recover(RecoveryTrigger trigger) async {
    _ref
        .read(historyRunnerProvider)
        .request(
          trigger.name,
          bypassBackoff: trigger != RecoveryTrigger.coldStart,
        );
  }
}
