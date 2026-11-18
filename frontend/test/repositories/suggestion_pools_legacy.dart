// Fix 9-fix-r4-fe (live defect 9-L-03): the "More from your artists"
// candidate statement exactly as candidate aa5d50bd shipped it, kept as the
// reference the rewritten statement must match row for row. It ran one
// correlated `NOT EXISTS` over history_events per catalog track of a recent
// artist (history_events has no index on entity_ref, so each one walked the
// play rows), which stalled the app's database for minutes at 100,000 events.
// Used only by the equivalence and performance tests; never by the app.
import 'package:drift/drift.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/suggestions.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

const _sumMicrosSql = 'SUM(CAST(ROUND(seconds_played * 1000000) AS INTEGER))';

/// ?1 boundary, ?2 maxFinite, ?3 now, ?4 window start (as shipped).
const legacyRecentArtistsSql =
    'SELECT $currentArtistKeySql AS k, '
    '$_sumMicrosSql AS micros, '
    'COUNT(CASE WHEN $qualifiedPlaySql THEN 1 END) AS q '
    'FROM history_events '
    'WHERE $playRowFilterSql AND occurred_at >= ?4 AND occurred_at < ?3 '
    'AND k IS NOT NULL GROUP BY k HAVING q >= 1';

/// The shipped candidate statement (correlated NOT EXISTS per track).
const legacyArtistCandidatesSql =
    'SELECT t.uuid_id AS uuid, tm.artist_id AS artist_id, '
    'tm.title AS title, ($usableDownloadPredicate) AS downloaded '
    'FROM tracks t JOIN trackmetadata tm ON tm.uuid_id = t.uuid_id '
    'WHERE tm.artist_id IN (SELECT k FROM ($legacyRecentArtistsSql)) '
    'AND NOT EXISTS (SELECT 1 FROM history_events '
    'WHERE entity_ref = t.uuid_id AND $playRowFilterSql '
    'AND occurred_at < ?3 AND $qualifiedPlaySql)';

List<Variable<Object>> legacyVars(int boundary, int nowMs) => [
  Variable.withInt(boundary),
  Variable.withReal(double.maxFinite),
  Variable.withInt(nowMs),
  Variable.withInt(nowMs - recentArtistWindow.inMilliseconds),
];

/// The artist pools as the shipped repository built them.
Future<List<ArtistPool>> legacyArtistPools(
  AppDatabase db,
  int boundary,
  int nowMs,
) async {
  final vars = legacyVars(boundary, nowMs);
  final recent =
      await db.customSelect(legacyRecentArtistsSql, variables: vars).get();
  final rows =
      await db.customSelect(legacyArtistCandidatesSql, variables: vars).get();
  final byArtist = <int, List<SuggestionCandidate>>{};
  for (final r in rows) {
    final id = r.read<int>('artist_id');
    byArtist.putIfAbsent(id, () => []).add(
      SuggestionCandidate(
        uuid: r.read<String>('uuid'),
        artistId: id,
        title: r.read<String?>('title'),
        isDownloaded: r.read<int>('downloaded') != 0,
      ),
    );
  }
  return [
    for (final r in recent)
      ArtistPool(
        artistId: r.read<int>('k'),
        recentMicros: r.read<int>('micros'),
        recentQualifiedPlays: r.read<int>('q'),
        candidates: byArtist[r.read<int>('k')] ?? const [],
      ),
  ];
}
