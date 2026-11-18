import 'package:flutter/material.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/listening_stats/listening_ranking_controller.dart';
import 'package:frontend/ui/listening_stats/listening_ranking_page.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card_view.dart';

/// The statistics page's three top lists: horizontally scrolling rows of
/// the shared Phase 4 cards, each with its rank and the snapshot's numbers.
class StatsTopListsView extends StatelessWidget {
  const StatsTopListsView({
    super.key,
    required this.lists,
    required this.onPlayTrack,
    required this.token,
  });

  final StatsTopLists lists;

  /// The snapshot the lists come from; See all pages the same one. Null:
  /// no See all.
  final HistorySnapshotToken? token;
  final void Function(TrackUI track) onPlayTrack;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Section(
        id: 'stats-top-tracks',
        kind: StatsRankingKind.tracks,
        token: token,
        title: 'Top tracks',
        cards: lists.tracks,
        onPlayTrack: onPlayTrack,
      ),
      _Section(
        id: 'stats-top-artists',
        kind: StatsRankingKind.artists,
        token: token,
        title: 'Top artists',
        cards: lists.artists,
        onPlayTrack: onPlayTrack,
      ),
      _Section(
        id: 'stats-top-albums',
        kind: StatsRankingKind.albums,
        token: token,
        title: 'Top albums',
        cards: lists.albums,
        onPlayTrack: onPlayTrack,
      ),
    ],
  );
}

class _Section extends StatelessWidget {
  const _Section({
    required this.id,
    required this.kind,
    required this.token,
    required this.title,
    required this.cards,
    required this.onPlayTrack,
  });

  final String id;
  final StatsRankingKind kind;
  final HistorySnapshotToken? token;
  final String title;
  final List<StatsRankedCard> cards;
  final void Function(TrackUI track) onPlayTrack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = statsRankedCardHeight(context);
    final token = this.token;
    return KeyedSubtree(
      key: ValueKey(id),
      child: Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
                if (cards.isNotEmpty && token != null)
                  TextButton(
                    onPressed: () => openListeningRanking(context, kind, token),
                    child: const Text('See all'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (cards.isEmpty)
              Text('None in this range.', style: theme.textTheme.bodySmall)
            else
              SizedBox(
                height: height,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: cards.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 4),
                  itemBuilder: (context, i) => StatsRankedCardView(
                    card: cards[i],
                    onPlayTrack: onPlayTrack,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
