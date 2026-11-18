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
    Duration resetWorkerWait = resetWorkerWaitBound,
  }) : _queue = queue,
       _downloader = downloader,
       _isOffline = isOffline,
       _onCompleted = onCompleted,
       _resetWorkerWait = resetWorkerWait;

  static const int maxConcurrent = 4;

  /// How long [reset] waits for cancelled workers before abandoning the ones
  /// that have not finished (a hung disk or DB write must not hold a log-out
  /// or server switch forever). Delete fences are not bounded.
  static const Duration resetWorkerWaitBound = Duration(seconds: 5);
  final Duration _resetWorkerWait;

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

  /// Set by a 401 (signed out): [pump] schedules nothing. Not the offline
  /// flag; nothing clears it, the scope rebuild after the next login drops
  /// the pool.
  bool get authPaused => _authPaused;

  bool _authPaused = false;

  /// Set when a request was withheld because the server is not verified
  /// (sign-off OPEN-M-11): [pump] schedules nothing until [resumeAfterVerified].
  bool get verifyPaused => _verifyPaused;
  bool _verifyPaused = false;

  /// The next verification arrived: schedules the withheld jobs again. Does
  /// not clear the 401 pause.
  void resumeAfterVerified() {
    _verifyPaused = false;
    pump();
  }

  /// True iff [uuidId] is currently being fenced by [fenceUuid]. Workers
  /// poll this at every commit checkpoint to bail out cleanly when their
  /// download is being deleted out from under them.
  bool isFenced(String uuidId) => _fencedUuids.contains(uuidId);

  /// Schedules queued jobs. Idempotent — safe to call repeatedly.
  void pump() {
    // Paused while offline. Jobs sit in `queued` and get picked up by [pump]
    // again on recovery.
    if (_isOffline() || _authPaused || _verifyPaused) return;
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
      unawaited(
        worker.whenComplete(() {
          // Only this worker's own entry: an abandoned worker finishing late
          // must not drop a newer worker's.
          if (identical(_activeWorkers[uuidId], worker)) {
            _activeWorkers.remove(uuidId);
          }
        }),
      );
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

  /// Cancels in-flight downloads, bumps the generation, awaits active workers,
  /// clears in-memory queue state, then asks the downloader to remove all
  /// known files + the downloads directory.
  Future<void> reset() async {
    _resetGeneration++;

    final waitedFor = Map<String, Future<void>>.of(_activeWorkers);
    await _cancelAndAwait(
      waitedFor.keys.toList(growable: false),
      bound: _resetWorkerWait,
    );
    // Forget any worker that did not finish: its generation is already bumped,
    // so a late commit is refused, and a later fence must not wait on it.
    // Only those waited for: a worker started during the wait stays tracked.
    waitedFor.forEach((uuid, worker) {
      if (identical(_activeWorkers[uuid], worker)) _activeWorkers.remove(uuid);
    });

    _activeCount = 0;
    _activeCancellers.clear();
    _queue.clearAll();

    await _downloader.deleteKnownDownloadedFiles();
    await _downloader.deleteDownloadDirectory();
  }

  /// Synchronous teardown path used by DownloadManager.dispose(). It invalidates
  /// workers before owned notifiers are disposed, then asks active streams to
  /// cancel without waiting for them. Workers that finish later observe the
  /// generation mismatch and skip queue/status updates.
  void abort() {
    _resetGeneration++;
    final cancellers = _activeCancellers.values.toList(growable: false);
    _activeCancellers.clear();
    _fencedUuids.clear();
    _activeCount = 0;
    _queue.clearAll();
    for (final canceller in cancellers) {
      unawaited(canceller().catchError((_) {}));
    }
  }

  /// Cancels the in-flight canceller (if any) for each uuid, then awaits the
  /// matching active workers in parallel. Cancelling ALL workers before
  /// awaiting any is the load-bearing ordering: awaiting one worker before
  /// cancelling the rest would serialise the teardown. Workers are snapshotted
  /// up front because a worker completing mid-call mutates [_activeWorkers].
  ///
  /// With a [bound] (reset only) the wait for the workers gives up after that
  /// long; without one (the delete fences) it waits for as long as it takes.
  Future<void> _cancelAndAwait(
    Iterable<String> uuids, {
    Duration? bound,
  }) async {
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
    if (workers.isEmpty) return;
    if (bound == null) {
      await Future.wait(workers);
      return;
    }
    // Bounded: stop waiting after [bound]; the timer is cancelled as soon as
    // the workers finish first so none outlives the call.
    final done = Completer<void>();
    final timer = Timer(bound, () {
      if (!done.isCompleted) done.complete();
    });
    unawaited(
      Future.wait(workers).then<void>(
        (_) {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
      ),
    );
    await done.future;
    timer.cancel();
  }

  Future<void> _runJob(String uuidId, int generation) async {
    try {
      if (generation != _resetGeneration) return;
      final idx = _queue.state.jobs.indexWhere(
        (j) => j.uuidId == uuidId && j.isActive,
      );
      if (idx < 0) return;
      final job = _queue.jobAt(idx);
      Future<void> Function()? registered;
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
            where: (j) => j.isActive,
          );
        },
        registerCanceller: (canceller) {
          // A worker from before a reset must not register over a newer one.
          if (generation != _resetGeneration) return;
          registered = canceller;
          _activeCancellers[job.uuidId] = canceller;
        },
        unregisterCanceller: () {
          if (registered != null &&
              identical(_activeCancellers[job.uuidId], registered)) {
            _activeCancellers.remove(job.uuidId);
          }
        },
      );
      if (generation != _resetGeneration) return;
      switch (outcome.kind) {
        case DownloadOutcomeKind.success:
          _queue.markJobByUuid(
            uuidId,
            (j) => j.withStatus(Completed(sizeBytes: outcome.sizeBytes)),
            where: (j) => j.isActive,
          );
          _onCompleted();
        case DownloadOutcomeKind.networkFailure:
          // Transport failure — revert to queued so the worker pool retries
          // once we're back online. The download restarts from zero, so the
          // status resets to a fresh Queued (no progress, no error).
          _queue.markJobByUuid(
            uuidId,
            (j) => j.withStatus(const Queued()),
            where: (j) => j.isActive,
          );
        case DownloadOutcomeKind.authRequired:
          // Signed out: back to queued, and stop scheduling so the job
          // can't hot-loop on 401s.
          _queue.markJobByUuid(
            uuidId,
            (j) => j.withStatus(const Queued()),
            where: (j) => j.isActive,
          );
          _authPaused = true;
        case DownloadOutcomeKind.otherFailure:
          _queue.markJobByUuid(
            uuidId,
            (j) => j.withStatus(
              Failed(message: outcome.errorMessage ?? 'unknown error'),
            ),
            where: (j) => j.isActive,
          );
        case DownloadOutcomeKind.cancelled:
          _queue.removeJob(uuidId);
          return;
        case DownloadOutcomeKind.notVerified:
          // Nothing was sent: back to a fresh Queued and stop scheduling
          // until the next verification, so the job can't hot-loop.
          _queue.markJobByUuid(
            uuidId,
            (j) => j.withStatus(const Queued()),
            where: (j) => j.isActive,
          );
          _verifyPaused = true;
      }
    } finally {
      if (generation == _resetGeneration) {
        _activeCount--;
        pump();
      }
    }
  }
}
