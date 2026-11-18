import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/feed_header.dart';
import 'package:frontend/ui/home/home_controller.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/library_sync_status_view.dart';

/// One Home entry point (SC-07). Phase 9 appends `listening_stats`.
@immutable
class HomeEntryPoint {
  const HomeEntryPoint({
    required this.id,
    required this.label,
    required this.icon,
    required this.destination,
  });

  final String id;
  final String label;
  final IconData icon;
  final BrowseDestination destination;
}

/// Phase 4's entry points, in order.
final homeEntryPointsProvider = Provider<List<HomeEntryPoint>>(
  (ref) => const [
    HomeEntryPoint(
      id: 'artists',
      label: 'Artists',
      icon: Icons.person,
      destination: BrowseDestination.artists,
    ),
    HomeEntryPoint(
      id: 'albums',
      label: 'Albums',
      icon: Icons.album,
      destination: BrowseDestination.albums,
    ),
    HomeEntryPoint(
      id: 'tracks',
      label: 'Tracks',
      icon: Icons.music_note,
      destination: BrowseDestination.tracks,
    ),
    HomeEntryPoint(
      id: 'downloaded',
      label: 'Downloaded',
      icon: Icons.download_done,
      destination: BrowseDestination.downloaded,
    ),
  ],
);

/// Stable Home section ids, in feed order (SC-07). Reserving an id fixes its
/// position; it does not render anything until its phase registers a spec.
abstract final class HomeSectionIds {
  static const search = 'home.search';
  static const syncStatus = 'home.sync_status'; // library sync feedback
  static const entryPoints = 'home.entry_points';
  static const filters = 'home.filters'; // Phase 6 (the Downloaded chip)
  static const recents = 'home.recents'; // Phase 6
  static const rediscover = 'home.rediscover'; // Phase 9B
  static const moreFromArtists = 'home.more_from_artists'; // Phase 9B

  static const order = [
    search,
    syncStatus,
    entryPoints,
    filters,
    recents,
    rediscover,
    moreFromArtists,
  ];
}

/// One Home section (SC-07). [hidePreferenceKey] is the only seam for
/// Phase 9B's `HomeLayoutPreferences` (always null in Phase 4).
@immutable
class HomeSectionSpec {
  const HomeSectionSpec({required this.id, this.build, this.hidePreferenceKey});

  final String id;

  /// Builds the section ([HomeSectionIds.search] is the feed header and
  /// needs none).
  final FeedSection Function(BuildContext context, WidgetRef ref)? build;
  final String? hidePreferenceKey;
}

/// Home's sections, listed in [HomeSectionIds.order] (a test guards it; a
/// later phase inserts its spec at its id's position). Phase 4 registers the
/// search header, the library sync status and the entry points.
final homeSectionsProvider = Provider<List<HomeSectionSpec>>(
  (ref) => [
    homeSearchSectionSpec,
    homeSyncStatusSectionSpec,
    homeEntryPointsSectionSpec,
    homeFiltersSectionSpec,
    homeRecentsSectionSpec,
  ],
);

/// The Downloaded chip, in its own section above the rails (SC-07, O6):
/// shown whenever recents is registered, even with no history.
final homeFiltersSectionSpec = HomeSectionSpec(
  id: HomeSectionIds.filters,
  build: (context, ref) =>
      _HomeControlsSection(HomeSectionIds.filters, ref.watch(homeControlsProvider), (
        context,
        controls,
      ) {
        return SliverToBoxAdapter(
          child: FilterBar(
            filters: controls.filters,
            onDownloadedChanged: controls.setDownloaded,
          ),
        );
      }),
);

/// Recently played: a live rail over [HomeControls.recents].
final homeRecentsSectionSpec = HomeSectionSpec(
  id: HomeSectionIds.recents,
  build: (context, ref) => _HomeControlsSection(
    HomeSectionIds.recents,
    ref.watch(homeControlsProvider),
    (context, controls) => _recentsRail(context, controls).buildSliver(context),
  ),
);

EntityRailSection _recentsRail(BuildContext context, HomeControls controls) {
  const id = HomeSectionIds.recents;
  const title = 'Recently played';
  const label = 'New activity';
  final seeAll = TextButton(
    onPressed: () => openSeeAllRecents(
      context,
      initialDownloaded: controls.filters.downloaded,
    ),
    child: const Text('See all'),
  );
  return switch (controls.recents) {
    HomeRecentsLoading() => const EntityRailSection(
      id: id,
      title: title,
      entities: [],
      state: RailState.loading,
      newActivityLabel: label,
    ),
    HomeRecentsFailed() => EntityRailSection(
      id: id,
      title: title,
      entities: const [],
      state: RailState.error,
      onRetry: controls.retryRecents,
      newActivityLabel: label,
    ),
    HomeRecentsReady(:final entities) => EntityRailSection(
      id: id,
      title: title,
      entities: entities,
      newActivityLabel: label,
      trailing: seeAll,
      onTap: (entity, _) => switch (entity) {
        TrackEntity(:final track) => controls.playTrack(track),
        AlbumEntity(:final album) => openAlbumDetail(context, album),
        ArtistEntity(:final artist) => openArtistDetail(context, artist),
      },
    ),
    HomeRecentsEmpty(:final filtered) => EntityRailSection(
      id: id,
      title: title,
      entities: const [],
      newActivityLabel: label,
      emptyMessage: filtered ? 'No downloaded recents' : null,
      trailing: filtered ? seeAll : null,
    ),
  };
}

/// A section whose sliver rebuilds when [controls] notifies.
class _HomeControlsSection extends FeedSection {
  const _HomeControlsSection(this.id, this.controls, this.builder);

  @override
  final String id;
  final HomeControls controls;
  final Widget Function(BuildContext context, HomeControls controls) builder;

  @override
  Widget buildSliver(BuildContext context) => ListenableBuilder(
    listenable: controls,
    builder: (context, _) => builder(context, controls),
  );
}

/// The library sync's bounded loading/error/Retry feedback (phase-4 §4).
final homeSyncStatusSectionSpec = HomeSectionSpec(
  id: HomeSectionIds.syncStatus,
  build: (context, ref) => const FeedStatusSection(
    id: HomeSectionIds.syncStatus,
    child: LibrarySyncStatusView(),
  ),
);

/// The navigate-style search header.
const homeSearchSectionSpec = HomeSectionSpec(id: HomeSectionIds.search);

/// The entry points, from [homeEntryPointsProvider].
final homeEntryPointsSectionSpec = HomeSectionSpec(
  id: HomeSectionIds.entryPoints,
  build: (context, ref) => EntryPointsSection(
    id: HomeSectionIds.entryPoints,
    entries: [
      for (final e in ref.watch(homeEntryPointsProvider))
        FeedEntryPoint(
          id: e.id,
          label: e.label,
          icon: e.icon,
          onSelected: () => openBrowse(context, e.destination),
        ),
    ],
  ),
);

/// Home: renders only the registry — its search header navigates to
/// Search, its sections come from [homeSectionsProvider].
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key, this.onSearchActivated});

  /// Select the Search tab and focus its field (the shell's job).
  final VoidCallback? onSearchActivated;

  @override
  ConsumerState<HomePage> createState() => HomePageState();
}

class HomePageState extends ConsumerState<HomePage> {
  final _feed = GlobalKey<SectionedFeedViewState>();

  /// Shell re-tap on the visible Home root.
  void scrollToTop() => _feed.currentState?.scrollToTop();

  @override
  Widget build(BuildContext context) {
    final specs = ref.watch(homeSectionsProvider);
    final hasHeader = specs.any((s) => s.id == HomeSectionIds.search);
    // The shell's floating chrome covers the top and bottom; the feed pads
    // itself by its insets (and scrolls behind the glass).
    final insets = ShellChromeInsets.of(context);
    return Material(
      type: MaterialType.transparency,
      // Side safe areas (landscape notches); top/bottom are the chrome's.
      child: SafeArea(
        top: false,
        bottom: false,
        child: SectionedFeedView(
          key: _feed,
          topPadding: insets.top,
          bottomPadding: insets.bottom,
          header: hasHeader
              ? FeedHeader.navigate(
                  onActivate: () => widget.onSearchActivated?.call(),
                )
              : null,
          sections: [
            for (final spec in specs)
              if (spec.build != null) spec.build!(context, ref),
          ],
        ),
      ),
    );
  }
}
