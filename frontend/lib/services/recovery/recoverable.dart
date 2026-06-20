/// What kind of "the app can catch up now" edge triggered a recovery run.
///
/// A subsystem registers for the subset of edges it actually cares about, so
/// one registry can own work with genuinely different triggers without forcing
/// every member to run on every edge. This is the key difference from the
/// reset flow, which has a single trigger.
enum RecoveryTrigger {
  /// The app process just started.
  coldStart,

  /// The app returned to the foreground (`AppLifecycleState.resumed`).
  appResume,

  /// Local-only mode just cleared — the backend is reachable again
  /// (`offlineModeProvider` went `true → false`).
  networkRecovered,
}

/// Contract for any subsystem with "catch up after a gap" work — sync,
/// resume paused downloads, reconcile local files against the DB.
///
/// New recovery work implements this (or a thin adapter) and registers in
/// `recoverablesProvider`. `RecoveryService` filters by [triggers], sorts by
/// [recoveryPriority], and invokes each member with failure isolation so one
/// broken subsystem cannot strand the rest.
///
/// Kept deliberately **distinct** from the reset registry
/// (`LocalResettable`/`ResetPriority`): reset wipes state and surfaces partial
/// failure to the user; recovery is best-effort background catch-up.
abstract class RecoverableService {
  /// Higher priorities run first. Use the constants on [RecoveryPriority] so
  /// the ordering between subsystems stays explicit.
  int get recoveryPriority;

  /// Which edges this subsystem responds to. A run for a trigger not in this
  /// set skips the subsystem entirely.
  Set<RecoveryTrigger> get triggers;

  /// Performs this subsystem's catch-up work for [trigger]. Must be safe to
  /// call repeatedly — recovery edges can flap (offline↔online) and resume
  /// can fire back-to-back with cold start.
  Future<void> recover(RecoveryTrigger trigger);
}

/// Priority slots that encode the order recovery steps must run in.
///
/// The ordering matters where one step's output feeds another: on a network
/// recovery, sync must land new/removed rows before resumed download workers
/// re-dispatch against them, so [sync] sorts above [resumeDownloads].
class RecoveryPriority {
  /// Pull `/changes` so local data reflects the server before anything reads
  /// it.
  static const sync = 100;

  /// Re-dispatch downloads that were left queued while offline.
  static const resumeDownloads = 80;

  /// Reconcile `tracks.file_path` against the filesystem (cold start / resume).
  static const reconcileDownloads = 60;
}
