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
enum _DownloadOutcome { success, networkFailure, otherFailure }

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
            j.state == DownloadState.completed ||
            j.state == DownloadState.failed,
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
  })  : _db = db,
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
  /// at any quality are skipped — the user explicitly requested that changing
  /// the download quality does NOT redownload existing files.
  Future<void> enqueueTracks(List<TrackUI> tracks, {required String quality}) async {
    if (!isValidQuality(quality)) {
      throw ArgumentError('invalid download quality: $quality');
    }
    final existingByUuid = {for (final j in _state.jobs) j.uuidId: j};
    final additions = <DownloadJob>[];

    for (final t in tracks) {
      if (t.filePath != null && File(t.filePath!).existsSync()) {
        continue; // already downloaded
      }
      final existing = existingByUuid[t.uuidId];
      if (existing != null &&
          (existing.state == DownloadState.queued ||
              existing.state == DownloadState.active)) {
        continue;
      }
      additions.add(DownloadJob(
        uuidId: t.uuidId,
        title: t.title,
        artist: t.artist,
        albumId: t.albumId,
        artistId: t.artistId,
        quality: quality,
        state: DownloadState.queued,
      ));
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

  /// Drops the failed/completed history. Active and queued jobs are kept.
  void clearFinished() {
    final remaining = _state.jobs
        .where(
          (j) =>
              j.state == DownloadState.queued || j.state == DownloadState.active,
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

  /// Removes the local file (if any) and clears `tracks.file_path` so the
  /// track reverts to streaming. Cover art is intentionally NOT deleted: it
  /// may be referenced by other tracks the user has downloaded.
  Future<void> deleteDownload(String uuidId) async {
    final row = await (_db.select(_db.tracks)
          ..where((t) => t.uuidId.equals(uuidId)))
        .getSingleOrNull();
    if (row != null && row.filePath != null) {
      final f = File(row.filePath!);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    await (_db.update(_db.tracks)..where((t) => t.uuidId.equals(uuidId)))
        .write(const TracksCompanion(filePath: Value(null)));
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
      final idx =
          _state.jobs.indexWhere((j) => j.state == DownloadState.queued);
      if (idx < 0) return;
      _activeCount++;
      _markJob(idx, _state.jobs[idx].copyWith(state: DownloadState.active));
      // Don't await — let workers run concurrently. Errors are captured into
      // the job's failed state.
      unawaited(_runJob(_state.jobs[idx].uuidId));
    }
  }

  Future<void> _runJob(String uuidId) async {
    try {
      final idx = _state.jobs.indexWhere((j) => j.uuidId == uuidId);
      if (idx < 0) return;
      final job = _state.jobs[idx];
      final outcome = await _downloadOne(job);
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
      }
    } finally {
      _activeCount--;
      _pump();
    }
  }

  Future<_DownloadOutcome> _downloadOne(DownloadJob job) async {
    final dir = await _ensureDownloadDir();

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
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            _markJobByUuid(
              job.uuidId,
              (j) => j.copyWith(progress: received / total),
            );
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);

      // Try to grab the cover art too. We don't fail the whole job if this
      // fails — the audio is what matters for playback.
      await _downloadCoverArtForTrack(job.uuidId);

      // Parse the actual bitrate the server served (may differ from source).
      final bitrateHeader = response.headers['x-audio-bitrate-kbps'];
      final downloadedBitrate =
          bitrateHeader != null ? int.tryParse(bitrateHeader) : null;

      // Persist the local file path, downloaded bitrate, and file size.
      await (_db.update(_db.tracks)..where((t) => t.uuidId.equals(job.uuidId)))
          .write(TracksCompanion(
            filePath: Value(destination.path),
            downloadedBitrateKbps: Value(downloadedBitrate),
            fileSizeBytes: Value(received),
          ));

      _markJobByUuid(job.uuidId, (j) => j.copyWith(fileSizeBytes: received));

      return _DownloadOutcome.success;
    } catch (e) {
      _markJobByUuid(
        job.uuidId,
        (j) => j.copyWith(errorMessage: e.toString()),
      );
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
      if (path != null && File(path).existsSync()) {
        result.add(r.read<String>('uuid_id'));
      }
    }
    return result;
  }

  /// Stable, paginated view used by the downloading page.
  UnmodifiableListView<DownloadJob> snapshot() =>
      UnmodifiableListView(_state.jobs);
}
