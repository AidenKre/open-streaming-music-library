import 'package:flutter/material.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/browse/browse_pages.dart';
import 'package:frontend/ui/downloaded_tracks_page.dart';
import 'package:frontend/ui/get_info_page.dart';
import 'package:frontend/ui/tracks_page.dart';

/// Library navigation, defined once (SC-06/SC-08): every surface opens
/// details and Get info through these, never by building its own route.
/// Navigation is a view concern, so these are plain view helpers.

/// An artist's album grid, pushed on the caller's navigator.
void openArtistDetail(BuildContext context, ArtistUI artist) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(artist.name)),
        body: AlbumsPage(artistId: artist.id),
      ),
    ),
  );
}

/// The title of an album's detail page; a Singles grouping is named after
/// its artist.
String albumDetailTitle(AlbumUI album) => album.isSingleGrouping
    ? '${album.artist ?? "Unknown Artist"} - Singles'
    : (album.name ?? 'Unknown Album');

/// An album's track list. Carries both the album id and its artist id (the
/// track query requires the artist with an album).
void openAlbumDetail(BuildContext context, AlbumUI album) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(albumDetailTitle(album))),
        body: TracksPage(artistId: album.artistId, albumId: album.id),
      ),
    ),
  );
}

/// The Get info inspector for [track].
void openTrackInfo(BuildContext context, TrackUI track) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => GetInfoPage(track: track)));
}

/// The library browse-all destinations (Home's entry points).
enum BrowseDestination { artists, albums, tracks, downloaded }

/// Opens a browse-all page on the caller's (tab) navigator; each owns one
/// back AppBar.
void openBrowse(BuildContext context, BrowseDestination destination) {
  final Widget page = switch (destination) {
    BrowseDestination.artists => const ArtistsBrowsePage(),
    BrowseDestination.albums => const AlbumsBrowsePage(),
    BrowseDestination.tracks => const TracksBrowsePage(),
    BrowseDestination.downloaded => const DownloadedTracksPage(),
  };
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}
