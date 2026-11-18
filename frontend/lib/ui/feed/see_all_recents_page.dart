import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/new_activity_notice.dart';
import 'package:frontend/ui/feed/see_all_recents_controller.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';
import 'package:frontend/ui/widgets/playback_notice.dart';
import 'package:frontend/ui/widgets/top_bar_actions.dart';

/// See all recently played: a snapshot grid (Phase 6 §3, §7).
class SeeAllRecentsPage extends ConsumerStatefulWidget {
  const SeeAllRecentsPage({super.key, required this.initialDownloaded});

  /// Home's chip value when the route opened.
  final bool initialDownloaded;

  @override
  ConsumerState<SeeAllRecentsPage> createState() => _SeeAllRecentsPageState();
}

class _SeeAllRecentsPageState extends ConsumerState<SeeAllRecentsPage> {
  late final SeeAllRecentsControls _controls;
  final _scroll = ScrollController();
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _controls = ref.read(seeAllRecentsControllerFactoryProvider)(
      initialDownloaded: widget.initialDownloaded,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recently played'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _controls.refresh,
          ),
          ...buildTopBarActions(context, ref),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controls,
        builder: (context, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _afterBuild());
          return Column(
            children: [
              FilterBar(
                filters: _controls.filters,
                onDownloadedChanged: _controls.setDownloaded,
              ),
              if (_controls.notice != SnapshotStaleness.fresh)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: NewActivityNotice(
                    message: _controls.notice == SnapshotStaleness.historyChanged
                        ? 'History changed'
                        : 'New activity',
                    actionLabel: 'Refresh',
                    onRefresh: _controls.refresh,
                  ),
                ),
              Expanded(child: _content(context)),
            ],
          );
        },
      ),
    );
  }

  Widget _content(BuildContext context) {
    final entities = _controls.entities;
    if (entities == null) {
      if (!_controls.failed) {
        return const Center(child: CircularProgressIndicator());
      }
      return LoadFailureNotice(
        message: 'Couldn’t load.',
        onRetry: _controls.retry,
      );
    }
    // Rows may all be gone while later pages remain: keep the grid path, so
    // its trailing loader and the near-end check fetch more.
    if (entities.isEmpty && !_controls.hasMore) {
      // An expired first page is not an empty history: the notice says it.
      if (_controls.notice == SnapshotStaleness.historyChanged) {
        return const SizedBox.shrink();
      }
      return Center(
        child: Text(
          _controls.filters.downloaded
              ? 'No downloaded recents'
              : 'No recently played items',
        ),
      );
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
                    mainAxisExtent: FeedCardExtent.of(context).height,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final entity = entities[i];
                      return KeyedSubtree(
                        key: entity.key,
                        child: cardFor(entity, onTap: () => _tap(entity)),
                      );
                    },
                    childCount: entities.length,
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

  void _tap(FeedEntity entity) => switch (entity) {
    TrackEntity(:final track) => showPlaybackOutcome(
      context,
      _controls.playTrack(track),
    ),
    AlbumEntity(:final album) => openAlbumDetail(context, album),
    ArtistEntity(:final artist) => openArtistDetail(context, artist),
  };
}
