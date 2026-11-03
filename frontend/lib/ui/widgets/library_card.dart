import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/ui/widgets/library_action_menu.dart';

/// Generic library item card used by [AlbumCard], [ArtistCard] and
/// [TrackCard].
///
/// Renders a square cover with an optional download badge overlay, a title
/// and optional subtitle. Its actions are [menu] (built by the one SC-06
/// menu builder, `buildLibraryActionMenu`): long-press opens it, and on
/// desktop a visible overflow button does too (long-press can't be the only
/// way to discover actions). The card holds no action logic of its own; the
/// surface supplies the primary [onTap] (null: no primary action).
class LibraryCard extends StatelessWidget {
  final Widget cover;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  /// The card's action menu; empty means no menu.
  final List<LibraryMenuEntry> menu;
  final bool isDownloading;

  /// Only for the "x/y" progress text while downloading.
  final AsyncValue<({int downloaded, int total})?> downloadCounts;

  /// The card's scope availability (SC-06): decides the downloaded badge.
  final PlaybackAvailability availability;

  /// Rendered dimmed (e.g. offline and not playable). Navigation and the
  /// menu's inspection entries stay usable.
  final bool dimmed;

  /// Screen-reader label: entity type, name and context.
  final String? semanticLabel;

  const LibraryCard({
    super.key,
    required this.cover,
    required this.title,
    this.subtitle,
    this.onTap,
    this.menu = const [],
    required this.isDownloading,
    required this.downloadCounts,
    required this.availability,
    this.dimmed = false,
    this.semanticLabel,
  });

  static bool get _isDesktop => switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final counts = downloadCounts.value;
    final isFullyDownloaded = availability.isFullyDownloaded;
    final showOverflow = _isDesktop && menu.isNotEmpty;

    final card = Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: menu.isEmpty
            ? null
            : () => showLibraryActionMenu(context, menu),
        child: Opacity(
          opacity: dimmed ? 0.5 : 1.0,
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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
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
                    if (showOverflow)
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          tooltip: 'More actions',
                          icon: const Icon(Icons.more_vert, size: 18),
                          onPressed: () => showLibraryActionMenu(context, menu),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (semanticLabel == null) return card;
    return Semantics(
      label: semanticLabel,
      button: onTap != null,
      container: true,
      child: card,
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
