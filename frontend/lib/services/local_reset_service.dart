import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_resettable.dart';

/// Coordinates a full local reset of frontend-owned state.
///
/// The service reads [localResettablesProvider] for the registered set,
/// sorts by descending [LocalResettable.resetPriority], and invokes each
/// step inside its own try/catch so a failure in one subsystem cannot
/// strand the rest in a half-reset state. New subsystems join the flow
/// by implementing [LocalResettable] (or adding a thin adapter) and
/// adding themselves to the provider — no edits to this class required.
class LocalResetService {
  LocalResetService(this._ref);

  final Ref _ref;

  Future<void> reset() async {
    final resettables = [..._ref.read(localResettablesProvider)]
      ..sort((a, b) => b.resetPriority.compareTo(a.resetPriority));
    final failures = <LocalResetFailure>[];
    for (final r in resettables) {
      try {
        await r.resetLocalState();
      } catch (e, st) {
        // Continue — one broken subsystem must not strand the rest in a
        // half-reset state. Failures are aggregated and rethrown below so
        // the caller can surface the partial-reset condition to the user.
        failures.add(LocalResetFailure(r.runtimeType, e, st));
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
  LocalResetFailure(this.subsystem, this.error, this.stackTrace);

  final Type subsystem;
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

final localResetServiceProvider = Provider<LocalResetService>((ref) {
  return LocalResetService(ref);
});

/// Subsystems registered for the full local-reset flow. Each entry is
/// either a class that implements [LocalResettable] directly (e.g.
/// [DownloadManager]) or a small adapter for stateless / third-party
/// reset steps (audio stop, SharedPreferences clear, ApiClient URL clear).
///
/// Order in this list does not matter — [LocalResetService] sorts by
/// priority. Keeping the list flat (vs. spreading registration across
/// providers) makes the full set of reset steps greppable from one place.
final localResettablesProvider = Provider<List<LocalResettable>>((ref) {
  return <LocalResettable>[
    _AudioStopResettable(ref),
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

class _AudioStopResettable implements LocalResettable {
  _AudioStopResettable(this._ref);
  final Ref _ref;

  @override
  int get resetPriority => ResetPriority.stopBackgroundWork;

  @override
  Future<void> resetLocalState() => _ref.read(audioProvider.notifier).stop();
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
