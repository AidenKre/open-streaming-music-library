import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/ui/widgets/library_action_menu.dart';

/// Generic library item card used by [AlbumCard] and [ArtistCard].
///
/// Renders a square cover with an optional download badge overlay, a title and
/// optional subtitle. Long-press opens [menu] (built by the one SC-06 menu
/// builder, `buildLibraryActionMenu`), so the card holds no action logic of
/// its own.
class LibraryCard extends StatelessWidget {
  final Widget cover;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  /// The card's action menu; empty means no long-press menu.
  final List<LibraryMenuEntry> menu;
  final bool isDownloading;
  /// Only for the "x/y" progress text while downloading.
  final AsyncValue<({int downloaded, int total})?> downloadCounts;

  /// The card's scope availability (SC-06): decides the downloaded badge.
  final PlaybackAvailability availability;

  const LibraryCard({
    required this.availability,
    super.key,
    required this.cover,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.menu = const [],
    required this.isDownloading,
    required this.downloadCounts,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final counts = downloadCounts.value;
    final isFullyDownloaded = availability.isFullyDownloaded;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: menu.isEmpty
            ? null
            : () => showLibraryActionMenu(context, menu),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                children: [
                  Positioned.fill(child: cover),
                  if (isFullyDownloaded)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: DownloadedBadge(colorScheme: colorScheme),
                    )
                  else if (isDownloading && counts != null)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: DownloadProgressBadge(
                        downloaded: counts.downloaded,
                        total: counts.total,
                        colorScheme: colorScheme,
                      ),
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
                    title,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DownloadedBadge extends StatelessWidget {
  final ColorScheme colorScheme;
  const DownloadedBadge({super.key, required this.colorScheme});

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

class DownloadProgressBadge extends StatelessWidget {
  final int downloaded;
  final int total;
  final ColorScheme colorScheme;
  const DownloadProgressBadge({
    super.key,
    required this.downloaded,
    required this.total,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$downloaded/$total',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: colorScheme.onPrimary,
        ),
      ),
    );
  }
}
