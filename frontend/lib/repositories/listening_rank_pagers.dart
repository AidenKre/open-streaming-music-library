import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

/// Entities per ranking page behind "See all" (the top lists show 10).
const rankingPageSize = 50;

/// One page of a ranking for a range, boundary and captured now.
typedef _RankingFetch<E, K> = Future<List<RankedPageEntry<E, K>>> Function(
  StatsRange range,
  int boundaryLocalId,
  int capturedNowUtcMs, {
  RankCursor<K>? after,
  required int limit,
});

/// A ranking behind "See all": keyset pages of [rankingPageSize] on the rank
/// tuple (seconds, qualified plays, key), all bound to one
/// [HistorySnapshotToken] (range, boundary, captured now).
///
/// Each page is read through [HistorySnapshotService.readPage]: inside the
/// page's read transaction the token's history-content and catalog-attribution
/// counters are compared first, and a mismatch returns [SnapshotExpired]
/// without running the ranking query. Expiry means the ranking the user was
/// paging is no longer the data on disk; the caller must capture a new token
/// (Refresh) and start again.
///
/// The pager also guarantees progress: every returned entry's cursor is
/// strictly after the requested one and in strict rank order, or the page
/// throws [RankingOrderError], so no caller can spin on a broken keyset.
abstract base class _RankingPager<E, K extends Object>
    implements SnapshotPager<RankedPageEntry<E, K>, RankCursor<K>> {
  _RankingPager(this._snapshots, this._fetch);

  final HistorySnapshotService _snapshots;
  final _RankingFetch<E, K> _fetch;

  /// Fails with [ArgumentError] for a token whose filter key is not a
  /// [StatsRange] or that was captured without the attribution counter
  /// (attribution expiry could not be decided).
  @override
  Future<SnapshotPageResult<RankedPageEntry<E, K>, RankCursor<K>>> page(
    HistorySnapshotToken token,
    RankCursor<K>? after,
    int limit,
  ) async {
    final range = token.filterKey;
    if (range is! StatsRange) {
      throw ArgumentError.value(
          range, 'token.filterKey', 'must be a StatsRange');
    }
    if (token.catalogAttributionVersion == null) {
      throw ArgumentError.value(token, 'token',
          'must be captured with the catalog attribution counter');
    }
    final result = await _snapshots
        .readPage<RankedPageEntry<E, K>, RankCursor<K>>(
      token,
      limit: limit,
      fetch: (n) => _fetch(
        range,
        token.boundaryLocalId,
        token.capturedNowUtcMs,
        after: after,
        limit: n,
      ),
      cursorOf: (e) => e.cursor,
    );
    if (result is SnapshotPage<RankedPageEntry<E, K>, RankCursor<K>>) {
      _checkProgress(after, result.items);
    }
    return result;
  }

  /// A new snapshot of [range] and its first page, in one transaction: the
  /// first page after a capture is never expired.
  Future<
    (
      HistorySnapshotToken,
      SnapshotPageResult<RankedPageEntry<E, K>, RankCursor<K>>,
    )
  >
  first(StatsRange range, int limit) async {
    return _snapshots.captureWith(
      range,
      attribution: true,
      (token) => page(token, null, limit),
    );
  }

  /// Throws [RankingOrderError] unless the cursors of [items] are in strict
  /// rank order, the first strictly after [after] when it is non-null.
  static void _checkProgress<E, K extends Object>(
    RankCursor<K>? after,
    List<RankedPageEntry<E, K>> items,
  ) {
    var previous = after;
    for (final item in items) {
      final cursor = item.cursor;
      if (previous != null && _compareRank(previous, cursor) >= 0) {
        throw RankingOrderError(
            'ranking page not strictly after $previous: got $cursor '
            '(requested cursor: $after)');
      }
      previous = cursor;
    }
  }
}

/// Rank order: listening micros descending, qualified plays descending, key
/// ascending. Negative when [a] ranks before [b].
int _compareRank<K extends Object>(RankCursor<K> a, RankCursor<K> b) {
  final byMicros = b.listeningMicros.compareTo(a.listeningMicros);
  if (byMicros != 0) return byMicros;
  final byPlays = b.qualifiedPlays.compareTo(a.qualifiedPlays);
  if (byPlays != 0) return byPlays;
  return _compareKeys(a.key, b.key);
}

/// SQLite's BINARY collation: ints numerically, strings by UTF-8 bytes (Dart's
/// UTF-16 `compareTo` orders some non-BMP and high-BMP characters differently).
int _compareKeys(Object a, Object b) => switch ((a, b)) {
      (final int x, final int y) => x.compareTo(y),
      (final String x, final String y) => _compareBytes(
          utf8.encode(x), utf8.encode(y)),
      _ => throw ArgumentError('unsupported ranking key types: '
          '${a.runtimeType}, ${b.runtimeType}'),
    };

int _compareBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

/// The top-tracks ranking (rank key: track uuid ascending on ties).
final class TopTracksPager extends _RankingPager<TrackUI, String> {
  TopTracksPager(HistorySnapshotService snapshots, ListeningStatsRepository stats)
      : super(snapshots, stats.trackRanking);
}

/// The top-artists ranking (rank key: current artist id ascending on ties).
final class TopArtistsPager extends _RankingPager<ArtistUI, int> {
  TopArtistsPager(HistorySnapshotService snapshots, ListeningStatsRepository stats)
      : super(snapshots, stats.artistRanking);
}

/// The top-albums ranking (rank key: current album id ascending on ties).
final class TopAlbumsPager extends _RankingPager<AlbumUI, int> {
  TopAlbumsPager(HistorySnapshotService snapshots, ListeningStatsRepository stats)
      : super(snapshots, stats.albumRanking);
}

final topTracksPagerProvider = Provider<TopTracksPager>(
  (ref) => TopTracksPager(
    ref.read(historySnapshotServiceProvider),
    ref.read(listeningStatsRepositoryProvider),
  ),
);

final topArtistsPagerProvider = Provider<TopArtistsPager>(
  (ref) => TopArtistsPager(
    ref.read(historySnapshotServiceProvider),
    ref.read(listeningStatsRepositoryProvider),
  ),
);

final topAlbumsPagerProvider = Provider<TopAlbumsPager>(
  (ref) => TopAlbumsPager(
    ref.read(historySnapshotServiceProvider),
    ref.read(listeningStatsRepositoryProvider),
  ),
);

/// A ranking page whose entries are not in strict rank order, or not strictly
/// after the requested cursor: the keyset is broken. Thrown instead of
/// returning a page a caller could re-request forever.
final class RankingOrderError extends StateError {
  RankingOrderError(super.message);
}
