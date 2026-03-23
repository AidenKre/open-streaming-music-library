import 'package:flutter/material.dart';

class ArtistCard extends StatelessWidget {
  final String artistName;
  final VoidCallback onTap;
  final VoidCallback? onPlayNext;
  final VoidCallback? onAddToQueue;

  const ArtistCard({
    super.key,
    required this.artistName,
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
            // TODO: Fetch artist art from API
            Expanded(
              child: Container(
                color: colorScheme.secondaryContainer,
                child: Icon(
                  Icons.person,
                  size: 48,
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                artistName,
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
