import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/suggestions.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';

/// Phase 9B suggestion pools (spec §5 items 1–2): read from local history
/// and the local catalog over one snapshot.
class SuggestionPoolsRepository {
  SuggestionPoolsRepository(this._db);

  final AppDatabase _db;

  /// The pools over history rows with `local_id <=` [boundaryLocalId], at
  /// [capturedNowUtcMs], read in one transaction.
  Future<SuggestionPools> load(int boundaryLocalId, int capturedNowUtcMs) =>
      _db.transaction(() async {
        final rediscover = await _rediscover(boundaryLocalId, capturedNowUtcMs);
        final artists = await _artists(boundaryLocalId, capturedNowUtcMs);
        return SuggestionPools(
          boundaryLocalId: boundaryLocalId,
          capturedNowUtcMs: capturedNowUtcMs,
          rediscover: rediscover,
          artists: artists,
        );
      });

  /// Recently listened artists with their unplayed catalog tracks: two
  /// grouped queries, joined by artist id in Dart.
  Future<List<ArtistPool>> _artists(int boundary, int nowMs) async {
    final vars = [
      Variable.withInt(boundary),
      Variable.withReal(double.maxFinite),
      Variable.withInt(nowMs),
      Variable.withInt(nowMs - _recentArtistWindowMs),
    ];
    final recent = await _db
        .customSelect(
          _recentArtistsSql,
          variables: vars,
          readsFrom: {_db.historyEvents, _db.tracks, _db.trackmetadata},
        )
        .get();
    final rows = await _db
        .customSelect(
          'SELECT t.uuid_id AS uuid, tm.artist_id AS artist_id, '
          'tm.title AS title, ($usableDownloadPredicate) AS downloaded '
          'FROM tracks t JOIN trackmetadata tm ON tm.uuid_id = t.uuid_id '
          'WHERE tm.artist_id IN (SELECT k FROM ($_recentArtistsSql)) '
          // 9-L-03: uncorrelated, so the played set is built once instead of
          // scanning history_events per candidate track.
          'AND t.uuid_id NOT IN (SELECT entity_ref FROM history_events '
          'WHERE $playRowFilterSql '
          'AND occurred_at < ?3 AND $qualifiedPlaySql)',
          variables: vars,
          readsFrom: {_db.historyEvents, _db.tracks, _db.trackmetadata},
        )
        .get();
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

  /// Resolvable tracks with at least two qualified counted listens, the
  /// latest at least 14 days before [nowMs]; one grouped query.
  Future<List<RediscoverCandidate>> _rediscover(int boundary, int nowMs) async {
    final rows = await _db
        .customSelect(
          'SELECT e.entity_ref AS uuid, e.micros AS micros, e.q AS q, '
          'e.last_q AS last_q, tm.artist_id AS artist_id, '
          'tm.title AS title, '
          '($usableDownloadPredicate) AS downloaded '
          'FROM (SELECT entity_ref, '
          '$listeningMicrosSql AS micros, '
          'COUNT(CASE WHEN $qualifiedPlaySql THEN 1 END) AS q, '
          'MAX(CASE WHEN $qualifiedPlaySql THEN occurred_at END) AS last_q '
          'FROM history_events '
          'WHERE $playRowFilterSql AND occurred_at < ?3 '
          'AND $resolvableTrackSql '
          'GROUP BY entity_ref) e '
          'JOIN tracks t ON t.uuid_id = e.entity_ref '
          'JOIN trackmetadata tm ON tm.uuid_id = t.uuid_id '
          'WHERE e.q >= 2 AND e.last_q <= ?4',
          variables: [
            Variable.withInt(boundary),
            Variable.withReal(double.maxFinite),
            Variable.withInt(nowMs),
            Variable.withInt(nowMs - _rediscoverMinAgeMs),
          ],
          readsFrom: {_db.historyEvents, _db.tracks, _db.trackmetadata},
        )
        .get();
    return [
      for (final r in rows)
        RediscoverCandidate(
          track: SuggestionCandidate(
            uuid: r.read<String>('uuid'),
            artistId: r.read<int?>('artist_id'),
            title: r.read<String?>('title'),
            isDownloaded: r.read<int>('downloaded') != 0,
          ),
          listeningMicros: r.read<int>('micros'),
          qualifiedPlays: r.read<int>('q'),
          lastQualifiedAtUtcMs: r.read<int>('last_q'),
        ),
    ];
  }
}

final int _rediscoverMinAgeMs = rediscoverMinAge.inMilliseconds;
final int _recentArtistWindowMs = recentArtistWindow.inMilliseconds;

/// Recent artists: the artist key of counted listens in the window, kept when
/// at least one is qualified. ?1 boundary, ?2 maxFinite, ?3 now, ?4 window
/// start.
final String _recentArtistsSql =
    'SELECT $currentArtistKeySql AS k, '
    '$listeningMicrosSql AS micros, '
    'COUNT(CASE WHEN $qualifiedPlaySql THEN 1 END) AS q '
    'FROM history_events '
    'WHERE $playRowFilterSql AND occurred_at >= ?4 AND occurred_at < ?3 '
    'AND k IS NOT NULL GROUP BY k HAVING q >= 1';

final suggestionPoolsRepositoryProvider = Provider<SuggestionPoolsRepository>(
  (ref) => SuggestionPoolsRepository(ref.read(databaseProvider)),
);
