import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';

class BrowseRepository {
  final AppDatabase _db;

  BrowseRepository(this._db);

  // ── Albums ──────────────────────────────────────────────────────────────

  Stream<List<AlbumUI>> watchAlbums({
    int? artistId,
    List<AlbumOrderParameter> orderBy = const [],
    int? limit,
    bool downloadedOnly = false,
  }) {
    return _db
        .watchAlbums(
          artistId: artistId,
          orderBy: orderBy,
          limit: limit,
          downloadedOnly: downloadedOnly,
        )
        .map((rows) => rows.map(AlbumUI.fromQueryRow).toList(growable: false));
  }

  // ── Artists ─────────────────────────────────────────────────────────────

  Stream<List<ArtistUI>> watchArtists({
    List<ArtistOrderParameter> orderBy = const [],
    int? limit,
    bool downloadedOnly = false,
  }) {
    return _db
        .watchArtists(
          orderBy: orderBy,
          limit: limit,
          downloadedOnly: downloadedOnly,
        )
        .map((rows) => rows.map(ArtistUI.fromQueryRow).toList(growable: false));
  }

  // ── Tracks ──────────────────────────────────────────────────────────────

  Stream<List<TrackUI>> watchTracks({
    List<OrderParameter> orderBy = const [],
    int? artistId,
    int? albumId,
    int? limit,
    bool downloadedOnly = false,
  }) {
    return _db
        .watchTracks(
          orderBy: orderBy,
          artistId: artistId,
          albumId: albumId,
          limit: limit,
          downloadedOnly: downloadedOnly,
        )
        .map((rows) => rows.map(TrackUI.fromQueryRow).toList(growable: false));
  }

  // ── Track loading for queue operations ──────────────────────────────────

  Future<List<TrackUI>> getTracksForAlbum(int artistId, int albumId) async {
    final uuids = await _db.getTrackUuids(
      artistId: artistId,
      albumId: albumId,
    );
    if (uuids.isEmpty) return [];
    final rows = await _db.getTracksByUuids(uuids);
    return rows.map(TrackUI.fromQueryRow).toList(growable: false);
  }

  Future<List<TrackUI>> getTracksForArtist(int artistId) async {
    final uuids = await _db.getTrackUuids(artistId: artistId);
    if (uuids.isEmpty) return [];
    final rows = await _db.getTracksByUuids(uuids);
    return rows.map(TrackUI.fromQueryRow).toList(growable: false);
  }

  // ── Search ──────────────────────────────────────────────────────────────

  Future<({List<ArtistUI> artists, List<AlbumUI> albums, List<TrackUI> tracks})>
  search(
    String query, {
    int limitPerType = 5,
    bool downloadedOnly = false,
  }) async {
    final results = await _db.getSearchResults(
      query,
      limitPerType: limitPerType,
      downloadedOnly: downloadedOnly,
    );
    return (
      artists: results.artists
          .map(ArtistUI.fromQueryRow)
          .toList(growable: false),
      albums: results.albums
          .map(AlbumUI.fromQueryRow)
          .toList(growable: false),
      tracks: results.tracks
          .map(TrackUI.fromQueryRow)
          .toList(growable: false),
    );
  }
}
