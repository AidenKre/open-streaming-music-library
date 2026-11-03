import 'package:frontend/database/database.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/repositories/collection_ordering.dart';
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

  /// Grid membership rule. [downloadedOnly] is an explicit Downloaded filter
  /// (a chip, which owns its own offline provenance). [offline] is the
  /// observed connectivity of a grid WITHOUT a chip (an artist's albums):
  /// offline such a grid shows only entries with something downloaded. Views
  /// pass observed state; this decides membership (SC-06/SC-26).
  ///
  /// A page WITH a chip must pass `offline: false`: the chip already applies
  /// offline auto-selection and must stay user-overridable (Phase 3 D12);
  /// passing connectivity too would lock it on while offline.
  static bool _gridDownloadedOnly(bool downloadedOnly, bool offline) =>
      downloadedOnly || offline;

  // ── Albums ──────────────────────────────────────────────────────────────

  Stream<List<AlbumUI>> watchAlbums({
    int? artistId,
    int? limit,
    bool downloadedOnly = false,
    bool offline = false,
  }) {
    return _db
        .watchAlbums(
          artistId: artistId,
          orderBy: CollectionOrdering.albumsFor(artistId),
          limit: limit,
          downloadedOnly: _gridDownloadedOnly(downloadedOnly, offline),
        )
        .map((rows) => rows.map(AlbumUI.fromQueryRow).toList(growable: false));
  }

  // ── Artists ─────────────────────────────────────────────────────────────

  Stream<List<ArtistUI>> watchArtists({
    int? limit,
    bool downloadedOnly = false,
    bool offline = false,
  }) {
    return _db
        .watchArtists(
          orderBy: CollectionOrdering.artists,
          limit: limit,
          downloadedOnly: _gridDownloadedOnly(downloadedOnly, offline),
        )
        .map((rows) => rows.map(ArtistUI.fromQueryRow).toList(growable: false));
  }

  // ── Tracks ──────────────────────────────────────────────────────────────

  Stream<List<TrackUI>> watchTracks({
    AlbumScope? album,
    int? limit,
    bool downloadedOnly = false,
  }) {
    return _db
        .watchTracks(
          orderBy: CollectionOrdering.tracksFor(album),
          artistId: album?.artistId,
          albumId: album?.albumId,
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

  /// The one membership query for library actions (SC-06): which tracks a
  /// Play next / Add to queue / Download / Delete on [scope] acts on, in the
  /// same [CollectionOrdering] the scope's page shows.
  ///
  /// [offline] is the caller's observed connectivity; the model maps it to
  /// membership. Phase 4 keeps today's rule (offline does not narrow the
  /// membership; queue actions on a collection are only enabled offline when
  /// it is fully downloaded, see `PlaybackAvailability`). Phase 6 narrows an
  /// offline collection to its downloaded members here.
  Future<List<TrackUI>> getTracksForScope(
    LibraryScope scope, {
    required bool offline,
  }) async {
    switch (scope) {
      case AlbumScope(:final artistId, :final albumId):
        return _tracksForAlbum(artistId, albumId);
      case ArtistScope(:final artistId):
        return _tracksForArtist(artistId);
      case TrackScope(:final track):
        return [track];
      case TracksScope(:final tracks):
        return tracks;
    }
  }

  /// An album's tracks in [CollectionOrdering.albumTracks].
  Future<List<TrackUI>> _tracksForAlbum(int artistId, int albumId) async {
    final rows = await _db.getTracks(
      orderBy: CollectionOrdering.albumTracks,
      artistId: artistId,
      albumId: albumId,
    );
    return rows.map(TrackUI.fromQueryRow).toList(growable: false);
  }

  /// An artist's tracks: the albums in the artist grid's order
  /// ([CollectionOrdering.artistAlbums]), each album's tracks in
  /// [CollectionOrdering.albumTracks]. Both orders are SQL; this only groups
  /// the ordered track rows by album, so neither is re-implemented in Dart.
  Future<List<TrackUI>> _tracksForArtist(int artistId) {
    return _db.transaction(() async {
      final albumRows = await _db.getAlbums(
        artistId: artistId,
        orderBy: CollectionOrdering.artistAlbums,
      );
      final trackRows = await _db.getTracks(
        orderBy: CollectionOrdering.albumTracks,
        artistId: artistId,
      );
      final byAlbum = <int?, List<TrackUI>>{};
      for (final row in trackRows) {
        final track = TrackUI.fromQueryRow(row);
        (byAlbum[track.albumId] ??= []).add(track);
      }
      return [
        for (final album in albumRows)
          ...?byAlbum.remove(album.read<int>('id')),
        // A track whose album is not among the artist's own albums (should
        // not happen with server-assigned ids) still plays, after them.
        for (final rest in byAlbum.values) ...rest,
      ];
    });
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
    // SQLite reads a negative LIMIT as "no limit".
    assert(
      limitPerType > 0 && limitPerType < 999,
      'limitPerType must be in 1..998, got $limitPerType',
    );
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
