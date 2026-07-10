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

  Future<void> sync() async {
    // Flush pending edits, then pull — in one mutex-guarded critical section
    // so a `/changes` pull can never clobber an unflushed optimistic edit
    // (the pull does a blind full-row upsert). Flushing first also satisfies
    // "flush before pull on reconnect" since this runs from the recovery edge.
    await _runGuarded((service) async {
      await ref.read(editOutboxProvider).flushLocked();
      return service.syncChanges();
    });
  }

  /// Reconcile a single track to current server truth (refetch + apply, or
  /// local-delete if gone). Used by conflict "take server" resolution, where
  /// the watermark may already have advanced past the conflicting revision so
  /// a `/changes` pull would fetch nothing. Returns true when the track was
  /// reconciled; false when skipped (offline, or a sync is in flight) or the
  /// refetch failed — the caller keeps its resolution marker and retries
  /// after the next sync.
  Future<bool> refreshTrack(String uuidId) {
    return _runGuarded((service) => service.refetchAndApplyTrack(uuidId));
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
