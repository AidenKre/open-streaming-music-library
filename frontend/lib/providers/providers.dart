import 'package:drift/drift.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('databaseProvider must be overridden');
});

final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) {
  return SharedPreferences.getInstance();
});

final tracksApiProvider = Provider<TracksApi>((ref) => TracksApi());

final queueRepositoryProvider = Provider<QueueRepository>((ref) {
  return QueueRepository(ref.read(databaseProvider));
});

final browseRepositoryProvider = Provider<BrowseRepository>((ref) {
  return BrowseRepository(ref.read(databaseProvider));
});

class TrackSyncState {
  final bool isSyncing;
  final String? error;

  const TrackSyncState({this.isSyncing = false, this.error});

  TrackSyncState copyWith({bool? isSyncing, String? error}) {
    return TrackSyncState(
      isSyncing: isSyncing ?? this.isSyncing,
      error: error,
    );
  }
}

class TrackSyncNotifier extends AsyncNotifier<TrackSyncState> {
  static const lastFetchTimeKey = 'lastFetchTime';

  @override
  Future<TrackSyncState> build() async {
    return const TrackSyncState();
  }

  Future<void> sync({int? artistId, int? albumId}) async {
    // Offline mode skips sync entirely — the network call would just fail.
    // OfflineModeNotifier re-invokes this on recovery, so the next online
    // tick will pick up everything that changed while we were dark.
    if (ref.read(offlineModeProvider)) return;

    final current = state.value;
    if (current != null && current.isSyncing) return;

    state = AsyncData(const TrackSyncState(isSyncing: true));

    try {
      final api = ref.read(tracksApiProvider);
      final db = ref.read(databaseProvider);
      final prefs = await ref.read(sharedPreferencesProvider.future);

      final lastFetchTime = prefs.getInt(lastFetchTimeKey);
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

      // First page: use time filters
      var response = await api.getTracksPage(
        newerThan: lastFetchTime,
        olderThan: now,
        artistId: artistId,
        albumId: albumId,
      );
      await _upsertTracks(db, response.data);

      // Tombstones only come back on the first page of an unscoped sync — the
      // backend cannot tell which deletions belong to a scoped (artist/album)
      // query, so it stays silent there. Apply them before rebuilding FTS so
      // the rebuild's `SELECT FROM trackmetadata` excludes deleted rows.
      final deletedUuids = response.deletedUuids;

      // Follow cursor for remaining pages
      while (response.nextCursor != null) {
        response = await api.getTracksPage(cursor: response.nextCursor);
        await _upsertTracks(db, response.data);
      }

      if (artistId == null && albumId == null && deletedUuids.isNotEmpty) {
        await _deleteTracks(db, deletedUuids);
      }

      await _rebuildFts(db);
      // Only fully unscoped syncs advance the global watermark. Scoped syncs
      // apply an artist/album filter to the backend query, so rows outside the
      // filter inside the same time window would be skipped forever if we
      // moved lastFetchTime past them here.
      if (artistId == null && albumId == null) {
        await prefs.setInt(lastFetchTimeKey, now);
      }
      state = AsyncData(const TrackSyncState());
    } catch (e) {
      state = AsyncData(TrackSyncState(error: e.toString()));
    }
  }

  Future<void> _upsertTracks(
    AppDatabase db,
    List<ClientTrackDto> tracks,
  ) async {
    await db.batch((batch) {
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
            db.artists,
            artistRow,
            onConflict: DoUpdate((_) => ArtistsCompanion(name: Value(effectiveArtist))),
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
            db.albums,
            albumRow,
            onConflict: DoUpdate((_) => AlbumsCompanion(
              name: hasAlbumName ? Value(meta.album) : const Value(null),
              artistId: Value(meta.artistId!),
              year: Value(meta.year),
              isSingleGrouping: Value(!hasAlbumName),
            )),
          );
        }
      }

      // Upsert tracks and trackmetadata
      for (final dto in tracks) {
        final tracksRow = tracksCompanionFromDto(dto);
        final metaRow = trackmetadataCompanionFromDto(dto);
        batch.insert(db.tracks, tracksRow, onConflict: DoUpdate((_) => tracksRow));
        batch.insert(db.trackmetadata, metaRow, onConflict: DoUpdate((_) => metaRow));
      }
    });
  }

  Future<void> _deleteTracks(AppDatabase db, List<String> uuids) async {
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
      await db.transaction(() async {
        // The play_order rows and queue_sessions.current_item_id /
        // resume_main_item_id reference queue_session_items by item_id. SQLite
        // FK enforcement is off (no PRAGMA foreign_keys), so the
        // QueueSessionPlayOrder cascade does not fire and current_item_id has
        // no FK at all — both must be cleaned up explicitly before the items
        // are deleted, or a saved session can be left pointing at a deleted
        // track and become unrestorable.
        final placeholders = List.filled(chunk.length, '?').join(', ');
        final itemIdSubquery =
            'SELECT item_id FROM queue_session_items WHERE uuid_id IN ($placeholders)';
        await db.customStatement(
          'DELETE FROM queue_session_play_order WHERE item_id IN ($itemIdSubquery)',
          chunk,
        );
        await db.customStatement(
          'UPDATE queue_sessions SET current_item_id = NULL '
          'WHERE current_item_id IN ($itemIdSubquery)',
          chunk,
        );
        await db.customStatement(
          'UPDATE queue_sessions SET resume_main_item_id = NULL '
          'WHERE resume_main_item_id IN ($itemIdSubquery)',
          chunk,
        );
        await (db.delete(
          db.queueSessionItems,
        )..where((t) => t.uuidId.isIn(chunk))).go();
        await (db.delete(
          db.trackmetadata,
        )..where((t) => t.uuidId.isIn(chunk))).go();
        await (db.delete(
          db.tracks,
        )..where((t) => t.uuidId.isIn(chunk))).go();
      });
    }
  }

  Future<void> _rebuildFts(AppDatabase db) async {
    await db.customStatement("INSERT INTO fts_artists(fts_artists) VALUES('delete-all')");
    await db.customStatement(
      "INSERT INTO fts_artists(rowid, name) "
      "SELECT id, name FROM artists",
    );

    await db.customStatement("INSERT INTO fts_albums(fts_albums) VALUES('delete-all')");
    await db.customStatement(
      "INSERT INTO fts_albums(rowid, name, artist_name) "
      "SELECT a.id, COALESCE(a.name, ''), ar.name "
      "FROM albums a JOIN artists ar ON a.artist_id = ar.id",
    );

    await db.customStatement("INSERT INTO fts_tracks(fts_tracks) VALUES('delete-all')");
    await db.customStatement(
      "INSERT INTO fts_tracks(rowid, title, artist_name, album_name) "
      "SELECT rowid, COALESCE(title, ''), COALESCE(artist, ''), COALESCE(album, '') "
      "FROM trackmetadata",
    );
  }
}

final trackSyncProvider =
    AsyncNotifierProvider<TrackSyncNotifier, TrackSyncState>(
  TrackSyncNotifier.new,
);
