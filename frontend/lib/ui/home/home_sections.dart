import 'package:flutter/foundation.dart';
import 'package:frontend/repositories/home_suggestions_service.dart'
    show SuggestionRail;

// Home's section ids, the rail-to-section mapping ([homeSectionIdOf]) and
// the rail engagement value, in a file of their own so the suggestions
// controller needs neither the Home page nor the feed view. It imports only
// the `SuggestionRail` enum.

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

/// The Home section a suggestion rail is shown in (its hide preference too).
String homeSectionIdOf(SuggestionRail rail) => switch (rail) {
  SuggestionRail.rediscover => HomeSectionIds.rediscover,
  SuggestionRail.moreFromArtists => HomeSectionIds.moreFromArtists,
};

/// Whether the user is looking into a rail (Phase 9 §5): at its start offset
/// or scrolled in, and whether a pointer is down on it.
@immutable
class RailEngagement {
  const RailEngagement({required this.atStart, required this.pointerDown});

  final bool atStart;
  final bool pointerDown;

  /// At the start with no pointer down: changing the items moves nothing
  /// under the user.
  bool get atRest => atStart && !pointerDown;

  @override
  bool operator ==(Object other) =>
      other is RailEngagement &&
      other.atStart == atStart &&
      other.pointerDown == pointerDown;

  @override
  int get hashCode => Object.hash(atStart, pointerDown);

  @override
  String toString() =>
      'RailEngagement(atStart: $atStart, pointerDown: $pointerDown)';
}
