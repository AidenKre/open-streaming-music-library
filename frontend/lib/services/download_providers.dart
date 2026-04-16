import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:frontend/models/ui/track_ui.dart';
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

/// True iff EVERY track on the album has been downloaded. Watches the
/// download-status version so the badge updates as downloads complete or
/// get deleted.
final albumDownloadedProvider =
    FutureProvider.family<bool, int>((ref, albumId) async {
  ref.watch(downloadStatusVersionProvider);
  final db = ref.watch(databaseProvider);
  final counts = await db.getAlbumDownloadCounts([albumId]);
  final entry = counts[albumId];
  if (entry == null) return false;
  return entry.total > 0 && entry.downloaded == entry.total;
});

/// True iff EVERY track by the artist has been downloaded.
final artistDownloadedProvider =
    FutureProvider.family<bool, int>((ref, artistId) async {
  ref.watch(downloadStatusVersionProvider);
  final db = ref.watch(databaseProvider);
  final counts = await db.getArtistDownloadCounts([artistId]);
  final entry = counts[artistId];
  if (entry == null) return false;
  return entry.total > 0 && entry.downloaded == entry.total;
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
