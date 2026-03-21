import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  Timer? _debounceTimer;
  String _query = '';
  List<ArtistUI> _artists = [];
  List<AlbumUI> _albums = [];
  List<TrackUI> _tracks = [];

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
      _search();
    });
  }

  Future<void> _search() async {
    if (_query.isEmpty) {
      setState(() {
        _artists = [];
        _albums = [];
        _tracks = [];
      });
      return;
    }

    final db = ref.read(databaseProvider);
    final results = await db.getSearchResults(_query, limitPerType: 5);

    if (!mounted) return;
    setState(() {
      _artists = results.artists.map(ArtistUI.fromQueryRow).toList();
      _albums = results.albums.map(AlbumUI.fromQueryRow).toList();
      _tracks = results.tracks.map(TrackUI.fromQueryRow).toList();
    });
  }

  void _onArtistTap(ArtistUI artist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(artist.name)),
          body: AlbumsPage(artistId: artist.id),
        ),
      ),
    );
  }

  void _onAlbumTap(AlbumUI album) {
    final String appBarTitle;
    if (album.isSingleGrouping) {
      appBarTitle = '${album.artist ?? "Unknown Artist"} - Singles';
    } else {
      appBarTitle = album.name ?? 'Unknown Album';
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(appBarTitle)),
          body: TracksPage(artistId: album.artistId, albumId: album.id),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasResults =
        _artists.isNotEmpty || _albums.isNotEmpty || _tracks.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search your library',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _controller.clear();
                          _onQueryChanged('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          if (_query.isNotEmpty && !hasResults)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text('No results found'),
              ),
            ),
          if (_artists.isNotEmpty) ...[
            _buildSectionHeader('Artists'),
            SizedBox(
              height: 160,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: _artists.length,
                itemBuilder: (context, index) {
                  final artist = _artists[index];
                  return SizedBox(
                    width: 140,
                    child: ArtistCard(
                      artistName: artist.name,
                      onTap: () => _onArtistTap(artist),
                    ),
                  );
                },
              ),
            ),
          ],
          if (_albums.isNotEmpty) ...[
            _buildSectionHeader('Albums'),
            SizedBox(
              height: 220,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: _albums.length,
                itemBuilder: (context, index) {
                  final album = _albums[index];
                  return SizedBox(
                    width: 160,
                    child: AlbumCard(
                      album: album,
                      onTap: () => _onAlbumTap(album),
                    ),
                  );
                },
              ),
            ),
          ],
          if (_tracks.isNotEmpty) ...[
            _buildSectionHeader('Songs'),
            for (final track in _tracks)
              TrackTile(
                track: track,
                onTap: () => ref.read(audioProvider.notifier).playFromQueue(
                  const QueueContext(),
                  track,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
