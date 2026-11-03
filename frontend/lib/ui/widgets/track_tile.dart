import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:frontend/ui/widgets/library_action_menu.dart';

class TrackTile extends StatelessWidget {
  final TrackUI track;
  final VoidCallback? onTap;
  /// This track's current conversion job, if any (caller-supplied -- the
  /// tile stays a plain StatelessWidget, same as `isHighlighted`/`isDimmed`;
  /// the page watches `conversionJobsProvider` and passes the result down).
  final ConversionJob? conversionJob;
  final bool isHighlighted;
  final bool isDimmed;
  /// When `false`, the row swallows taps and the more-vert button is rendered
  /// in a disabled state. Used by offline mode on the tracks page so the row
  /// stays visible (visual consistency with album views) but inert.
  final bool isInteractive;
  final Widget? trailing;

  /// The row's action menu (from `buildLibraryActionMenu`), behind the
  /// overflow button. Empty: no overflow button (e.g. full-player queue rows).
  final List<LibraryMenuEntry> menu;

  const TrackTile({
    super.key,
    required this.track,
    this.onTap,
    this.menu = const [],
    this.conversionJob,
    this.isHighlighted = false,
    this.isDimmed = false,
    this.isInteractive = true,
    this.trailing,
  });

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
                  if (trailing == null && (conversionJob?.isActive ?? false)) ...[
                    const SizedBox(width: 8),
                    Opacity(
                      opacity: opacity,
                      child: Icon(
                        Icons.sync,
                        size: 16,
                        color: colors.primary,
                      ),
                    ),
                  ],
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
                  if (trailing == null && menu.isNotEmpty) ...[
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
                            ? () => showLibraryActionMenu(context, menu)
                            : null,
                      ),
                    ),
                  ],
                  if (trailing == null && menu.isEmpty) ...[
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


/// The surface-specific conversion rows of a track menu: "Cancel conversion"
/// while [conversionJob] is active (disabled without [onCancelConvert]),
/// otherwise "Convert…" when [onConvert] is available (null hides it:
/// offline, no `convert` capability, or no allowed target -- see
/// `canConvertTrack`; a pending edit does NOT hide it, the flow blocks that).
List<LibraryMenuEntry> conversionMenuEntries({
  ConversionJob? conversionJob,
  VoidCallback? onConvert,
  VoidCallback? onCancelConvert,
}) {
  if (conversionJob?.isActive ?? false) {
    return [
      LibraryMenuAction(
        icon: Icons.close,
        label: 'Cancel conversion',
        onSelected: onCancelConvert,
      ),
    ];
  }
  if (onConvert == null) return const [];
  return [
    LibraryMenuAction(
      icon: Icons.transform,
      label: 'Convert…',
      onSelected: onConvert,
    ),
  ];
}

/// A library track row: [TrackTile] with the one SC-06 menu (Get info via
/// `library_routes.dart`, actions via `LibraryActionControls`) and its
/// dimming/interactivity from `PlaybackAvailability` -- the page supplies
/// only the primary tap and any surface-specific [extraActions].
class LibraryTrackTile extends ConsumerWidget {
  const LibraryTrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.trailing,
    this.conversionJob,
    this.extraActions = const [],
  });

  final TrackUI track;
  final VoidCallback onTap;
  final Widget? trailing;
  final ConversionJob? conversionJob;
  final List<LibraryMenuEntry> extraActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = TrackScope(track);
    final availability = ref.watch(playbackAvailabilityProvider(scope));
    return TrackTile(
      track: track,
      trailing: trailing,
      conversionJob: conversionJob,
      // Offline, a track that can't play stays visible but dimmed and inert.
      isDimmed: !availability.canPlay,
      isInteractive: availability.canPlay,
      onTap: onTap,
      menu: buildLibraryActionMenu(
        scope,
        availability,
        actions: ref.watch(libraryActionsProvider),
        onGetInfo: () => openTrackInfo(context, track),
        extraActions: extraActions,
      ),
    );
  }
}
