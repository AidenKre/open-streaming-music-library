import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:frontend/ui/widgets/library_action_menu.dart';
import 'package:frontend/ui/widgets/library_card.dart';

/// A track as a card (rails): a thin [LibraryCard] wrapper with square art,
/// title and artist, download counts of 1, and the one SC-06 menu (with Get
/// info). It does not decide queue semantics: the surface supplies [onTap]
/// (Search plays its capped result list; Phase 6 recents play one track).
/// Offline and not playable, it is dimmed and its tap is blocked, while the
/// menu's Get info stays available.
class TrackCard extends ConsumerWidget {
  const TrackCard({super.key, required this.track, this.onTap});

  final TrackUI track;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final scope = TrackScope(track);
    final availability = ref.watch(playbackAvailabilityProvider(scope));
    final isDownloading = ref.watch(
      downloadManagerListenableProvider.select(
        (m) => m.state.isPending(track.uuidId),
      ),
    );
    final title = track.title ?? 'Unknown Title';
    final artist = track.artist ?? 'Unknown Artist';
    return LibraryCard(
      cover: CoverArtImage(
        hasAlbumArt: track.hasAlbumArt,
        coverArtId: track.coverArtId,
        borderRadius: BorderRadius.zero,
        fallback: Container(
          color: colorScheme.primaryContainer,
          child: Icon(
            Icons.music_note,
            size: 48,
            color: colorScheme.onPrimaryContainer,
          ),
        ),
      ),
      title: title,
      subtitle: artist,
      semanticLabel: 'Song, $title, by $artist',
      onTap: availability.canPlay ? onTap : null,
      dimmed: !availability.canPlay,
      availability: availability,
      isDownloading: isDownloading,
      downloadCounts: AsyncData((
        downloaded: track.isDownloaded ? 1 : 0,
        total: 1,
      )),
      menu: buildLibraryActionMenu(
        scope,
        availability,
        actions: ref.watch(libraryActionsProvider),
        onGetInfo: () => openTrackInfo(context, track),
      ),
    );
  }
}
