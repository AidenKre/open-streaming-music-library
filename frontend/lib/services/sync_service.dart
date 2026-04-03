import 'dart:io';

import 'package:drift/drift.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/change_entry_dto.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SyncResult {
  final Set<int> affectedQueueSessionIds;
  final Set<String> deletedTrackUuids;

  const SyncResult({
    this.affectedQueueSessionIds = const {},
    this.deletedTrackUuids = const {},
  });
}

/// Drives revision-based incremental sync: pages the `/changes` stream,
/// applies the interleaved upsert/delete entries into the local database in
/// revision order, advances the watermark, and rebuilds search indexes.
class SyncService {
  final AppDatabase _db;
  final TracksApi _api;
  final QueueRepository _queueRepo;
  final SharedPreferences _prefs;

  SyncService({
    required AppDatabase db,
    required TracksApi api,
    required QueueRepository queueRepository,
    required SharedPreferences prefs,
  }) : _db = db,
       _api = api,
       _queueRepo = queueRepository,
       _prefs = prefs;

  // Last monotonic revision the client has applied. Sent as `after_revision`
  // and advanced per page; absence means a full resync from 0.
  static const lastRevisionKey = 'lastRevision';

  Future<SyncResult> syncChanges() async {
    var after = _prefs.getInt(lastRevisionKey) ?? 0;
    final affectedQueueSessionIds = <int>{};
    final deletedTrackUuids = <String>{};

    // Page through the revision-ordered change stream. Upserts and deletes
    // interleave by revision; apply them in order so a later delete of a
    // uuid wins over an earlier upsert. Persist the watermark per page —
    // re-applying a page is idempotent (DoUpdate upserts, uuid-keyed
    // deletes), so a crash mid-sync just resumes from the last saved page.
    while (true) {
      final response = await _api.getChangesPage(afterRevision: after);
      await _applyChanges(
        response.changes,
        affectedQueueSessionIds: affectedQueueSessionIds,
        deletedTrackUuids: deletedTrackUuids,
      );
      final cursor = response.nextCursor;
      if (cursor != null) {
        final lastAppliedRevision = response.changes.isEmpty
            ? null
            : response.changes.last.revision;
        if (cursor <= after ||
            (lastAppliedRevision != null && cursor < lastAppliedRevision)) {
          throw FormatException(
            'Invalid non-advancing changes cursor: $cursor after $after',
          );
        }
        // More pages remain. Advance by the server's cursor (the highest
        // revision it consumed) rather than the last applied entry: a row may
        // have been concurrently deleted mid-read and dropped from `changes`,
        // and trusting the cursor both avoids stalling and is a safe watermark
        // (that row's delete carries a higher revision and arrives later).
        after = cursor;
        await _prefs.setInt(lastRevisionKey, after);
      } else {
        // Final page: persist the highest revision actually seen, if any.
        if (response.changes.isNotEmpty) {
          await _prefs.setInt(lastRevisionKey, response.changes.last.revision);
        }
        break;
      }
    }

    await _db.rebuildFtsIndexes();
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
    await _db.customStatement(
      'DELETE FROM albums WHERE NOT EXISTS ('
      'SELECT 1 FROM trackmetadata tm WHERE tm.album_id = albums.id'
      ')',
    );
    await _db.customStatement(
      'DELETE FROM artists WHERE NOT EXISTS ('
      'SELECT 1 FROM trackmetadata tm WHERE tm.artist_id = artists.id'
      ')',
    );
  }

  Future<void> _deleteTracks(
    List<String> uuids, {
    required Set<int> affectedQueueSessionIds,
    required Set<String> deletedTrackUuids,
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
      final localFilePaths = <String>[];
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
      await _deleteLocalFiles(localFilePaths);
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
