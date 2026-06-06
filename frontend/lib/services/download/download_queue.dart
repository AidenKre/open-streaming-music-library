import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Lifecycle state of a [DownloadJob], modelled as a sealed hierarchy so the
/// state-only fields (`progress`, `errorMessage`, `fileSizeBytes`) live on the
/// variants they belong to. Switching on `job.status` is exhaustively checked
/// by the analyzer — adding a new variant forces every call site to handle it.
sealed class DownloadStatus {
  const DownloadStatus();
}

class Queued extends DownloadStatus {
  const Queued();
}

class Active extends DownloadStatus {
  final double progress; // 0.0..1.0
  const Active({this.progress = 0.0});
}

class Completed extends DownloadStatus {
  final int sizeBytes;
  const Completed({required this.sizeBytes});
}

class Failed extends DownloadStatus {
  final String message;
  const Failed({required this.message});
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
  final DownloadStatus status;

  const DownloadJob({
    required this.uuidId,
    required this.title,
    required this.artist,
    required this.quality,
    required this.status,
    this.albumId,
    this.artistId,
  });

  bool get isQueued => status is Queued;
  bool get isActive => status is Active;
  bool get isCompleted => status is Completed;
  bool get isFailed => status is Failed;

  DownloadJob withStatus(DownloadStatus status) => DownloadJob(
    uuidId: uuidId,
    title: title,
    artist: artist,
    albumId: albumId,
    artistId: artistId,
    quality: quality,
    status: status,
  );
}

/// In-memory list of jobs partitioned by state. The user requested that this
/// list only resets on app restart or explicit "clear", so we keep completed
/// jobs around forever during the session.
@immutable
class DownloadQueueState {
  final List<DownloadJob> jobs;
  const DownloadQueueState({this.jobs = const []});

  Iterable<DownloadJob> get active => jobs.where((j) => j.isActive);
  Iterable<DownloadJob> get queued => jobs.where((j) => j.isQueued);
  Iterable<DownloadJob> get finished =>
      jobs.where((j) => j.isCompleted || j.isFailed);
}

/// Owns the in-memory list of [DownloadJob]s and notifies listeners on every
/// mutation. The queue is mutation-only — actual file work happens in
/// [TrackDownloader], and the worker pool reads/writes here through the
/// `markJob*` helpers and [findFirstQueuedIndex].
class DownloadQueue extends ChangeNotifier {
  DownloadQueueState _state = const DownloadQueueState();
  bool _disposed = false;

  DownloadQueueState get state => _state;

  UnmodifiableListView<DownloadJob> snapshot() =>
      UnmodifiableListView(_state.jobs);

  /// Appends [additions] to the queue. Caller is responsible for filtering
  /// duplicates / already-downloaded tracks before calling.
  void addAll(List<DownloadJob> additions) {
    if (additions.isEmpty) return;
    _state = DownloadQueueState(jobs: [..._state.jobs, ...additions]);
    notifyListeners();
  }

  /// Replaces the job at [index] with [updated]. Used by the worker pool to
  /// transition Queued → Active → Completed/Failed and to push progress
  /// updates.
  void markJob(int index, DownloadJob updated) {
    final next = [..._state.jobs];
    next[index] = updated;
    _state = DownloadQueueState(jobs: next);
    notifyListeners();
  }

  /// Convenience for the common pattern of mutating a job by uuid. No-ops if
  /// the uuid isn't currently in the queue (e.g. it was cleared by reset).
  void markJobByUuid(String uuidId, DownloadJob Function(DownloadJob) fn) {
    final idx = _state.jobs.indexWhere((j) => j.uuidId == uuidId);
    if (idx < 0) return;
    markJob(idx, fn(_state.jobs[idx]));
  }

  /// Returns the index of the first queued job, or -1 if none. Used by the
  /// worker pool to pick the next job to dispatch.
  int findFirstQueuedIndex() => _state.jobs.indexWhere((j) => j.isQueued);

  /// Returns the job at [index]. Caller must check the index is valid.
  DownloadJob jobAt(int index) => _state.jobs[index];

  /// Drops the failed/completed history. Active and queued jobs are kept.
  void clearFinished() {
    final remaining = _state.jobs
        .where((j) => j.isQueued || j.isActive)
        .toList(growable: false);
    _state = DownloadQueueState(jobs: remaining);
    notifyListeners();
  }

  /// Cancels a queued job. In-flight downloads keep running — cancelling
  /// mid-stream is intentionally not supported in v1.
  void cancelQueued(String uuidId) {
    final idx = _state.jobs.indexWhere((j) => j.uuidId == uuidId);
    if (idx < 0) return;
    final job = _state.jobs[idx];
    if (!job.isQueued) return;
    final updated = [..._state.jobs]..removeAt(idx);
    _state = DownloadQueueState(jobs: updated);
    notifyListeners();
  }

  /// Removes the job with [uuidId] regardless of its state. Used by the
  /// worker pool's fence path so a deleted track stops occupying a UI row
  /// (and a queue slot) the instant the fence engages. No-op if the uuid
  /// isn't in the queue.
  void removeJob(String uuidId) {
    final idx = _state.jobs.indexWhere((j) => j.uuidId == uuidId);
    if (idx < 0) return;
    final updated = [..._state.jobs]..removeAt(idx);
    _state = DownloadQueueState(jobs: updated);
    notifyListeners();
  }

  /// Clears the queue entirely. Used by the worker pool when resetting.
  void clearAll() {
    _state = const DownloadQueueState();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
