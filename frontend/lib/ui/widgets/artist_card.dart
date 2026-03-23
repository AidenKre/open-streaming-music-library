import 'package:flutter/material.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';

class ArtistCard extends StatelessWidget {
  final ArtistUI artist;
  final VoidCallback onTap;
  final VoidCallback? onPlayNext;
  final VoidCallback? onAddToQueue;

  const ArtistCard({
    super.key,
    required this.artist,
    required this.onTap,
    this.onPlayNext,
    this.onAddToQueue,
  });

  void _showArtistMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onPlayNext != null)
              ListTile(
                leading: const Icon(Icons.playlist_play),
                title: const Text('Play Next'),
                onTap: () {
                  Navigator.pop(ctx);
                  onPlayNext!();
                },
              ),
            if (onAddToQueue != null)
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: const Text('Add to Queue'),
                onTap: () {
                  Navigator.pop(ctx);
                  onAddToQueue!();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: (onPlayNext != null || onAddToQueue != null)
            ? () => _showArtistMenu(context)
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: CoverArtImage(
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
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                artist.name,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
