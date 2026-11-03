import 'package:frontend/database/database.dart';
import 'package:frontend/models/library_scope.dart';

/// The one model-owned order for every library list (SC-06): a detail page's
/// rows, the queue a row tap builds, and the tracks a menu's Play next / Add
/// to queue (`BrowseRepository.getTracksForScope`) acts on all come from here,
/// so what a page shows is what plays. Views never pass order parameters.
abstract final class CollectionOrdering {
  /// An album's tracks: disc, then track number (missing counts as 0), then
  /// case-insensitive title, then uuid. No per-track-artist key, so a
  /// compilation plays in track order.
  static final List<OrderParameter> albumTracks = [
    OrderParameter(column: 'disc_number', nullsAs: 0),
    OrderParameter(column: 'track_number', nullsAs: 0),
    OrderParameter(column: 'title', caseInsensitive: true),
    OrderParameter(column: 'uuid_id'),
  ];

  /// The whole library (Tracks and Downloaded lists): artist, album, disc,
  /// track, uuid. Unchanged from the pre-Phase-4 view order.
  static final List<OrderParameter> libraryTracks = [
    OrderParameter(column: 'artist'),
    OrderParameter(column: 'album'),
    OrderParameter(column: 'disc_number'),
    OrderParameter(column: 'track_number'),
    OrderParameter(column: 'uuid_id'),
  ];

  /// An artist's album grid: year newest first (unknown last), Singles
  /// grouping last, name (case-insensitive), album id.
  static final List<AlbumOrderParameter> artistAlbums = [
    AlbumOrderParameter(column: 'year', isAscending: false, nullsLast: true),
    AlbumOrderParameter(column: 'is_single_grouping'),
    AlbumOrderParameter(column: 'name', nullsLast: true),
    AlbumOrderParameter(column: 'id'),
  ];

  /// Every album: by artist name, then each artist's grid order.
  static final List<AlbumOrderParameter> allAlbums = [
    AlbumOrderParameter(column: 'artist'),
    ...artistAlbums,
  ];

  /// The artist list: by name (case-insensitive).
  static final List<ArtistOrderParameter> artists = [
    ArtistOrderParameter(column: 'name'),
  ];

  /// Album order for an album grid: one artist's, or (null) every album.
  static List<AlbumOrderParameter> albumsFor(int? artistId) =>
      artistId == null ? allAlbums : artistAlbums;

  /// Track order for a track list: one album's, or (null) the library's.
  static List<OrderParameter> tracksFor(AlbumScope? album) =>
      album == null ? libraryTracks : albumTracks;
}
