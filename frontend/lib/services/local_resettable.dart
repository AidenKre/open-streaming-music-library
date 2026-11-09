/// Contract for any subsystem whose local state must be wiped on a full
/// reset (e.g. disconnect, log out, "forget this device").
///
/// New persistent subsystems implement this and register themselves in
/// `localResettablesProvider`. `LocalResetService` sorts by priority and
/// invokes each one, isolating failures so one broken subsystem cannot
/// strand the rest in a half-reset state.
abstract class LocalResettable {
  /// Higher priorities run first. Use the constants on [ResetPriority] so
  /// the ordering between subsystems stays explicit.
  int get resetPriority;

  /// Wipes this subsystem's local state. Must be idempotent — reset can
  /// be triggered multiple times, including after a partial earlier run.
  Future<void> resetLocalState();
}

/// Priority slots that encode the dependency order between reset steps.
///
/// The ordering matters: background work must stop before its inputs are
/// deleted; files must be removed before the DB rows that reference them;
/// the transport URL is cleared last so any in-flight retry sees the
/// already-cleared state instead of racing it.
class ResetPriority {
  static const stopBackgroundWork = 100; // audio playback, polling
  static const cancelInFlight = 80; // download workers
  static const deleteFiles = 60;
  static const clearCaches = 40;
  static const wipeDatabase = 20;
  static const clearPreferences = 10;
  static const clearTransport = 0;
}

/// SC-15 step 2 participant: stops timers, cancels network work and settles
/// in-flight DB work when a reset starts (after the fence). Registered in
/// `localQuiescablesProvider`; best effort, bounded by a timeout.
abstract interface class Quiescable {
  /// Names the participant in reset diagnostics.
  String get quiesceName;

  Future<void> quiesce();
}

/// Contributes a line to the Disconnect confirmation's "will be lost" copy
/// (SC-15), or null when it has nothing pending. Registered in
/// `lossReportersProvider`.
abstract interface class LossReporter {
  Future<String?> pendingLossSummary();
}
