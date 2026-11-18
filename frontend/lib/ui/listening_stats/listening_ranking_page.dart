import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/new_activity_notice.dart';
import 'package:frontend/ui/listening_stats/listening_ranking_controller.dart';
import 'package:frontend/ui/listening_stats/listening_stats_format.dart';
import 'package:frontend/ui/listening_stats/top_lists.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';

/// Opens "See all" for [kind] over the statistics page's [token].
void openListeningRanking(
  BuildContext context,
  StatsRankingKind kind,
  HistorySnapshotToken token,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListeningRankingPage(kind: kind, token: token),
  ),
);

/// "See all" for one statistics ranking: keyset pages of the statistics
/// page's snapshot (spec §3 para 5, §4).
class ListeningRankingPage extends ConsumerStatefulWidget {
  const ListeningRankingPage({
    super.key,
    required this.kind,
    required this.token,
  });

  final StatsRankingKind kind;

  /// The statistics page's snapshot.
  final HistorySnapshotToken token;

  @override
  ConsumerState<ListeningRankingPage> createState() =>
      _ListeningRankingPageState();
}

class _ListeningRankingPageState extends ConsumerState<ListeningRankingPage> {
  late final ListeningRankingControls _controls;
  final _scroll = ScrollController();
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _controls = ref.read(listeningRankingControllerFactoryProvider)(
      widget.kind,
      widget.token,
    );
    _epoch = _controls.snapshotEpoch;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _controls.dispose();
    super.dispose();
  }

  /// After each frame: a new snapshot starts at the top, and a page that does
  /// not fill the viewport asks for more.
  void _afterBuild() {
    if (!mounted || !_scroll.hasClients) return;
    if (_controls.snapshotEpoch != _epoch) {
      _epoch = _controls.snapshotEpoch;
      _scroll.jumpTo(0);
    }
    _maybeLoadMore(_scroll.position);
  }

  void _maybeLoadMore(ScrollMetrics m) {
    if (_controls.hasMore && m.extentAfter < m.viewportDimension) {
      _controls.loadMore();
    }
  }

  String get _title => switch (widget.kind) {
    StatsRankingKind.tracks => 'Top tracks',
    StatsRankingKind.artists => 'Top artists',
    StatsRankingKind.albums => 'Top albums',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: ListenableBuilder(
        listenable: _controls,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_title),
            Text(
              rangeLabel(_controls.range),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: _controls.refresh,
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: _controls,
      builder: (context, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _afterBuild());
        final notice = _notice();
        return Column(
          children: [
            if (notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: notice,
              ),
            Expanded(child: _content(context)),
          ],
        );
      },
    ),
  );

  /// One notice at a time: the freshness notice wins.
  Widget? _notice() {
    if (_controls.notice != SnapshotStaleness.fresh) {
      return NewActivityNotice(
        message: _controls.notice == SnapshotStaleness.historyChanged
            ? 'Listening history changed'
            : 'New listening activity',
        actionLabel: 'Refresh',
        onRefresh: _controls.refresh,
      );
    }
    if (_controls.cards?.any((c) => c.unavailable) ?? false) {
      return NewActivityNotice(
        message: 'Some items are no longer available',
        actionLabel: 'Refresh',
        onRefresh: _controls.refresh,
      );
    }
    return null;
  }

  Widget _content(BuildContext context) {
    final cards = _controls.cards;
    if (cards == null) {
      if (!_controls.failed) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Couldn’t load.'),
            TextButton(onPressed: _controls.retry, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (cards.isEmpty && !_controls.hasMore) {
      // An expired first page is not an empty ranking: the notice says it.
      if (_controls.expired) return const SizedBox.shrink();
      return const Center(child: Text('Nothing ranked in this range.'));
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        _maybeLoadMore(n.metrics);
        return false;
      },
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: ShellChromeInsets.padEnd(
              context,
              const EdgeInsets.all(8),
            ),
            sliver: SliverMainAxisGroup(
              slivers: [
                SliverGrid(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: FeedCardExtent.cardWidth,
                    mainAxisExtent: statsRankedCardHeight(context),
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => StatsRankedCardView(
                      card: cards[i],
                      onPlayTrack: _controls.playTrack,
                    ),
                    childCount: cards.length,
                  ),
                ),
                if (_controls.hasMore)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: _controls.failed
                            ? TextButton(
                                onPressed: _controls.retry,
                                child: const Text('Retry'),
                              )
                            : const CircularProgressIndicator(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
