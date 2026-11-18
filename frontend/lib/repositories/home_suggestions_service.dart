/// Phase 9B Home suggestions (spec §5): one frozen snapshot per rail
/// refresh (SC-10 token with catalog attribution + the 9B.1 pools at its
/// boundary), the pure 9B.1 selection, and SC-12 hydration. Model: no `ui/`
/// import, no HTTP.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/models/suggestions.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/suggestion_pools_repository.dart';

/// The two Home suggestion rails.
enum SuggestionRail { rediscover, moreFromArtists }

/// One rail's hydrated picks.
class RailPicks {
  const RailPicks({required this.tracks, required this.emptiedByFilter});

  final List<TrackUI> tracks;

  /// True when [tracks] is empty only because of the Downloaded filter: the
  /// same snapshot and current track give picks without it (SC-07: the
  /// section says so instead of hiding).
  final bool emptiedByFilter;
}

/// Both rails' picks for one (current track, filter).
class SuggestionView {
  const SuggestionView({
    required this.rediscover,
    required this.moreFromArtists,
    required this.complete,
  });

  final RailPicks rediscover;
  final RailPicks moreFromArtists;

  /// False when some picks are not hydrated yet (they are left out).
  final bool complete;

  RailPicks of(SuggestionRail rail) => switch (rail) {
    SuggestionRail.rediscover => rediscover,
    SuggestionRail.moreFromArtists => moreFromArtists,
  };
}

/// A frozen history snapshot and its pools, with the tracks hydrated so far.
class SuggestionSnapshot {
  SuggestionSnapshot({required this.token, required this.pools});

  final HistorySnapshotToken token;
  final SuggestionPools pools;

  final Map<String, TrackUI> _hydrated = {};

  /// Uuids `getTracksByUuids` dropped: gone from the catalog.
  final Set<String> _missing = {};
}

class HomeSuggestionsService {
  HomeSuggestionsService({
    required HistorySnapshotService snapshots,
    required SnapshotFreshness freshness,
    required SuggestionPoolsRepository pools,
    required BrowseRepository browse,
  }) : _snapshots = snapshots,
       _freshness = freshness,
       _pools = pools,
       _browse = browse;

  final HistorySnapshotService _snapshots;
  final SnapshotFreshness _freshness;
  final SuggestionPoolsRepository _pools;
  final BrowseRepository _browse;

  /// The SC-10 filter key of Home suggestion snapshots.
  static const filterKey = 'home.suggestions';

  Future<SuggestionSnapshot> capture() async {
    final (token, pools) = await _snapshots.captureWith(
      filterKey,
      attribution: true,
      (token) => _pools.load(token.boundaryLocalId, token.capturedNowUtcMs),
    );
    return SuggestionSnapshot(token: token, pools: pools);
  }

  Stream<SnapshotStaleness> watch(SuggestionSnapshot snapshot) =>
      _freshness.watch(snapshot.token, kinds: const {HistoryKind.play});

  SuggestionView pickNow(
    SuggestionSnapshot snapshot, {
    String? currentUuid,
    required BrowseFilters filter,
  }) {
    final picked = selectSuggestions(
      snapshot.pools,
      currentUuid: currentUuid,
      filter: filter,
    );
    final unfiltered = filter.downloaded
        ? selectSuggestions(
            snapshot.pools,
            currentUuid: currentUuid,
            filter: filter.userSetDownloaded(false),
          )
        : picked;
    var complete = true;
    RailPicks rail(
      List<SuggestionCandidate> picks,
      List<SuggestionCandidate> withoutFilter,
    ) {
      final tracks = <TrackUI>[];
      for (final c in picks) {
        final t = snapshot._hydrated[c.uuid];
        if (t != null) {
          tracks.add(t);
        } else if (!snapshot._missing.contains(c.uuid)) {
          complete = false;
        }
      }
      return RailPicks(
        tracks: tracks,
        emptiedByFilter:
            picks.isEmpty && filter.downloaded && withoutFilter.isNotEmpty,
      );
    }

    return SuggestionView(
      rediscover: rail(picked.rediscover, unfiltered.rediscover),
      moreFromArtists: rail(picked.moreFromArtists, unfiltered.moreFromArtists),
      complete: complete,
    );
  }

  Future<SuggestionView> resolve(
    SuggestionSnapshot snapshot, {
    String? currentUuid,
    required BrowseFilters filter,
  }) async {
    final picked = selectSuggestions(
      snapshot.pools,
      currentUuid: currentUuid,
      filter: filter,
    );
    final need = <String>[];
    final seen = <String>{};
    for (final c in [...picked.rediscover, ...picked.moreFromArtists]) {
      if (!snapshot._hydrated.containsKey(c.uuid) &&
          !snapshot._missing.contains(c.uuid) &&
          seen.add(c.uuid)) {
        need.add(c.uuid);
      }
    }
    if (need.isNotEmpty) {
      final tracks = await _browse.getTracksByUuids(need);
      for (final t in tracks) {
        snapshot._hydrated[t.uuidId] = t;
      }
      for (final u in need) {
        if (!snapshot._hydrated.containsKey(u)) snapshot._missing.add(u);
      }
    }
    return pickNow(snapshot, currentUuid: currentUuid, filter: filter);
  }
}

final homeSuggestionsServiceProvider = Provider<HomeSuggestionsService>(
  (ref) => HomeSuggestionsService(
    snapshots: ref.read(historySnapshotServiceProvider),
    freshness: ref.read(snapshotFreshnessProvider),
    pools: ref.read(suggestionPoolsRepositoryProvider),
    browse: ref.read(browseRepositoryProvider),
  ),
);
