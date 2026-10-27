import 'package:frontend/api/jobs_api.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/services/edit_sync_mutex.dart';
import 'package:frontend/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('databaseProvider must be overridden');
});

final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) {
  return SharedPreferences.getInstance();
});

final tracksApiProvider = Provider<TracksApi>((ref) => TracksApi());

final jobsApiProvider = Provider<JobsApi>((ref) => JobsApi());

final queueRepositoryProvider = Provider<QueueRepository>((ref) {
  return QueueRepository(ref.read(databaseProvider));
});

final browseRepositoryProvider = Provider<BrowseRepository>((ref) {
  return BrowseRepository(ref.read(databaseProvider));
});

class TrackSyncState {
  final bool isSyncing;
  final String? error;
  final int queueMutationVersion;
  final int downloadMutationVersion;
  final Set<int> affectedQueueSessionIds;
  final Set<String> deletedTrackUuids;

  const TrackSyncState({
    this.isSyncing = false,
    this.error,
    this.queueMutationVersion = 0,
    this.downloadMutationVersion = 0,
    this.affectedQueueSessionIds = const {},
    this.deletedTrackUuids = const {},
  });

  TrackSyncState copyWith({
    bool? isSyncing,
    String? error,
    int? queueMutationVersion,
    int? downloadMutationVersion,
    Set<int>? affectedQueueSessionIds,
    Set<String>? deletedTrackUuids,
  }) {
    return TrackSyncState(
      isSyncing: isSyncing ?? this.isSyncing,
      error: error,
      queueMutationVersion: queueMutationVersion ?? this.queueMutationVersion,
      downloadMutationVersion:
          downloadMutationVersion ?? this.downloadMutationVersion,
      affectedQueueSessionIds:
          affectedQueueSessionIds ?? this.affectedQueueSessionIds,
      deletedTrackUuids: deletedTrackUuids ?? this.deletedTrackUuids,
    );
  }
}

class TrackSyncNotifier extends AsyncNotifier<TrackSyncState> {
  @override
  Future<TrackSyncState> build() async {
    return const TrackSyncState();
  }

  /// The currently running guarded operation (a [sync] or [refreshTrack]),
  /// so [syncFresh] can wait it out. Set/cleared in lockstep with
  /// `isSyncing`.
  Future<bool>? _inFlightRun;

  Future<void> sync() async {
    await _syncOnce();
  }

  /// Like [sync], but guarantees a flush + `/changes` pull that *started
  /// after this call* has completed: if a sync is already in flight (whose
  /// pull may predate the caller's precondition) it is awaited first and
  /// then a fresh one is run. Returns true only when that fresh pull
  /// succeeded; false when offline or the pull failed (the error is still
  /// published on [state]). Used where a stale local revision would be sent
  /// to the server (e.g. the convert flow's `base_revision`) and after a
  /// server-side change the client must pick up (a finished conversion).
  Future<bool> syncFresh() async {
    // Bounded: each in-flight run we wait out finishes in finite time, and
    // a fresh entrant can't slip in between our null check and
    // `_runGuarded`'s synchronous isSyncing claim (no awaits between them).
    for (var i = 0; i < 5; i++) {
      final inFlight = _inFlightRun;
      if (inFlight != null) {
        await inFlight;
        continue;
      }
      if (ref.read(offlineModeProvider)) return false;
      return _syncOnce();
    }
    return false;
  }

  Future<bool> _syncOnce() async {
    // Flush pending edits, then pull — in one mutex-guarded critical section
    // so a `/changes` pull can never clobber an unflushed optimistic edit
    // (the pull does a blind full-row upsert). Flushing first also satisfies
    // "flush before pull on reconnect" since this runs from the recovery edge.
    final ran = await _runGuarded((service) async {
      await ref.read(editOutboxProvider).flushLocked();
      return service.syncChanges();
    });
    // Finish take-server resolutions deferred while offline or mid-sync —
    // outside the critical section; refreshTrack re-takes the guards itself.
    if (ran) {
      await ref.read(editOutboxProvider).retryTakeServerResolutions();
    }
    return ran;
  }

  /// Reconcile a single track to current server truth (refetch + apply, or
  /// local-delete if gone). Used by conflict "take server" resolution, where
  /// the watermark may already have advanced past the conflicting revision so
  /// a `/changes` pull would fetch nothing. Returns true when the track was
  /// reconciled; false when skipped (offline, or a sync is in flight) or the
  /// refetch failed — the caller keeps its resolution marker and retries
  /// after the next sync.
  Future<bool> refreshTrack(String uuidId, {bool rebuildParentFts = true}) {
    return _runGuarded(
      (service) => service.refetchAndApplyTrack(
        uuidId,
        rebuildParentFts: rebuildParentFts,
      ),
    );
  }

  /// Runs one sync operation with the shared guards: offline no-ops,
  /// `isSyncing` serializes concurrent entrants (two operations publishing
  /// the same mutation version would make the audio coordinator's
  /// `<=`-version guard drop the second one's queue reconciliation), the op
  /// executes under the edit/sync mutex, and the result is mapped onto the
  /// state that is current AT PUBLISH TIME. Returns true when [op] ran and
  /// its result was published.
  Future<bool> _runGuarded(
    Future<SyncResult> Function(SyncService service) op,
  ) {
    // Offline mode skips entirely (see [_runGuardedBody]).
    if (ref.read(offlineModeProvider)) return Future.value(false);
    final current = state.value;
    if (current != null && current.isSyncing) return Future.value(false);
    // Synchronously claims the slot: `_runGuardedBody` publishes
    // isSyncing:true before its first await.
    final run = _runGuardedBody(op);
    _inFlightRun = run;
    return run.whenComplete(() {
      if (identical(_inFlightRun, run)) _inFlightRun = null;
    });
  }

  Future<bool> _runGuardedBody(
    Future<SyncResult> Function(SyncService service) op,
  ) async {
    // Offline mode skips entirely — the network call would just fail.
    // OfflineModeNotifier re-invokes sync on recovery, so the next online
    // tick will pick up everything that changed while we were dark.
    if (ref.read(offlineModeProvider)) return false;

    // No awaits between this check and the isSyncing:true publish below, so
    // two entrants can't both pass the guard.
    final current = state.value;
    if (current != null && current.isSyncing) return false;

    state = AsyncData(
      TrackSyncState(
        isSyncing: true,
        queueMutationVersion: current?.queueMutationVersion ?? 0,
        downloadMutationVersion: current?.downloadMutationVersion ?? 0,
      ),
    );

    try {
      final service = SyncService(
        db: ref.read(databaseProvider),
        api: ref.read(tracksApiProvider),
        queueRepository: ref.read(queueRepositoryProvider),
        prefs: await ref.read(sharedPreferencesProvider.future),
      );
      final mutex = ref.read(editSyncMutexProvider);
      final result = await mutex.run(() => op(service));
      final latest = state.value ?? current;
      state = AsyncData(
        TrackSyncState(
          queueMutationVersion: result.affectedQueueSessionIds.isEmpty
              ? (latest?.queueMutationVersion ?? 0)
              : (latest?.queueMutationVersion ?? 0) + 1,
          downloadMutationVersion: result.deletedTrackUuids.isEmpty
              ? (latest?.downloadMutationVersion ?? 0)
              : (latest?.downloadMutationVersion ?? 0) + 1,
          affectedQueueSessionIds: result.affectedQueueSessionIds,
          deletedTrackUuids: result.deletedTrackUuids,
        ),
      );
      return true;
    } catch (e) {
      final latest = state.value ?? current;
      state = AsyncData(
        TrackSyncState(
          error: e.toString(),
          queueMutationVersion: latest?.queueMutationVersion ?? 0,
          downloadMutationVersion: latest?.downloadMutationVersion ?? 0,
        ),
      );
      return false;
    }
  }
}

final trackSyncProvider =
    AsyncNotifierProvider<TrackSyncNotifier, TrackSyncState>(
      TrackSyncNotifier.new,
    );
