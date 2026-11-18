/// Phase 9B rediscovery suggestions (spec §5 items 1–2, para 3): the
/// snapshot pools the repository reads and the pure selection over them.
/// Pure model: no I/O, no clock, no randomness, nothing from `ui/`.
library;

import 'package:frontend/models/browse_filters.dart';

/// A Rediscover track's last qualified play is at least this old.
const Duration rediscoverMinAge = Duration(days: 14);

/// The window (ending at captured now) in which an artist counts as recently
/// listened.
const Duration recentArtistWindow = Duration(days: 30);

/// Maximum tracks per rail.
const int suggestionCap = 20;

/// Maximum artists taken into More from your artists.
const int artistCap = 10;

/// Maximum tracks taken per artist.
const int perArtistCap = 2;

/// A resolvable catalog track as the snapshot saw it.
class SuggestionCandidate {
  const SuggestionCandidate({
    required this.uuid,
    this.artistId,
    this.title,
    required this.isDownloaded,
  });

  final String uuid;

  /// The track's current artist; null when unknown.
  final int? artistId;

  /// The track's current title; null when unknown.
  final String? title;

  /// A usable local download at capture (`usableDownloadPredicate`).
  final bool isDownloaded;

  @override
  bool operator ==(Object other) =>
      other is SuggestionCandidate &&
      other.uuid == uuid &&
      other.artistId == artistId &&
      other.title == title &&
      other.isDownloaded == isDownloaded;

  @override
  int get hashCode => Object.hash(uuid, artistId, title, isDownloaded);

  @override
  String toString() => 'SuggestionCandidate($uuid)';
}

/// A Rediscover pool entry: at least two qualified plays in all time, the
/// last one at least 14 days before the snapshot's captured now.
class RediscoverCandidate {
  const RediscoverCandidate({
    required this.track,
    required this.listeningMicros,
    required this.qualifiedPlays,
    required this.lastQualifiedAtUtcMs,
  });

  final SuggestionCandidate track;

  /// All-time listening time in integer microseconds (exact ties, as 9A).
  final int listeningMicros;

  /// All-time qualified plays (>= 2).
  final int qualifiedPlays;

  /// Start of the most recent qualified play (UTC ms).
  final int lastQualifiedAtUtcMs;
}

/// A recently listened artist (at least one qualified play in the last 30
/// days) and its catalog tracks with zero qualified plays in all time.
class ArtistPool {
  const ArtistPool({
    required this.artistId,
    required this.recentMicros,
    required this.recentQualifiedPlays,
    required this.candidates,
  });

  final int artistId;

  /// Listening time in the last 30 days, integer microseconds.
  final int recentMicros;

  /// Qualified plays in the last 30 days (>= 1).
  final int recentQualifiedPlays;

  /// Unplayed (zero qualified plays) catalog tracks of the artist, any order.
  final List<SuggestionCandidate> candidates;
}

/// Everything the selection needs, read from one history snapshot.
class SuggestionPools {
  const SuggestionPools({
    required this.boundaryLocalId,
    required this.capturedNowUtcMs,
    required this.rediscover,
    required this.artists,
  });

  final int boundaryLocalId;
  final int capturedNowUtcMs;

  /// Rediscover candidates, any order.
  final List<RediscoverCandidate> rediscover;

  /// Recently listened artists, any order.
  final List<ArtistPool> artists;
}

/// The two rails' contents. An empty list means that rail collapses.
class Suggestions {
  const Suggestions({required this.rediscover, required this.moreFromArtists});

  final List<SuggestionCandidate> rediscover;
  final List<SuggestionCandidate> moreFromArtists;
}

/// Picks both rails from [pools] for the current track [currentUuid] and the
/// Home chip's [filter] (SC-09).
Suggestions selectSuggestions(
  SuggestionPools pools, {
  String? currentUuid,
  required BrowseFilters filter,
}) {
  bool eligible(SuggestionCandidate c) =>
      c.uuid != currentUuid && (!filter.downloaded || c.isDownloaded);

  final rediscover = pools.rediscover.where((c) => eligible(c.track)).toList()
    ..sort((a, b) {
      final byListening = b.listeningMicros.compareTo(a.listeningMicros);
      if (byListening != 0) return byListening;
      final byLast = a.lastQualifiedAtUtcMs.compareTo(b.lastQualifiedAtUtcMs);
      if (byLast != 0) return byLast;
      return a.track.uuid.compareTo(b.track.uuid);
    });

  final rankedArtists = pools.artists.toList()
    ..sort((a, b) {
      final byMicros = b.recentMicros.compareTo(a.recentMicros);
      if (byMicros != 0) return byMicros;
      final byPlays = b.recentQualifiedPlays.compareTo(a.recentQualifiedPlays);
      if (byPlays != 0) return byPlays;
      return a.artistId.compareTo(b.artistId);
    });
  final picks = <List<SuggestionCandidate>>[];
  for (final artist in rankedArtists) {
    final usable = artist.candidates.where(eligible).toList();
    if (usable.isEmpty) continue;
    usable.sort(_compareByTitleThenUuid);
    picks.add(usable.take(perArtistCap).toList());
    if (picks.length == artistCap) break;
  }
  final interleaved = <SuggestionCandidate>[
    for (var round = 0; round < perArtistCap; round++)
      for (final p in picks)
        if (round < p.length) p[round],
  ];

  return Suggestions(
    rediscover: List.unmodifiable(
      rediscover.take(suggestionCap).map((c) => c.track),
    ),
    moreFromArtists: List.unmodifiable(interleaved.take(suggestionCap)),
  );
}

String? _normalizedTitle(SuggestionCandidate c) => c.title?.trim().toLowerCase();

/// Normalized title ascending (unknown title after every known one), then uuid.
int _compareByTitleThenUuid(SuggestionCandidate a, SuggestionCandidate b) {
  final ta = _normalizedTitle(a);
  final tb = _normalizedTitle(b);
  if (ta != tb) {
    if (ta == null) return 1;
    if (tb == null) return -1;
    final c = ta.compareTo(tb);
    if (c != 0) return c;
  }
  return a.uuid.compareTo(b.uuid);
}
