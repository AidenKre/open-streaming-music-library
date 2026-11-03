import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/feed_header.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';
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
  ],
);

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
