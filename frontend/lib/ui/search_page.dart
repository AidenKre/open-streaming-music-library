import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/utils/library_search_controller.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
import 'package:frontend/ui/widgets/downloaded_only_badge.dart';
import 'package:frontend/ui/widgets/library_search_field.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  // Shared with the in-page search on the browse tabs: debounce, generation
  // stale-guard (a request that started before an offline flip or a newer
  // query never overwrites newer results), and dispose-cancel all live there.
  late final LibrarySearchController _search;

  @override
  void initState() {
    super.initState();
    _search = LibrarySearchController(
      repository: ref.read(browseRepositoryProvider),
      types: SearchType.values.toSet(),
      limitPerType: 5,
      // Offline: the repository filters to locally-downloaded content inside
      // the FTS query (before LIMIT), so a downloaded match ranked below the
      // top 5 is still returned.
      downloadedOnly: () => ref.read(offlineModeProvider),
    )..addListener(_onSearchChanged);
  }

  void _onSearchChanged() => setState(() {});

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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
    ref.listen(downloadStatusVersionProvider, (_, _) {
      // Online: patch the existing rows with refreshed download fields.
      // Offline: the visible result set is filtered by downloaded state, so
      // a delete that removes the last downloaded match must re-run the FTS
      // query — patching alone would leave the dead row on screen.
      _search.onDownloadStatusChanged();
    });
    ref.listen<bool>(offlineModeProvider, (prev, next) {
      if (prev != next) _search.rerun();
    });
    final manager = ref.watch(downloadManagerListenableProvider);
    final isOffline = ref.watch(offlineModeProvider);

    final query = _search.query;
    final artists = _search.results.artists;
    final albums = _search.results.albums;
    final tracks = _search.results.tracks;

    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: ListView(
        children: [
          if (isOffline) const DownloadedOnlyBadge(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: LibrarySearchField(
              hintText: 'Search your library',
              autofocus: true,
              onChanged: _search.onQueryChanged,
              onCleared: _search.clear,
            ),
          ),
          if (_search.isActive && !_search.hasResults && !_search.isSearching)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  isOffline
                      ? 'No downloaded results match "$query". '
                          'Reconnect to the server to search the full library.'
                      : 'No results found',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          if (artists.isNotEmpty) ...[
            _buildSectionHeader('Artists'),
            SizedBox(
              height: 190,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: artists.length,
                itemBuilder: (context, index) {
                  final artist = artists[index];
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
          if (albums.isNotEmpty) ...[
            _buildSectionHeader('Albums'),
            SizedBox(
              height: 220,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: albums.length,
                itemBuilder: (context, index) {
                  final album = albums[index];
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
          if (tracks.isNotEmpty) ...[
            _buildSectionHeader('Songs'),
            for (final track in tracks)
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
                          tracks.map((t) => t.uuidId).toList(),
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
