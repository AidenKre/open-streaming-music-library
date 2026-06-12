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
  // Per-uuid tombstones held only for the duration of a [fenceUuid] call so
  // an in-flight worker that's already past its last generation check can
  // still observe the fence at the rename/DB-write boundaries (and clean up).
  // Scoped this narrowly because a long-lived tombstone would block the
  // immediate re-enqueue that callers like enqueueTracksAtQuality rely on.
  final Set<String> _fencedUuids = {};

  /// True iff [uuidId] is currently being fenced by [fenceUuid]. Workers
  /// poll this at every commit checkpoint to bail out cleanly when their
  /// download is being deleted out from under them.
  bool isFenced(String uuidId) => _fencedUuids.contains(uuidId);

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

  /// Removes any queued job for [uuidId] and fences an active worker so it
  /// abandons the in-flight download before committing. Awaits the active
  /// worker (if any) so the caller can safely clear DB state afterward
  /// without racing against a late `_commitDownload`.
  ///
  /// The fence is released once this future completes; callers that need the
  /// uuid blocked for longer should hold the fence themselves.
  Future<void> fenceUuid(String uuidId) async {
    _fencedUuids.add(uuidId);
    try {
      _queue.removeJob(uuidId);
      await _cancelAndAwait([uuidId]);
    } finally {
      _fencedUuids.remove(uuidId);
    }
  }

  /// Bulk variant of [fenceUuid].
  Future<void> fenceUuids(Iterable<String> uuids) async {
    final list = uuids.toList(growable: false);
    if (list.isEmpty) return;
    _fencedUuids.addAll(list);
    try {
      for (final uuid in list) {
        _queue.removeJob(uuid);
      }
      await _cancelAndAwait(list);
    } finally {
      _fencedUuids.removeAll(list);
    }
  }

  /// Cancels in-flight downloads, bumps the generation, awaits cancellable
  /// workers, clears in-memory queue state, then asks the downloader to
  /// remove all known files + the downloads directory.
  Future<void> reset() async {
    _resetGeneration++;

    await _cancelAndAwait(_activeCancellers.keys.toList(growable: false));

    _activeCount = 0;
    _activeCancellers.clear();
    _queue.clearAll();

    await _downloader.deleteKnownDownloadedFiles();
    await _downloader.deleteDownloadDirectory();
  }

  /// Cancels the in-flight canceller (if any) for each uuid, then awaits the
  /// matching active workers in parallel. Cancelling ALL workers before
  /// awaiting any is the load-bearing ordering: awaiting one worker before
  /// cancelling the rest would serialise the teardown. Workers are snapshotted
  /// up front because a worker completing mid-call mutates [_activeWorkers].
  Future<void> _cancelAndAwait(Iterable<String> uuids) async {
    final list = uuids.toList(growable: false);
    if (list.isEmpty) return;
    final workers = [
      for (final uuid in list)
        if (_activeWorkers[uuid] != null) _activeWorkers[uuid]!,
    ];
    for (final uuid in list) {
      final canceller = _activeCancellers[uuid];
      if (canceller != null) {
        try {
          await canceller();
        } catch (_) {}
      }
    }
    if (workers.isNotEmpty) {
      await Future.wait(workers);
    }
  }

  Future<void> _runJob(String uuidId, int generation) async {
    try {
      if (generation != _resetGeneration) return;
      final idx = _queue.state.jobs.indexWhere((j) => j.uuidId == uuidId);
      if (idx < 0) return;
      final job = _queue.jobAt(idx);
      // A fenced uuid means a delete is in-flight; the downloader treats
      // this exactly like a reset (skip rename, skip DB write, drop the
      // partial file) so the deletion can't be undone by a late commit.
      final outcome = await _downloader.download(
        job: job,
        generationCheck: () =>
            generation == _resetGeneration && !_fencedUuids.contains(uuidId),
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
