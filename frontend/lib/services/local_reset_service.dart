import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/auth_api.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/dead_sign_in_records.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/history/listen_recorder.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/storage/owned_file_cleanup_providers.dart';
import 'package:frontend/services/session_event_log.dart';
import 'package:frontend/services/uploads/upload_manager.dart';

/// Coordinates a full local reset of frontend-owned state in three steps
/// (SC-15):
///
///  1. **Fence** (first, awaited): bump the in-memory [generation]
///     synchronously, then delete the SC-01 binding row so every in-flight
///     durable write becomes a no-op. If the delete fails, the reset aborts
///     with [LocalResetAbortedException] before quiesce or wipe.
///  2. **Quiesce** (best effort, bounded by [quiesceTimeout] each): the
///     [localQuiescablesProvider] participants, in list order, stop timers
///     and settle in-flight work. Failures and timeouts are reported but
///     never block the wipe: the fence already protects the new store.
///  3. **Wipe**: [localResettablesProvider] sorted by descending
///     [LocalResettable.resetPriority], each step inside its own try/catch
///     so a failure in one subsystem cannot strand the rest in a
///     half-reset state.
///
/// A durable `resetPending` flag (review major 2, user 2026-11-09) is saved
/// before the fence and cleared only once every wipe step succeeded. A reset
/// the app was killed in, or whose wipe failed, is finished by
/// [completePendingReset] at the next launch or login, before anything
/// binds or syncs, so the next server can never adopt the old store.
///
/// Quiesce and wipe failures are aggregated into one [LocalResetException].
/// New subsystems join by implementing [Quiescable] / [LocalResettable]
/// (or adding a thin adapter) and registering in the providers — no edits
/// to this class required.
class LocalResetService {
  LocalResetService(
    this._ref, {
    this.quiesceTimeout = const Duration(seconds: 5),
  });

  final Ref _ref;
  final Duration quiesceTimeout;

  /// The in-memory session generation (SC-15 step 1), bumped synchronously
  /// when a reset starts. In-memory work started before a reset compares it
  /// to drop its result (durable writes are fenced by the binding row
  /// instead); the scope rebuild discards everything else. Its first readers
  /// are the 5A background runners (SingleFlightRunner).
  int get generation => _generation;
  int _generation = 0;

  /// The Disconnect confirmation's "will be lost" lines, one per
  /// [LossReporter] that has something pending, in registry order. A
  /// reporter that fails is unknown, not zero: it contributes
  /// [uncountedLossSummary] (once per call) instead of being dropped, so this
  /// never throws because of a reporter.
  Future<List<String>> pendingLossSummaries() async {
    final summaries = <String>[];
    var uncounted = false;
    for (final reporter in _ref.read(lossReportersProvider)) {
      try {
        final summary = await reporter.pendingLossSummary();
        if (summary != null) summaries.add(summary);
      } catch (_) {
        if (!uncounted) summaries.add(uncountedLossSummary);
        uncounted = true;
      }
    }
    return summaries;
  }

  static const uncountedLossSummary =
      'Some unsent changes could not be counted';

  /// The SharedPreferences key of the durable reset marker. The prefs wipe
  /// keeps it; only a fully successful wipe removes it.
  static const resetPendingKey = 'resetPending';

  /// A reset started and has not finished its wipe (killed, or a wipe step
  /// failed): [completePendingReset] must run before anything binds.
  Future<bool> hasPendingReset() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    return prefs.getBool(resetPendingKey) ?? false;
  }

  /// Whether the session token may be sent to the revoke target: the app is
  /// not offline (after an outage the host at the saved address is in doubt,
  /// a network switch can put another host there; review F1), and the gate
  /// verified the bound instance at the revoke client's base URL in this
  /// scope and no check failed since (a re-probe in flight doesn't forget
  /// it). Read before the gate is stopped or closed.
  bool _gateVerified() =>
      !_ref.read(offlineModeProvider) &&
      _ref
          .read(serverBindingGateProvider)
          .maySendTokenTo(_ref.read(apiClientProvider).baseUrl);

  /// The one-shot revoke client (sign-off OPEN-M-11), taken at the same
  /// entry point as [_gateVerified] while the lenient revoke rule holds; null
  /// when it does not.
  ApiClient? _takeRevoker(bool verified) =>
      verified ? _ref.read(apiClientProvider).revokeOnceClient() : null;

  /// Revokes the scope's session, best effort, when signed in and a revoker
  /// was taken.
  Future<void> _revokeWith(ApiClient? revoker) async {
    if (revoker != null && _ref.read(credentialsProvider) != null) {
      await revokeBestEffort(revoker);
    }
  }

  Future<void> reset() async {
    final verified = _gateVerified();
    final revoker = _takeRevoker(verified);
    // 1. Fence. The generation bump happens before the first await. The
    // pending marker is saved first: a kill from here on is finished by the
    // next launch.
    _generation++;
    try {
      final prefs = await _ref.read(sharedPreferencesProvider.future);
      if (!await prefs.setBool(resetPendingKey, true)) {
        throw StateError('the reset marker could not be saved');
      }
      await _ref.read(serverBindingRepositoryProvider).fence();
    } catch (e) {
      // A wipe would most likely fail too: report and stop. (A saved marker
      // makes the next launch wipe anyway, as the user asked for.)
      throw LocalResetAbortedException(e);
    }
    _stopGate();

    final failures = <LocalResetFailure>[];

    // 2. Quiesce.
    for (final q in _ref.read(localQuiescablesProvider)) {
      try {
        await q.quiesce().timeout(quiesceTimeout);
      } catch (e, st) {
        failures.add(LocalResetFailure(q.runtimeType, e, st, quiesce: true));
      }
    }

    // Disconnect also revokes the session (best effort), once the fence held
    // and old-scope work is quiesced, before the wipe deletes the credentials.
    await _revokeWith(revoker);

    // 3. Wipe.
    await _wipe(failures);
    if (failures.isNotEmpty) {
      throw LocalResetException(failures);
    }
  }

  /// Logout (spec 7.6): not a reset, so no marker and no wipe. Bumps the
  /// generation, quiesces (playback admission first, then listens and
  /// history, so the last checkpoint lands), rotates the binding token so
  /// late writes from the old scope are no-ops, stops the gate, revokes the
  /// session best effort, and deletes the stored credentials. Right after the
  /// rotation, earlier sign-ins' upload and deletion records are removed
  /// (best effort, local only), unless [keepUnsent]: then they stay for the
  /// same user's next login. The saved URL
  /// and every local store stay. Every step runs even if an earlier one
  /// fails; failures (quiesce ones flagged) are thrown together, except that
  /// quiesce failures alone do not throw.
  Future<void> signOut({bool keepUnsent = false}) async {
    final verified = _gateVerified();
    final revoker = _takeRevoker(verified);
    _generation++;
    final failures = <LocalResetFailure>[];
    for (final q in _ref.read(localQuiescablesProvider)) {
      try {
        await q.quiesce().timeout(quiesceTimeout);
      } catch (e, st) {
        failures.add(LocalResetFailure(q.runtimeType, e, st, quiesce: true));
      }
    }
    // The kept records are found again by their token after the rotation.
    try {
      final dead = _ref.read(deadSignInRecordsProvider);
      if (keepUnsent) {
        final row = await _ref.read(serverBindingRepositoryProvider).current();
        if (row != null) await dead.keepForNextLogin(row.localBindingId);
      } else {
        await dead.forgetKept();
      }
    } catch (e) {
      developer.log(
        'kept sign-in token not updated: ${e.runtimeType}',
        name: 'LocalResetService',
      );
    }
    try {
      final record = await _ref.read(serverBindingRepositoryProvider).rotate();
      if (record != null && !keepUnsent) {
        // Earlier sign-ins' upload and deletion records are fenced for good;
        // dropping them must never fail the log-out.
        try {
          await _ref
              .read(deadSignInRecordsProvider)
              .removeAllBut(record.localBindingId);
        } catch (e) {
          developer.log(
            'dead sign-in records not removed: ${e.runtimeType}',
            name: 'LocalResetService',
          );
        }
      }
    } catch (e, st) {
      failures.add(
        LocalResetFailure(ServerBindingRepository, e, st),
      );
    }
    // Closed for good (not just stopped): no recovery edge may restart it
    // and hand the rotated token to old-scope runners.
    final gate = _ref.read(serverBindingGateProvider);
    gate.stop(); // back to idle: a closed gate keeps its last state
    gate.dispose();
    await _revokeWith(revoker);
    try {
      await _ref.read(credentialStoreProvider).delete();
    } catch (e, st) {
      failures.add(LocalResetFailure(CredentialStore, e, st));
    }
    if (failures.any((f) => !f.quiesce)) {
      throw LocalResetException(failures);
    }
  }

  /// Finishes a reset that never completed its wipe (review major 2): the
  /// app was killed during it, or a wipe step failed. Fence and wipe again;
  /// nothing runs yet, so there is nothing to quiesce. Clears the marker
  /// only when the whole wipe succeeds; throws like [reset] otherwise.
  Future<void> completePendingReset() async {
    _generation++;
    try {
      await _ref.read(serverBindingRepositoryProvider).fence();
    } catch (e) {
      throw LocalResetAbortedException(e);
    }
    _stopGate();
    final failures = <LocalResetFailure>[];
    await _wipe(failures);
    if (failures.isNotEmpty) {
      throw LocalResetException(failures);
    }
  }

  /// The fence stops local writes; the gate must stop handing out the old
  /// verified token too, or a request started now (an edit flush, a sync)
  /// would still reach the server with what the user was told is lost.
  void _stopGate() {
    if (_ref.exists(serverBindingGateProvider)) {
      _ref.read(serverBindingGateProvider).stop();
    }
  }

  /// Runs every wipe step, then clears the pending marker if all of them
  /// succeeded. A marker that can't be cleared is reported (else a later
  /// launch would wipe the next session).
  Future<void> _wipe(List<LocalResetFailure> failures) async {
    final resettables = [..._ref.read(localResettablesProvider)]
      ..sort((a, b) => b.resetPriority.compareTo(a.resetPriority));
    var wiped = true;
    for (final r in resettables) {
      try {
        await r.resetLocalState();
      } catch (e, st) {
        // Continue — one broken subsystem must not strand the rest in a
        // half-reset state. Failures are aggregated and rethrown below so
        // the caller can surface the partial-reset condition to the user.
        failures.add(LocalResetFailure(r.runtimeType, e, st, participant: r));
        wiped = false;
      }
    }
    if (!wiped) return; // the marker stays: the next launch wipes again
    try {
      final prefs = await _ref.read(sharedPreferencesProvider.future);
      if (!await prefs.remove(resetPendingKey)) {
        throw StateError('the reset marker could not be cleared');
      }
    } catch (e, st) {
      failures.add(LocalResetFailure(LocalResetService, e, st));
    }
  }
}

/// One subsystem's failure during [LocalResetService.reset]. Kept as a
/// distinct type so callers can introspect which steps failed without
/// parsing strings.
class LocalResetFailure {
  LocalResetFailure(
    this.subsystem,
    this.error,
    this.stackTrace, {
    this.participant,
    this.quiesce = false,
  });

  /// A quiesce step failed or timed out: the wipe still ran, and the fence
  /// keeps its late work out of the new store, so nothing was left behind.
  final bool quiesce;

  final Type subsystem;

  /// The participant that failed, when known (lets callers ask what was
  /// left behind, e.g. whether the database wipe failed).
  final Object? participant;
  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => '$subsystem: $error';
}

/// Thrown by [LocalResetService.reset] when at least one subsystem failed
/// to reset. All other subsystems still ran — a partial reset is the
/// design, not a bug — but the caller MUST treat the overall reset as
/// failed so it does not lie to the user about cleanup having succeeded.
class LocalResetException implements Exception {
  LocalResetException(this.failures);

  final List<LocalResetFailure> failures;

  @override
  String toString() =>
      'LocalResetException: ${failures.length} subsystem(s) failed to reset '
      '(${failures.join('; ')})';
}

/// The reset's fence (the binding-row delete) failed; nothing was quiesced
/// or wiped.
class LocalResetAbortedException implements Exception {
  LocalResetAbortedException(this.cause);
  final Object cause;

  @override
  String toString() => 'LocalResetAbortedException: fence failed ($cause)';
}

/// SC-15 quiesce participants, run in THIS order (no priority sort) after
/// the fence and before the wipe. Playback goes first; later phases' runners
/// register after it.
final localQuiescablesProvider = Provider<List<Quiescable>>((ref) {
  return <Quiescable>[
    _PlaybackQuiescable(ref),
    _ListenQuiescable(ref),
    _PreviewQuiescable(ref),
    _HistoryQuiescable(ref),
    _UploadsQuiescable(ref),
    DeleteJobsQuiescable(ref),
    _OwnedCleanupQuiescable(ref),
    _SubmissionsQuiescable(ref),
  ];
});

/// Contributors to the Disconnect confirmation's "will be lost" copy, in
/// display order.
final lossReportersProvider = Provider<List<LossReporter>>((ref) {
  return <LossReporter>[
    ref.read(editOutboxProvider),
    _HistoryLossReporter(ref),
    UploadLossReporter(
      intents: ref.read(uploadIntentStoreProvider),
      binding: ref.read(serverBindingRepositoryProvider),
    ),
    DeleteJobsLossReporter(
      submissions: ref.read(durableSubmissionProvider),
      binding: ref.read(serverBindingRepositoryProvider),
    ),
  ];
});

final localResetServiceProvider = Provider<LocalResetService>((ref) {
  return LocalResetService(ref);
});

/// Subsystems registered for the full local-reset flow. Each entry is
/// either a class that implements [LocalResettable] directly (e.g.
/// [DownloadManager]) or a small adapter for stateless / third-party
/// reset steps (offline polling stop, SharedPreferences clear). The
/// [CredentialStore] is a participant too (Phase M, SC-15).
/// Playback is not wiped here: it is quiesced first
/// ([localQuiescablesProvider]).
///
/// Order in this list does not matter — [LocalResetService] sorts by
/// priority. Keeping the list flat (vs. spreading registration across
/// providers) makes the full set of reset steps greppable from one place.
final localResettablesProvider = Provider<List<LocalResettable>>((ref) {
  return <LocalResettable>[
    _OfflineExitResettable(ref),
    ref.read(downloadManagerProvider),
    ref.read(localCoverArtStoreProvider),
    ref.read(coverArtCacheProvider),
    ref.read(databaseProvider),
    _PrefsClearResettable(ref),
    ref.read(credentialStoreProvider),
    ?ref.read(sessionEventLogFileProvider),
  ];
});

// ── Adapters ────────────────────────────────────────────────────────────
//
// Adapters wrap reset steps whose owning class would not otherwise know
// about [LocalResettable] (Riverpod notifiers accessed via [Ref], the
// third-party SharedPreferences, the scope rebuild replaces the transport URL).
// Direct implementors live on the subsystem class itself.

/// The playback runtime as one ordered quiesce participant: closes playback
/// admission synchronously, then stops audio (SC-15, SC-27).
class _PlaybackQuiescable implements Quiescable {
  _PlaybackQuiescable(this._ref);
  final Ref _ref;

  @override
  String get quiesceName => 'playback';

  @override
  Future<void> quiesce() => _ref.read(queuePlayerProvider.notifier).quiesce();
}

/// Listen recording, after playback (SC-15): stops taking observations
/// and waits out its write in flight. Never builds a recorder.
class _ListenQuiescable implements Quiescable {
  _ListenQuiescable(this._ref);
  final Ref _ref;

  @override
  String get quiesceName => 'listens';

  @override
  Future<void> quiesce() async {
    if (_ref.exists(listenRecorderProvider)) {
      await _ref.read(listenRecorderProvider).quiesce();
    }
  }
}

/// The preview player, after listens (SC-15): cancels pending loads, stops
/// and releases the output. Never builds the player.
class _PreviewQuiescable implements Quiescable {
  _PreviewQuiescable(this._ref);
  final Ref _ref;

  @override
  String get quiesceName => 'preview';

  @override
  Future<void> quiesce() async {
    if (_ref.exists(previewPlayerProvider)) {
      await _ref.read(previewPlayerProvider.notifier).quiesce();
    }
  }
}

/// Durable submissions, after history (SC-15): aborts sends in flight and
/// closes admission. Never builds the helper.
class _UploadsQuiescable implements Quiescable {
  _UploadsQuiescable(this._ref);
  final Ref _ref;

  @override
  String get quiesceName => 'uploads';

  @override
  Future<void> quiesce() async {
    if (_ref.exists(uploadManagerProvider)) {
      await _ref.read(uploadManagerProvider).quiesce();
    }
  }
}

/// The owned-file cleanup worker, after uploads and before submissions
/// (SC-15): stops the runner. The SC-01 fence makes any in-flight cleanup
/// write a no-op and the wipe empties the table, so no gate is needed. Never
/// builds the runner.
class _OwnedCleanupQuiescable implements Quiescable {
  _OwnedCleanupQuiescable(this._ref);
  final Ref _ref;

  @override
  String get quiesceName => 'owned-file-cleanup';

  @override
  Future<void> quiesce() async {
    if (_ref.exists(ownedFileCleanupRunnerProvider)) {
      await _ref.read(ownedFileCleanupRunnerProvider).quiesce();
    }
  }
}

class _SubmissionsQuiescable implements Quiescable {
  _SubmissionsQuiescable(this._ref);
  final Ref _ref;

  @override
  String get quiesceName => 'submissions';

  @override
  Future<void> quiesce() async {
    if (_ref.exists(durableSubmissionProvider)) {
      await _ref.read(durableSubmissionProvider).quiesce();
    }
  }
}

class _OfflineExitResettable implements LocalResettable {
  _OfflineExitResettable(this._ref);
  final Ref _ref;

  @override
  int get resetPriority => ResetPriority.stopBackgroundWork;

  @override
  Future<void> resetLocalState() async {
    // Cancel the health-poll timer without publishing an offline→online
    // transition. A normal `exitOffline()` here would trigger the app-level
    // recovery listener (sync + resume downloads) against state that is
    // mid-wipe — see comment on [OfflineModeNotifier.cancelOfflinePolling].
    _ref.read(offlineModeProvider.notifier).cancelOfflinePolling();
  }
}

class _PrefsClearResettable implements LocalResettable {
  _PrefsClearResettable(this._ref);
  final Ref _ref;

  @override
  int get resetPriority => ResetPriority.clearPreferences;

  @override
  Future<void> resetLocalState() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    // Everything but the pending-reset marker, which only a completed wipe
    // removes (LocalResetService._wipe).
    for (final key in prefs.getKeys().toList()) {
      if (key == LocalResetService.resetPendingKey) continue;
      if (!await prefs.remove(key)) {
        throw StateError('preference "$key" could not be cleared');
      }
    }
  }
}

/// The history runner as a quiesce participant (after playback): stops its
/// triggers, then waits out the pass in flight.
class _HistoryQuiescable implements Quiescable {
  _HistoryQuiescable(this._ref);
  final Ref _ref;

  @override
  String get quiesceName => 'history';

  @override
  Future<void> quiesce() async {
    // Never builds them just to stop them.
    if (_ref.exists(historySyncTriggersProvider)) {
      _ref.read(historySyncTriggersProvider).dispose();
    }
    if (_ref.exists(historyRunnerProvider)) {
      await _ref.read(historyRunnerProvider).quiesce();
    }
  }
}

/// Unsent local history (pending upload, quarantined events included).
class _HistoryLossReporter implements LossReporter {
  _HistoryLossReporter(this._ref);
  final Ref _ref;

  @override
  Future<String?> pendingLossSummary() async {
    final repository = _ref.read(historyRepositoryProvider);
    final counts = await repository.counts();
    // Listens not yet saved as events (in progress, or a frozen failed
    // finalization) are unsent history too: the wipe deletes them.
    final drafts = (await repository.drafts()).length;
    final n = counts.pending + counts.quarantined + drafts;
    if (n == 0) return null;
    return '$n unsent history event${n == 1 ? '' : 's'}';
  }
}
