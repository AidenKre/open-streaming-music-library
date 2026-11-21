import 'dart:developer' as developer;
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:drift/drift.dart'
    show TableUpdate, UpdateKind, Variable;
import 'package:flutter/foundation.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/services/app_files_directory.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/codec_support.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/download/download_queue.dart';
import 'package:frontend/services/download/download_status_reader.dart';
import 'package:frontend/services/download/track_downloader.dart';
import 'package:frontend/services/download/worker_pool.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';
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

/// Coordinates concurrent track + cover-art downloads.
///
/// Façade over four single-responsibility collaborators:
/// * [DownloadQueue] — the in-memory job list + change notifications.
/// * [TrackDownloader] — the per-job HTTP→file→DB pipeline.
/// * [WorkerPool] — concurrency + generation gating.
/// * [DownloadStatusReader] — the downloaded-status change-version.
///
/// The public API forwards to these — see each method for which one it
/// delegates to. Active jobs sit at the top of the UI list, completed at
/// the bottom (the natural ordering of the underlying queue keeps these
/// positions stable). The manager writes downloaded files to the app docs
/// dir and updates `tracks.file_path` so playback can prefer the local
/// copy.
class DownloadManager extends ChangeNotifier implements LocalResettable {
  final AppDatabase _db;
  final LocalCoverArtStore _coverArtStore;
  final OwnedFileCleanup _ownedCleanup;
  final void Function()? _onOwnedCleanupPending;
  // Optional: if supplied, the server is asked to pre-transcode queued tracks
  // at the current stream quality in parallel with downloading them.
  final QueueWarmService? _warmService;
  // Provides the current stream quality for server warm calls.
  final String Function()? _streamQualityFn;

  /// Which codecs this device can decode (review major 1).
  final CodecSupport Function()? _codecSupportFn;

  /// The quality [track] is actually downloaded at when [quality] is asked:
  /// "original" passes the source codec through, so a codec this device
  /// can't decode is downloaded at the best transcoded quality (AAC) and the
  /// job names the codec (user, 2026-11-09).
  ({String quality, String? unsupportedCodec}) _deliveredQuality(
    TrackUI track,
    String quality,
  ) {
    final codecs = _codecSupportFn?.call();
    if (quality != originalQuality || codecs == null) {
      return (quality: quality, unsupportedCodec: null);
    }
    final label = codecs.unsupportedLabel(track.codec);
    if (label == null || !codecs.canDecode(AudioCodecFamily.aac.name)) {
      return (quality: quality, unsupportedCodec: null);
    }
    return (quality: transcodedFallbackQuality, unsupportedCodec: label);
  }

  late final DownloadQueue _queue;
  late final TrackDownloader _downloader;
  late final WorkerPool _pool;
  late final DownloadStatusReader _status;
  bool _disposed = false;

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

  /// Notified once when the underlying tracks table changes such that
  /// downloaded-status checks may have new answers. Lets the UI invalidate
  /// derived providers without polling the DB.
  ValueNotifier<int> get downloadStatusVersion => _status.downloadStatusVersion;

  /// Exposed so reconciliation can bump the same change-version that download
  /// completion uses; consumers should not depend on its members.
  DownloadStatusReader get statusReader => _status;

  DownloadManager({
    required AppDatabase db,
    required LocalCoverArtStore coverArtStore,
    Future<Directory> Function()? directoryProvider,
    QueueWarmService? warmService,
    String Function()? streamQualityFn,
    required ApiClient apiClient,
    bool Function()? isOfflineFn,
    void Function()? onNetworkFailure,
    CodecSupport Function()? codecSupportFn,
    OwnedFileCleanup? ownedFileCleanup,
    void Function()? onOwnedCleanupPending,
  }) : _db = db,
       _coverArtStore = coverArtStore,
       _ownedCleanup =
           ownedFileCleanup ??
           OwnedFileCleanup(
             db: db,
             documentsDirectory: directoryProvider ?? appFilesDirectory,
           ),
       _onOwnedCleanupPending = onOwnedCleanupPending,
       _warmService = warmService,
       _streamQualityFn = streamQualityFn,
       _codecSupportFn = codecSupportFn {
    _status = DownloadStatusReader();
    _queue = DownloadQueue();
    _queue.addListener(notifyListeners);
    _downloader = TrackDownloader(
      db: db,
      coverArtStore: coverArtStore,
      directoryProvider: directoryProvider ?? appFilesDirectory,
      apiClient: apiClient,
      ownedFileCleanup: _ownedCleanup,
      onOwnedCleanupPending: onOwnedCleanupPending,
      onNetworkFailure: onNetworkFailure,
    );
    _pool = WorkerPool(
      queue: _queue,
      downloader: _downloader,
      isOffline: isOfflineFn ?? (() => false),
      onCompleted: _status.bumpVersion,
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
    _pool.abort();
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
    return _enqueueInternal(tracks, quality: quality, replacements: const {});
  }

  Future<void> _enqueueInternal(
    List<TrackUI> tracks, {
    required String quality,
    required Map<String, String> replacements,
    bool explicitQuality = false,
  }) async {
    // Tracks both pre-existing queued/active jobs AND uuids already added in
    // this batch. Without this, a duplicate uuid in [tracks] would mint a
    // second job writing the same partial/destination path as the first.
    final seenUuids = <String>{
      for (final j in _queue.state.jobs)
        if (j.isQueued || j.isActive) j.uuidId,
    };
    final additions = <DownloadJob>[];

    for (final t in tracks) {
      if (seenUuids.contains(t.uuidId)) continue;
      // A damaged download (decision 6) is replaced like a re-download: the
      // kept file stays until the new one is committed.
      final replaces = replacements[t.uuidId] ??
          (t.isDownloadDamaged ? t.filePath : null);
      // Fresh (non-replacement) jobs skip when a file is already on disk;
      // replacement jobs deliberately keep going — that's the whole point.
      if (replaces == null &&
          t.isDownloaded &&
          await File(t.filePath!).exists()) {
        continue; // already downloaded
      }
      seenUuids.add(t.uuidId);
      // A damaged download is replaced at the quality it was downloaded at
      // (kept with the mark), unless a quality was explicitly chosen.
      final stored = t.downloadedQuality;
      final requested = !explicitQuality &&
              t.isDownloadDamaged &&
              isValidQuality(stored)
          ? stored!
          : quality;
      final delivered = _deliveredQuality(t, requested);
      additions.add(
        DownloadJob(
          uuidId: t.uuidId,
          title: t.title,
          artist: t.artist,
          albumId: t.albumId,
          artistId: t.artistId,
          quality: delivered.quality,
          status: const Queued(),
          replacesFilePath: replaces,
          unsupportedCodec: delivered.unsupportedCodec,
        ),
      );
    }

    // The loop above awaited (file checks): a concurrent enqueue may have
    // queued one of these uuids since the snapshot was taken. Re-check the
    // LIVE queue with no await before adding, so one uuid never gets two jobs
    // (and so two workers on one file).
    final live = _queue.state;
    additions.removeWhere((j) => live.isPending(j.uuidId));
    if (additions.isEmpty) return;

    _queue.removeFinishedJobsForUuids(additions.map((j) => j.uuidId));
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

    _pool.pump();
  }

  /// Schedules [tracks] for download at [quality], re-downloading any track
  /// whose copy was not downloaded at [quality] (its stored quality differs
  /// or is missing). Tracks already downloaded at [quality] are skipped.
  ///
  /// This is the "explicit user intent" path: when someone picks
  /// "Download at 320 kbps" from the split-download menu, they want a 320
  /// kbps copy regardless of what's on disk. Compare with [enqueueTracks],
  /// which preserves whatever copy already exists.
  Future<void> enqueueTracksAtQuality(
    List<TrackUI> tracks, {
    required String quality,
    // Bypasses the "already at this quality" skip below. Used to force a
    // redownload at the SAME quality when the file itself is known to be
    // stale for a reason the quality check can't see (the track changed on
    // the server since the download) -- not a new re-download pathway, just
    // this one existing check made optional.
    bool force = false,
  }) async {
    if (!isValidQuality(quality)) {
      throw ArgumentError('invalid download quality: $quality');
    }

    final toEnqueue = <TrackUI>[];
    final replacements = <String, String>{};
    for (final t in tracks) {
      final hasFile = t.filePath != null && await File(t.filePath!).exists();
      // A damaged download is never "already at this quality".
      if (hasFile && !force && !t.isDownloadDamaged &&
          _qualityMatches(t, _deliveredQuality(t, quality).quality)) {
        continue; // already at the requested quality
      }
      if (hasFile) {
        // Different quality — schedule a two-phase replacement so the working
        // copy survives a failed/cancelled redownload. The downloader writes
        // to a distinct path, swaps the DB row, then removes the old file.
        replacements[t.uuidId] = t.filePath!;
      }
      toEnqueue.add(t);
    }

    if (toEnqueue.isEmpty) return;
    await _enqueueInternal(
      toEnqueue,
      quality: quality,
      replacements: replacements,
      explicitQuality: true,
    );
  }

  /// True iff [track]'s file on disk was produced by a request for [quality].
  ///
  /// Uses the stored `downloadedQuality` (the preset that produced the file),
  /// not the actual on-disk bitrate — these can differ when the backend
  /// served a passthrough (e.g. requested 320 on a 96 kbps source returns
  /// the original bytes, with `downloadedBitrateKbps=96` but
  /// `downloadedQuality='320'`). Matching on the actual bitrate would cause
  /// non-idempotent redownload loops in that case.
  ///
  /// A copy without a stored quality never matches: every commit stores one,
  /// so it can only come from data this app no longer opens.
  bool _qualityMatches(TrackUI track, String quality) =>
      track.downloadedQuality == quality;

  /// Queues a forced replacement download for each stale track at the
  /// quality its copy was downloaded at (the two-phase `replacements` path,
  /// so a failure keeps the stale-but-playable copy). A stored quality that
  /// is no longer a valid preset falls back to [fallbackQuality]. Each
  /// quality group is queued independently, so one failing group doesn't
  /// stop the rest. Returns how many tracks could not be queued.
  Future<int> redownloadStale(
    List<TrackUI> tracks, {
    required String fallbackQuality,
  }) =>
      _redownloadAtStoredQuality(tracks, fallbackQuality: fallbackQuality);

  /// Replaces damaged downloads (decision 6) at the quality each was
  /// downloaded at (kept with the mark), [fallbackQuality] when unknown.
  /// The damaged file stays until the new download is committed. Returns
  /// how many tracks could not be scheduled.
  Future<int> redownloadDamaged(
    List<TrackUI> tracks, {
    required String fallbackQuality,
  }) =>
      _redownloadAtStoredQuality(tracks, fallbackQuality: fallbackQuality);

  Future<int> _redownloadAtStoredQuality(
    List<TrackUI> tracks, {
    required String fallbackQuality,
  }) async {
    final byQuality = <String, List<TrackUI>>{};
    for (final t in tracks) {
      final stored = t.downloadedQuality;
      final quality = isValidQuality(stored) ? stored! : fallbackQuality;
      (byQuality[quality] ??= []).add(t);
    }
    var failed = 0;
    for (final entry in byQuality.entries) {
      try {
        await enqueueTracksAtQuality(entry.value, quality: entry.key, force: true);
      } catch (e) {
        failed += entry.value.length;
        developer.log(
          're-download enqueue failed (${entry.key}): $e',
          name: 'DownloadManager',
        );
      }
    }
    return failed;
  }

  /// Drops the failed/completed history. Active and queued jobs are kept.
  void clearFinished() => _queue.clearFinished();

  /// Cancels a queued job; a download in progress is [cancelActive]'s.
  void cancelQueued(String uuidId) => _queue.cancelQueued(uuidId);

  /// Cancels a download in progress (other-issues row 74); see
  /// [WorkerPool.cancelActive] for the end state.
  Future<void> cancelActive(String uuidId) => _pool.cancelActive(uuidId);

  /// Full local-reset hook. Cancels in-flight workers, clears the in-memory
  /// queue, deletes completed/partial files, and prevents stale workers from
  /// writing DB state if they complete after the reset generation changes.
  Future<void> resetAndDeleteFiles() async {
    try {
      await _pool.reset();
    } finally {
      _status.bumpVersion();
    }
  }

  // --- LocalResettable -------------------------------------------------------
  // The manager owns both in-flight workers and on-disk files. Slot at
  // [ResetPriority.cancelInFlight] (higher than file deletion) because the
  // pool.reset() call itself stops workers _then_ deletes their files: we
  // must run before the database step drops the rows that point at them.
  @override
  int get resetPriority => ResetPriority.cancelInFlight;

  @override
  Future<void> resetLocalState() => resetAndDeleteFiles();

  /// Removes the local file (if any), and a kept damaged copy, and clears
  /// `tracks.file_path` so the track reverts to streaming. Its stored cover
  /// goes too when no remaining download uses it (see [_dropDownloads]).
  ///
  /// Cancels any queued/active download for [uuidId] first so a late
  /// `_commitDownload` can't restore the row after we null it out.
  Future<void> deleteDownload(String uuidId) async {
    await _pool.fenceUuid(uuidId);
    final token = (await ServerBindingRepository(_db).current())
        ?.localBindingId;
    final pending = await _dropDownloads([uuidId], token);
    if (pending) _onOwnedCleanupPending?.call();
    _status.bumpVersion();
  }

  Future<void> deleteDownloadsForUuids(Iterable<String> uuids) async {
    final uuidList = uuids.toList(growable: false);
    if (uuidList.isEmpty) return;

    // Cancel any queued/active downloads for these uuids before touching the
    // DB so a worker that's already in its commit window can't write a new
    // file_path after we null them out.
    await _pool.fenceUuids(uuidList);
    if (_disposed) return;

    final token = (await ServerBindingRepository(_db).current())
        ?.localBindingId;
    var pending = false;
    const chunkSize = 200;
    for (var i = 0; i < uuidList.length; i += chunkSize) {
      final chunk = uuidList.sublist(
        i,
        i + chunkSize > uuidList.length ? uuidList.length : i + chunkSize,
      );
      if (await _dropDownloads(chunk, token)) pending = true;
    }
    if (pending) _onOwnedCleanupPending?.call();
    _status.bumpVersion();
  }

  /// Clears the downloaded-state columns of [uuids] and, in the same
  /// transaction, enqueues their owned files (including a kept damaged copy)
  /// for durable cleanup. After the commit it attempts the deletions now,
  /// then deletes each of their stored covers that no remaining download
  /// uses (owner, 2026-11-17). A transaction failure propagates (nothing is
  /// cleared). Returns whether any cleanup row was kept for a later retry.
  Future<bool> _dropDownloads(List<String> uuids, String? token) async {
    late final Set<int> covers;
    final ids = await _db.transaction(() async {
      final placeholders = List.filled(uuids.length, '?').join(', ');
      final paths = await _db.ownedTrackFilePaths(uuids: uuids);
      covers = await _db.downloadedCoverArtIds(uuids);
      // Cleared without notifying the tracks watchers: they learn of it once
      // the whole operation is over (see the publish below), so no DB work
      // follows the notification. The SET list comes from
      // [clearedDownloadColumns] itself.
      final cleared = clearedDownloadColumns.toColumns(false);
      await _db.customUpdate(
        'UPDATE tracks SET '
        '${cleared.keys.map((c) => '$c = ?').join(', ')} '
        'WHERE uuid_id IN ($placeholders)',
        variables: [
          for (final v in cleared.values) v as Variable,
          ...uuids.map(Variable.withString),
        ],
        updates: const {},
      );
      return _ownedCleanup.enqueueInTransaction(paths, localBindingId: token);
    });
    try {
      final kept = await _attemptCleanup(ids, token);
      await _coverArtStore.removeEachIfUnused(
        covers,
        _db.coverArtUsedByDownload,
      );
      return kept;
    } finally {
      _db.notifyUpdates({
        TableUpdate.onTable(_db.tracks, kind: UpdateKind.update),
      });
    }
  }

  Future<bool> _attemptCleanup(List<int> ids, String? token) async {
    if (ids.isEmpty) return false;
    final outcomes = await _ownedCleanup.cleanRows(ids, bindingToken: token);
    final kept = outcomes.values
        .where((o) => o == OwnedCleanupOutcome.failed)
        .length;
    if (kept > 0) {
      developer.log(
        'delete download: $kept file(s) kept for cleanup retry',
        name: 'DownloadManager',
      );
    }
    return kept > 0;
  }

  /// Called by recovery after the binding gate verified the server (and by
  /// the download provider on every verification). Re-dispatches jobs left
  /// queued while offline or withheld because the server was not verified
  /// (sign-off OPEN-M-11); it does not clear the signed-out (401) pause.
  void resumeIfPaused() => _pool.resumeAfterVerified();

  /// Stable, paginated view used by the downloading page.
  UnmodifiableListView<DownloadJob> snapshot() => _queue.snapshot();
}
