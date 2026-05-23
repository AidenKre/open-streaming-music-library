import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/ui/widgets/download_quality_sheet.dart';

/// Generic library item card used by [AlbumCard] and [ArtistCard].
///
/// Renders a square cover with an optional download badge overlay, a title and
/// optional subtitle, and a long-press popup menu with Play Next / Add to
/// Queue / Download / Delete download options. Per-context labels and data
/// lookups are supplied by the wrapper widgets.
class LibraryCard extends ConsumerWidget {
  final Widget cover;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onPlayNext;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onDownload;
  final void Function(String quality)? onDownloadAtQuality;
  final VoidCallback? onDeleteDownload;
  final bool isDownloading;
  final AsyncValue<({int downloaded, int total})> downloadCounts;
  // Labels differ between album / artist contexts:
  final String playNextLabel;
  final String addToQueueLabel;
  final String downloadLabel;
  final String deleteDownloadLabel;

  const LibraryCard({
    super.key,
    required this.cover,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.onPlayNext,
    this.onAddToQueue,
    this.onDownload,
    this.onDownloadAtQuality,
    this.onDeleteDownload,
    required this.isDownloading,
    required this.downloadCounts,
    this.playNextLabel = 'Play Next',
    this.addToQueueLabel = 'Add to Queue',
    this.downloadLabel = 'Download',
    this.deleteDownloadLabel = 'Delete downloads',
  });

  void _showMenu(
    BuildContext context, {
    required bool hasAnyDownloaded,
    required bool isFullyDownloaded,
    required bool queueEnabled,
  }) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onPlayNext != null)
              ListTile(
                leading: const Icon(Icons.playlist_play),
                title: Text(playNextLabel),
                enabled: queueEnabled,
                onTap: queueEnabled
                    ? () {
                        Navigator.pop(ctx);
                        onPlayNext!();
                      }
                    : null,
              ),
            if (onAddToQueue != null)
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(addToQueueLabel),
                enabled: queueEnabled,
                onTap: queueEnabled
                    ? () {
                        Navigator.pop(ctx);
                        onAddToQueue!();
                      }
                    : null,
              ),
            // Download (for the missing tracks) and Delete are independent:
            // a partially-downloaded item shows both.
            if (!isFullyDownloaded && onDownload != null)
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
                    : null,
              ),
            if (hasAnyDownloaded && onDeleteDownload != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(deleteDownloadLabel),
                onTap: () {
                  Navigator.pop(ctx);
                  onDeleteDownload!();
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
    final counts = downloadCounts.value;
    final isOffline = ref.watch(offlineModeProvider);

    final hasAnyDownloaded = (counts?.downloaded ?? 0) > 0;
    final isFullyDownloaded = counts != null &&
        counts.total > 0 &&
        counts.downloaded == counts.total;
    // Offline, a queue action must not enqueue streaming-only tracks, so it's
    // allowed only when the whole item is downloaded.
    final queueEnabled = !isOffline || isFullyDownloaded;

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
            ? () => _showMenu(
                  context,
                  hasAnyDownloaded: hasAnyDownloaded,
                  isFullyDownloaded: isFullyDownloaded,
                  queueEnabled: queueEnabled,
                )
            : null,
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
