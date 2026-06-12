import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:frontend/models/ui/track_ui.dart';
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

final downloadManagerProvider = Provider<DownloadManager>((ref) {
  final manager = DownloadManager(
    db: ref.read(databaseProvider),
    coverArtStore: ref.read(localCoverArtStoreProvider),
    warmService: ref.read(queueWarmServiceProvider),
    streamQualityFn: () => ref.read(streamQualityProvider),
    isOfflineFn: () => ref.read(offlineModeProvider),
    onNetworkFailure: () =>
        ref.read(offlineModeProvider.notifier).enterOffline(),
  );
  ref.onDispose(manager.dispose);
  return manager;
});

/// Watches the download manager so widgets rebuild whenever the queue
/// changes. Returning the manager itself keeps the API consistent with the
/// rest of the app — consumers always reach into `state` for data.
final downloadManagerListenableProvider = ChangeNotifierProvider<DownloadManager>(
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
final downloadedStatsProvider =
    StreamProvider<({int count, int totalBytes})>((ref) {
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
  return manager.state.jobs
      .any((j) => scopeId(j) == id && (j.isQueued || j.isActive));
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

({int downloaded, int total}) _sliceCounts(
  Map<int, ({int total, int downloaded})> map,
  int id,
) {
  final entry = map[id];
  return (downloaded: entry?.downloaded ?? 0, total: entry?.total ?? 0);
}

/// DB-backed (downloaded, total) counts for an album; refreshes on each
/// completed/deleted download. Backed by the batched map provider.
final albumDownloadCountsProvider =
    Provider.family<AsyncValue<({int downloaded, int total})>, int>(
  (ref, albumId) => ref
      .watch(_albumDownloadCountsMapProvider)
      .whenData((map) => _sliceCounts(map, albumId)),
);

/// DB-backed (downloaded, total) counts for an artist; refreshes on each
/// completed/deleted download. Backed by the batched map provider.
final artistDownloadCountsProvider =
    Provider.family<AsyncValue<({int downloaded, int total})>, int>(
  (ref, artistId) => ref
      .watch(_artistDownloadCountsMapProvider)
      .whenData((map) => _sliceCounts(map, artistId)),
);

// ── Sealed DownloadScope + unified entry points ─────────────────────────
// Shared across albums_page, artist_page, search_page, tracks_page, and
// downloaded_tracks_page. Adding a new download source (e.g. playlists)
// is now a one-line `class PlaylistScope` constructor.

sealed class DownloadScope {
  const DownloadScope();
}

class AlbumScope extends DownloadScope {
  final int artistId;
  final int albumId;
  const AlbumScope({required this.artistId, required this.albumId});
}

class ArtistScope extends DownloadScope {
  final int artistId;
  const ArtistScope({required this.artistId});
}

class TrackScope extends DownloadScope {
  final TrackUI track;
  const TrackScope(this.track);
}

class TracksScope extends DownloadScope {
  final List<TrackUI> tracks;
  const TracksScope(this.tracks);
}

Future<List<TrackUI>> _resolveTracks(WidgetRef ref, DownloadScope scope) {
  switch (scope) {
    case AlbumScope(:final artistId, :final albumId):
      return ref
          .read(browseRepositoryProvider)
          .getTracksForAlbum(artistId, albumId);
    case ArtistScope(:final artistId):
      return ref.read(browseRepositoryProvider).getTracksForArtist(artistId);
    case TrackScope(:final track):
      return Future.value([track]);
    case TracksScope(:final tracks):
      return Future.value(tracks);
  }
}

/// Enqueue downloads for the given scope.
///
/// When [quality] is null the user's current default download quality (from
/// `downloadQualityProvider`) is applied. When [quality] is non-null the
/// manager's `enqueueTracksAtQuality` path is used so the per-call override
/// wins regardless of the default.
Future<void> downloadScope(
  WidgetRef ref,
  DownloadScope scope, {
  String? quality,
}) async {
  final tracks = await _resolveTracks(ref, scope);
  if (tracks.isEmpty) return;
  final manager = ref.read(downloadManagerProvider);
  if (quality == null) {
    await manager.enqueueTracks(
      tracks,
      quality: ref.read(downloadQualityProvider),
    );
  } else {
    await manager.enqueueTracksAtQuality(tracks, quality: quality);
  }
}

/// Delete downloads for the given scope. `TrackScope` deletes a single
/// track via `deleteDownload(uuidId)`; everything else delegates to
/// `deleteDownloadsForUuids` on the resolved track list.
Future<void> deleteScope(WidgetRef ref, DownloadScope scope) async {
  final manager = ref.read(downloadManagerProvider);
  if (scope is TrackScope) {
    await manager.deleteDownload(scope.track.uuidId);
    return;
  }
  final tracks = await _resolveTracks(ref, scope);
  if (tracks.isEmpty) return;
  await manager.deleteDownloadsForUuids(tracks.map((t) => t.uuidId));
}
