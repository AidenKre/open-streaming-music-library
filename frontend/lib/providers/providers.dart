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
    // Offline mode skips sync entirely — the network call would just fail.
    // OfflineModeNotifier re-invokes this on recovery, so the next online
    // tick will pick up everything that changed while we were dark.
    if (ref.read(offlineModeProvider)) return;

    final current = state.value;
    if (current != null && current.isSyncing) return;

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
      // Flush pending edits, then pull — in one mutex-guarded critical section
      // so a `/changes` pull can never clobber an unflushed optimistic edit
      // (the pull does a blind full-row upsert). Flushing first also satisfies
      // "flush before pull on reconnect" since this runs from the recovery edge.
      final mutex = ref.read(editSyncMutexProvider);
      final outbox = ref.read(editOutboxProvider);
      final result = await mutex.run(() async {
        await outbox.flushLocked();
        return service.syncChanges();
      });
      final nextQueueMutationVersion = result.affectedQueueSessionIds.isEmpty
          ? (current?.queueMutationVersion ?? 0)
          : (current?.queueMutationVersion ?? 0) + 1;
      final nextDownloadMutationVersion = result.deletedTrackUuids.isEmpty
          ? (current?.downloadMutationVersion ?? 0)
          : (current?.downloadMutationVersion ?? 0) + 1;
      state = AsyncData(
        TrackSyncState(
          queueMutationVersion: nextQueueMutationVersion,
          downloadMutationVersion: nextDownloadMutationVersion,
          affectedQueueSessionIds: result.affectedQueueSessionIds,
          deletedTrackUuids: result.deletedTrackUuids,
        ),
      );
    } catch (e) {
      state = AsyncData(
        TrackSyncState(
          error: e.toString(),
          queueMutationVersion: current?.queueMutationVersion ?? 0,
          downloadMutationVersion: current?.downloadMutationVersion ?? 0,
        ),
      );
    }
  }
}

final trackSyncProvider =
    AsyncNotifierProvider<TrackSyncNotifier, TrackSyncState>(
      TrackSyncNotifier.new,
    );
