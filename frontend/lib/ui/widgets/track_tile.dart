import 'package:flutter/material.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:frontend/ui/widgets/download_quality_sheet.dart';

class TrackTile extends StatelessWidget {
  final TrackUI track;
  final VoidCallback? onTap;
  final VoidCallback? onPlayNext;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onDownload;
  final void Function(String quality)? onDownloadAtQuality;
  final VoidCallback? onDeleteDownload;
  final bool isHighlighted;
  final bool isDimmed;
  /// When `false`, the row swallows taps and the more-vert button is rendered
  /// in a disabled state. Used by offline mode on the tracks page so the row
  /// stays visible (visual consistency with album views) but inert.
  final bool isInteractive;
  final Widget? trailing;

  const TrackTile({
    super.key,
    required this.track,
    this.onTap,
    this.onPlayNext,
    this.onAddToQueue,
    this.onDownload,
    this.onDownloadAtQuality,
    this.onDeleteDownload,
    this.isHighlighted = false,
    this.isDimmed = false,
    this.isInteractive = true,
    this.trailing,
  });

  void _showTrackMenu(BuildContext context) {
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
            if (track.isDownloaded && onDeleteDownload != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete download'),
                onTap: () {
                  Navigator.pop(ctx);
                  onDeleteDownload!();
                },
              )
            else if (!track.isDownloaded && onDownload != null)
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
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final opacity = isDimmed ? 0.5 : 1.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: isInteractive ? onTap : null,
          child: Container(
            color: isHighlighted
                ? colors.primaryContainer.withValues(alpha: 0.3)
                : null,
            height: 64,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Opacity(
                    opacity: opacity,
                    child: isHighlighted
                        ? Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: colors.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Icon(Icons.equalizer, color: colors.primary),
                          )
                        : CoverArtImage(
                            hasAlbumArt: track.hasAlbumArt,
                            coverArtId: track.coverArtId,
                            width: 48,
                            height: 48,
                            borderRadius: BorderRadius.circular(4),
                            fallback: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: colors.primaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Icon(Icons.music_note,
                                  color: colors.onPrimaryContainer),
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Opacity(
                      opacity: opacity,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title ?? 'Unknown Title',
                            style: textTheme.bodyLarge?.copyWith(
                              color: isHighlighted ? colors.primary : null,
                              fontWeight:
                                  isHighlighted ? FontWeight.bold : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            track.subtitle,
                            style: textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (trailing != null) trailing!,
                  if (trailing == null && track.isDownloaded) ...[
                    const SizedBox(width: 8),
                    Opacity(
                      opacity: opacity,
                      child: Icon(
                        Icons.download_done,
                        size: 16,
                        color: colors.primary,
                      ),
                    ),
                  ],
                  if (trailing == null &&
                      (onPlayNext != null || onAddToQueue != null)) ...[
                    const SizedBox(width: 8),
                    Opacity(
                      opacity: opacity,
                      child: Text(
                        track.formattedDuration,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(Icons.more_vert,
                            size: 20, color: colors.onSurfaceVariant),
                        // Null onPressed renders the button in Flutter's
                        // built-in disabled style (grayed but visible).
                        onPressed: isInteractive
                            ? () => _showTrackMenu(context)
                            : null,
                      ),
                    ),
                  ],
                  if (trailing == null &&
                      onPlayNext == null &&
                      onAddToQueue == null) ...[
                    const SizedBox(width: 8),
                    Opacity(
                      opacity: opacity,
                      child: Text(
                        track.formattedDuration,
                        style: textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        const Divider(height: 1, thickness: 0.5, indent: 76),
      ],
    );
  }
}
