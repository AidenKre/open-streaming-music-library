import 'dart:async';

import 'package:frontend/services/download/download_queue.dart';
import 'package:frontend/services/download/track_downloader.dart';

/// Schedules up to [maxConcurrent] in-flight [TrackDownloader.download] calls,
/// pulls the next queued [DownloadJob] from the [DownloadQueue] when slots
/// free, and updates the queue based on each download's outcome.
///
/// Owns the **reset generation**: a counter incremented on every [reset] so
/// in-flight workers can detect a wipe via the `generationCheck` callback
/// they hand to the downloader. Workers that finish after a reset short-
/// circuit their queue updates so a fresh queue isn't polluted by stale
/// results.
class WorkerPool {
  WorkerPool({
    required DownloadQueue queue,
    required TrackDownloader downloader,
    required bool Function() isOffline,
    required void Function() onCompleted,
  }) : _queue = queue,
       _downloader = downloader,
       _isOffline = isOffline,
       _onCompleted = onCompleted;

  static const int maxConcurrent = 4;

  final DownloadQueue _queue;
  final TrackDownloader _downloader;
  final bool Function() _isOffline;
  // Called once per successful download so the manager can bump the
  // downloaded-status version notifier.
  final void Function() _onCompleted;

  int _activeCount = 0;
  int _resetGeneration = 0;
  final Map<String, Future<void> Function()> _activeCancellers = {};
  final Map<String, Future<void>> _activeWorkers = {};

  /// Schedules queued jobs. Idempotent — safe to call repeatedly.
  void pump() {
    // Paused while offline. Jobs sit in `queued` and get picked up by [pump]
    // again on recovery.
    if (_isOffline()) return;
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

  /// Cancels in-flight downloads, bumps the generation, awaits cancellable
  /// workers, clears in-memory queue state, then asks the downloader to
  /// remove all known files + the downloads directory.
  Future<void> reset() async {
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
          _onCompleted();
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
        pump();
      }
    }
  }
}
