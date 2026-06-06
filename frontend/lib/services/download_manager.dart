import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/download/download_queue.dart';
import 'package:frontend/services/download/download_status_reader.dart';
import 'package:frontend/services/download/track_downloader.dart';
import 'package:frontend/services/download/worker_pool.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/queue_warm_service.dart';

// Re-export the sealed status hierarchy + job/state types so existing
// consumers (UI, providers, tests) keep importing them via this file.
export 'package:frontend/services/download/download_queue.dart'
    show
        DownloadJob,
        DownloadStatus,
        Queued,
        Active,
        Completed,
        Failed,
        DownloadQueueState;

String formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Coordinates concurrent track + cover-art downloads.
///
/// Façade over four single-responsibility collaborators:
/// * [DownloadQueue] — the in-memory job list + change notifications.
/// * [TrackDownloader] — the per-job HTTP→file→DB pipeline.
/// * [WorkerPool] — concurrency + generation gating.
/// * [DownloadStatusReader] — DB read-side helpers + change-version.
///
/// The public API forwards to these — see each method for which one it
/// delegates to. Active jobs sit at the top of the UI list, completed at
/// the bottom (the natural ordering of the underlying queue keeps these
/// positions stable). The manager writes downloaded files to the app docs
/// dir and updates `tracks.file_path` so playback can prefer the local
/// copy.
class DownloadManager extends ChangeNotifier implements LocalResettable {
  final AppDatabase _db;
  // Optional: if supplied, the server is asked to pre-transcode queued tracks
  // at the current stream quality in parallel with downloading them.
  final QueueWarmService? _warmService;
  // Provides the current stream quality for server warm calls.
  final String Function()? _streamQualityFn;

  late final DownloadQueue _queue;
  late final TrackDownloader _downloader;
  late final WorkerPool _pool;
  late final DownloadStatusReader _status;
  bool _disposed = false;

  /// Test seam fired immediately before the partial→destination rename. Lets a
  /// test deterministically interleave [resetAndDeleteFiles] with the commit
  /// step so the rename-race fix can be regressed. Forwards to the inner
  /// [TrackDownloader].
  @visibleForTesting
  set testHookBeforeRename(Future<void> Function(String uuidId)? hook) {
    _downloader.testHookBeforeRename = hook;
  }

  @visibleForTesting
  Future<void> Function(String uuidId)? get testHookBeforeRename =>
      _downloader.testHookBeforeRename;

  /// Test seam fired between the rename and the DB write. Exercises the
  /// narrower window where a worker has produced a tracked file but not yet
  /// recorded it. Forwards to the inner [TrackDownloader].
  @visibleForTesting
  set testHookBeforeDbWrite(Future<void> Function(String uuidId)? hook) {
    _downloader.testHookBeforeDbWrite = hook;
  }

  @visibleForTesting
  Future<void> Function(String uuidId)? get testHookBeforeDbWrite =>
      _downloader.testHookBeforeDbWrite;

  /// Notified once when the underlying tracks table changes such that
  /// downloaded-status checks may have new answers. Lets the UI invalidate
  /// derived providers without polling the DB.
  ValueNotifier<int> get downloadStatusVersion => _status.downloadStatusVersion;

  /// Exposed so reconciliation can bump the same change-version that download
  /// completion uses; consumers should not depend on its members.
  DownloadStatusReader get statusReader => _status;

  DownloadManager({
    required AppDatabase db,
    required LocalCoverArtStore coverArtStore,
    Future<Directory> Function()? directoryProvider,
    QueueWarmService? warmService,
    String Function()? streamQualityFn,
    ApiClient? apiClient,
    bool Function()? isOfflineFn,
    void Function()? onNetworkFailure,
  }) : _db = db,
       _warmService = warmService,
       _streamQualityFn = streamQualityFn {
    _status = DownloadStatusReader(db: db);
    _queue = DownloadQueue();
    _queue.addListener(notifyListeners);
    _downloader = TrackDownloader(
      db: db,
      coverArtStore: coverArtStore,
      directoryProvider:
          directoryProvider ?? getApplicationDocumentsDirectory,
      apiClient: apiClient ?? ApiClient.instance,
      onNetworkFailure: onNetworkFailure,
    );
    _pool = WorkerPool(
      queue: _queue,
      downloader: _downloader,
      isOffline: isOfflineFn ?? (() => false),
      onCompleted: _status.bumpVersion,
    );
  }

  DownloadQueueState get state => _queue.state;

  @override
  void dispose() {
    // Idempotent: downloadManagerProvider registers a dispose hook and the
    // ChangeNotifierProvider exposing the manager disposes it too, so this can
    // be called twice when a ProviderScope tears down.
    if (_disposed) return;
    _disposed = true;
    _queue.removeListener(notifyListeners);
    _queue.dispose();
    _status.dispose();
    super.dispose();
  }

  /// Schedules [tracks] for download at [quality]. Tracks already downloaded
  /// at any quality are skipped — the default-quality download path does NOT
  /// redownload existing files. Callers wanting "give me this at quality X
  /// even if I already have it at Y" should use [enqueueTracksAtQuality].
  Future<void> enqueueTracks(
    List<TrackUI> tracks, {
    required String quality,
  }) async {
    if (!isValidQuality(quality)) {
      throw ArgumentError('invalid download quality: $quality');
    }
    return _enqueueInternal(tracks, quality: quality, replacements: const {});
  }

  Future<void> _enqueueInternal(
    List<TrackUI> tracks, {
    required String quality,
    required Map<String, String> replacements,
  }) async {
    final existingByUuid = {for (final j in _queue.state.jobs) j.uuidId: j};
    final additions = <DownloadJob>[];

    for (final t in tracks) {
      final replaces = replacements[t.uuidId];
      // Fresh (non-replacement) jobs skip when a file is already on disk;
      // replacement jobs deliberately keep going — that's the whole point.
      if (replaces == null &&
          t.filePath != null &&
          await File(t.filePath!).exists()) {
        continue; // already downloaded
      }
      final existing = existingByUuid[t.uuidId];
      if (existing != null && (existing.isQueued || existing.isActive)) {
        continue;
      }
      additions.add(
        DownloadJob(
          uuidId: t.uuidId,
          title: t.title,
          artist: t.artist,
          albumId: t.albumId,
          artistId: t.artistId,
          quality: quality,
          status: const Queued(),
          replacesFilePath: replaces,
        ),
      );
    }

    if (additions.isEmpty) return;

    _queue.addAll(additions);

    // Ask the server to pre-transcode queued tracks at the current stream
    // quality in parallel. This way, if the user streams a track before its
    // download finishes, the encode may already be cached.
    final warm = _warmService;
    final qualityFn = _streamQualityFn;
    if (warm != null && qualityFn != null) {
      warm.scheduleWarmUuids(
        additions.map((j) => j.uuidId).toList(growable: false),
        quality: qualityFn(),
      );
    }

    _pool.pump();
  }

  /// Schedules [tracks] for download at [quality], re-downloading any track
  /// whose currently-stored file is at a different bitrate. Tracks whose
  /// `downloadedBitrateKbps` already matches the requested kbps are skipped.
  ///
  /// This is the "explicit user intent" path: when someone picks
  /// "Download at 320 kbps" from the split-download menu, they want a 320
  /// kbps copy regardless of what's on disk. Compare with [enqueueTracks],
  /// which preserves whatever copy already exists.
  ///
  /// Edge case: when [quality] is `original`, the requested-kbps lookup is
  /// undefined (the source bitrate is unknown to the client). We treat that
  /// as "always re-download" if a file is on disk — that's strictly better
  /// than silently no-op'ing.
  Future<void> enqueueTracksAtQuality(
    List<TrackUI> tracks, {
    required String quality,
  }) async {
    if (!isValidQuality(quality)) {
      throw ArgumentError('invalid download quality: $quality');
    }

    final toEnqueue = <TrackUI>[];
    final replacements = <String, String>{};
    for (final t in tracks) {
      final hasFile = t.filePath != null && await File(t.filePath!).exists();
      if (hasFile && _qualityMatches(t, quality)) {
        continue; // already at the requested quality
      }
      if (hasFile) {
        // Different quality — schedule a two-phase replacement so the working
        // copy survives a failed/cancelled redownload. The downloader writes
        // to a distinct path, swaps the DB row, then removes the old file.
        replacements[t.uuidId] = t.filePath!;
      }
      toEnqueue.add(t);
    }

    if (toEnqueue.isEmpty) return;
    await _enqueueInternal(
      toEnqueue,
      quality: quality,
      replacements: replacements,
    );
  }

  /// True iff [track]'s file on disk was produced by a request for [quality].
  ///
  /// Uses the stored `downloadedQuality` (the preset that produced the file),
  /// not the actual on-disk bitrate — these can differ when the backend
  /// served a passthrough (e.g. requested 320 on a 96 kbps source returns
  /// the original bytes, with `downloadedBitrateKbps=96` but
  /// `downloadedQuality='320'`). Matching on the actual bitrate would cause
  /// non-idempotent redownload loops in that case.
  ///
  /// Returns false when `downloadedQuality` is null, which happens for files
  /// downloaded before this column existed; the explicit-quality path will
  /// then re-download once to populate the field.
  bool _qualityMatches(TrackUI track, String quality) {
    final stored = track.downloadedQuality;
    if (stored != null) return stored == quality;
    // Back-compat for files saved before downloadedQuality existed: keep the
    // old bitrate-based check so we don't force a redownload of every
    // pre-migration file the first time the user touches it. Original-quality
    // requests still conservatively re-download (we can't know the source
    // bitrate from the client).
    if (quality == originalQuality) return false;
    final bitrate = track.downloadedBitrateKbps;
    if (bitrate == null) return false;
    final requested = int.tryParse(quality);
    if (requested == null) return false;
    return bitrate == requested;
  }

  /// Drops the failed/completed history. Active and queued jobs are kept.
  void clearFinished() => _queue.clearFinished();

  /// Cancels a queued job. In-flight downloads keep running — cancelling
  /// mid-stream is intentionally not supported in v1 since aborting an http
  /// stream cleanly is fiddly and the user didn't ask for it.
  void cancelQueued(String uuidId) => _queue.cancelQueued(uuidId);

  /// Full local-reset hook. Cancels in-flight workers, clears the in-memory
  /// queue, deletes completed/partial files, and prevents stale workers from
  /// writing DB state if they complete after the reset generation changes.
  Future<void> resetAndDeleteFiles() async {
    await _pool.reset();
    _status.bumpVersion();
  }

  // --- LocalResettable -------------------------------------------------------
  // The manager owns both in-flight workers and on-disk files. Slot at
  // [ResetPriority.cancelInFlight] (higher than file deletion) because the
  // pool.reset() call itself stops workers _then_ deletes their files: we
  // must run before the database step drops the rows that point at them.
  @override
  int get resetPriority => ResetPriority.cancelInFlight;

  @override
  Future<void> resetLocalState() => resetAndDeleteFiles();

  /// Removes the local file (if any) and clears `tracks.file_path` so the
  /// track reverts to streaming. Cover art is intentionally NOT deleted: it
  /// may be referenced by other tracks the user has downloaded.
  ///
  /// Cancels any queued/active download for [uuidId] first so a late
  /// `_commitDownload` can't restore the row after we null it out.
  Future<void> deleteDownload(String uuidId) async {
    await _pool.fenceUuid(uuidId);
    final row = await (_db.select(
      _db.tracks,
    )..where((t) => t.uuidId.equals(uuidId))).getSingleOrNull();
    if (row != null && row.filePath != null) {
      final f = File(row.filePath!);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    await (_db.update(_db.tracks)..where((t) => t.uuidId.equals(uuidId))).write(
      const TracksCompanion(
        filePath: Value(null),
        downloadedBitrateKbps: Value(null),
        fileSizeBytes: Value(null),
        downloadedQuality: Value(null),
      ),
    );
    _status.bumpVersion();
  }

  Future<void> deleteDownloadsForUuids(Iterable<String> uuids) async {
    final uuidList = uuids.toList(growable: false);
    if (uuidList.isEmpty) return;

    // Cancel any queued/active downloads for these uuids before touching the
    // DB so a worker that's already in its commit window can't write a new
    // file_path after we null them out.
    await _pool.fenceUuids(uuidList);

    // 1. Read current file paths in one query.
    final placeholders = List.filled(uuidList.length, '?').join(', ');
    final rows = await _db
        .customSelect(
          'SELECT uuid_id, file_path FROM tracks '
          'WHERE uuid_id IN ($placeholders) AND file_path IS NOT NULL',
          variables: uuidList.map(Variable.withString).toList(),
        )
        .get();

    // 2. Delete files from disk (best-effort — orphan files are harmless).
    for (final row in rows) {
      final path = row.readNullable<String>('file_path');
      if (path != null) {
        final f = File(path);
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }

    // 3. Null out all file_paths in a single transaction.
    await _db.transaction(() async {
      for (final uuid in uuidList) {
        await (_db.update(_db.tracks)..where((t) => t.uuidId.equals(uuid)))
            .write(const TracksCompanion(
          filePath: Value(null),
          downloadedBitrateKbps: Value(null),
          fileSizeBytes: Value(null),
          downloadedQuality: Value(null),
        ));
      }
    });

    _status.bumpVersion();
  }

  /// Called by OfflineModeNotifier when the network returns. Re-dispatches
  /// any jobs that were left queued while offline.
  void resumeIfPaused() => _pool.pump();

  /// Returns the set of uuid_ids that have a non-null `file_path` (and the
  /// file actually exists on disk). Used by aggregate "fully downloaded"
  /// queries for albums/artists.
  Future<Set<String>> downloadedUuidsForUuids(Iterable<String> uuids) =>
      _status.downloadedUuidsForUuids(uuids);

  /// Stable, paginated view used by the downloading page.
  UnmodifiableListView<DownloadJob> snapshot() => _queue.snapshot();
}
