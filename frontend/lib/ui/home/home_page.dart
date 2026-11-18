import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/feed_header.dart';
import 'package:frontend/ui/home/home_controller.dart';
import 'package:frontend/ui/home/home_sections.dart';
import 'package:frontend/repositories/home_suggestions_service.dart' show SuggestionRail;
import 'package:frontend/ui/home/home_suggestions_controller.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';
import 'package:frontend/ui/widgets/library_sync_status_view.dart';
import 'package:frontend/ui/widgets/playback_notice.dart';

export 'package:frontend/ui/home/home_sections.dart' show HomeSectionIds;

/// One Home entry point (SC-07).
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

/// Phase 4's entry points, then Phase 9's Listening stats.
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
    HomeEntryPoint(
      id: 'listening_stats',
      label: 'Listening stats',
      icon: Icons.insights,
      destination: BrowseDestination.listeningStats,
    ),
  ],
);

/// One Home section (SC-07). A section with a [hidePreferenceKey] can be
/// hidden in Settings (`HomeLayoutPreferences`); one without is always shown.
@immutable
class HomeSectionSpec {
  const HomeSectionSpec({required this.id, this.build, this.hidePreferenceKey});

  final String id;

  /// Builds the section ([HomeSectionIds.search] is the feed header and
  /// needs none).
  final FeedSection Function(BuildContext context, WidgetRef ref)? build;
  final String? hidePreferenceKey;
}

/// Home's sections, listed in [HomeSectionIds.order] (a test guards it),
/// without the hidden ones.
final homeSectionsProvider = Provider<List<HomeSectionSpec>>((ref) {
  final preferences = ref.watch(homeLayoutPreferencesProvider);
  // A hideable section stays out while the preference is unknown.
  final known = preferences.hasValue || preferences.hasError;
  final hidden = preferences.value?.hidden ?? const <String>{};
  return [
    for (final spec in [
      homeSearchSectionSpec,
      homeSyncStatusSectionSpec,
      homeEntryPointsSectionSpec,
      homeFiltersSectionSpec,
      homeRecentsSectionSpec,
      homeRediscoverSectionSpec,
      homeMoreFromArtistsSectionSpec,
    ])
      if (spec.hidePreferenceKey == null ||
          (known && !hidden.contains(spec.hidePreferenceKey)))
        spec,
  ];
});

/// Rediscover: a frozen-snapshot rail over [HomeSuggestionsControls].
final homeRediscoverSectionSpec = HomeSectionSpec(
  id: HomeSectionIds.rediscover,
  hidePreferenceKey: HomeSectionIds.rediscover,
  build: (context, ref) => _suggestionsSection(
    ref,
    SuggestionRail.rediscover,
    HomeSectionIds.rediscover,
    'Rediscover',
    'Tracks you enjoyed, but haven’t played in two weeks',
  ),
);

/// More from your artists: unplayed music from recently listened artists.
final homeMoreFromArtistsSectionSpec = HomeSectionSpec(
  id: HomeSectionIds.moreFromArtists,
  hidePreferenceKey: HomeSectionIds.moreFromArtists,
  build: (context, ref) => _suggestionsSection(
    ref,
    SuggestionRail.moreFromArtists,
    HomeSectionIds.moreFromArtists,
    'More from your artists',
    'Music you haven’t played through yet, from artists you listened to in '
        'the last 30 days',
  ),
);

FeedSection _suggestionsSection(
  WidgetRef ref,
  SuggestionRail rail,
  String id,
  String title,
  String subtitle,
) => _ListenableSection<HomeSuggestionsControls>(
  id,
  ref.watch(homeSuggestionsControlsProvider),
  (context, controls) {
    void engagement(RailEngagement e) => controls.setRailEngagement(rail, e);
    return switch (controls.stateOf(rail)) {
      SuggestionRailLoading() => EntityRailSection(
        id: id,
        title: title,
        subtitle: subtitle,
        entities: const [],
        state: RailState.loading,
        onEngagementChanged: engagement,
      ),
      SuggestionRailFailed() => EntityRailSection(
        id: id,
        title: title,
        subtitle: subtitle,
        entities: const [],
        state: RailState.error,
        onRetry: () => controls.retry(rail),
        onEngagementChanged: engagement,
      ),
      SuggestionRailReady(
        :final tracks,
        :final emptiedByFilter,
        :final resetToken,
        :final showNotice,
      ) =>
        EntityRailSection(
          id: id,
          title: title,
          subtitle: subtitle,
          entities: [for (final t in tracks) TrackEntity(t)],
          resetToken: resetToken,
          onTap: (entity, _) => showPlaybackOutcome(
            context,
            controls.playTrack((entity as TrackEntity).track),
          ),
          emptyMessage: emptiedByFilter ? 'No downloaded suggestions' : null,
          onEngagementChanged: engagement,
          notice: showNotice
              ? RailNotice(
                  message: 'New listening activity',
                  actionLabel: 'Refresh',
                  onTap: () => controls.refreshRail(rail),
                )
              : null,
        ),
    }.buildSliver(context);
  },
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
        TrackEntity(:final track) => showPlaybackOutcome(
          context,
          controls.playTrack(track),
        ),
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
typedef _HomeControlsSection = _ListenableSection<HomeControls>;

class _ListenableSection<C extends Listenable> extends FeedSection {
  const _ListenableSection(this.id, this.controls, this.builder);

  @override
  final String id;
  final C controls;
  final Widget Function(BuildContext context, C controls) builder;

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
