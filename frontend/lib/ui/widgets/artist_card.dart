import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:frontend/ui/widgets/library_action_menu.dart';
import 'package:frontend/ui/widgets/library_card.dart';

class ArtistCard extends ConsumerWidget {
  final ArtistUI artist;
  final VoidCallback onTap;

  const ArtistCard({
    super.key,
    required this.artist,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final scope = ArtistScope(artistId: artist.id);
    final availability = ref.watch(playbackAvailabilityProvider(scope));
    final isDownloading = ref.watch(artistIsDownloadingProvider(artist.id));
    final downloadCounts = ref.watch(artistDownloadCountsProvider(artist.id));

    return LibraryCard(
      cover: CoverArtImage(
        hasAlbumArt: artist.coverArtId != null,
        coverArtId: artist.coverArtId,
        borderRadius: BorderRadius.zero,
        fallback: Container(
          color: colorScheme.secondaryContainer,
          child: Icon(
            Icons.person,
            size: 48,
            color: colorScheme.onSecondaryContainer,
          ),
        ),
      ),
      title: artist.name,
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
