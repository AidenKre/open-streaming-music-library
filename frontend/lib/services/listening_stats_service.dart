import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

/// One statistics snapshot (spec §4; SC-10): the token and every read made
/// under it.
class StatsSnapshot {
  const StatsSnapshot({
    required this.token,
    required this.stats,
    required this.hasHistory,
    required this.pendingListens,
  });
  final HistorySnapshotToken token;
  final ListeningStats stats;

  /// Any countable listen within the boundary, whatever its date.
  final bool hasHistory;

  /// Counted listens within the boundary still waiting to upload.
  final int pendingListens;
}

/// The statistics page's model-side snapshot read (9-R1-14).
class ListeningStatsService {
  ListeningStatsService(this._stats, this._snapshots);

  final ListeningStatsRepository _stats;
  final HistorySnapshotService _snapshots;

  /// The token and every read made under it, in one transaction.
  Future<StatsSnapshot> snapshot(StatsRange range) async {
    final (token, results) = await _snapshots.captureWith<List<Object>>(
      range,
      attribution: true,
      (token) => Future.wait<Object>([
        _stats.load(range, token.boundaryLocalId, token.capturedNowUtcMs),
        _stats.hasListens(token.boundaryLocalId),
        _stats.pendingListens(
          range,
          token.boundaryLocalId,
          token.capturedNowUtcMs,
        ),
      ], eagerError: true),
    );
    return StatsSnapshot(
      token: token,
      stats: results[0] as ListeningStats,
      hasHistory: results[1] as bool,
      pendingListens: results[2] as int,
    );
  }
}

final listeningStatsServiceProvider = Provider<ListeningStatsService>(
  (ref) => ListeningStatsService(
    ref.read(listeningStatsRepositoryProvider),
    ref.read(historySnapshotServiceProvider),
  ),
);
