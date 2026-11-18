import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';

/// Phase 9 listening statistics (spec §2, §3): every aggregate of one range
/// read from local history in SQL, bounded by an insertion boundary.
class ListeningStatsRepository {
  /// [downloadedArtOnly] says whether covers must come from usable downloads
  /// only: offline the cards use the downloaded-only cover rule, like
  /// Recently Played (whose Downloaded filter auto-applies offline), so a
  /// cover never needs the network. Tracks are unaffected.
  ListeningStatsRepository(
    this._db,
    this._browse, {
    bool Function()? downloadedArtOnly,
  }) : _downloadedArtOnly = downloadedArtOnly ?? (() => false);

  final bool Function() _downloadedArtOnly;

  final AppDatabase _db;
  final BrowseRepository _browse;

  /// The statistics of [range] over history rows with `local_id <=`
  /// [boundaryLocalId], at [capturedNowUtcMs].
  ///
  /// Every read runs in one transaction, so totals, chart and lists come
  /// from one snapshot.
  Future<ListeningStats> load(
    StatsRange range,
    int boundaryLocalId,
    int capturedNowUtcMs,
  ) => _db.transaction(
    () => _load(range, boundaryLocalId, capturedNowUtcMs),
  );

  /// Counted listens within the boundary still waiting to upload, whatever
  /// their date.
  Future<int> pendingListens(int boundaryLocalId) async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS n FROM history_events '
          'WHERE $_baseFilter AND pending_upload = 1',
          variables: [
            Variable.withInt(boundaryLocalId),
            Variable.withReal(double.maxFinite),
          ],
          readsFrom: {_db.historyEvents},
        )
        .getSingle();
    return row.read<int>('n');
  }

  /// Whether any countable listen exists within the insertion boundary,
  /// whatever its date: tells "no history at all" from "none in this range".
  Future<bool> hasListens(int boundaryLocalId) async {
    final row = await _db
        .customSelect(
          'SELECT EXISTS(SELECT 1 FROM history_events '
          'WHERE $_baseFilter) AS present',
          variables: [
            Variable.withInt(boundaryLocalId),
            Variable.withReal(double.maxFinite),
          ],
          readsFrom: {_db.historyEvents},
        )
        .getSingle();
    return row.read<int>('present') == 1;
  }

  /// The UTC calendar years holding at least one counted listen (the
  /// filters of [load], started before [capturedNowUtcMs]) among rows with
  /// `local_id <=` [boundaryLocalId], newest first.
  Future<List<int>> listeningYears(
    int boundaryLocalId,
    int capturedNowUtcMs,
  ) async {
    final rows = await _db
        .customSelect(
          "SELECT DISTINCT CAST(strftime('%Y', occurred_at / 1000, "
          "'unixepoch') AS INTEGER) AS y FROM history_events "
          'WHERE $_baseFilter AND occurred_at < ?3 ORDER BY y DESC',
          variables: [
            Variable.withInt(boundaryLocalId),
            Variable.withReal(double.maxFinite),
            Variable.withInt(capturedNowUtcMs),
          ],
          readsFrom: {_db.historyEvents},
        )
        .get();
    return [for (final r in rows) r.read<int>('y')];
  }

  Future<ListeningStats> _load(
    StatsRange range,
    int boundaryLocalId,
    int capturedNowUtcMs,
  ) async {
    final window = range.resolve(capturedNowUtcMs);
    final vars = _vars(range, boundaryLocalId, capturedNowUtcMs);
    final totals = await _totals(vars);
    final overlong = await _overlongCount(vars);
    final plan = window.bucketPlan(
      earliestListenUtcMs: totals.read<int?>('earliest'),
    );
    final buckets = await _buckets(window, plan, vars);
    final trackRows = await _ranking(vars, _trackKey);
    final artistRows = await _ranking(vars, _artistKey);
    final albumRows = await _ranking(vars, _albumKey);
    final tracks = await _browse.getTracksByUuids([
      for (final r in trackRows) r.read<String>('k'),
    ]);
    final artists = await _browse.getArtistsByIds([
      for (final r in artistRows) r.read<int>('k'),
    ], downloadedArtOnly: _downloadedArtOnly());
    final albums = await _browse.getAlbumsByIds([
      for (final r in albumRows) r.read<int>('k'),
    ], downloadedArtOnly: _downloadedArtOnly());
    return ListeningStats(
      range: range,
      window: window,
      boundaryLocalId: boundaryLocalId,
      totals: ListeningTotals(
        listeningSeconds: totals.read<double>('secs'),
        qualifiedPlays: totals.read<int>('q'),
        uniqueTracks: totals.read<int>('uniq'),
        activeDays: totals.read<int>('days'),
      ),
      unavailable: ListeningSubtotal(
        listeningSeconds: totals.read<double>('u_secs'),
        qualifiedPlays: totals.read<int>('u_q'),
      ),
      futureTimestampCount: totals.read<int>('future'),
      overlongListenCount: overlong,
      buckets: buckets,
      chartCapped: plan.capped,
      topTracks: _entries(_ranked<TrackUI, String>(
          trackRows, tracks, (t) => t.uuidId)),
      topArtists:
          _entries(_ranked<ArtistUI, int>(artistRows, artists, (a) => a.id)),
      topAlbums:
          _entries(_ranked<AlbumUI, int>(albumRows, albums, (a) => a.id)),
    );
  }

  /// The positional variables ?1..?5 of the shared fragments.
  List<Variable> _vars(
    StatsRange range,
    int boundaryLocalId,
    int capturedNowUtcMs,
  ) {
    final window = range.resolve(capturedNowUtcMs);
    return [
      Variable.withInt(boundaryLocalId),
      Variable.withReal(double.maxFinite),
      Variable.withInt(window.countedEndUtcMs),
      Variable.withInt(window.startUtcMs ?? _minUtcMs),
      Variable.withInt(capturedNowUtcMs),
    ];
  }

  /// One row of totals, the unavailable subtotal, the future count and the
  /// earliest counted listen.
  Future<QueryRow> _totals(List<Variable> vars) => _db
      .customSelect(
        'SELECT '
        'COALESCE(SUM(CASE WHEN $_inRange THEN seconds_played END), 0.0) '
        'AS secs, '
        'COUNT(CASE WHEN $_inRange AND $_qualified THEN 1 END) AS q, '
        'COUNT(DISTINCT CASE WHEN $_inRange AND $_qualified '
        'THEN entity_ref END) AS uniq, '
        'COUNT(DISTINCT CASE WHEN $_inRange '
        'THEN occurred_at / 86400000 END) AS days, '
        'COALESCE(SUM(CASE WHEN $_inRange AND NOT $_resolvable '
        'THEN seconds_played END), 0.0) AS u_secs, '
        'COUNT(CASE WHEN $_inRange AND $_qualified AND NOT $_resolvable '
        'THEN 1 END) AS u_q, '
        'COUNT(CASE WHEN occurred_at >= ?5 THEN 1 END) AS future, '
        'MIN(CASE WHEN $_inRange THEN occurred_at END) AS earliest '
        'FROM history_events WHERE $_baseFilter',
        variables: vars,
        readsFrom: {_db.historyEvents, _db.tracks, _db.trackmetadata},
      )
      .getSingle();

  /// Finite play rows above [maxListenSeconds] (any track) that started in
  /// the counted window or at/after the captured now: excluded from every
  /// statistic, counted here whatever their date. An overlong row is never in
  /// the future count.
  Future<int> _overlongCount(List<Variable> vars) async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS n FROM history_events '
          'WHERE $_playRows '
          'AND seconds_played > $maxListenSeconds AND seconds_played <= ?2 '
          'AND ($_inRange OR occurred_at >= ?5)',
          variables: vars,
          readsFrom: {_db.historyEvents},
        )
        .getSingle();
    return row.read<int>('n');
  }

  /// The zero-filled chart: one grouped sum, then a walk over the plan.
  Future<List<ListeningBucket>> _buckets(
    StatsWindow window,
    StatsBucketPlan plan,
    List<Variable> vars,
  ) async {
    if (plan.spans.isEmpty) return const [];
    final isDay = window.unit == StatsBucketUnit.day;
    final keyExpr = isDay
        ? 'occurred_at / 86400000'
        : "strftime('%Y-%m', occurred_at / 1000, 'unixepoch')";
    final rows = await _db
        .customSelect(
          'SELECT $keyExpr AS k, SUM(seconds_played) AS secs '
          'FROM history_events '
          'WHERE $_baseFilter AND $_inRange AND occurred_at >= ?6 '
          'GROUP BY k',
          variables: [...vars, Variable.withInt(plan.spans.first.startUtcMs)],
          readsFrom: {_db.historyEvents},
        )
        .get();
    final byKey = {
      for (final r in rows) r.data['k'].toString(): r.read<double>('secs'),
    };
    return [
      for (final span in plan.spans)
        ListeningBucket(
          startUtcMs: span.startUtcMs,
          endUtcMs: span.endUtcMs,
          listeningSeconds:
              byKey[isDay
                  ? (span.startUtcMs ~/ 86400000).toString()
                  : _monthKey(span.startUtcMs)] ??
              0.0,
        ),
    ];
  }

  /// Rows `(k, micros, q)` grouped by [keyExpr] (a SQL expression over a
  /// history row; NULL = not ranked), ranked by seconds, qualified plays,
  /// then key. Seconds are summed as integer microseconds so equal recorded
  /// time ties exactly whatever the split (double sums differ in the last bit).
  /// With [after] only rows strictly after that keyset position are returned.
  /// The one ranking definition: the top lists and the paged lists share it.
  Future<List<QueryRow>> _ranking(
    List<Variable> vars,
    String keyExpr, {
    RankCursor<Object>? after,
    int limit = _topLimit,
  }) {
    final keyVar = switch (after?.key) {
      final int k => Variable.withInt(k),
      final String k => Variable.withString(k),
      null => null,
      final k => throw ArgumentError.value(
          k, 'after.key', 'must be an int or a String'),
    };
    return _db
        .customSelect(
          'SELECT $keyExpr AS k, '
          'SUM(CAST(ROUND(seconds_played * 1000000) AS INTEGER)) AS micros, '
          'COUNT(CASE WHEN $_qualified THEN 1 END) AS q '
          'FROM history_events '
          'WHERE $_baseFilter AND $_inRange AND k IS NOT NULL '
          'GROUP BY k '
          '${after == null ? '' : 'HAVING micros < ?7 OR (micros = ?7 AND '
              '(q < ?8 OR (q = ?8 AND k > ?9))) '}'
          'ORDER BY micros DESC, q DESC, k ASC LIMIT ?6',
          variables: [
            ...vars,
            Variable.withInt(limit),
            if (after != null) ...[
              Variable.withInt(after.listeningMicros),
              Variable.withInt(after.qualifiedPlays),
              keyVar!,
            ],
          ],
          readsFrom: {
            _db.historyEvents,
            _db.tracks,
            _db.trackmetadata,
            _db.artists,
            _db.albums,
          },
        )
        .get();
  }

  /// The shown [trackUuids], [artistIds] and [albumIds] as they resolve now
  /// through the SC-12 resolvers: emitted on listen and again whenever the
  /// catalog tables change. Ids that no longer resolve are absent.
  Stream<CurrentStatsEntities> watchCurrent({
    List<String> trackUuids = const [],
    List<int> artistIds = const [],
    List<int> albumIds = const [],
  }) {
    late final StreamController<CurrentStatsEntities> out;
    StreamSubscription<Set<TableUpdate>>? sub;
    var closed = false;
    var dirty = false;
    var reading = false;

    // One read at a time, in order; changes arriving during a read coalesce
    // into one further read.
    Future<void> pump() async {
      if (reading) return;
      reading = true;
      try {
        while (dirty && !closed) {
          dirty = false;
          final current = await _db.transaction(() async {
            final tracks = trackUuids.isEmpty
                ? const <TrackUI>[]
                : await _browse.getTracksByUuids(trackUuids);
            final artists = artistIds.isEmpty
                ? const <ArtistUI>[]
                : await _browse.getArtistsByIds(
                    artistIds,
                    downloadedArtOnly: _downloadedArtOnly(),
                  );
            final albums = albumIds.isEmpty
                ? const <AlbumUI>[]
                : await _browse.getAlbumsByIds(
                    albumIds,
                    downloadedArtOnly: _downloadedArtOnly(),
                  );
            return CurrentStatsEntities(
              tracks: {for (final t in tracks) t.uuidId: t},
              artists: {for (final a in artists) a.id: a},
              albums: {for (final a in albums) a.id: a},
            );
          });
          if (!closed) out.add(current);
        }
      } catch (e, st) {
        if (!closed) out.addError(e, st);
      } finally {
        reading = false;
      }
    }

    out = StreamController<CurrentStatsEntities>(
      onListen: () {
        // Subscribed before the first read, so a change during it re-reads.
        sub = _db
            .tableUpdates(TableUpdateQuery.onAllTables(
                [_db.trackmetadata, _db.tracks, _db.albums, _db.artists]))
            .listen((_) {
          dirty = true;
          unawaited(pump());
        });
        dirty = true;
        unawaited(pump());
      },
      onCancel: () async {
        closed = true;
        await sub?.cancel();
      },
    );
    return out.stream;
  }

  /// One keyset page of the track ranking inside [range]'s window, hydrated
  /// (one SC-12 call) and in rank order. Each entry carries the cursor built
  /// from the row's exact integer microseconds, qualified plays and uuid.
  /// Plain reads: callers run it inside the snapshot service's page
  /// transaction.
  Future<List<RankedPageEntry<TrackUI, String>>> trackRanking(
    StatsRange range,
    int boundaryLocalId,
    int capturedNowUtcMs, {
    RankCursor<String>? after,
    required int limit,
  }) => _rankingPage<TrackUI, String>(
        range,
        boundaryLocalId,
        capturedNowUtcMs,
        keyExpr: _trackKey,
        after: after,
        limit: limit,
        hydrate: _browse.getTracksByUuids,
        idOf: (t) => t.uuidId,
      );

  /// One keyset page of the artist ranking (current catalog parent ids).
  Future<List<RankedPageEntry<ArtistUI, int>>> artistRanking(
    StatsRange range,
    int boundaryLocalId,
    int capturedNowUtcMs, {
    RankCursor<int>? after,
    required int limit,
  }) => _rankingPage<ArtistUI, int>(
        range,
        boundaryLocalId,
        capturedNowUtcMs,
        keyExpr: _artistKey,
        after: after,
        limit: limit,
        hydrate: (ids) => _browse.getArtistsByIds(
          ids,
          downloadedArtOnly: _downloadedArtOnly(),
        ),
        idOf: (a) => a.id,
      );

  /// One keyset page of the album ranking (current catalog parent ids).
  Future<List<RankedPageEntry<AlbumUI, int>>> albumRanking(
    StatsRange range,
    int boundaryLocalId,
    int capturedNowUtcMs, {
    RankCursor<int>? after,
    required int limit,
  }) => _rankingPage<AlbumUI, int>(
        range,
        boundaryLocalId,
        capturedNowUtcMs,
        keyExpr: _albumKey,
        after: after,
        limit: limit,
        hydrate: (ids) => _browse.getAlbumsByIds(
          ids,
          downloadedArtOnly: _downloadedArtOnly(),
        ),
        idOf: (a) => a.id,
      );

  /// The shared paged-ranking body: the same variables as [_load], the one
  /// ranking query, then hydration and the row-to-entry mapping.
  Future<List<RankedPageEntry<T, K>>> _rankingPage<T, K extends Object>(
    StatsRange range,
    int boundaryLocalId,
    int capturedNowUtcMs, {
    required String keyExpr,
    required RankCursor<K>? after,
    required int limit,
    required Future<List<T>> Function(List<K>) hydrate,
    required K Function(T) idOf,
  }) async {
    final vars = _vars(range, boundaryLocalId, capturedNowUtcMs);
    final rows = await _ranking(vars, keyExpr, after: after, limit: limit);
    final entities = await hydrate([for (final r in rows) r.read<K>('k')]);
    return _ranked<T, K>(rows, entities, idOf);
  }

  List<RankedEntry<T>> _entries<T, K>(List<RankedPageEntry<T, K>> l) =>
      [for (final e in l) e.entry];

  /// Ranked rows joined to their hydrated entities, in rank order; a row
  /// whose entity did not hydrate is skipped.
  List<RankedPageEntry<T, K>> _ranked<T, K extends Object>(
    List<QueryRow> rows,
    List<T> entities,
    K Function(T) idOf,
  ) {
    final byId = {for (final e in entities) idOf(e): e};
    return [
      for (final r in rows)
        if (byId[r.read<K>('k')] case final entity?)
          RankedPageEntry(
            RankedEntry(
              entity: entity,
              listeningSeconds: r.read<int>('micros') / 1e6,
              qualifiedPlays: r.read<int>('q'),
            ),
            RankCursor<K>(
              listeningMicros: r.read<int>('micros'),
              qualifiedPlays: r.read<int>('q'),
              key: r.read<K>('k'),
            ),
          ),
    ];
  }
}

const _topLimit = 10;

/// The most seconds one listen row may carry and still count: seven days of
/// played audio, which no real listen of a single track reaches. Rows above
/// it are excluded from every statistic (reported through
/// `ListeningStats.overlongListenCount`), which keeps the integer-microsecond
/// ranking sum far from SQLite's 64-bit overflow (it would take more than 15
/// million rows of this length).
const maxListenSeconds = 7 * 24 * 3600.0;

/// The played track's uuid, only when the track still resolves.
const _trackKey = 'CASE WHEN $_resolvable THEN entity_ref END';

/// The played track's current artist, only when its `artists` row exists.
const _artistKey =
    '(SELECT tm.artist_id FROM tracks t '
    'JOIN trackmetadata tm ON tm.uuid_id = t.uuid_id '
    'JOIN artists ar ON ar.id = tm.artist_id WHERE t.uuid_id = entity_ref)';

/// The played track's current album, only when the album and its album
/// artist rows exist (the SC-12 album projection's join).
const _albumKey =
    '(SELECT tm.album_id FROM tracks t '
    'JOIN trackmetadata tm ON tm.uuid_id = t.uuid_id '
    'JOIN albums al ON al.id = tm.album_id '
    'JOIN artists aa ON aa.id = al.artist_id WHERE t.uuid_id = entity_ref)';

String _monthKey(int utcMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(utcMs, isUtc: true);
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}';
}

// SQL fragments shared by the aggregates. Positional variables: ?1 boundary
// local_id, ?2 double.maxFinite (SQLite stores +Infinity, so "finite" is
// `<= maxFinite`; the fragment itself bounds seconds by [maxListenSeconds],
// ?2 remains for the track-length checks), ?3 counted end, ?4 start (all
// time binds _minUtcMs), ?5 now.

/// Play events of tracks within the insertion boundary, whatever their
/// seconds.
const _playRows =
    "kind = 'play' AND entity_type = 'track' AND local_id <= ?1";

/// Finalized positive play events of tracks within the insertion boundary,
/// whose seconds are above zero and at most [maxListenSeconds]. The `?2`
/// (finite) check is implied by the bound; it stays so every statement using
/// this fragment keeps referencing ?2 and callers keep binding both variables.
const _baseFilter =
    '$_playRows AND seconds_played > 0 '
    'AND seconds_played <= $maxListenSeconds AND seconds_played <= ?2';

/// The event started inside the range's counted window.
const _inRange = '(occurred_at >= ?4 AND occurred_at < ?3)';

/// DateTime's minimum: stands in for "no start" so ?4 stays a plain bound
/// the `(kind, occurred_at)` index can use.
const _minUtcMs = -8640000000000000;

/// Seconds reach min(30, length / 2); an unknown, non-positive or infinite
/// length requires the full 30 seconds.
const _qualified =
    'seconds_played >= CASE WHEN track_length > 0 AND track_length <= ?2 '
    'THEN MIN(30.0, track_length / 2.0) ELSE 30.0 END';

/// The event's track still resolves (same join as `getTracksByUuids`).
const _resolvable =
    'EXISTS (SELECT 1 FROM tracks t JOIN trackmetadata tm '
    'ON tm.uuid_id = t.uuid_id WHERE t.uuid_id = entity_ref)';

final listeningStatsRepositoryProvider = Provider<ListeningStatsRepository>(
  (ref) => ListeningStatsRepository(
    ref.read(databaseProvider),
    ref.read(browseRepositoryProvider),
    downloadedArtOnly: () => ref.read(offlineModeProvider),
  ),
);

// Public aliases of the fragments above for other history readers (Phase 9B
// suggestion pools). Positional-variable contract: bind ?1 = boundary
// local_id (Variable.withInt) and ?2 = double.maxFinite (Variable.withReal);
// any further variables of the caller start at ?3.

/// [_baseFilter]: finalized positive play events of tracks within the boundary.
const playRowFilterSql = _baseFilter;

/// [_qualified]: seconds reach min(30, length / 2), else 30.
const qualifiedPlaySql = _qualified;

/// [_resolvable]: the event's track still has `tracks` and `trackmetadata`.
const resolvableTrackSql = _resolvable;

/// [_artistKey]: the played track's current artist id, when its row exists.
const currentArtistKeySql = _artistKey;
