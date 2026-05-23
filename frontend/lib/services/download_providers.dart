import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
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

/// True iff any queued/active jobs belong to the given album.
final albumIsDownloadingProvider = Provider.family<bool, int>((ref, albumId) {
  final manager = ref.watch(downloadManagerListenableProvider);
  return manager.state.jobs.any((j) =>
      j.albumId == albumId &&
      (j.state == DownloadState.queued || j.state == DownloadState.active));
});

/// True iff any queued/active jobs belong to the given artist.
final artistIsDownloadingProvider = Provider.family<bool, int>((ref, artistId) {
  final manager = ref.watch(downloadManagerListenableProvider);
  return manager.state.jobs.any((j) =>
      j.artistId == artistId &&
      (j.state == DownloadState.queued || j.state == DownloadState.active));
});

/// DB-backed (downloaded, total) counts for an album; refreshes on each
/// completed/deleted download.
final albumDownloadCountsProvider =
    FutureProvider.family<({int downloaded, int total}), int>(
        (ref, albumId) async {
  ref.watch(downloadStatusVersionProvider);
  final db = ref.watch(databaseProvider);
  final counts = await db.getAlbumDownloadCounts([albumId]);
  final entry = counts[albumId];
  return (downloaded: entry?.downloaded ?? 0, total: entry?.total ?? 0);
});

/// DB-backed (downloaded, total) counts for an artist; refreshes on each
/// completed/deleted download.
final artistDownloadCountsProvider =
    FutureProvider.family<({int downloaded, int total}), int>(
        (ref, artistId) async {
  ref.watch(downloadStatusVersionProvider);
  final db = ref.watch(databaseProvider);
  final counts = await db.getArtistDownloadCounts([artistId]);
  final entry = counts[artistId];
  return (downloaded: entry?.downloaded ?? 0, total: entry?.total ?? 0);
});

// ── Download / delete helpers ───────────────────────────────────────────
// Shared across albums_page, artist_page, search_page, and tracks_page so
// the same logic isn't duplicated in every callback.

Future<void> downloadAlbumTracks(WidgetRef ref, int? artistId, int albumId) async {
  if (artistId == null) return;
  final tracks = await ref.read(browseRepositoryProvider)
      .getTracksForAlbum(artistId, albumId);
  if (tracks.isNotEmpty) {
    final quality = ref.read(downloadQualityProvider);
    ref.read(downloadManagerProvider).enqueueTracks(tracks, quality: quality);
  }
}

Future<void> deleteAlbumDownloads(WidgetRef ref, int? artistId, int albumId) async {
  if (artistId == null) return;
  final tracks = await ref.read(browseRepositoryProvider)
      .getTracksForAlbum(artistId, albumId);
  if (tracks.isNotEmpty) {
    await ref
        .read(downloadManagerProvider)
        .deleteDownloadsForUuids(tracks.map((t) => t.uuidId));
  }
}

Future<void> downloadArtistTracks(WidgetRef ref, int artistId) async {
  final tracks = await ref.read(browseRepositoryProvider)
      .getTracksForArtist(artistId);
  if (tracks.isNotEmpty) {
    final quality = ref.read(downloadQualityProvider);
    ref.read(downloadManagerProvider).enqueueTracks(tracks, quality: quality);
  }
}

Future<void> deleteArtistDownloads(WidgetRef ref, int artistId) async {
  final tracks = await ref.read(browseRepositoryProvider)
      .getTracksForArtist(artistId);
  if (tracks.isNotEmpty) {
    await ref
        .read(downloadManagerProvider)
        .deleteDownloadsForUuids(tracks.map((t) => t.uuidId));
  }
}

void downloadTrack(WidgetRef ref, TrackUI track) {
  final quality = ref.read(downloadQualityProvider);
  ref.read(downloadManagerProvider).enqueueTracks([track], quality: quality);
}

void deleteTrackDownload(WidgetRef ref, String uuidId) {
  ref.read(downloadManagerProvider).deleteDownload(uuidId);
}

// ── Quality-specific download helpers ──────────────────────────────────────
// Used by the split download tile's quality picker.

Future<void> downloadAlbumTracksAtQuality(
    WidgetRef ref, int? artistId, int albumId, String quality) async {
  if (artistId == null) return;
  final tracks = await ref.read(browseRepositoryProvider)
      .getTracksForAlbum(artistId, albumId);
  if (tracks.isNotEmpty) {
    ref
        .read(downloadManagerProvider)
        .enqueueTracksAtQuality(tracks, quality: quality);
  }
}

Future<void> downloadArtistTracksAtQuality(
    WidgetRef ref, int artistId, String quality) async {
  final tracks = await ref.read(browseRepositoryProvider)
      .getTracksForArtist(artistId);
  if (tracks.isNotEmpty) {
    ref
        .read(downloadManagerProvider)
        .enqueueTracksAtQuality(tracks, quality: quality);
  }
}

void downloadTrackAtQuality(WidgetRef ref, TrackUI track, String quality) {
  ref
      .read(downloadManagerProvider)
      .enqueueTracksAtQuality([track], quality: quality);
}
