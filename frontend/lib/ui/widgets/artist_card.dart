import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';

class ArtistCard extends ConsumerWidget {
  final ArtistUI artist;
  final VoidCallback onTap;
  final VoidCallback? onPlayNext;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onDownload;
  final VoidCallback? onDeleteDownload;

  const ArtistCard({
    super.key,
    required this.artist,
    required this.onTap,
    this.onPlayNext,
    this.onAddToQueue,
    this.onDownload,
    this.onDeleteDownload,
  });

  void _showArtistMenu(BuildContext context, bool isDownloaded) {
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
            if (isDownloaded && onDeleteDownload != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete downloads'),
                onTap: () {
                  Navigator.pop(ctx);
                  onDeleteDownload!();
                },
              )
            else if (!isDownloaded && onDownload != null)
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Download'),
                onTap: () {
                  Navigator.pop(ctx);
                  onDownload!();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDownloaded =
        ref.watch(artistDownloadedProvider(artist.id)).maybeWhen(
              data: (v) => v,
              orElse: () => false,
            );

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: (onPlayNext != null ||
                onAddToQueue != null ||
                onDownload != null ||
                onDeleteDownload != null)
            ? () => _showArtistMenu(context, isDownloaded)
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                children: [
                  Positioned.fill(
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
                  if (isDownloaded)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: _DownloadedBadge(colorScheme: colorScheme),
                    ),
                ],
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

class _DownloadedBadge extends StatelessWidget {
  final ColorScheme colorScheme;
  const _DownloadedBadge({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colorScheme.primary,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.download_done,
        size: 14,
        color: colorScheme.onPrimary,
      ),
    );
  }
}
