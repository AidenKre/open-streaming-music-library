import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/track_cache_manager.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/queue_warm_service.dart';

enum DownloadState { queued, active, completed, failed }

/// Why a single download attempt ended. Drives whether [DownloadManager]
/// marks the job completed, re-queues it for retry, or fails it.
enum _DownloadOutcome { success, networkFailure, otherFailure, cancelled }

class _DownloadCancelled implements Exception {}

/// Sentinel for [DownloadJob.copyWith] so a caller can pass `errorMessage:
/// null` to genuinely clear the field (a plain `null` default is
/// indistinguishable from "not supplied").
const Object _sentinel = Object();

String formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Snapshot of one download as exposed to the UI. The job IS the track —
/// users can have at most one in-flight download per uuid.
@immutable
class DownloadJob {
  final String uuidId;
  final String? title;
  final String? artist;
  final int? albumId;
  final int? artistId;
  final String quality;
  final DownloadState state;
  final double progress; // 0.0..1.0; only meaningful while active
  final String? errorMessage;
  final int? fileSizeBytes;

  const DownloadJob({
    required this.uuidId,
    required this.title,
    required this.artist,
    required this.quality,
    required this.state,
    this.albumId,
    this.artistId,
    this.progress = 0.0,
    this.errorMessage,
    this.fileSizeBytes,
  });

  DownloadJob copyWith({
    DownloadState? state,
    double? progress,
    Object? errorMessage = _sentinel,
    int? fileSizeBytes,
  }) {
    return DownloadJob(
      uuidId: uuidId,
      title: title,
      artist: artist,
      albumId: albumId,
      artistId: artistId,
      quality: quality,
      state: state ?? this.state,
      progress: progress ?? this.progress,
      errorMessage: errorMessage == _sentinel
          ? this.errorMessage
          : errorMessage as String?,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
    );
  }
}

/// In-memory list of jobs partitioned by state. The user requested that this
/// list only resets on app restart or explicit "clear", so we keep completed
/// jobs around forever during the session.
@immutable
class DownloadQueueState {
  final List<DownloadJob> jobs;
  const DownloadQueueState({this.jobs = const []});

  Iterable<DownloadJob> get active =>
      jobs.where((j) => j.state == DownloadState.active);
  Iterable<DownloadJob> get queued =>
      jobs.where((j) => j.state == DownloadState.queued);
  Iterable<DownloadJob> get finished => jobs.where(
    (j) =>
        j.state == DownloadState.completed || j.state == DownloadState.failed,
  );
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
  final LocalCoverArtStore _coverArtStore;
  final Future<Directory> Function() _directoryProvider;
  // Optional: if supplied, the server is asked to pre-transcode queued tracks
  // at the current stream quality in parallel with downloading them.
  final QueueWarmService? _warmService;
  // Provides the current stream quality for server warm calls.
  final String Function()? _streamQualityFn;
  final ApiClient _apiClient;
  // When true, the pump won't dispatch new workers; queued jobs wait for
  // resumeIfPaused() on recovery.
  final bool Function() _isOfflineFn;
  // Reports a transport failure so the app enters offline mode. Called when a
  // download drops mid-stream — that failure happens after ApiClient handed us
  // the response, so ApiClient's own onNetworkFailure hook never fires.
  final void Function()? _onNetworkFailure;

  DownloadQueueState _state = const DownloadQueueState();
  Directory? _downloadDir;
  int _activeCount = 0;
  bool _disposed = false;
  int _resetGeneration = 0;
  final Map<String, Future<void> Function()> _activeCancellers = {};
  final Map<String, Future<void>> _activeWorkers = {};

  /// Test seam fired immediately before the partial→destination rename. Lets a
  /// test deterministically interleave [resetAndDeleteFiles] with the commit
  /// step so the rename-race fix can be regressed.
  @visibleForTesting
  Future<void> Function(String uuidId)? testHookBeforeRename;

  /// Test seam fired between the rename and the DB write. Exercises the
  /// narrower window where a worker has produced a tracked file but not yet
  /// recorded it.
  @visibleForTesting
  Future<void> Function(String uuidId)? testHookBeforeDbWrite;

  /// Notified once when the underlying tracks table changes such that
  /// downloaded-status checks may have new answers. Lets the UI invalidate
  /// derived providers without polling the DB.
  final ValueNotifier<int> downloadStatusVersion = ValueNotifier<int>(0);

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
       _coverArtStore = coverArtStore,
       _directoryProvider =
           directoryProvider ?? getApplicationDocumentsDirectory,
       _warmService = warmService,
       _streamQualityFn = streamQualityFn,
       _apiClient = apiClient ?? ApiClient.instance,
       _isOfflineFn = isOfflineFn ?? (() => false),
       _onNetworkFailure = onNetworkFailure;

  DownloadQueueState get state => _state;

  @override
  void dispose() {
    // Idempotent: downloadManagerProvider registers a dispose hook and the
    // ChangeNotifierProvider exposing the manager disposes it too, so this can
    // be called twice when a ProviderScope tears down.
    if (_disposed) return;
    _disposed = true;
    downloadStatusVersion.dispose();
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
    final existingByUuid = {for (final j in _state.jobs) j.uuidId: j};
    final additions = <DownloadJob>[];

    for (final t in tracks) {
      if (t.filePath != null && await File(t.filePath!).exists()) {
        continue; // already downloaded
      }
      final existing = existingByUuid[t.uuidId];
      if (existing != null &&
          (existing.state == DownloadState.queued ||
              existing.state == DownloadState.active)) {
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
          state: DownloadState.queued,
        ),
      );
    }

    if (additions.isEmpty) return;

    _state = DownloadQueueState(jobs: [..._state.jobs, ...additions]);
    notifyListeners();

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
  void clearFinished() {
    final remaining = _state.jobs
        .where(
          (j) =>
              j.state == DownloadState.queued ||
              j.state == DownloadState.active,
        )
        .toList(growable: false);
    _state = DownloadQueueState(jobs: remaining);
    notifyListeners();
  }

  /// Cancels a queued job. In-flight downloads keep running — cancelling
  /// mid-stream is intentionally not supported in v1 since aborting an http
  /// stream cleanly is fiddly and the user didn't ask for it.
  void cancelQueued(String uuidId) {
    final idx = _state.jobs.indexWhere((j) => j.uuidId == uuidId);
    if (idx < 0) return;
    final job = _state.jobs[idx];
    if (job.state != DownloadState.queued) return;
    final updated = [..._state.jobs]..removeAt(idx);
    _state = DownloadQueueState(jobs: updated);
    notifyListeners();
  }

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
    _state = const DownloadQueueState();

    await _deleteKnownDownloadedFiles();
    await _deleteDownloadDirectory();

    _bumpVersion();
    notifyListeners();
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
      final idx = _state.jobs.indexWhere(
        (j) => j.state == DownloadState.queued,
      );
      if (idx < 0) return;
      _activeCount++;
      _markJob(idx, _state.jobs[idx].copyWith(state: DownloadState.active));
      // Don't await — let workers run concurrently. Errors are captured into
      // the job's failed state.
      final generation = _resetGeneration;
      final uuidId = _state.jobs[idx].uuidId;
      final worker = _runJob(uuidId, generation);
      _activeWorkers[uuidId] = worker;
      unawaited(worker.whenComplete(() => _activeWorkers.remove(uuidId)));
    }
  }

  Future<void> _runJob(String uuidId, int generation) async {
    try {
      if (generation != _resetGeneration) return;
      final idx = _state.jobs.indexWhere((j) => j.uuidId == uuidId);
      if (idx < 0) return;
      final job = _state.jobs[idx];
      final outcome = await _downloadOne(job, generation);
      if (generation != _resetGeneration) return;
      switch (outcome) {
        case _DownloadOutcome.success:
          _markJobByUuid(
            uuidId,
            (j) => j.copyWith(state: DownloadState.completed, progress: 1.0),
          );
          _bumpVersion();
        case _DownloadOutcome.networkFailure:
          // Transport failure — revert to queued so the worker pool retries
          // once we're back online. The download restarts from zero, so
          // reset progress and clear the error.
          _markJobByUuid(
            uuidId,
            (j) => j.copyWith(
              state: DownloadState.queued,
              progress: 0.0,
              errorMessage: null,
            ),
          );
        case _DownloadOutcome.otherFailure:
          _markJobByUuid(
            uuidId,
            (j) => j.copyWith(state: DownloadState.failed),
          );
        case _DownloadOutcome.cancelled:
          return;
      }
    } finally {
      if (generation == _resetGeneration) {
        _activeCount--;
        _pump();
      }
    }
  }

  Future<_DownloadOutcome> _downloadOne(DownloadJob job, int generation) async {
    final dir = await _ensureDownloadDir();
    if (generation != _resetGeneration) {
      return _DownloadOutcome.cancelled;
    }

    http.StreamedResponse response;
    try {
      response = await _apiClient.send(
        () => http.Request(
          'GET',
          buildTrackStreamUri(job.uuidId, quality: job.quality),
        ),
      );
    } on ApiException catch (e) {
      _markJobByUuid(
        job.uuidId,
        (j) => j.copyWith(errorMessage: 'HTTP ${e.statusCode}'),
      );
      return _DownloadOutcome.otherFailure;
    } on NetworkException catch (e) {
      // ApiClient already fired its onNetworkFailure hook for the exhausted
      // handshake; report defensively too in case it wasn't wired.
      _markJobByUuid(
        job.uuidId,
        (j) => j.copyWith(errorMessage: 'Connection failed: ${e.message}'),
      );
      _onNetworkFailure?.call();
      return _DownloadOutcome.networkFailure;
    } catch (e) {
      // Defensive fallback for unexpected exceptions that escape ApiClient's
      // typed exceptions — without this, _runJob never marks the job failed
      // and it stays stuck in `active`.
      _markJobByUuid(job.uuidId, (j) => j.copyWith(errorMessage: e.toString()));
      return _DownloadOutcome.otherFailure;
    }
    if (generation != _resetGeneration) {
      return _DownloadOutcome.cancelled;
    }

    // ApiClient.send guarantees a 2xx response or throws — no defensive check needed.

    // Determine the file extension from the server's X-Audio-Extension header.
    // Transcoded files are always m4a; originals get their actual extension.
    // Fall back to 'audio' only as a last resort (AVFoundation rejects unknown
    // extensions, but 'audio' is better than a silent failure from a wrong one).
    final ext = job.quality != originalQuality
        ? 'm4a'
        : (response.headers['x-audio-extension'] ?? 'audio');

    final destination = File(p.join(dir.path, '${job.uuidId}.$ext'));
    final partial = File('${destination.path}.partial');

    try {
      if (await partial.exists()) await partial.delete();

      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = partial.openWrite();
      StreamSubscription<List<int>>? subscription;
      final streamDone = Completer<void>();
      _activeCancellers[job.uuidId] = () async {
        await subscription?.cancel();
        if (!streamDone.isCompleted) {
          streamDone.completeError(_DownloadCancelled());
        }
      };
      try {
        subscription = response.stream.listen(
          (chunk) {
            if (generation != _resetGeneration) {
              return;
            }
            sink.add(chunk);
            received += chunk.length;
            if (total > 0) {
              _markJobByUuid(
                job.uuidId,
                (j) => j.copyWith(progress: received / total),
              );
            }
          },
          onDone: () {
            if (!streamDone.isCompleted) {
              streamDone.complete();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!streamDone.isCompleted) {
              streamDone.completeError(error, stackTrace);
            }
          },
          cancelOnError: true,
        );
        await streamDone.future;
        await sink.flush();
      } finally {
        _activeCancellers.remove(job.uuidId);
        await sink.close();
      }

      if (generation != _resetGeneration) {
        await _deleteIfExists(partial);
        return _DownloadOutcome.cancelled;
      }

      // Parse the actual bitrate the server served (may differ from source).
      final bitrateHeader = response.headers['x-audio-bitrate-kbps'];
      final downloadedBitrate = bitrateHeader != null
          ? int.tryParse(bitrateHeader)
          : null;

      final committed = await _commitDownload(
        uuidId: job.uuidId,
        partial: partial,
        destination: destination,
        generation: generation,
        downloadedBitrate: downloadedBitrate,
        received: received,
      );
      if (!committed) return _DownloadOutcome.cancelled;

      // Try to grab the cover art too. We don't fail the whole job if this
      // fails — the audio is what matters for playback.
      await _downloadCoverArtForTrack(job.uuidId);

      _markJobByUuid(job.uuidId, (j) => j.copyWith(fileSizeBytes: received));

      return _DownloadOutcome.success;
    } on _DownloadCancelled {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      return _DownloadOutcome.cancelled;
    } catch (e) {
      _markJobByUuid(job.uuidId, (j) => j.copyWith(errorMessage: e.toString()));
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      // A drop after headers arrived doesn't surface through ApiClient (the
      // response stream was already handed to us), so classify it here: a
      // transport error re-queues for retry, anything else (e.g. a disk
      // write failure) is a genuine, permanent failure.
      if (e is SocketException ||
          e is http.ClientException ||
          e is TimeoutException) {
        _onNetworkFailure?.call();
        return _DownloadOutcome.networkFailure;
      }
      return _DownloadOutcome.otherFailure;
    }
  }

  /// Performs the partial→destination rename and the DB row update under a
  /// generation guard. Returns true on commit, false if the reset generation
  /// moved during the commit (in which case any state left on disk is cleaned
  /// up so [resetAndDeleteFiles] doesn't leak files or DB rows).
  Future<bool> _commitDownload({
    required String uuidId,
    required File partial,
    required File destination,
    required int generation,
    required int? downloadedBitrate,
    required int received,
  }) async {
    final beforeRename = testHookBeforeRename;
    if (beforeRename != null) await beforeRename(uuidId);

    if (generation != _resetGeneration) {
      await _deleteIfExists(partial);
      return false;
    }

    if (await destination.exists()) await destination.delete();
    await partial.rename(destination.path);

    final beforeDbWrite = testHookBeforeDbWrite;
    if (beforeDbWrite != null) await beforeDbWrite(uuidId);

    // Reset happened between rename and DB write. The destination file isn't
    // referenced by any row yet, so resetAndDeleteFiles couldn't have deleted
    // it — clean up here.
    if (generation != _resetGeneration) {
      await _deleteIfExists(destination);
      return false;
    }

    await (_db.update(
      _db.tracks,
    )..where((t) => t.uuidId.equals(uuidId))).write(
      TracksCompanion(
        filePath: Value(destination.path),
        downloadedBitrateKbps: Value(downloadedBitrate),
        fileSizeBytes: Value(received),
      ),
    );
    return true;
  }

  Future<void> _downloadCoverArtForTrack(String uuidId) async {
    final row = await _db
        .customSelect(
          'SELECT cover_art_id, has_album_art FROM trackmetadata WHERE uuid_id = ? LIMIT 1',
          variables: [Variable.withString(uuidId)],
        )
        .getSingleOrNull();
    if (row == null) return;
    final coverArtId = row.readNullable<int>('cover_art_id');
    final hasAlbumArt = row.read<bool>('has_album_art');
    if (!hasAlbumArt || coverArtId == null) return;
    if (_coverArtStore.has(coverArtId)) return;
    await _coverArtStore.download(coverArtId);
  }

  Future<Directory> _ensureDownloadDir() async {
    if (_downloadDir != null) return _downloadDir!;
    final base = await _directoryProvider();
    final dir = Directory(p.join(base.path, 'tracks'));
    await dir.create(recursive: true);
    _downloadDir = dir;
    return dir;
  }

  Future<void> _deleteKnownDownloadedFiles() async {
    final rows = await _db
        .customSelect(
          'SELECT file_path FROM tracks WHERE file_path IS NOT NULL',
          readsFrom: {_db.tracks},
        )
        .get();
    for (final row in rows) {
      final path = row.readNullable<String>('file_path');
      if (path == null) continue;
      await _deleteIfExists(File(path));
    }
  }

  Future<void> _deleteDownloadDirectory() async {
    final dir =
        _downloadDir ??
        Directory(p.join((await _directoryProvider()).path, 'tracks'));
    _downloadDir = null;
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  void _markJob(int idx, DownloadJob updated) {
    final next = [..._state.jobs];
    next[idx] = updated;
    _state = DownloadQueueState(jobs: next);
    notifyListeners();
  }

  void _markJobByUuid(String uuidId, DownloadJob Function(DownloadJob) fn) {
    final idx = _state.jobs.indexWhere((j) => j.uuidId == uuidId);
    if (idx < 0) return;
    _markJob(idx, fn(_state.jobs[idx]));
  }

  void _bumpVersion() {
    downloadStatusVersion.value += 1;
  }

  /// Returns the set of uuid_ids that have a non-null `file_path` (and the
  /// file actually exists on disk). Used by aggregate "fully downloaded"
  /// queries for albums/artists.
  Future<Set<String>> downloadedUuidsForUuids(Iterable<String> uuids) async {
    final unique = uuids.toSet().toList(growable: false);
    if (unique.isEmpty) return const <String>{};
    final placeholders = List.filled(unique.length, '?').join(', ');
    final rows = await _db
        .customSelect(
          'SELECT uuid_id, file_path FROM tracks '
          'WHERE uuid_id IN ($placeholders) AND file_path IS NOT NULL',
          variables: unique.map(Variable.withString).toList(),
        )
        .get();
    final result = <String>{};
    for (final r in rows) {
      final path = r.readNullable<String>('file_path');
      if (path != null && await File(path).exists()) {
        result.add(r.read<String>('uuid_id'));
      }
    }
    return result;
  }

  /// Stable, paginated view used by the downloading page.
  UnmodifiableListView<DownloadJob> snapshot() =>
      UnmodifiableListView(_state.jobs);
}
