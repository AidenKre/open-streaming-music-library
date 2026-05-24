import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
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
  bool _isSearching = false;
  List<ArtistUI> _artists = [];
  List<AlbumUI> _albums = [];
  List<TrackUI> _tracks = [];

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _patchDownloadStates() async {
    if (!mounted) return;
    final uuids = _tracks.map((t) => t.uuidId).toList();
    if (uuids.isEmpty) return;
    final db = ref.read(databaseProvider);
    final states = await db.getTrackDownloadStates(uuids);
    if (!mounted) return;
    setState(() {
      _tracks = _tracks.map((t) {
        final s = states[t.uuidId];
        if (s == null) return t;
        return t.copyWith(
          filePath: s.filePath,
          downloadedBitrateKbps: s.downloadedBitrateKbps,
          fileSizeBytes: s.fileSizeBytes,
        );
      }).toList();
    });
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
        _isSearching = false;
        _artists = [];
        _albums = [];
        _tracks = [];
      });
      return;
    }

    setState(() => _isSearching = true);

    // Offline: the repository filters to locally-downloaded content inside the
    // FTS query (before LIMIT), so a downloaded match ranked below the top 5
    // is still returned.
    final results = await ref.read(browseRepositoryProvider).search(
          _query,
          limitPerType: 5,
          downloadedOnly: ref.read(offlineModeProvider),
        );

    if (!mounted) return;
    setState(() {
      _isSearching = false;
      _artists = results.artists;
      _albums = results.albums;
      _tracks = results.tracks;
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
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(downloadStatusVersionProvider, (_, _) => _patchDownloadStates());
    ref.listen<bool>(offlineModeProvider, (prev, next) {
      if (prev != next) _search();
    });
    final manager = ref.watch(downloadManagerListenableProvider);
    final isOffline = ref.watch(offlineModeProvider);

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
          if (_query.isNotEmpty && !hasResults && !_isSearching)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('No results found')),
            ),
          if (_artists.isNotEmpty) ...[
            _buildSectionHeader('Artists'),
            SizedBox(
              height: 190,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: _artists.length,
                itemBuilder: (context, index) {
                  final artist = _artists[index];
                  return SizedBox(
                    width: 140,
                    child: ArtistCard(
                      artist: artist,
                      onTap: () => _onArtistTap(artist),
                      onPlayNext: () async {
                        final tracks = await ref.read(browseRepositoryProvider)
                            .getTracksForArtist(artist.id);
                        if (tracks.isNotEmpty) {
                          ref.read(audioProvider.notifier).playNext(tracks);
                        }
                      },
                      onAddToQueue: () async {
                        final tracks = await ref.read(browseRepositoryProvider)
                            .getTracksForArtist(artist.id);
                        if (tracks.isNotEmpty) {
                          ref.read(audioProvider.notifier).addToQueue(tracks);
                        }
                      },
                      onDownload: isOffline
                          ? null
                          : () => downloadScope(
                              ref, ArtistScope(artistId: artist.id)),
                      onDownloadAtQuality: isOffline
                          ? null
                          : (q) => downloadScope(
                              ref, ArtistScope(artistId: artist.id),
                              quality: q),
                      onDeleteDownload: () => deleteScope(
                          ref, ArtistScope(artistId: artist.id)),
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
                      onPlayNext: () async {
                        final tracks = await ref.read(browseRepositoryProvider)
                            .getTracksForAlbum(album.artistId, album.id);
                        if (tracks.isNotEmpty) {
                          ref.read(audioProvider.notifier).playNext(tracks);
                        }
                      },
                      onAddToQueue: () async {
                        final tracks = await ref.read(browseRepositoryProvider)
                            .getTracksForAlbum(album.artistId, album.id);
                        if (tracks.isNotEmpty) {
                          ref.read(audioProvider.notifier).addToQueue(tracks);
                        }
                      },
                      onDownload: isOffline
                          ? null
                          : () => downloadScope(
                              ref,
                              AlbumScope(
                                  artistId: album.artistId, albumId: album.id),
                            ),
                      onDownloadAtQuality: isOffline
                          ? null
                          : (q) => downloadScope(
                              ref,
                              AlbumScope(
                                  artistId: album.artistId, albumId: album.id),
                              quality: q,
                            ),
                      onDeleteDownload: () => deleteScope(
                        ref,
                        AlbumScope(
                            artistId: album.artistId, albumId: album.id),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          if (_tracks.isNotEmpty) ...[
            _buildSectionHeader('Songs'),
            for (final track in _tracks)
              Builder(
                key: ValueKey(track.uuidId),
                builder: (_) {
                  final job = manager.state.jobs
                      .where((j) => j.uuidId == track.uuidId)
                      .firstOrNull;
                  Widget? trailing;
                  if (job != null) {
                    trailing = switch (job.status) {
                      Active(:final progress) => SizedBox(
                          width: 80,
                          child: LinearProgressIndicator(
                            value: progress > 0 ? progress : null,
                          ),
                        ),
                      Queued() => const Icon(Icons.schedule, size: 16),
                      Completed() || Failed() => null,
                    };
                  }
                  return TrackTile(
                    track: track,
                    trailing: trailing,
                    onTap: () => ref
                        .read(audioProvider.notifier)
                        .playFromTrackList(
                          _tracks.map((t) => t.uuidId).toList(),
                          track,
                          sourceType: 'search',
                        ),
                    onPlayNext: () =>
                        ref.read(audioProvider.notifier).playNext([track]),
                    onAddToQueue: () =>
                        ref.read(audioProvider.notifier).addToQueue([track]),
                    onDownload: () => downloadScope(ref, TrackScope(track)),
                    onDownloadAtQuality: (q) =>
                        downloadScope(ref, TrackScope(track), quality: q),
                    onDeleteDownload: () =>
                        deleteScope(ref, TrackScope(track)),
                  );
                },
              ),
          ],
        ],
      ),
    );
  }
}
