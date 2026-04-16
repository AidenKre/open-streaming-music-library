import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:frontend/ui/widgets/download_quality_sheet.dart';

class AlbumCard extends ConsumerWidget {
  final AlbumUI album;
  final VoidCallback onTap;
  final VoidCallback? onPlayNext;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onDownload;
  final void Function(String quality)? onDownloadAtQuality;
  final VoidCallback? onDeleteDownload;

  const AlbumCard({
    super.key,
    required this.album,
    required this.onTap,
    this.onPlayNext,
    this.onAddToQueue,
    this.onDownload,
    this.onDownloadAtQuality,
    this.onDeleteDownload,
  });

  void _showAlbumMenu(BuildContext context, bool isDownloaded) {
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
              SplitDownloadTile(
                onDownload: () {
                  Navigator.pop(ctx);
                  onDownload!();
                },
                onDownloadAtQuality: onDownloadAtQuality != null
                    ? (quality) {
                        Navigator.pop(ctx);
                        onDownloadAtQuality!(quality);
                      }
                    : (_) {},
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
    final isSingle = album.isSingleGrouping;
    final isDownloaded =
        ref.watch(albumDownloadedProvider(album.id)).maybeWhen(
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
            ? () => _showAlbumMenu(context, isDownloaded)
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isSingle ? 'Singles' : (album.name ?? 'Unknown Album'),
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      album.artist ?? 'Unknown Artist',
                      if (album.year != null) album.year.toString(),
                    ].join(' \u2022 '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
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
