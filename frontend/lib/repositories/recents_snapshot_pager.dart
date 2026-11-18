import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/recently_played_repository.dart';

/// The See all snapshot's filter key (value-equal record).
typedef RecentsFilterKey = ({bool downloadedOnly});

/// SC-10's first concrete pager: See all's deduped recents.
class RecentsSnapshotPager
    implements SnapshotPager<ResolvedRecent, RecentRef> {
  RecentsSnapshotPager(this._snapshots, this._recents, this._freshness);

  final HistorySnapshotService _snapshots;
  final RecentlyPlayedRepository _recents;
  final SnapshotFreshness _freshness;

  /// Staleness of the token, counting only new recents events (clicks):
  /// other history kinds leave it fresh.
  Stream<SnapshotStaleness> watchFreshness(HistorySnapshotToken token) =>
      _freshness.watch(token, kinds: {recentsEventKind});

  /// Captures a token whose filter key is the Downloaded selection.
  Future<HistorySnapshotToken> capture({required bool downloadedOnly}) =>
      _snapshots.capture((downloadedOnly: downloadedOnly));

  /// Live hydration of the already loaded [refs] under the token's chip.
  Stream<List<ResolvedRecent>> watchLoaded(
    HistorySnapshotToken token,
    List<RecentRef> refs,
  ) => _recents.watchResolved(
    refs,
    downloadedOnly: _keyOf(token).downloadedOnly,
  );

  RecentsFilterKey _keyOf(HistorySnapshotToken token) {
    final key = token.filterKey;
    if (key is! RecentsFilterKey) {
      throw ArgumentError.value(
        token,
        'token',
        'not captured by RecentsSnapshotPager',
      );
    }
    return key;
  }

  @override
  Future<SnapshotPageResult<ResolvedRecent, RecentRef>> page(
    HistorySnapshotToken token,
    RecentRef? after,
    int limit,
  ) {
    final key = _keyOf(token);
    // The boundary applies before dedupe inside the repository; the counters
    // are validated and the rows read in one transaction by readPage.
    return _snapshots.readPage<ResolvedRecent, RecentRef>(
      token,
      limit: limit,
      fetch: (n) => _recents.page(
        boundaryLocalId: token.boundaryLocalId,
        after: after,
        limit: n,
        downloadedOnly: key.downloadedOnly,
      ),
      cursorOf: (r) => r.ref,
    );
  }
}

final recentsSnapshotPagerProvider = Provider<RecentsSnapshotPager>(
  (ref) => RecentsSnapshotPager(
    ref.read(historySnapshotServiceProvider),
    ref.read(recentlyPlayedRepositoryProvider),
    ref.read(snapshotFreshnessProvider),
  ),
);
