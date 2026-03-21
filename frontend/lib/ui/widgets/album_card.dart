import 'package:flutter/material.dart';
import 'package:frontend/models/ui/album_ui.dart';

class AlbumCard extends StatelessWidget {
  final AlbumUI album;
  final VoidCallback onTap;
  final VoidCallback? onPlayNext;
  final VoidCallback? onAddToQueue;

  const AlbumCard({
    super.key,
    required this.album,
    required this.onTap,
    this.onPlayNext,
    this.onAddToQueue,
  });

  void _showAlbumMenu(BuildContext context) {
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
    final isSingle = album.isSingleGrouping;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: (onPlayNext != null || onAddToQueue != null)
            ? () => _showAlbumMenu(context)
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // TODO: Fetch album art from API
            AspectRatio(
              aspectRatio: 1,
              child: Container(
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
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
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