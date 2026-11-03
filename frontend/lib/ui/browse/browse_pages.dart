import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/artist_page.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/top_bar_actions.dart';

/// Browse-all routes (Home's entry points, phase-4 §4): each owns a single
/// back AppBar with the top-bar actions and reuses its page body in
/// browse-all mode (Downloaded chip + in-page search). Chrome ownership is
/// here; the bodies own no Scaffold.
class _BrowseRoute extends ConsumerWidget {
  const _BrowseRoute({required this.title, required this.body});

  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: buildTopBarActions(context, ref),
      ),
      body: body,
    );
  }
}

/// Every artist, with the chip and artist-only search.
class ArtistsBrowsePage extends StatelessWidget {
  const ArtistsBrowsePage({super.key});

  @override
  Widget build(BuildContext context) =>
      const _BrowseRoute(title: 'Artists', body: ArtistsPage(browseAll: true));
}

/// Every album (all artists), with the chip and album-only search.
class AlbumsBrowsePage extends StatelessWidget {
  const AlbumsBrowsePage({super.key});

  @override
  Widget build(BuildContext context) =>
      const _BrowseRoute(title: 'Albums', body: AlbumsPage(browseAll: true));
}

/// The whole library's tracks, with the chip and track-only search. Its
/// creation refreshes the library (the old Tracks-tab sync, phase-4 §4).
class TracksBrowsePage extends StatelessWidget {
  const TracksBrowsePage({super.key});

  @override
  Widget build(BuildContext context) =>
      const _BrowseRoute(title: 'Tracks', body: TracksPage(browseAll: true));
}
