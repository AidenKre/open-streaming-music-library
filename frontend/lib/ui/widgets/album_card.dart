import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:frontend/ui/widgets/library_action_menu.dart';
import 'package:frontend/ui/widgets/library_card.dart';

class AlbumCard extends ConsumerWidget {
  final AlbumUI album;
  final VoidCallback onTap;

  const AlbumCard({
    super.key,
    required this.album,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final scope = AlbumScope(artistId: album.artistId, albumId: album.id);
    final isSingle = album.isSingleGrouping;
    final availability = ref.watch(playbackAvailabilityProvider(scope));
    final isDownloading = ref.watch(albumIsDownloadingProvider(album.id));
    final downloadCounts = ref.watch(albumDownloadCountsProvider(album.id));

    final subtitle = [
      album.artist ?? 'Unknown Artist',
      if (album.year != null) album.year.toString(),
    ].join(' • ');

    return LibraryCard(
      cover: CoverArtImage(
        hasAlbumArt: album.coverArtId != null,
        coverArtId: album.coverArtId,
        borderRadius: BorderRadius.zero,
        fallback: Container(
          color: isSingle
              ? colorScheme.tertiaryContainer
              : colorScheme.primaryContainer,
          child: Icon(
            isSingle ? Icons.library_music_outlined : Icons.album,
            size: 48,
            color: isSingle
                ? colorScheme.onTertiaryContainer
                : colorScheme.onPrimaryContainer,
          ),
        ),
      ),
      title: isSingle ? 'Singles' : (album.name ?? 'Unknown Album'),
      subtitle: subtitle,
      onTap: onTap,
      availability: availability,
      menu: buildLibraryActionMenu(
        scope,
        availability,
        actions: ref.watch(libraryActionsProvider),
      ),
      isDownloading: isDownloading,
      downloadCounts: downloadCounts,
    );
  }
}
