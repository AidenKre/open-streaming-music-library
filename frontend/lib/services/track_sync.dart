import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/download_providers.dart'
    show localCoverArtStoreProvider;
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/services/edit_sync_mutex.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/storage/owned_file_cleanup_providers.dart';
import 'package:frontend/services/sync_service.dart';

class TrackSyncState {
  final bool isSyncing;
  final String? error;

  /// A LIBRARY (catalog) sync is running, as opposed to a single-track
  /// refresh. The user-facing sync status follows only these.
  final bool librarySyncing;

  /// The last library sync's failure (null once one succeeds). Untouched by
  /// single-track refreshes, which publish only [error].
  final String? libraryError;

  /// The last library sync failed because the server's library looks
  /// restored from an older backup (`ServerRegressedException`, SC-01
  /// rule 5): a Retry cannot help, only a reset. Set and cleared with
  /// [libraryError].
  final bool libraryServerRestored;
  final int queueMutationVersion;
  final int downloadMutationVersion;
  final Set<int> affectedQueueSessionIds;
  final Set<String> deletedTrackUuids;

  /// Sessions of [affectedQueueSessionIds] whose removed current item was
  /// the end of the queue (no wrap): playback there stops (U20-B-01).
  final Set<int> endedQueueSessionIds;

  const TrackSyncState({
    this.isSyncing = false,
    this.error,
    this.librarySyncing = false,
    this.libraryError,
    this.libraryServerRestored = false,
    this.queueMutationVersion = 0,
    this.downloadMutationVersion = 0,
    this.affectedQueueSessionIds = const {},
    this.deletedTrackUuids = const {},
    this.endedQueueSessionIds = const {},
  });
}

class TrackSyncNotifier extends AsyncNotifier<TrackSyncState> {
  @override
  Future<TrackSyncState> build() async {
    return const TrackSyncState();
  }

  /// The currently running guarded operation (a [sync] or [refreshTrack]),
  /// so [syncFresh] can wait it out. Set/cleared in lockstep with
  /// `isSyncing`.
  Future<bool>? _inFlightRun;

  Future<void> sync() async {
    await _syncOnce();
  }

  /// Like [sync], but guarantees a flush + `/changes` pull that *started
  /// after this call* has completed: if a sync is already in flight (whose
  /// pull may predate the caller's precondition) it is awaited first and
  /// then a fresh one is run. Returns true only when that fresh pull
  /// succeeded; false when offline, when no connection is verified (SC-01:
  /// it never waits on the binding gate), or the pull failed (the error is
  /// still published on [state]). Used where a stale local revision would be sent
  /// to the server (e.g. the convert flow's `base_revision`) and after a
  /// server-side change the client must pick up (a finished conversion).
  Future<bool> syncFresh() async {
    // No verified connection: fail now rather than wait on the gate (or on a
    // run that waits on it) -- this is a user-facing, bounded call.
    if (ref.read(serverBindingGateProvider).state is! BindingVerified) {
      return false;
    }
    // Bounded: each in-flight run we wait out finishes in finite time, and
    // a fresh entrant can't slip in between our null check and
    // `_runGuarded`'s synchronous isSyncing claim (no awaits between them).
    for (var i = 0; i < 5; i++) {
      final inFlight = _inFlightRun;
      if (inFlight != null) {
        await inFlight;
        continue;
      }
      if (ref.read(offlineModeProvider)) return false;
      return _syncOnce();
    }
    return false;
  }

  /// A user's own action (Convert) waits out a pending binding verdict, up to
  /// [ServerBindingGate.tokenWaitBound], instead of failing at once.
  /// Background callers use [syncFresh] and keep failing fast.
  Future<bool> syncFreshForUserAction() async {
    await ref.read(serverBindingGateProvider).verdictSettled();
    if (!ref.mounted) return false;
    return syncFresh();
  }

  Future<bool> _syncOnce() async {
    // Flush pending edits, then pull, in one mutex-guarded critical section:
    // no edit is queued between the two, and every edit the flush delivered
    // is on the server before the pull's blind full-row upsert reads the
    // track back. An edit still unsent when the pull runs (the flush stopped
    // or skipped it, or it is in conflict or rejected) stays in the outbox;
    // if the pull carries a newer server version of that track, the upsert
    // replaces the edit's optimistic local values, and the outbox still holds
    // them to send or resolve later. Flushing first also satisfies "flush
    // before pull on reconnect" since this runs from the recovery edge.
    final ran = await _runGuarded((service) async {
      final flushed = await ref
          .read(editOutboxProvider)
          .flushLocked(bindingToken: service.bindingToken);
      // The gate moved on mid-flush (e.g. a different-server report): send
      // nothing further this pass.
      if (!flushed) return const SyncResult();
      return service.syncChanges();
    }, library: true);
    // Finish take-server resolutions deferred while offline or mid-sync —
    // outside the critical section; refreshTrack re-takes the guards itself.
    if (ran) {
      await ref.read(editOutboxProvider).retryTakeServerResolutions();
    }
    return ran;
  }

  /// Reconcile a single track to current server truth (refetch + apply, or
  /// local-delete if gone). Used by conflict "take server" resolution, where
  /// the watermark may already have advanced past the conflicting revision so
  /// a `/changes` pull would fetch nothing. Returns true when the track was
  /// reconciled; false when skipped (offline, or a sync is in flight) or the
  /// refetch failed — the caller keeps its resolution marker and retries
  /// after the next sync.
  Future<bool> refreshTrack(String uuidId, {bool rebuildParentFts = true}) {
    return _runGuarded(
      (service) => service.refetchAndApplyTrack(
        uuidId,
        rebuildParentFts: rebuildParentFts,
      ),
    );
  }

  /// Runs one sync operation with the shared guards: offline no-ops,
  /// `isSyncing` serializes concurrent entrants (two operations publishing
  /// the same mutation version would make the queue player's
  /// `<=`-version guard drop the second one's queue reconciliation), the op
  /// executes under the edit/sync mutex, and the result is mapped onto the
  /// state that is current AT PUBLISH TIME. Returns true when [op] ran and
  /// its result was published.
  Future<bool> _runGuarded(
    Future<SyncResult> Function(SyncService service) op, {
    bool library = false,
  }) {
    // Offline mode skips entirely (see [_runGuardedBody]).
    if (ref.read(offlineModeProvider)) return Future.value(false);
    final current = state.value;
    if (current != null && current.isSyncing) return Future.value(false);
    // `_inFlightRun` is the synchronous claim while `_runGuardedBody` awaits
    // the binding gate (before it publishes isSyncing:true).
    if (_inFlightRun != null) return Future.value(false);
    final run = _runGuardedBody(op, library: library);
    _inFlightRun = run;
    return run.whenComplete(() {
      if (identical(_inFlightRun, run)) _inFlightRun = null;
    });
  }

  /// [library]: a catalog sync (publishes [TrackSyncState.librarySyncing]
  /// and owns [TrackSyncState.libraryError]); other runs carry those over.
  /// A 401 is a wait, not a failure: the pre-run errors are restored.
  Future<bool> _runGuardedBody(
    Future<SyncResult> Function(SyncService service) op, {
    required bool library,
  }) async {
    // Offline mode skips entirely — the network call would just fail.
    // OfflineModeNotifier re-invokes sync on recovery, so the next online
    // tick will pick up everything that changed while we were dark.
    if (ref.read(offlineModeProvider)) return false;

    // SC-01 rules 1 and 4: wait until the binding gate has verified the
    // current connection, and capture its token; every write of this run is
    // fenced by it. A gate closed with the scope (reset/disconnect) skips
    // silently (no state, no error).
    final gate = ref.read(serverBindingGateProvider);
    final String bindingToken;
    final int? connection;
    try {
      bindingToken = await gate.awaitVerified();
      // Same synchronous segment: the connection this token was verified on.
      connection = gate.verifiedConnection;
    } on BindingGateClosedException {
      return false;
    }
    if (ref.read(offlineModeProvider)) return false;

    // No awaits between this check and the isSyncing:true publish below, so
    // two entrants can't both pass the guard ([_runGuarded] also holds the
    // `_inFlightRun` claim across the gate wait above).
    final current = state.value;
    if (current != null && current.isSyncing) return false;

    state = AsyncData(
      TrackSyncState(
        isSyncing: true,
        librarySyncing: library,
        libraryError: library ? null : current?.libraryError,
        libraryServerRestored:
            !library && (current?.libraryServerRestored ?? false),
        queueMutationVersion: current?.queueMutationVersion ?? 0,
        downloadMutationVersion: current?.downloadMutationVersion ?? 0,
      ),
    );

    SyncService? service;
    try {
      service = SyncService(
        db: ref.read(databaseProvider),
        api: ref.read(tracksApiProvider),
        queueRepository: ref.read(queueRepositoryProvider),
        bindingToken: bindingToken,
        ownedFileCleanup: ref.read(ownedFileCleanupProvider),
        removeUnusedCovers: (ids, inUse) =>
            ref.read(localCoverArtStoreProvider).removeEachIfUnused(ids, inUse),
      );
      final mutex = ref.read(editSyncMutexProvider);
      final built = service;
      final result = await mutex.run(() => op(built));
      final latest = state.value ?? current;
      state = AsyncData(
        _publishedState(
          latest,
          result,
          libraryError: library ? null : latest?.libraryError,
          libraryServerRestored:
              !library && (latest?.libraryServerRestored ?? false),
        ),
      );
      // D29: retries rows a failed cleanup attempt kept.
      ref.read(ownedFileCleanupRunnerProvider).request('sync');
      return true;
    } catch (e) {
      if ((e is ApiException && e.statusCode == 401) ||
          e is ServerInstanceChangedException) {
        // A 401, or a page stamped by another server (SC-01 rule 6): a wait,
        // not a failure. Back to the pre-run errors; the client's 401 hook
        // already withheld the token and handed the 401's stamp to the gate
        // (signed out, or another server), and a stamp mismatch is handed to
        // the gate (rule 1's different-server flow).
        if (e is ServerInstanceChangedException && connection != null) {
          gate.reportDifferentInstance(connection, e);
        }
        final latest = state.value ?? current;
        state = AsyncData(
          _publishedState(
            latest,
            service?.committedChanges ?? const SyncResult(),
            error: current?.error,
            libraryError: current?.libraryError,
            libraryServerRestored: current?.libraryServerRestored ?? false,
          ),
        );
        return false;
      }
      final latest = state.value ?? current;
      state = AsyncData(
        _publishedState(
          latest,
          e is BindingFencedException
              ? const SyncResult()
              : (service?.committedChanges ?? const SyncResult()),
          error: e.toString(),
          libraryError: library ? e.toString() : latest?.libraryError,
          // Decision 3 (a): a restored server is told apart from every other
          // failure; a Retry cannot help there.
          libraryServerRestored: library
              ? e is ServerRegressedException
              : (latest?.libraryServerRestored ?? false),
        ),
      );
      return false;
    }
  }

  /// The one publication of what a run changed (success or failure): bumps
  /// each mutation version once, and only when that kind of change happened.
  TrackSyncState _publishedState(
    TrackSyncState? latest,
    SyncResult changes, {
    String? error,
    String? libraryError,
    bool libraryServerRestored = false,
  }) {
    final queueVersion = latest?.queueMutationVersion ?? 0;
    final downloadVersion = latest?.downloadMutationVersion ?? 0;
    return TrackSyncState(
      error: error,
      libraryError: libraryError,
      libraryServerRestored: libraryServerRestored,
      queueMutationVersion: changes.affectedQueueSessionIds.isEmpty
          ? queueVersion
          : queueVersion + 1,
      downloadMutationVersion: changes.deletedTrackUuids.isEmpty
          ? downloadVersion
          : downloadVersion + 1,
      affectedQueueSessionIds: changes.affectedQueueSessionIds,
      deletedTrackUuids: changes.deletedTrackUuids,
      endedQueueSessionIds: changes.endedQueueSessionIds,
    );
  }
}

final trackSyncProvider =
    AsyncNotifierProvider<TrackSyncNotifier, TrackSyncState>(
      TrackSyncNotifier.new,
    );
