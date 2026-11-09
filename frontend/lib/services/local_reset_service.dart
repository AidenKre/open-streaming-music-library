import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/services/local_resettable.dart';

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

  Future<void> reset() async {
    // 1. Fence. The generation bump happens before the first await.
    _generation++;
    try {
      await _ref.read(serverBindingRepositoryProvider).fence();
    } catch (e) {
      // A wipe would most likely fail too: report and stop.
      throw LocalResetAbortedException(e);
    }

    final failures = <LocalResetFailure>[];

    // 2. Quiesce.
    for (final q in _ref.read(localQuiescablesProvider)) {
      try {
        await q.quiesce().timeout(quiesceTimeout);
      } catch (e, st) {
        failures.add(LocalResetFailure(q.runtimeType, e, st));
      }
    }

    // 3. Wipe.
    final resettables = [..._ref.read(localResettablesProvider)]
      ..sort((a, b) => b.resetPriority.compareTo(a.resetPriority));
    for (final r in resettables) {
      try {
        await r.resetLocalState();
      } catch (e, st) {
        // Continue — one broken subsystem must not strand the rest in a
        // half-reset state. Failures are aggregated and rethrown below so
        // the caller can surface the partial-reset condition to the user.
        failures.add(LocalResetFailure(r.runtimeType, e, st, participant: r));
      }
    }
    if (failures.isNotEmpty) {
      throw LocalResetException(failures);
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
  });

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
  return <Quiescable>[_PlaybackQuiescable(ref)];
});

/// Contributors to the Disconnect confirmation's "will be lost" copy, in
/// display order.
final lossReportersProvider = Provider<List<LossReporter>>((ref) {
  return <LossReporter>[ref.read(editOutboxProvider)];
});

final localResetServiceProvider = Provider<LocalResetService>((ref) {
  return LocalResetService(ref);
});

/// Subsystems registered for the full local-reset flow. Each entry is
/// either a class that implements [LocalResettable] directly (e.g.
/// [DownloadManager]) or a small adapter for stateless / third-party
/// reset steps (offline polling stop, SharedPreferences clear, ApiClient URL
/// clear). Playback is not wiped here: it is quiesced first
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
    _ApiClientUrlResettable(),
  ];
});

// ── Adapters ────────────────────────────────────────────────────────────
//
// Adapters wrap reset steps whose owning class would not otherwise know
// about [LocalResettable] (Riverpod notifiers accessed via [Ref], the
// third-party SharedPreferences, the static ApiClient.init entry point).
// Direct implementors live on the subsystem class itself.

/// The playback runtime as one ordered quiesce participant: closes playback
/// admission synchronously, then stops audio (SC-15, SC-27).
class _PlaybackQuiescable implements Quiescable {
  _PlaybackQuiescable(this._ref);
  final Ref _ref;

  @override
  String get quiesceName => 'playback';

  @override
  Future<void> quiesce() => _ref.read(audioProvider.notifier).quiesce();
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
    await prefs.clear();
  }
}

class _ApiClientUrlResettable implements LocalResettable {
  @override
  int get resetPriority => ResetPriority.clearTransport;

  @override
  Future<void> resetLocalState() async {
    ApiClient.init('');
  }
}
