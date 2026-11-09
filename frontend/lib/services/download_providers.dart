import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path_provider/path_provider.dart';

import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/playback/codec_support.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download/download_reconciliation_service.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/queue_warm_service.dart';
import 'package:frontend/services/settings_service.dart';

/// Initialised once at startup. The store is async because it touches the
/// filesystem to ensure the cover-art directory exists.
final localCoverArtStoreProvider = Provider<LocalCoverArtStore>((ref) {
  throw UnimplementedError(
    'localCoverArtStoreProvider must be overridden at app startup',
  );
});

final downloadDirectoryProvider = Provider<Future<Directory> Function()>((ref) {
  return getApplicationDocumentsDirectory;
});

final downloadManagerProvider = Provider<DownloadManager>((ref) {
  var providerDisposed = false;
  final manager = DownloadManager(
    db: ref.read(databaseProvider),
    coverArtStore: ref.read(localCoverArtStoreProvider),
    directoryProvider: ref.read(downloadDirectoryProvider),
    warmService: ref.read(queueWarmServiceProvider),
    streamQualityFn: () => ref.read(streamQualityProvider),
    codecSupportFn: () => ref.read(codecSupportProvider),
    isOfflineFn: () => providerDisposed ? true : ref.read(offlineModeProvider),
    onNetworkFailure: () {
      if (providerDisposed) return;
      ref.read(offlineModeProvider.notifier).enterOffline();
    },
  );
  ref.listen<AsyncValue<TrackSyncState>>(trackSyncProvider, (previous, next) {
    final previousValue = previous?.value;
    final nextValue = next.value;
    if (nextValue == null) return;
    final previousVersion = previousValue?.downloadMutationVersion ?? 0;
    if (nextValue.downloadMutationVersion <= previousVersion) return;
    final deletedUuids = nextValue.deletedTrackUuids;
    if (deletedUuids.isEmpty) return;
    unawaited(
      manager.deleteDownloadsForUuids(deletedUuids).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        developer.log(
          'Failed to clean up downloads for sync tombstones',
          name: 'download_providers',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  });
  ref.onDispose(() {
    providerDisposed = true;
    manager.dispose();
  });
  return manager;
});

/// Watches the download manager so widgets rebuild whenever the queue
/// changes. Returning the manager itself keeps the API consistent with the
/// rest of the app — consumers always reach into `state` for data.
final downloadManagerListenableProvider =
    ChangeNotifierProvider<DownloadManager>(
      (ref) => ref.watch(downloadManagerProvider),
    );

/// Reconciles stale local download paths against the filesystem. Triggered
/// at app startup and on app resume — see `_FrontendState` in `main.dart`.
final downloadReconciliationServiceProvider =
    Provider<DownloadReconciliationService>((ref) {
      final manager = ref.read(downloadManagerProvider);
      return DownloadReconciliationService(
        db: ref.read(databaseProvider),
        statusReader: manager.statusReader,
      );
    });

/// Live count and total size of downloaded tracks for the Downloads tab header.
final downloadedStatsProvider = StreamProvider<({int count, int totalBytes})>((
  ref,
) {
  return ref.watch(databaseProvider).watchDownloadedStats();
});

/// Bumps every time a track is downloaded or deleted, so derived providers
/// (album/artist downloaded badges) can revalidate.
final downloadStatusVersionProvider = StreamProvider<int>((ref) {
  final manager = ref.watch(downloadManagerProvider);
  final controller = StreamController<int>();
  controller.add(manager.downloadStatusVersion.value);
  void listener() => controller.add(manager.downloadStatusVersion.value);
  manager.downloadStatusVersion.addListener(listener);
  ref.onDispose(() {
    manager.downloadStatusVersion.removeListener(listener);
    controller.close();
  });
  return controller.stream;
});

/// True iff any queued/active job belongs to the scope picked by [scopeId]
/// (e.g. `(j) => j.albumId`). One implementation shared by the album/artist
/// variants so a fix can't land in one and miss the other.
bool _isDownloading(Ref ref, int id, int? Function(DownloadJob) scopeId) {
  final manager = ref.watch(downloadManagerListenableProvider);
  return manager.state.jobs.any(
    (j) => scopeId(j) == id && (j.isQueued || j.isActive),
  );
}

/// True iff any queued/active jobs belong to the given album.
final albumIsDownloadingProvider = Provider.family<bool, int>(
  (ref, albumId) => _isDownloading(ref, albumId, (j) => j.albumId),
);

/// True iff any queued/active jobs belong to the given artist.
final artistIsDownloadingProvider = Provider.family<bool, int>(
  (ref, artistId) => _isDownloading(ref, artistId, (j) => j.artistId),
);

/// Download counts for every album, batched into ONE grouped query and
/// recomputed once per download-status change. Cards read their own slice via
/// [albumDownloadCountsProvider] instead of each issuing its own query.
final _albumDownloadCountsMapProvider =
    FutureProvider<Map<int, ({int total, int downloaded})>>((ref) async {
      ref.watch(downloadStatusVersionProvider);
      return ref.watch(databaseProvider).getAllAlbumDownloadCounts();
    });

final _artistDownloadCountsMapProvider =
    FutureProvider<Map<int, ({int total, int downloaded})>>((ref) async {
      ref.watch(downloadStatusVersionProvider);
      return ref.watch(databaseProvider).getAllArtistDownloadCounts();
    });

/// [id]'s counts, or null when the map has no entry (unknown, not 0/0).
({int downloaded, int total})? _sliceCounts(
  Map<int, ({int total, int downloaded})> map,
  int id,
) {
  final entry = map[id];
  if (entry == null) return null;
  return (downloaded: entry.downloaded, total: entry.total);
}

/// DB-backed (downloaded, total) counts for an album; refreshes on each
/// completed/deleted download. Backed by the batched map provider.
final albumDownloadCountsProvider =
    Provider.family<AsyncValue<({int downloaded, int total})?>, int>(
      (ref, albumId) => ref
          .watch(_albumDownloadCountsMapProvider)
          .whenData((map) => _sliceCounts(map, albumId)),
    );

/// DB-backed (downloaded, total) counts for an artist; refreshes on each
/// completed/deleted download. Backed by the batched map provider.
final artistDownloadCountsProvider =
    Provider.family<AsyncValue<({int downloaded, int total})?>, int>(
      (ref, artistId) => ref
          .watch(_artistDownloadCountsMapProvider)
          .whenData((map) => _sliceCounts(map, artistId)),
    );

/// Whether [LibraryScope] can play/queue now and what its download actions
/// offer (SC-06): the one enablement predicate every surface reads.
///
/// Album/artist scopes read the batched count maps above (one grouped query
/// for every card, recomputed per download event), never a per-card
/// resolution. Unknown is not zero: while the map loads, or when it has no
/// entry for the scope (it is recomputed only on download events, so an
/// album synced after it was built is absent), the result is `unknown`.
/// Track scopes are computed from the rows' own download state.
///
/// Auto-dispose and keyed by value-equal scopes, so rebuilt cards reuse one
/// element instead of leaking one per rebuild.
final playbackAvailabilityProvider =
    Provider.autoDispose.family<PlaybackAvailability, LibraryScope>((
      ref,
      scope,
    ) {
      final offline = ref.watch(offlineModeProvider);
      ({int total, int downloaded})? counts;
      var undecodable = 0;
      switch (scope) {
        case AlbumScope(:final albumId):
          final map = ref.watch(_albumDownloadCountsMapProvider).value;
          if (map == null) return PlaybackAvailability.unknown(offline: offline);
          counts = map[albumId];
        case ArtistScope(:final artistId):
          final map = ref.watch(_artistDownloadCountsMapProvider).value;
          if (map == null) return PlaybackAvailability.unknown(offline: offline);
          counts = map[artistId];
        // A download in a codec this device can't decode is still a
        // download (Delete applies) but doesn't play offline (review major
        // 1). Album/artist counts above are by download only; offline
        // playback skips such a track.
        case TrackScope(:final track):
          final codecs = ref.watch(codecSupportProvider);
          counts = (total: 1, downloaded: track.isDownloaded ? 1 : 0);
          undecodable = track.isDownloaded && !codecs.playsDownload(track) ? 1 : 0;
        case TracksScope(:final tracks):
          final codecs = ref.watch(codecSupportProvider);
          final downloaded = tracks.where((t) => t.isDownloaded).toList();
          counts = (total: tracks.length, downloaded: downloaded.length);
          undecodable =
              downloaded.where((t) => !codecs.playsDownload(t)).length;
      }
      if (counts == null) return PlaybackAvailability.unknown(offline: offline);
      return PlaybackAvailability.of(
        offline: offline,
        downloaded: counts.downloaded,
        total: counts.total,
        undecodable: undecodable,
      );
    });
