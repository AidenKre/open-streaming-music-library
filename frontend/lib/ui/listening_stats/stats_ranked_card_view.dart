import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/listening_stats/listening_stats_format.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/widgets/library_card.dart';

/// The height of a ranked card: the shared card plus its rank line and a
/// numbers line that may wrap to two lines, at the current text scale.
double statsRankedCardHeight(BuildContext context) {
  final style = Theme.of(context).textTheme.bodySmall;
  final scaler = MediaQuery.textScalerOf(context);
  final captions =
      3 * scaler.scale((style?.fontSize ?? 12) * (style?.height ?? 1.5)) + 8;
  return FeedCardExtent.of(context).height + captions;
}

/// One ranked card of the statistics: the shared Phase 4 card (or a dimmed
/// stand-in when it no longer resolves) with its rank and numbers.
class StatsRankedCardView extends ConsumerWidget {
  const StatsRankedCardView({
    super.key,
    required this.card,
    required this.onPlayTrack,
  });

  final StatsRankedCard card;
  final void Function(TrackUI track) onPlayTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final plays = card.qualifiedPlays;
    final entity = card.entity;
    return KeyedSubtree(
      key: entity.key,
      child: SizedBox(
        width: FeedCardExtent.cardWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: FeedCardExtent.of(context).height,
              child: card.unavailable
                  ? _UnavailableCard(
                      entity: entity,
                      offline: ref.watch(offlineModeProvider),
                    )
                  : cardFor(entity, onTap: () => _open(context, entity)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('#${card.rank}', style: theme.textTheme.bodySmall),
                  Text(
                    '${formatListeningTime(card.listeningSeconds)} · '
                    '$plays qualified ${plays == 1 ? 'play' : 'plays'}',
                    style: theme.textTheme.bodySmall,
                    maxLines: 2,
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

  void _open(BuildContext context, FeedEntity entity) => switch (entity) {
    TrackEntity(:final track) => onPlayTrack(track),
    AlbumEntity(:final album) => openAlbumDetail(context, album),
    ArtistEntity(:final artist) => openArtistDetail(context, artist),
  };
}

/// An entity that no longer resolves: dimmed, no tap, no menu.
class _UnavailableCard extends StatelessWidget {
  const _UnavailableCard({required this.entity, required this.offline});

  final FeedEntity entity;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (title, icon) = switch (entity) {
      TrackEntity(:final TrackUI track) => (
        track.title ?? 'Unknown Title',
        Icons.music_note,
      ),
      AlbumEntity(:final AlbumUI album) => (
        album.name ?? 'Unknown Album',
        Icons.album,
      ),
      ArtistEntity(:final ArtistUI artist) => (
        artist.name,
        Icons.person,
      ),
    };
    return LibraryCard(
      cover: Container(
        color: colors.primaryContainer,
        child: Icon(icon, size: 48, color: colors.onPrimaryContainer),
      ),
      title: title,
      subtitle: 'No longer available',
      dimmed: true,
      menu: const [],
      isDownloading: false,
      downloadCounts: const AsyncData(null),
      availability: PlaybackAvailability.unknown(offline: offline),
    );
  }
}
