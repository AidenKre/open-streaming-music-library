import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/ui/feed/feed.dart';

/// One entry of a statistics ranking as a card (a presentation type): the
/// entity as it resolves now (or the snapshot's read model when it no
/// longer resolves), its rank and the snapshot's numbers.
final class StatsRankedCard {
  const StatsRankedCard({
    required this.entity,
    required this.rank,
    required this.listeningSeconds,
    required this.qualifiedPlays,
    required this.unavailable,
  });

  final FeedEntity entity;

  /// 1-based position in the ranking.
  final int rank;
  final double listeningSeconds;
  final int qualifiedPlays;

  /// Deleted, or no longer resolving: not playable or openable; its numbers
  /// still count.
  final bool unavailable;
}

/// The statistics page's three top lists.
final class StatsTopLists {
  const StatsTopLists({
    required this.tracks,
    required this.artists,
    required this.albums,
  });

  final List<StatsRankedCard> tracks;
  final List<StatsRankedCard> artists;
  final List<StatsRankedCard> albums;

  /// Some shown entity no longer resolves (the page prompts a refresh).
  bool get hasUnavailable =>
      [...tracks, ...artists, ...albums].any((c) => c.unavailable);
}

/// The cards of [entries] ranked from [firstRank], built from the snapshot's
/// own read models. A card is unavailable only when [current] is known and
/// no longer resolves the shown entity (`currentOf` decides, never this
/// function); otherwise it shows the current read model.
List<StatsRankedCard> rankedCards(
  List<RankedEntry<Object>> entries,
  CurrentStatsEntities? current, {
  int firstRank = 1,
}) {
  final cards = <StatsRankedCard>[];
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final now = current?.currentOf(entry.entity);
    cards.add(
      StatsRankedCard(
        entity: feedEntityOf(now ?? entry.entity)!,
        rank: firstRank + i,
        listeningSeconds: entry.listeningSeconds,
        qualifiedPlays: entry.qualifiedPlays,
        unavailable: current != null && now == null,
      ),
    );
  }
  return cards;
}
