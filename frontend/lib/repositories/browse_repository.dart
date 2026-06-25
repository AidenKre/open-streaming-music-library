import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';

class BrowseRepository {
  final AppDatabase _db;

  BrowseRepository(this._db);

  // ── Albums ──────────────────────────────────────────────────────────────

  Future<List<AlbumUI>> getAlbums({
    int? artistId,
    List<AlbumOrderParameter> orderBy = const [],
    List<AlbumRowFilterParameter> cursorFilters = const [],
    int? limit,
    bool downloadedOnly = false,
  }) async {
    final rows = await _db.getAlbums(
      artistId: artistId,
      orderBy: orderBy,
      cursorFilters: cursorFilters,
      limit: limit,
      downloadedOnly: downloadedOnly,
    );
    return rows.map(AlbumUI.fromQueryRow).toList(growable: false);
  }

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

  Stream<int> watchAlbumsCount({
    int? artistId,
    List<AlbumOrderParameter> orderBy = const [],
    List<AlbumRowFilterParameter> cursorFilters = const [],
    bool downloadedOnly = false,
  }) {
    return _db.watchAlbumsCount(
      artistId: artistId,
      orderBy: orderBy,
      cursorFilters: cursorFilters,
      downloadedOnly: downloadedOnly,
    );
  }

  // ── Artists ─────────────────────────────────────────────────────────────

  Future<List<ArtistUI>> getArtists({
    List<ArtistOrderParameter> orderBy = const [],
    List<ArtistRowFilterParameter> cursorFilters = const [],
    int? limit,
    bool downloadedOnly = false,
  }) async {
    final rows = await _db.getArtists(
      orderBy: orderBy,
      cursorFilters: cursorFilters,
      limit: limit,
      downloadedOnly: downloadedOnly,
    );
    return rows.map(ArtistUI.fromQueryRow).toList(growable: false);
  }

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

  Stream<int> watchArtistCount({
    List<ArtistOrderParameter> orderBy = const [],
    List<ArtistRowFilterParameter> cursorFilters = const [],
    bool downloadedOnly = false,
  }) {
    return _db.watchArtistCount(
      orderBy: orderBy,
      cursorFilters: cursorFilters,
      downloadedOnly: downloadedOnly,
    );
  }

  // ── Tracks ──────────────────────────────────────────────────────────────

  Future<List<TrackUI>> getTracks({
    List<OrderParameter> orderBy = const [],
    List<RowFilterParameter> cursorFilters = const [],
    int? artistId,
    int? albumId,
    int? limit,
    bool downloadedOnly = false,
  }) async {
    final rows = await _db.getTracks(
      orderBy: orderBy,
      cursorFilters: cursorFilters,
      artistId: artistId,
      albumId: albumId,
      limit: limit,
      downloadedOnly: downloadedOnly,
    );
    return rows.map(TrackUI.fromQueryRow).toList(growable: false);
  }

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

  Stream<int> watchTrackCount({
    List<OrderParameter> orderBy = const [],
    List<RowFilterParameter> cursorFilters = const [],
    int? artistId,
    int? albumId,
    bool downloadedOnly = false,
  }) {
    return _db.watchTrackCount(
      orderBy: orderBy,
      cursorFilters: cursorFilters,
      artistId: artistId,
      albumId: albumId,
      downloadedOnly: downloadedOnly,
    );
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
