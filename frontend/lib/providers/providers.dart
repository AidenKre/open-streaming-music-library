import 'package:drift/drift.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  return AppDatabase(openAppDatabase());
});

final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) {
  return SharedPreferences.getInstance();
});

final tracksApiProvider = Provider<TracksApi>((ref) => TracksApi());

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

      // Follow cursor for remaining pages
      while (response.nextCursor != null) {
        response = await api.getTracksPage(cursor: response.nextCursor);
        await _upsertTracks(db, response.data);
      }

      await _rebuildFts(db);
      await prefs.setInt(lastFetchTimeKey, now);
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

  Future<void> _rebuildFts(AppDatabase db) async {
    await db.customStatement("DELETE FROM fts_artists");
    await db.customStatement(
      "INSERT INTO fts_artists(rowid, name) "
      "SELECT id, name FROM artists",
    );

    await db.customStatement("DELETE FROM fts_albums");
    await db.customStatement(
      "INSERT INTO fts_albums(rowid, name, artist_name) "
      "SELECT a.id, COALESCE(a.name, ''), ar.name "
      "FROM albums a JOIN artists ar ON a.artist_id = ar.id",
    );

    await db.customStatement("DELETE FROM fts_tracks");
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
