import 'dart:developer' as developer;

import 'package:drift/drift.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/change_entry_dto.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';
import 'package:path_provider/path_provider.dart';

// Moved (B.13); re-exported so importers keep working.
export 'package:frontend/repositories/sync_cursor_store.dart'
    show ServerRegressedException;

class SyncResult {
  final Set<int> affectedQueueSessionIds;
  final Set<String> deletedTrackUuids;

  /// Sessions of [affectedQueueSessionIds] whose removed current item was the
  /// end of the queue with no wrap: playback there must stop (U20-B-01).
  final Set<int> endedQueueSessionIds;

  const SyncResult({
    this.affectedQueueSessionIds = const {},
    this.deletedTrackUuids = const {},
    this.endedQueueSessionIds = const {},
  });
}

/// Drives revision-based incremental sync: pages the `/changes` stream,
/// applies the interleaved upsert/delete entries into the local database in
/// revision order, advances the watermark, and updates the search entries of
/// the tracks each page changed, in that page's transaction.
///
/// Every local write is fenced (SC-01 rule 4) by [bindingToken], the
/// `local_binding_id` captured when the sync task started: once a reset
/// deletes or a re-bind replaces the binding row, a late write throws
/// [BindingFencedException] and changes nothing.
class SyncService {
  final AppDatabase _db;
  final TracksApi _api;
  final QueueRepository _queueRepo;
  final String _bindingToken;
  final ServerBindingRepository _binding;
  final SyncCursorStore _cursors;
  final OwnedFileCleanup _ownedCleanup;

  SyncService({
    required AppDatabase db,
    required TracksApi api,
    required QueueRepository queueRepository,
    required String bindingToken,
    OwnedFileCleanup? ownedFileCleanup,
  }) : _db = db,
       _api = api,
       _queueRepo = queueRepository,
       _bindingToken = bindingToken,
       _binding = ServerBindingRepository(db),
       _cursors = SyncCursorStore(db),
       _ownedCleanup =
           ownedFileCleanup ??
           OwnedFileCleanup(
             db: db,
             documentsDirectory: getApplicationDocumentsDirectory,
           );

  /// The binding token this run's writes are fenced by (SC-01 rule 4), for
  /// work sharing the run's critical section (the edit outbox flush).
  String get bindingToken => _bindingToken;

  final _committed = _SyncEffects();

  /// What this service's runs have changed and COMMITTED so far. Each page /
  /// refetch collects into its own effects and merges here only after its
  /// fenced transaction returned, so a refused or rolled-back page never
  /// leaks. A caller reads this after a failure to publish what an earlier
  /// page did change.
  SyncResult get committedChanges => SyncResult(
        affectedQueueSessionIds:
            Set.unmodifiable(_committed.affectedQueueSessionIds),
        deletedTrackUuids: Set.unmodifiable(_committed.deletedTrackUuids),
        endedQueueSessionIds: Set.unmodifiable(_committed.endedSessionIds),
      );

  Future<SyncResult> syncChanges() async {
    // The catalog watermark (last monotonic revision applied) lives in
    // `sync_cursors.catalog` (SC-02).
    final after = await _cursors.read(SyncStream.catalog);
    // Each page updates its own search entries in the transaction that saves
    // it, so a sync that saved nothing touches no search table, and one that
    // fails or is killed after a page leaves that page's tracks searchable.
    await _applyPages(after);
    return committedChanges;
  }

  Future<void> _applyPages(int after) async {

    // Page through the revision-ordered change stream. Upserts and deletes
    // interleave by revision; apply them in order so a later delete of a
    // uuid wins over an earlier upsert. Each page and its cursor advance
    // commit in one fenced transaction, so a crash or failure mid-page
    // resumes from the last committed page.
    while (true) {
      final requestedAfter = after;
      final response = await _api.getChangesPage(afterRevision: requestedAfter);
      // SC-01 rule 5: compare with the `after` this request sent, never with
      // the cursor after applying.
      if (response.latestRevision < requestedAfter) {
        try {
          await _binding.clearCatalogReconciled(
            _bindingToken,
            servedBy: response.servedBy,
          );
        } on BindingFencedException {
          // a reset is under way: nothing to clear
        }
        throw ServerRegressedException(
          requestedAfter: requestedAfter,
          latestRevision: response.latestRevision,
        );
      }
      final cursor = response.nextCursor;
      final lastAppliedRevision = response.changes.isEmpty
          ? null
          : response.changes.last.revision;
      if (cursor != null &&
          (cursor <= requestedAfter ||
              (lastAppliedRevision != null && cursor < lastAppliedRevision))) {
        throw FormatException(
          'Invalid non-advancing changes cursor: $cursor after $requestedAfter',
        );
      }
      // More pages remain: advance by the server's cursor (the highest
      // revision it consumed) rather than the last applied entry: a row may
      // have been concurrently deleted mid-read and dropped from `changes`,
      // and trusting the cursor both avoids stalling and is a safe watermark
      // (that row's delete carries a higher revision and arrives later).
      // Final page: the highest revision actually seen, if any.
      final newCursor = cursor ?? lastAppliedRevision;
      final page = _SyncEffects();
      await _binding.runFenced(_bindingToken, servedBy: response.servedBy, () async {
        final searchBefore = await _readSearchBeforePage(response.changes);
        await _applyChanges(response.changes, page);
        await _updateSearchIndex(searchBefore, page);
        if (newCursor != null) {
          await _cursors.write(SyncStream.catalog, newCursor);
        }
        // Final page: the first complete catalog sync since binding (Phase 5
        // §3a), committed with that page.
        if (cursor == null) {
          await _binding.markCatalogReconciledInTransaction();
        }
      });
      // The page is committed: only now do its changes count.
      _committed.addCommitted(page);
      // Only once the deletes are committed.
      await _attemptOwnedCleanup(page.cleanupIds);
      if (cursor == null) break;
      after = cursor;
    }
  }

  /// Reconcile a single track to current server truth: refetch it and upsert
  /// locally, or delete it locally if the server reports it gone (404/410).
  /// Unlike [syncChanges] this does not consult the watermark, so it can
  /// recover a track even after the watermark has advanced past the change
  /// that needs re-applying (the conflict "take server" case). Does not move
  /// the watermark — a later `/changes` pull is still authoritative.
  /// [rebuildParentFts]: false lets a caller batching several single-track
  /// refetches in a row (e.g. retrying multiple queued take-server markers)
  /// defer this to one rebuild after the whole batch instead of paying it
  /// once per track.
  Future<SyncResult> refetchAndApplyTrack(
    String uuidId, {
    bool rebuildParentFts = true,
  }) async {
    final effects = _SyncEffects();
    ClientTrackDto? dto;
    try {
      dto = await _api.getTrack(uuidId);
    } on ApiException catch (e) {
      // 404/410: gone on the server -> delete locally (dto stays null).
      if (e.statusCode != 404 && e.statusCode != 410) rethrow;
    }
    await _binding.runFenced(_bindingToken, () async {
      final before = await _db.readTrackFtsEntry(uuidId);
      if (dto != null) {
        await _upsertTracks([dto]);
      } else {
        await _deleteTracks([uuidId], effects);
      }
      // Targeted FTS maintenance: exactly one track row changed, so apply a
      // per-row fts_tracks delta instead of the O(library) rebuild. The
      // upsert may also have created/renamed/pruned parent rows, so
      // re-derive just the two small parent indexes.
      await _db.applyTrackFtsDelta(uuidId, before);
      if (rebuildParentFts) await _db.rebuildParentFtsIndexes();
    });
    _committed.addCommitted(effects);
    await _attemptOwnedCleanup(effects.cleanupIds);
    return SyncResult(
      affectedQueueSessionIds: effects.affectedQueueSessionIds,
      deletedTrackUuids: effects.deletedTrackUuids,
      endedQueueSessionIds: effects.endedSessionIds,
    );
  }

  /// The search state of what [changes] write: every entry's track, and the
  /// artist and album ids its upserts carry.
  Future<PageSearchBefore> _readSearchBeforePage(List<ChangeEntryDto> changes) {
    final upserted = [
      for (final e in changes)
        if (e.track != null) e.track!.metadata,
    ];
    return _db.readSearchBeforePage(
      trackIds: {for (final e in changes) e.uuidId},
      artistIds: {
        for (final m in upserted)
          if (m.artistId != null) m.artistId!,
      },
      albumIds: {
        for (final m in upserted)
          if (m.albumId != null) m.albumId!,
      },
    );
  }

  /// The page's search update, run in the page's transaction after its
  /// writes. If the index turns out not to hold what the tables say (FTS5
  /// raises SQLITE_CORRUPT_VTAB, see [isSearchIndexMismatch]), the partial
  /// update is undone (it ran in a savepoint) and the three search tables are
  /// rebuilt in full from the rows just written, so the page is saved and the
  /// sync goes on. Any other error fails the page as before.
  Future<void> _updateSearchIndex(
    PageSearchBefore before,
    _SyncEffects page,
  ) async {
    try {
      await _db.transaction(
        () => _db.applySearchDeltaOfPage(
          before,
          parentsPruned: page.parentRowsPruned > 0,
        ),
      );
    } on Object catch (e) {
      if (!isSearchIndexMismatch(e)) rethrow;
      developer.log(
        'The search index did not match the library; rebuilt it in full',
        name: 'SyncService',
      );
      await _db.rebuildFtsIndexes();
    }
  }

  /// Applies an ordered change page, grouping consecutive runs of the same
  /// type so upserts and deletes are batched without reordering across a
  /// type boundary (preserving revision order between them).
  Future<void> _applyChanges(
    List<ChangeEntryDto> changes,
    _SyncEffects effects,
  ) async {
    var i = 0;
    while (i < changes.length) {
      final type = changes[i].type;
      var j = i;
      while (j < changes.length && changes[j].type == type) {
        j++;
      }
      final run = changes.sublist(i, j);
      switch (type) {
        case ChangeEntryType.upsert:
          effects.parentRowsPruned +=
              await _upsertTracks([for (final e in run) e.track!]);
        case ChangeEntryType.delete:
          await _deleteTracks([for (final e in run) e.uuidId], effects);
      }
      i = j;
    }
  }

  /// Returns how many artist and album rows the orphan prune removed.
  Future<int> _upsertTracks(List<ClientTrackDto> tracks) async {
    return _db.transaction(() async {
      await _db.batch((batch) {
        // Upsert artists first (parent table)
        for (final dto in tracks) {
          final meta = dto.metadata;
          final effectiveArtist = meta.albumArtist ?? meta.artist;
          if (meta.artistId != null && effectiveArtist != null) {
            final artistRow = ArtistsCompanion(
              id: Value(meta.artistId!),
              name: Value(effectiveArtist),
            );
            batch.insert(
              _db.artists,
              artistRow,
              onConflict: DoUpdate(
                (_) => ArtistsCompanion(name: Value(effectiveArtist)),
              ),
            );
          }
        }

        // Upsert albums (references artists)
        for (final dto in tracks) {
          final meta = dto.metadata;
          if (meta.albumId != null && meta.artistId != null) {
            final hasAlbumName = meta.album != null && meta.album!.isNotEmpty;
            final albumRow = AlbumsCompanion(
              id: Value(meta.albumId!),
              name: hasAlbumName ? Value(meta.album) : const Value(null),
              artistId: Value(meta.artistId!),
              year: Value(meta.year),
              isSingleGrouping: Value(!hasAlbumName),
            );
            batch.insert(
              _db.albums,
              albumRow,
              onConflict: DoUpdate(
                (_) => AlbumsCompanion(
                  name: hasAlbumName ? Value(meta.album) : const Value(null),
                  artistId: Value(meta.artistId!),
                  year: Value(meta.year),
                  isSingleGrouping: Value(!hasAlbumName),
                ),
              ),
            );
          }
        }

        // Upsert tracks and trackmetadata
        for (final dto in tracks) {
          final tracksRow = tracksCompanionFromDto(dto);
          final metaRow = trackmetadataCompanionFromDto(dto);
          batch.insert(
            _db.tracks,
            tracksRow,
            onConflict: DoUpdate((_) => tracksRow),
          );
          batch.insert(
            _db.trackmetadata,
            metaRow,
            onConflict: DoUpdate((_) => metaRow),
          );
        }
      });
      return _pruneOrphanParents();
    });
  }

  /// Returns how many artist and album rows it removed.
  Future<int> _pruneOrphanParents() async {
    // customUpdate (not customStatement) so the deletes notify the albums/
    // artists stream watchers directly — the reactive browse lists drop the
    // emptied cards without depending on a sibling write to trigger them.
    final albumsRemoved = await _db.customUpdate(
      'DELETE FROM albums WHERE NOT EXISTS ('
      'SELECT 1 FROM trackmetadata tm WHERE tm.album_id = albums.id'
      ')',
      updates: {_db.albums},
      updateKind: UpdateKind.delete,
    );
    final artistsRemoved = await _db.customUpdate(
      'DELETE FROM artists WHERE NOT EXISTS ('
      'SELECT 1 FROM trackmetadata tm WHERE tm.artist_id = artists.id'
      ')',
      updates: {_db.artists},
      updateKind: UpdateKind.delete,
    );
    return albumsRemoved + artistsRemoved;
  }

  /// Must run inside the caller's fenced transaction. Adds the deleted
  /// tracks' downloaded files to the durable cleanup queue (same transaction,
  /// before the references are lost) and adds the row ids to the effects'
  /// cleanup ids; the caller attempts them only after that transaction
  /// commits.
  Future<void> _deleteTracks(List<String> uuids, _SyncEffects effects) async {
    // Child rows go first (trackmetadata before tracks). The schema declares
    // those references, but the app never turns SQLite's foreign_keys on, so
    // nothing enforces the order (see AppDatabase). We chunk to keep the IN
    // list bounded — SQLite accepts thousands of bind vars but huge bursts of
    // deletes are rare and worth fragmenting for predictability.
    const chunkSize = 200;
    for (var i = 0; i < uuids.length; i += chunkSize) {
      final chunk = uuids.sublist(
        i,
        i + chunkSize > uuids.length ? uuids.length : i + chunkSize,
      );
      effects.deletedTrackUuids.addAll(chunk);
      await _db.transaction(() async {
        final queueRemoval = await _queueRepo
            .removeTrackUuidsFromQueuesInTransaction(chunk);
        effects.affectedQueueSessionIds.addAll(queueRemoval.affectedSessionIds);
        effects.land(
          ended: queueRemoval.endedSessionIds,
          relanded: queueRemoval.relandedSessionIds,
        );
        effects.cleanupIds.addAll(
          await _ownedCleanup.enqueueInTransaction(
            await _localFilePathsForTracks(chunk),
            localBindingId: _bindingToken,
          ),
        );
        await (_db.delete(
          _db.trackmetadata,
        )..where((t) => t.uuidId.isIn(chunk))).go();
        await (_db.delete(_db.tracks)..where((t) => t.uuidId.isIn(chunk))).go();
        await _db.rejectUnsentEditsOfDeletedTracks(chunk);
        effects.parentRowsPruned += await _pruneOrphanParents();
      });
    }
  }

  Future<List<String>> _localFilePathsForTracks(List<String> uuids) async {
    // Includes a kept damaged copy (decision 6).
    return _db.ownedTrackFilePaths(uuids: uuids);
  }

  /// Best effort after the fenced commit: the rows are durable and the
  /// cleanup runner retries them, so a failing attempt never fails the sync.
  Future<void> _attemptOwnedCleanup(List<int> ids) async {
    if (ids.isEmpty) return;
    try {
      await _ownedCleanup.cleanRows(ids, bindingToken: _bindingToken);
    } on Object catch (e) {
      developer.log(
        'owned cleanup attempt failed for ${ids.length} row(s): $e',
        name: 'SyncService',
      );
    }
  }
}

/// What applying catalog changes did: the queue sessions touched, the
/// deleted tracks, the sessions whose playback must stop or may go on, and
/// the clean-up rows to attempt after the commit. A page or a refetch
/// collects into its own; the service merges it into its committed effects
/// only after the fenced transaction returned.
class _SyncEffects {
  final affectedQueueSessionIds = <int>{};
  final deletedTrackUuids = <String>{};

  /// Sessions whose removed current item was the end of the queue (no wrap).
  final endedSessionIds = <int>{};

  /// Sessions that landed on an item again after being ended.
  final relandedSessionIds = <int>{};

  final cleanupIds = <int>[];

  /// Artist and album rows the orphan prune removed: the page's parent search
  /// indexes must be rebuilt. Not merged into the committed effects.
  var parentRowsPruned = 0;

  /// The one rule for ended sessions: a session that re-landed is no longer
  /// ended; one that ended (later) is.
  void land({required Set<int> ended, required Set<int> relanded}) {
    endedSessionIds
      ..removeAll(relanded)
      ..addAll(ended);
    relandedSessionIds.addAll(relanded);
  }

  /// Merges [committed] (a page or a refetch whose transaction committed).
  void addCommitted(_SyncEffects committed) {
    affectedQueueSessionIds.addAll(committed.affectedQueueSessionIds);
    deletedTrackUuids.addAll(committed.deletedTrackUuids);
    land(
      ended: committed.endedSessionIds,
      relanded: committed.relandedSessionIds,
    );
  }
}
