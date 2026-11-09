import 'package:flutter/foundation.dart';
import 'package:frontend/models/ui/track_ui.dart';

/// The queue `source_type` of a browse list's session: one album's list, or
/// (null) the whole library.
String browseQueueSource(AlbumScope? album) =>
    album == null ? 'library' : 'album';

/// What a library action acts on (SC-06): one album, one artist, one track,
/// or an explicit list of tracks. The single source of "which tracks" for
/// queue actions, downloads, deletes and playback availability; membership is
/// resolved by `BrowseRepository.getTracksForScope`.
///
/// Scopes are value-equal so they can key auto-dispose provider families
/// without leaking an element per rebuild.
@immutable
sealed class LibraryScope {
  const LibraryScope();
}

@immutable
final class AlbumScope extends LibraryScope {
  final int artistId;
  final int albumId;
  const AlbumScope({required this.artistId, required this.albumId});

  @override
  bool operator ==(Object other) =>
      other is AlbumScope &&
      other.artistId == artistId &&
      other.albumId == albumId;

  @override
  int get hashCode => Object.hash(AlbumScope, artistId, albumId);

  @override
  String toString() => 'AlbumScope(artist: $artistId, album: $albumId)';
}

@immutable
final class ArtistScope extends LibraryScope {
  final int artistId;
  const ArtistScope({required this.artistId});

  @override
  bool operator ==(Object other) =>
      other is ArtistScope && other.artistId == artistId;

  @override
  int get hashCode => Object.hash(ArtistScope, artistId);

  @override
  String toString() => 'ArtistScope(artist: $artistId)';
}

/// One track. Equal by uuid and download state: a download changes what the
/// scope can do offline, so it must be a new key for availability.
@immutable
final class TrackScope extends LibraryScope {
  final TrackUI track;
  const TrackScope(this.track);

  @override
  bool operator ==(Object other) =>
      other is TrackScope &&
      other.track.uuidId == track.uuidId &&
      other.track.isDownloaded == track.isDownloaded &&
      other.track.isDownloadDamaged == track.isDownloadDamaged;

  @override
  int get hashCode => Object.hash(
      TrackScope, track.uuidId, track.isDownloaded, track.isDownloadDamaged);

  @override
  String toString() => 'TrackScope(${track.uuidId})';
}

/// An explicit, ordered list of tracks.
@immutable
final class TracksScope extends LibraryScope {
  final List<TrackUI> tracks;
  const TracksScope(this.tracks);

  @override
  bool operator ==(Object other) {
    if (other is! TracksScope || other.tracks.length != tracks.length) {
      return false;
    }
    for (var i = 0; i < tracks.length; i++) {
      if (other.tracks[i].uuidId != tracks[i].uuidId ||
          other.tracks[i].isDownloaded != tracks[i].isDownloaded) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    TracksScope,
    Object.hashAll([
      for (final t in tracks) Object.hash(t.uuidId, t.isDownloaded),
    ]),
  );

  @override
  String toString() => 'TracksScope(${tracks.length} tracks)';
}
