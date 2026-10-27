import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';

/// Entity kinds a [BrowseRepository.search] can be asked for.
enum SearchType { artists, albums, tracks }

typedef LibrarySearchResults = ({
  List<ArtistUI> artists,
  List<AlbumUI> albums,
  List<TrackUI> tracks,
});

const LibrarySearchResults emptySearchResults = (
  artists: <ArtistUI>[],
  albums: <AlbumUI>[],
  tracks: <TrackUI>[],
);

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

  /// Live list of downloaded tracks that changed on the server since they
  /// were downloaded and haven't been dismissed. The stale rule is applied in
  /// SQL ([staleDownloadPredicate]), not by mapping every downloaded row.
  Stream<List<TrackUI>> watchStaleDownloads() {
    return _db.watchStaleDownloads().map(
      (rows) => rows.map(TrackUI.fromQueryRow).toList(growable: false),
    );
  }

  // ── Track loading for queue operations ──────────────────────────────────

  /// The current state of a single track, or null if it no longer exists.
  /// Used to re-check a track's revision/codec right before an action that
  /// needs fresh state (e.g. after a `/changes` sync, before enqueuing a
  /// conversion) rather than trusting a possibly-stale in-memory `TrackUI`.
  Future<TrackUI?> getTrack(String uuidId) async {
    final rows = await _db.getTrackByUuid(uuidId);
    if (rows.isEmpty) return null;
    return TrackUI.fromQueryRow(rows.first);
  }

  /// Live form of [getTrack] (null while the track isn't in the local DB).
  Stream<TrackUI?> watchTrack(String uuidId) {
    return _db.watchTrackByUuid(uuidId).map(
      (rows) => rows.isEmpty ? null : TrackUI.fromQueryRow(rows.first),
    );
  }

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

  /// [tracks] with their local download state re-read from the DB, for lists
  /// that are snapshots rather than live queries (search results). Order and
  /// length are preserved; a row whose track has vanished is left as is.
  Future<List<TrackUI>> withFreshDownloadState(List<TrackUI> tracks) async {
    if (tracks.isEmpty) return tracks;
    final states = await _db.getTrackDownloadStates(
      tracks.map((t) => t.uuidId).toList(),
    );
    return tracks.map((t) {
      final s = states[t.uuidId];
      if (s == null) return t;
      return t.copyWith(
        filePath: s.filePath,
        downloadedBitrateKbps: s.downloadedBitrateKbps,
        fileSizeBytes: s.fileSizeBytes,
        downloadedQuality: s.downloadedQuality,
        // Staleness compares these against `revision`, so patch all four
        // together or a re-download/dismiss would read inconsistently.
        revision: s.revision,
        downloadedAtRevision: s.downloadedAtRevision,
        downloadedCodec: s.downloadedCodec,
        staleDismissedAtRevision: s.staleDismissedAtRevision,
      );
    }).toList(growable: false);
  }

  // ── Search ──────────────────────────────────────────────────────────────

  /// The one FTS search used by every search surface: the global Search page
  /// asks for all [types], an in-page browse search for just its own, and
  /// Phase 4's Home reuses the same call. [downloadedOnly] is applied inside
  /// the FTS query (before the per-type LIMIT), so a low-ranked downloaded
  /// match is never cut off. Keep [limitPerType] well under 999: hydration
  /// binds one SQL variable per hit.
  Future<LibrarySearchResults> search(
    String query, {
    Set<SearchType> types = const {
      SearchType.artists,
      SearchType.albums,
      SearchType.tracks,
    },
    int limitPerType = 5,
    bool downloadedOnly = false,
  }) async {
    if (types.isEmpty) return emptySearchResults;
    final results = await _db.getSearchResults(
      query,
      searchArtists: types.contains(SearchType.artists),
      searchAlbums: types.contains(SearchType.albums),
      searchTracks: types.contains(SearchType.tracks),
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
