import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';

/// One plain `NotifierProvider<List<ConversionJob>>` -- unlike downloads
/// (`DownloadQueue`, a `ChangeNotifier` backing DB rows outside Riverpod),
/// the conversion job list lives entirely in this notifier's own state, so
/// there's no "status-version" bridging notifier needed.
final conversionJobsProvider =
    NotifierProvider<ConversionJobsNotifier, List<ConversionJob>>(
      ConversionJobsNotifier.new,
    );

/// The comma-separated active-status filter `GET /jobs` accepts.
const activeJobStatuses = 'queued,running';

class ConversionJobsNotifier extends Notifier<List<ConversionJob>> {
  @visibleForTesting
  static Duration pollInterval = const Duration(seconds: 3);

  /// Ceiling for the failure backoff (the interval doubles per consecutive
  /// failed poll and resets on the next success).
  @visibleForTesting
  static Duration maxPollBackoff = const Duration(seconds: 30);

  /// Page size for the active-set fetch. Mutable so tests can exercise the
  /// cursor-following path without minting 50+ jobs.
  @visibleForTesting
  static int activePageSize = 50;

  /// Upper bound on active-set pages per poll (guards a misbehaving cursor).
  static const _maxActivePages = 20;

  Timer? _pollTimer;
  bool _pollInFlight = false;
  bool _disposed = false;
  int _consecutiveFailures = 0;

  /// Set by [refreshAll] until an active-set fetch that STARTED after it
  /// succeeds. While set, polling keeps rescheduling (with backoff) even with
  /// no locally-known active job -- otherwise a discovery poll that fails on
  /// a cold start/resume (empty local state, e.g. a 503) would never retry
  /// and server-side jobs would stay invisible until the next recovery edge.
  bool _discoveryPending = false;

  /// Bumped per [refreshAll]; a poll only satisfies discovery if it began at
  /// the current generation (one already in flight when [refreshAll] was
  /// called may predate the gap it's meant to cover).
  int _discoveryGeneration = 0;

  @override
  List<ConversionJob> build() {
    ref.onDispose(() {
      _disposed = true;
      _pollTimer?.cancel();
      _pollTimer = null;
    });
    return const [];
  }

  /// Enqueues a conversion and starts polling for it. Throws the
  /// `ApiException`/`NetworkException` from the POST unchanged -- the
  /// caller maps it to user-facing text.
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
    if (_disposed) return job;
    _publish(_merge(state, [job]));
    _consecutiveFailures = 0;
    _scheduleNextPoll();
    return job;
  }

  /// Cancels a job and reflects the result locally immediately (polling
  /// will also pick it up, but this avoids waiting a full poll interval).
  /// A poll already in flight can't revert this: [_merge] never moves a
  /// terminal local job back to an active status.
  Future<void> cancel(int jobId) async {
    final cancelled = await ref.read(jobsApiProvider).cancelJob(jobId);
    if (!cancelled || _disposed) return;
    final existing = _findByJobId(jobId);
    if (existing != null) {
      _publish(_merge(state, [existing.withStatus(const ConversionCancelled())]));
    }
  }

  /// Discovers any queued/running jobs this client doesn't know about yet
  /// (e.g. from a previous app session or another device), settles the
  /// final state of tracked jobs that finished while we weren't polling
  /// (offline, backgrounded), and resumes polling while any is active.
  /// Called from recovery (reconnect/cold start/resume). Never throws.
  Future<void> refreshAll() async {
    if (_disposed) return;
    _discoveryPending = true;
    _discoveryGeneration++;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _poll();
  }

  ConversionJob? _findByJobId(int jobId) {
    for (final job in state) {
      if (job.jobId == jobId) return job;
    }
    return null;
  }

  /// Folds [fetched] into [current]: updates known jobs, appends new ones.
  /// A fetched non-terminal status never overwrites a terminal local one --
  /// the backend never reactivates a finished job (retry mints a new one),
  /// so that combination can only be a stale in-flight poll racing a local
  /// cancel.
  List<ConversionJob> _merge(
    List<ConversionJob> current,
    Iterable<ConversionJob> fetched,
  ) {
    final next = [...current];
    for (final job in fetched) {
      final index = next.indexWhere((j) => j.jobId == job.jobId);
      if (index == -1) {
        next.add(job);
      } else if (next[index].isTerminal && job.isActive) {
        continue;
      } else {
        next[index] = job;
      }
    }
    return next;
  }

  /// Assigns [next] only if it differs, so an unchanged poll doesn't rebuild
  /// every watcher (each track row and the Conversions page).
  void _publish(List<ConversionJob> next) {
    if (_disposed) return;
    if (listEquals(next, state)) return;
    state = next;
  }

  void _scheduleNextPoll() {
    if (_disposed) return;
    _pollTimer?.cancel();
    final backoff = pollInterval * math.pow(2, _consecutiveFailures).toInt();
    final delay = backoff > maxPollBackoff ? maxPollBackoff : backoff;
    _pollTimer = Timer(delay, _poll);
  }

  /// One poll. Self-reschedules only while a job is active (or a
  /// [refreshAll] discovery is still pending) -- the next poll is queued
  /// after this one finishes, so polls never overlap. Gated on online: while
  /// offline it neither fetches nor reschedules; the recovery registry's
  /// `networkRecovered` edge calls [refreshAll] to restart it. Also a no-op
  /// with no server configured (first install / after Disconnect): the
  /// request would fail as a NetworkException, which the API client treats
  /// as "server unreachable" and flips the app into offline mode. Failures
  /// are logged and retried with exponential backoff; nothing escapes (this
  /// runs from a bare Timer callback).
  Future<void> _poll() async {
    if (_disposed || _pollInFlight) return;
    if (ref.read(offlineModeProvider)) return;
    if (ApiClient.instance.baseUrl.isEmpty) return;
    _pollInFlight = true;
    var ok = false;
    try {
      await _pollOnce(_discoveryGeneration);
      ok = true;
    } catch (e, st) {
      debugPrint('Conversion job poll failed: $e\n$st');
    } finally {
      _pollInFlight = false;
    }
    if (_disposed) return;
    _consecutiveFailures = ok ? 0 : math.min(_consecutiveFailures + 1, 16);
    if (_discoveryPending || state.any((j) => j.isActive)) {
      _scheduleNextPoll();
    }
  }

  Future<void> _pollOnce(int generation) async {
    final api = ref.read(jobsApiProvider);

    // 1. The full active set in one (paged) call -- covers every active job
    //    regardless of how much history its track has.
    final active = <ConversionJob>[];
    int? cursor;
    for (var page = 0; page < _maxActivePages; page++) {
      final result = await api.getJobsPage(
        status: activeJobStatuses,
        cursor: cursor,
        limit: activePageSize,
        retry: false,
      );
      if (_disposed) return;
      active.addAll(result.jobs);
      final next = result.nextCursor;
      if (next == null || (cursor != null && next <= cursor)) break;
      cursor = next;
    }
    if (generation == _discoveryGeneration) _discoveryPending = false;

    // 2. Tracked jobs that left the active set finished in the meantime:
    //    fetch each one's final state exactly (cursor is exclusive, so
    //    `jobId - 1` + limit 1 returns that job if it still exists).
    final activeIds = {for (final j in active) j.jobId};
    final departed = state
        .where((j) => j.isActive && !activeIds.contains(j.jobId))
        .toList();
    final settled = <ConversionJob>[];
    final vanished = <int>{};
    for (final job in departed) {
      final found = await api.getJobs(
        uuidId: job.uuidId,
        cursor: job.jobId - 1,
        limit: 1,
        retry: false,
      );
      if (_disposed) return;
      final match = found.where((j) => j.jobId == job.jobId);
      if (match.isEmpty) {
        // Gone server-side (pruned); drop it rather than poll it forever.
        vanished.add(job.jobId);
      } else {
        settled.add(match.first);
      }
    }

    final before = state;
    final next = _merge(
      before.where((j) => !vanished.contains(j.jobId)).toList(),
      [...active, ...settled],
    );
    final finishedOne = next.any((j) {
      if (!j.isDone) return false;
      final prev = before.where((p) => p.jobId == j.jobId).firstOrNull;
      return prev != null && prev.isActive;
    });
    _publish(next);

    // A finished conversion bumped the track's codec/revision server-side;
    // pull it so stale-download detection and the next edit's base_revision
    // see it. Once per poll, however many jobs finished together.
    if (finishedOne && !_disposed) {
      unawaited(
        ref.read(trackSyncProvider.notifier).syncFresh().catchError((
          Object e,
        ) {
          debugPrint('Post-conversion sync failed: $e');
          return false;
        }),
      );
    }
  }
}
