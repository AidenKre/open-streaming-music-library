import 'package:flutter/material.dart';
import 'package:frontend/models/ui/album_ui.dart';

class AlbumCard extends StatelessWidget {
  final AlbumUI album;
  final VoidCallback onTap;

  const AlbumCard({super.key, required this.album, required this.onTap});

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