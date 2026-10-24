import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/providers/providers.dart';

/// One plain `NotifierProvider<List<ConversionJob>>` -- unlike downloads
/// (`DownloadQueue`, a `ChangeNotifier` backing DB rows outside Riverpod),
/// the conversion job list lives entirely in this notifier's own state, so
/// there's no "status-version" bridging notifier needed.
final conversionJobsProvider =
    NotifierProvider<ConversionJobsNotifier, List<ConversionJob>>(
      ConversionJobsNotifier.new,
    );

class ConversionJobsNotifier extends Notifier<List<ConversionJob>> {
  @visibleForTesting
  static Duration pollInterval = const Duration(seconds: 3);

  Timer? _pollTimer;
  bool _pollInFlight = false;
  bool _disposed = false;

  @override
  List<ConversionJob> build() {
    ref.onDispose(() {
      _disposed = true;
      _pollTimer?.cancel();
      _pollTimer = null;
    });
    return const [];
  }

  /// Enqueues a conversion and starts polling for it.
  Future<ConversionJob> enqueue({
    required String uuidId,
    required String targetCodec,
    required int? targetBitrateKbps,
    required int? baseRevision,
  }) async {
    final job = await ref.read(jobsApiProvider).postConversionJob(
      uuidId: uuidId,
      targetCodec: targetCodec,
      targetBitrateKbps: targetBitrateKbps,
      baseRevision: baseRevision,
    );
    _upsert(job);
    _scheduleNextPoll();
    return job;
  }

  /// Cancels a job and reflects the result locally immediately (polling
  /// will also pick it up, but this avoids waiting a full poll interval).
  Future<void> cancel(int jobId) async {
    final cancelled = await ref.read(jobsApiProvider).cancelJob(jobId);
    if (!cancelled) return;
    final existing = _findByJobId(jobId);
    if (existing != null) {
      _upsert(existing.withStatus(const ConversionCancelled()));
    }
  }

  /// Discovers any queued/running jobs this client doesn't know about yet
  /// (e.g. from a previous app session or another device) and resumes
  /// polling for them. Called from recovery (reconnect/cold start).
  Future<void> refreshAll() async {
    if (_disposed) return;
    final api = ref.read(jobsApiProvider);
    final queued = await api.getJobs(status: 'queued');
    final running = await api.getJobs(status: 'running');
    for (final job in [...queued, ...running]) {
      _upsert(job);
    }
    if (_disposed) return;
    if (state.any((j) => j.isActive)) {
      _scheduleNextPoll();
    }
  }

  ConversionJob? _findByJobId(int jobId) {
    for (final job in state) {
      if (job.jobId == jobId) return job;
    }
    return null;
  }

  void _upsert(ConversionJob job) {
    if (_disposed) return;
    final next = [...state];
    final index = next.indexWhere((j) => j.jobId == job.jobId);
    if (index == -1) {
      next.add(job);
    } else {
      next[index] = job;
    }
    state = next;
  }

  void _scheduleNextPoll() {
    _pollTimer?.cancel();
    _pollTimer = Timer(pollInterval, _poll);
  }

  Future<void> _poll() async {
    if (_disposed || _pollInFlight) return;
    final activeUuids = state.where((j) => j.isActive).map((j) => j.uuidId).toSet();
    if (activeUuids.isEmpty) return;
    _pollInFlight = true;
    try {
      final api = ref.read(jobsApiProvider);
      for (final uuid in activeUuids) {
        final fetched = await api.getJobs(uuidId: uuid);
        for (final job in fetched) {
          _upsert(job);
        }
      }
    } finally {
      _pollInFlight = false;
    }
    if (_disposed) return;
    if (state.any((j) => j.isActive)) {
      _scheduleNextPoll();
    }
  }
}
