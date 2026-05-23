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
import 'package:frontend/services/local_cover_art_store.dart';
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
/// 4 workers process the queue. Active jobs sit at the top of the UI list,
/// completed at the bottom (the natural ordering of the underlying list keeps
/// these positions stable). The manager writes downloaded files to the app
/// docs dir and updates `tracks.file_path` so playback can prefer the local
/// copy.
class DownloadManager extends ChangeNotifier {
  static const int maxConcurrent = 4;

  final AppDatabase _db;
  // Optional: if supplied, the server is asked to pre-transcode queued tracks
  // at the current stream quality in parallel with downloading them.
  final QueueWarmService? _warmService;
  // Provides the current stream quality for server warm calls.
  final String Function()? _streamQualityFn;
  // When true, the pump won't dispatch new workers; queued jobs wait for
  // resumeIfPaused() on recovery.
  final bool Function() _isOfflineFn;

  late final DownloadQueue _queue;
  late final TrackDownloader _downloader;
  int _activeCount = 0;
  bool _disposed = false;
  int _resetGeneration = 0;
  final Map<String, Future<void> Function()> _activeCancellers = {};
  final Map<String, Future<void>> _activeWorkers = {};

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

  late final DownloadStatusReader _status;

  /// Notified once when the underlying tracks table changes such that
  /// downloaded-status checks may have new answers. Lets the UI invalidate
  /// derived providers without polling the DB.
  ValueNotifier<int> get downloadStatusVersion => _status.downloadStatusVersion;

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
       _streamQualityFn = streamQualityFn,
       _isOfflineFn = isOfflineFn ?? (() => false) {
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
    final existingByUuid = {for (final j in _queue.state.jobs) j.uuidId: j};
    final additions = <DownloadJob>[];

    for (final t in tracks) {
      if (t.filePath != null && await File(t.filePath!).exists()) {
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

    _pump();
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
    for (final t in tracks) {
      final hasFile = t.filePath != null && await File(t.filePath!).exists();
      if (hasFile && _qualityMatches(t, quality)) {
        continue; // already at the requested quality
      }
      if (hasFile) {
        // Different quality — drop the stale local copy and queue a fresh
        // download. deleteDownload also clears tracks.file_path so the
        // skip-if-downloaded check in enqueueTracks doesn't fire.
        await deleteDownload(t.uuidId);
      }
      // Strip the file path on the in-memory copy too, otherwise the
      // skip-if-downloaded check in enqueueTracks would re-skip this track
      // based on the stale value the caller passed in.
      toEnqueue.add(hasFile ? t.copyWith(filePath: null) : t);
    }

    if (toEnqueue.isEmpty) return;
    await enqueueTracks(toEnqueue, quality: quality);
  }

  /// True iff [track]'s stored downloaded bitrate matches [quality]. Returns
  /// false for `original` (we don't know the source's true bitrate, so we
  /// conservatively re-download) and false when `downloadedBitrateKbps` is
  /// null.
  bool _qualityMatches(TrackUI track, String quality) {
    final stored = track.downloadedBitrateKbps;
    if (stored == null) return false;
    if (quality == originalQuality) return false;
    final requested = int.tryParse(quality);
    if (requested == null) return false;
    return stored == requested;
  }

  /// Drops the failed/completed history. Active and queued jobs are kept.
  void clearFinished() => _queue.clearFinished();

  /// Cancels a queued job. In-flight downloads keep running — cancelling
  /// mid-stream is intentionally not supported in v1 since aborting an http
  /// stream cleanly is fiddly and the user didn't ask for it.
  void cancelQueued(String uuidId) => _queue.cancelQueued(uuidId);

  /// Full local-reset hook. It cancels in-flight workers, clears the in-memory
  /// queue, deletes completed/partial files, and prevents stale workers from
  /// writing DB state if they complete after the reset generation changes.
  Future<void> resetAndDeleteFiles() async {
    _resetGeneration++;

    final workerSnapshot = Map<String, Future<void>>.from(_activeWorkers);
    final cancellableUuids = _activeCancellers.keys.toList(growable: false);
    for (final uuid in cancellableUuids) {
      try {
        await _activeCancellers[uuid]?.call();
      } catch (_) {}
    }

    final cancellableWorkers = [
      for (final uuid in cancellableUuids)
        if (workerSnapshot[uuid] != null) workerSnapshot[uuid]!,
    ];
    if (cancellableWorkers.isNotEmpty) {
      await Future.wait(cancellableWorkers);
    }

    _activeCount = 0;
    _activeCancellers.clear();
    _queue.clearAll();

    await _downloader.deleteKnownDownloadedFiles();
    await _downloader.deleteDownloadDirectory();

    _bumpVersion();
  }

  /// Removes the local file (if any) and clears `tracks.file_path` so the
  /// track reverts to streaming. Cover art is intentionally NOT deleted: it
  /// may be referenced by other tracks the user has downloaded.
  Future<void> deleteDownload(String uuidId) async {
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
      const TracksCompanion(filePath: Value(null)),
    );
    _bumpVersion();
  }

  Future<void> deleteDownloadsForUuids(Iterable<String> uuids) async {
    final uuidList = uuids.toList(growable: false);
    if (uuidList.isEmpty) return;

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
            .write(const TracksCompanion(filePath: Value(null)));
      }
    });

    _bumpVersion();
  }

  /// Called by OfflineModeNotifier when the network returns. Re-dispatches
  /// any jobs that were left queued while offline.
  void resumeIfPaused() {
    _pump();
  }

  void _pump() {
    // Paused while offline. Jobs sit in `queued` and get picked up by
    // resumeIfPaused() on recovery.
    if (_isOfflineFn()) return;
    while (_activeCount < maxConcurrent) {
      final idx = _queue.findFirstQueuedIndex();
      if (idx < 0) return;
      _activeCount++;
      _queue.markJob(idx, _queue.jobAt(idx).withStatus(const Active()));
      // Don't await — let workers run concurrently. Errors are captured into
      // the job's failed state.
      final generation = _resetGeneration;
      final uuidId = _queue.jobAt(idx).uuidId;
      final worker = _runJob(uuidId, generation);
      _activeWorkers[uuidId] = worker;
      unawaited(worker.whenComplete(() => _activeWorkers.remove(uuidId)));
    }
  }

  Future<void> _runJob(String uuidId, int generation) async {
    try {
      if (generation != _resetGeneration) return;
      final idx = _queue.state.jobs.indexWhere((j) => j.uuidId == uuidId);
      if (idx < 0) return;
      final job = _queue.jobAt(idx);
      final outcome = await _downloader.download(
        job: job,
        generationCheck: () => generation == _resetGeneration,
        onProgress: (progress) {
          _queue.markJobByUuid(
            job.uuidId,
            (j) => j.withStatus(Active(progress: progress)),
          );
        },
        registerCanceller: (canceller) {
          _activeCancellers[job.uuidId] = canceller;
        },
        unregisterCanceller: () {
          _activeCancellers.remove(job.uuidId);
        },
      );
      if (generation != _resetGeneration) return;
      switch (outcome.kind) {
        case DownloadOutcomeKind.success:
          _queue.markJobByUuid(
            uuidId,
            (j) => j.withStatus(Completed(sizeBytes: outcome.sizeBytes)),
          );
          _bumpVersion();
        case DownloadOutcomeKind.networkFailure:
          // Transport failure — revert to queued so the worker pool retries
          // once we're back online. The download restarts from zero, so the
          // status resets to a fresh Queued (no progress, no error).
          _queue.markJobByUuid(uuidId, (j) => j.withStatus(const Queued()));
        case DownloadOutcomeKind.otherFailure:
          _queue.markJobByUuid(
            uuidId,
            (j) => j.withStatus(
              Failed(message: outcome.errorMessage ?? 'unknown error'),
            ),
          );
        case DownloadOutcomeKind.cancelled:
          return;
      }
    } finally {
      if (generation == _resetGeneration) {
        _activeCount--;
        _pump();
      }
    }
  }

  void _bumpVersion() {
    _status.bumpVersion();
  }

  /// Returns the set of uuid_ids that have a non-null `file_path` (and the
  /// file actually exists on disk). Used by aggregate "fully downloaded"
  /// queries for albums/artists.
  Future<Set<String>> downloadedUuidsForUuids(Iterable<String> uuids) =>
      _status.downloadedUuidsForUuids(uuids);

  /// Stable, paginated view used by the downloading page.
  UnmodifiableListView<DownloadJob> snapshot() => _queue.snapshot();
}
