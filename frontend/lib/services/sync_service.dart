import 'dart:io';

import 'package:drift/drift.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/change_entry_dto.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SyncResult {
  final Set<int> affectedQueueSessionIds;
  final Set<String> deletedTrackUuids;

  const SyncResult({
    this.affectedQueueSessionIds = const {},
    this.deletedTrackUuids = const {},
  });
}

/// The server answered with a `latestRevision` below the `after` this client
/// requested: it was restored from an older backup (SC-01 rule 5). Nothing
/// from that response was applied.
class ServerRegressedException implements Exception {
  ServerRegressedException({
    required this.requestedAfter,
    required this.latestRevision,
  });
  final int requestedAfter;
  final int latestRevision;

  @override
  String toString() =>
      'ServerRegressedException(requested after $requestedAfter, '
      'server latest $latestRevision)';
}

/// Drives revision-based incremental sync: pages the `/changes` stream,
/// applies the interleaved upsert/delete entries into the local database in
/// revision order, advances the watermark, and rebuilds search indexes.
///
/// Every local write is fenced (SC-01 rule 4) by [bindingToken], the
/// `local_binding_id` captured when the sync task started: once a reset
/// deletes or a re-bind replaces the binding row, a late write throws
/// [BindingFencedException] and changes nothing.
class SyncService {
  final AppDatabase _db;
  final TracksApi _api;
  final QueueRepository _queueRepo;
  final SharedPreferences _prefs;
  final String _bindingToken;
  final ServerBindingRepository _binding;
  final SyncCursorStore _cursors;

  SyncService({
    required AppDatabase db,
    required TracksApi api,
    required QueueRepository queueRepository,
    required SharedPreferences prefs,
    required String bindingToken,
  }) : _db = db,
       _api = api,
       _queueRepo = queueRepository,
       _prefs = prefs,
       _bindingToken = bindingToken,
       _binding = ServerBindingRepository(db),
       _cursors = SyncCursorStore(db);

  /// The binding token this run's writes are fenced by (SC-01 rule 4), for
  /// work sharing the run's critical section (the edit outbox flush).
  String get bindingToken => _bindingToken;

  /// The pre-SC-02 SharedPreferences key of the catalog watermark, read once
  /// and removed by [SyncCursorStore.migrateLegacyCatalogCursor].
  static const lastRevisionKey = SyncCursorStore.legacyCatalogPrefKey;

  Future<SyncResult> syncChanges() async {
    // The catalog watermark (last monotonic revision applied) lives in
    // `sync_cursors.catalog` (SC-02); a pre-SC-02 pref moves there once.
    await _cursors.migrateLegacyCatalogCursor(
      _prefs,
      transaction: (body) => _binding.runFenced(_bindingToken, body),
    );
    var after = await _cursors.read(SyncStream.catalog);
    final affectedQueueSessionIds = <int>{};
    final deletedTrackUuids = <String>{};

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
      final localFilePaths = <String>[];
      await _binding.runFenced(_bindingToken, () async {
        await _applyChanges(
          response.changes,
          affectedQueueSessionIds: affectedQueueSessionIds,
          deletedTrackUuids: deletedTrackUuids,
          localFilePaths: localFilePaths,
        );
        if (newCursor != null) {
          await _cursors.write(SyncStream.catalog, newCursor);
        }
        // Final page: the first complete catalog sync since binding (Phase 5
        // §3a), committed with that page.
        if (cursor == null) {
          await _binding.markCatalogReconciledInTransaction();
        }
      });
      // Only once the deletes are committed.
      await _deleteLocalFiles(localFilePaths);
      if (cursor == null) break;
      after = cursor;
    }

    await _db.rebuildFtsIndexes();
    return SyncResult(
      affectedQueueSessionIds: affectedQueueSessionIds,
      deletedTrackUuids: deletedTrackUuids,
    );
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
    final affectedQueueSessionIds = <int>{};
    final deletedTrackUuids = <String>{};
    ClientTrackDto? dto;
    try {
      dto = await _api.getTrack(uuidId);
    } on ApiException catch (e) {
      // 404/410: gone on the server -> delete locally (dto stays null).
      if (e.statusCode != 404 && e.statusCode != 410) rethrow;
    }
    final localFilePaths = <String>[];
    await _binding.runFenced(_bindingToken, () async {
      final before = await _db.readTrackFtsEntry(uuidId);
      if (dto != null) {
        await _upsertTracks([dto]);
      } else {
        await _deleteTracks(
          [uuidId],
          affectedQueueSessionIds: affectedQueueSessionIds,
          deletedTrackUuids: deletedTrackUuids,
          localFilePaths: localFilePaths,
        );
      }
      // Targeted FTS maintenance: exactly one track row changed, so apply a
      // per-row fts_tracks delta instead of the O(library) rebuild. The
      // upsert may also have created/renamed/pruned parent rows, so
      // re-derive just the two small parent indexes.
      await _db.applyTrackFtsDelta(uuidId, before);
      if (rebuildParentFts) await _db.rebuildParentFtsIndexes();
    });
    await _deleteLocalFiles(localFilePaths);
    return SyncResult(
      affectedQueueSessionIds: affectedQueueSessionIds,
      deletedTrackUuids: deletedTrackUuids,
    );
  }

  /// Applies an ordered change page, grouping consecutive runs of the same
  /// type so upserts and deletes are batched without reordering across a
  /// type boundary (preserving revision order between them).
  Future<void> _applyChanges(
    List<ChangeEntryDto> changes, {
    required Set<int> affectedQueueSessionIds,
    required Set<String> deletedTrackUuids,
    required List<String> localFilePaths,
  }) async {
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
          await _upsertTracks([for (final e in run) e.track!]);
        case ChangeEntryType.delete:
          await _deleteTracks(
            [for (final e in run) e.uuidId],
            affectedQueueSessionIds: affectedQueueSessionIds,
            deletedTrackUuids: deletedTrackUuids,
            localFilePaths: localFilePaths,
          );
      }
      i = j;
    }
  }

  Future<void> _upsertTracks(List<ClientTrackDto> tracks) async {
    await _db.transaction(() async {
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
      await _pruneOrphanParents();
    });
  }

  Future<void> _pruneOrphanParents() async {
    // customUpdate (not customStatement) so the deletes notify the albums/
    // artists stream watchers directly — the reactive browse lists drop the
    // emptied cards without depending on a sibling write to trigger them.
    await _db.customUpdate(
      'DELETE FROM albums WHERE NOT EXISTS ('
      'SELECT 1 FROM trackmetadata tm WHERE tm.album_id = albums.id'
      ')',
      updates: {_db.albums},
      updateKind: UpdateKind.delete,
    );
    await _db.customUpdate(
      'DELETE FROM artists WHERE NOT EXISTS ('
      'SELECT 1 FROM trackmetadata tm WHERE tm.artist_id = artists.id'
      ')',
      updates: {_db.artists},
      updateKind: UpdateKind.delete,
    );
  }

  /// Must run inside the caller's fenced transaction. Adds the deleted
  /// tracks' downloaded files to [localFilePaths]; the caller deletes them
  /// only after that transaction commits.
  Future<void> _deleteTracks(
    List<String> uuids, {
    required Set<int> affectedQueueSessionIds,
    required Set<String> deletedTrackUuids,
    required List<String> localFilePaths,
  }) async {
    // FKs on trackmetadata.uuid_id → tracks.uuid_id (and queue_session_items)
    // force child-first deletes. We chunk to keep the IN list bounded — SQLite
    // accepts thousands of bind vars but huge bursts of deletes are rare and
    // worth fragmenting for predictability.
    const chunkSize = 200;
    for (var i = 0; i < uuids.length; i += chunkSize) {
      final chunk = uuids.sublist(
        i,
        i + chunkSize > uuids.length ? uuids.length : i + chunkSize,
      );
      deletedTrackUuids.addAll(chunk);
      await _db.transaction(() async {
        final queueRemoval = await _queueRepo
            .removeTrackUuidsFromQueuesInTransaction(chunk);
        affectedQueueSessionIds.addAll(queueRemoval.affectedSessionIds);
        localFilePaths.addAll(await _localFilePathsForTracks(chunk));
        await (_db.delete(
          _db.trackmetadata,
        )..where((t) => t.uuidId.isIn(chunk))).go();
        await (_db.delete(_db.tracks)..where((t) => t.uuidId.isIn(chunk))).go();
        await _pruneOrphanParents();
      });
    }
  }

  Future<List<String>> _localFilePathsForTracks(List<String> uuids) async {
    if (uuids.isEmpty) return const [];

    final placeholders = List.filled(uuids.length, '?').join(', ');
    final rows = await _db
        .customSelect(
          'SELECT file_path FROM tracks '
          'WHERE uuid_id IN ($placeholders) AND file_path IS NOT NULL',
          variables: uuids.map(Variable.withString).toList(),
        )
        .get();

    return rows
        .map((row) => row.readNullable<String>('file_path'))
        .nonNulls
        .toList(growable: false);
  }

  Future<void> _deleteLocalFiles(List<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }
}
