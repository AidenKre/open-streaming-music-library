import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/audio/track_cache_manager.dart';
import 'package:frontend/services/download/download_queue.dart';
import 'package:frontend/services/local_cover_art_store.dart';

/// Why a single download attempt ended. Drives whether the caller marks the
/// job completed, re-queues it for retry, or fails it.
///
/// On [success], [sizeBytes] holds the number of bytes received. On
/// [otherFailure], [errorMessage] is the human-readable failure.
class DownloadOutcome {
  final DownloadOutcomeKind kind;
  final int sizeBytes;
  final String? errorMessage;
  const DownloadOutcome._(
    this.kind, {
    this.sizeBytes = 0,
    this.errorMessage,
  });

  static const cancelled = DownloadOutcome._(DownloadOutcomeKind.cancelled);
  static const networkFailure = DownloadOutcome._(
    DownloadOutcomeKind.networkFailure,
  );
  static DownloadOutcome success(int sizeBytes) =>
      DownloadOutcome._(DownloadOutcomeKind.success, sizeBytes: sizeBytes);
  static DownloadOutcome otherFailure(String message) =>
      DownloadOutcome._(DownloadOutcomeKind.otherFailure, errorMessage: message);
}

enum DownloadOutcomeKind { success, networkFailure, otherFailure, cancelled }

class _DownloadCancelled implements Exception {}

/// Runs the per-track HTTP download → file rename → DB commit pipeline.
///
/// The downloader is generation-agnostic itself: it accepts a
/// `generationCheck` callback that returns true while the work is still
/// valid (the caller bumps a generation counter when the user resets
/// downloads). The downloader bails out of the in-flight stream and any
/// commit windows whenever the check returns false.
///
/// Cancellation is also exposed via `registerCanceller` — the worker pool
/// stores the canceller so a reset can interrupt the response stream and
/// the cancel-in-flight tests can preempt before the rename.
class TrackDownloader {
  TrackDownloader({
    required AppDatabase db,
    required LocalCoverArtStore coverArtStore,
    required Future<Directory> Function() directoryProvider,
    required ApiClient apiClient,
    void Function()? onNetworkFailure,
  }) : _db = db,
       _coverArtStore = coverArtStore,
       _directoryProvider = directoryProvider,
       _apiClient = apiClient,
       _onNetworkFailure = onNetworkFailure;

  final AppDatabase _db;
  final LocalCoverArtStore _coverArtStore;
  final Future<Directory> Function() _directoryProvider;
  final ApiClient _apiClient;
  final void Function()? _onNetworkFailure;

  Directory? _downloadDir;

  /// Test seam fired immediately before the partial→destination rename. Lets
  /// a test deterministically interleave a reset with the commit step so the
  /// rename-race fix can be regressed. Surface via
  /// [DownloadManager.testHookBeforeRename] which wraps this with
  /// `@visibleForTesting`.
  Future<void> Function(String uuidId)? testHookBeforeRename;

  /// Test seam fired between the rename and the DB write. Exercises the
  /// narrower window where a worker has produced a tracked file but not yet
  /// recorded it. Surface via [DownloadManager.testHookBeforeDbWrite] which
  /// wraps this with `@visibleForTesting`.
  Future<void> Function(String uuidId)? testHookBeforeDbWrite;

  /// Downloads one job. Returns the outcome.
  ///
  /// [generationCheck] is polled before each commit window; when it returns
  /// false the in-flight work is abandoned and any partial/destination files
  /// are cleaned up.
  ///
  /// [onProgress] receives fractions in [0.0, 1.0] as bytes stream in.
  ///
  /// [registerCanceller] is invoked once with a future-producing function
  /// that, when called, cancels the HTTP stream cleanly. [unregisterCanceller]
  /// is invoked once the stream has finished (regardless of outcome).
  Future<DownloadOutcome> download({
    required DownloadJob job,
    required bool Function() generationCheck,
    required void Function(double progress) onProgress,
    required void Function(Future<void> Function() canceller) registerCanceller,
    required void Function() unregisterCanceller,
  }) async {
    final dir = await _ensureDownloadDir();
    if (!generationCheck()) {
      return DownloadOutcome.cancelled;
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
      return DownloadOutcome.otherFailure('HTTP ${e.statusCode}');
    } on NetworkException {
      // ApiClient already fired its onNetworkFailure hook for the exhausted
      // handshake; report defensively too in case it wasn't wired.
      _onNetworkFailure?.call();
      return DownloadOutcome.networkFailure;
    } catch (e) {
      // Defensive fallback for unexpected exceptions that escape ApiClient's
      // typed exceptions — without this, the worker pool never marks the job
      // failed and it stays stuck in `active`.
      return DownloadOutcome.otherFailure(e.toString());
    }
    if (!generationCheck()) {
      return DownloadOutcome.cancelled;
    }

    // Always use the server's X-Audio-Extension header for the saved extension.
    // The backend may return passthrough bytes even for a transcoded-quality
    // request (e.g. source is already at or below the requested bitrate), so
    // assuming `.m4a` for non-original would mislabel the file. Fall back to
    // 'audio' only when the header is missing.
    final ext = response.headers['x-audio-extension'] ?? 'audio';

    final destination = File(p.join(dir.path, '${job.uuidId}.$ext'));
    final partial = File('${destination.path}.partial');

    try {
      if (await partial.exists()) await partial.delete();

      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = partial.openWrite();
      StreamSubscription<List<int>>? subscription;
      final streamDone = Completer<void>();
      registerCanceller(() async {
        await subscription?.cancel();
        if (!streamDone.isCompleted) {
          streamDone.completeError(_DownloadCancelled());
        }
      });
      try {
        subscription = response.stream.listen(
          (chunk) {
            if (!generationCheck()) {
              return;
            }
            sink.add(chunk);
            received += chunk.length;
            if (total > 0) {
              onProgress(received / total);
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
        unregisterCanceller();
        await sink.close();
      }

      if (!generationCheck()) {
        await _deleteIfExists(partial);
        return DownloadOutcome.cancelled;
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
        generationCheck: generationCheck,
        downloadedBitrate: downloadedBitrate,
        downloadedQuality: job.quality,
        received: received,
      );
      if (!committed) return DownloadOutcome.cancelled;

      // Try to grab the cover art too. We don't fail the whole job if this
      // fails — the audio is what matters for playback.
      await _downloadCoverArtForTrack(job.uuidId);

      return DownloadOutcome.success(received);
    } on _DownloadCancelled {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      return DownloadOutcome.cancelled;
    } catch (e) {
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
        return DownloadOutcome.networkFailure;
      }
      return DownloadOutcome.otherFailure(e.toString());
    }
  }

  /// Performs the partial→destination rename and the DB row update under a
  /// generation guard. Returns true on commit, false if the reset generation
  /// moved during the commit (in which case any state left on disk is cleaned
  /// up so a reset doesn't leak files or DB rows).
  Future<bool> _commitDownload({
    required String uuidId,
    required File partial,
    required File destination,
    required bool Function() generationCheck,
    required int? downloadedBitrate,
    required String downloadedQuality,
    required int received,
  }) async {
    final beforeRename = testHookBeforeRename;
    if (beforeRename != null) await beforeRename(uuidId);

    if (!generationCheck()) {
      await _deleteIfExists(partial);
      return false;
    }

    if (await destination.exists()) await destination.delete();
    await partial.rename(destination.path);

    final beforeDbWrite = testHookBeforeDbWrite;
    if (beforeDbWrite != null) await beforeDbWrite(uuidId);

    // Reset happened between rename and DB write. The destination file isn't
    // referenced by any row yet, so the reset path couldn't have deleted it
    // — clean up here.
    if (!generationCheck()) {
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
        downloadedQuality: Value(downloadedQuality),
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

  /// Deletes the file at every `tracks.file_path` recorded in the DB.
  /// Best-effort — orphan files are harmless.
  Future<void> deleteKnownDownloadedFiles() async {
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

  /// Removes the entire downloads directory (including any partials).
  Future<void> deleteDownloadDirectory() async {
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
}
