import 'dart:math' show min;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/collection_ref.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/table_watch.dart';

/// The entity kinds a recent can be. Any other `entity_type` in history is
/// kept in history but never surfaces as a recent.
enum RecentEntityType { track, album, artist }

/// One deduped recent: an entity and its newest clicked event. Also the
/// keyset tuple, sorted `(occurredAt DESC, eventUuid DESC, type DESC,
/// ref DESC)` with binary text comparison.
@immutable
final class RecentRef {
  const RecentRef({
    required this.type,
    required this.ref,
    required this.occurredAt,
    required this.eventUuid,
  });

  final RecentEntityType type;
  final String ref;
  final int occurredAt;
  final String eventUuid;

  @override
  bool operator ==(Object other) =>
      other is RecentRef &&
      other.type == type &&
      other.ref == ref &&
      other.occurredAt == occurredAt &&
      other.eventUuid == eventUuid;

  @override
  int get hashCode => Object.hash(type, ref, occurredAt, eventUuid);

  @override
  String toString() => 'RecentRef(${type.name}, $ref, $occurredAt, $eventUuid)';
}

/// A recent hydrated for display. [entity] is the track, album or artist
/// read model (`TrackUI` / `AlbumUI` / `ArtistUI`).
@immutable
final class ResolvedRecent {
  const ResolvedRecent({
    required this.ref,
    required this.entity,
  });

  final RecentRef ref;
  final Object entity;
}

class RecentlyPlayedRepository {
  RecentlyPlayedRepository(this._db, this._browse);

  final AppDatabase _db;
  final BrowseRepository _browse;

  /// The SQL stage alone: deduped, eligible refs in tuple order, before the
  /// Dart re-validation and hydration.
  @visibleForTesting
  Future<List<RecentRef>> eligibleRefs({
    int? boundaryLocalId,
    RecentRef? after,
    required int limit,
    bool downloadedOnly = false,
  }) async {
    final (sql, vars) = _eligibleRefsSql(
      boundaryLocalId: boundaryLocalId,
      after: after,
      limit: limit,
      downloadedOnly: downloadedOnly,
    );
    final rows = await _db
        .customSelect(
          sql,
          variables: vars,
          readsFrom: _readsFrom,
        )
        .get();
    return [
      for (final row in rows)
        RecentRef(
          type: RecentEntityType.values.byName(row.read<String>('entity_type')),
          ref: row.read<String>('entity_ref'),
          occurredAt: row.read<int>('occurred_at'),
          eventUuid: row.read<String>('event_uuid'),
        ),
    ];
  }

  /// One keyset page of hydrated recents (Phase 6 §6).
  ///
  /// Returns up to [limit] entries, all eligible and hydrated, in tuple order;
  /// fewer only when history is exhausted. The caller derives its cursor from
  /// the last returned entry's `ref`. Entities that vanish between the SQL
  /// stage and hydration, or whose collection ref fails the Dart
  /// `CollectionRef.tryParse` re-check, are dropped and the slice is refilled
  /// from the next eligible refs, so a wrong replacement is never rendered.
  ///
  /// Opens no transaction of its own and awaits nothing started outside the
  /// call, so it is safe inside `HistorySnapshotService.readPage`'s
  /// transaction. Hydration is batched: one query per kind per round, never
  /// one per card. Throws [ArgumentError] when [limit] is not positive.
  Future<List<ResolvedRecent>> page({
    required int boundaryLocalId,
    RecentRef? after,
    required int limit,
    bool downloadedOnly = false,
  }) => _read(
    boundaryLocalId: boundaryLocalId,
    after: after,
    limit: limit,
    downloadedOnly: downloadedOnly,
  );

  /// The one table list eligibility and hydration read (Phase 6 §6, plus
  /// `server_binding` for catalog readiness, D10). Both the SQL stage's
  /// `readsFrom` and the live stream's trigger use it.
  Set<ResultSetImplementation> get _readsFrom => {
    _db.historyEvents,
    _db.tracks,
    _db.trackmetadata,
    _db.albums,
    _db.artists,
    _db.serverBinding,
  };

  /// The fill loop behind [page] and [watchRecent]; [boundaryLocalId] null
  /// reads live history.
  Future<List<ResolvedRecent>> _read({
    int? boundaryLocalId,
    RecentRef? after,
    required int limit,
    required bool downloadedOnly,
  }) async {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit', 'must be > 0');
    final binding = await ServerBindingRepository(_db).current();
    final instanceId = binding?.instanceId ?? '';
    final out = <ResolvedRecent>[];
    var cursor = after;
    while (out.length < limit) {
      final want = limit - out.length;
      final refs = await eligibleRefs(
        boundaryLocalId: boundaryLocalId,
        after: cursor,
        limit: want,
        downloadedOnly: downloadedOnly,
      );
      if (refs.isEmpty) break;
      out.addAll(await _resolve(refs, instanceId, downloadedOnly));
      // The last examined ref, not the last kept one, so every round advances.
      cursor = refs.last;
      if (refs.length < want) break; // history exhausted
    }
    return out;
  }

  /// Hydrates one batch of refs, preserving their order and dropping any whose
  /// entity did not come back.
  Future<List<ResolvedRecent>> _resolve(
    List<RecentRef> refs,
    String instanceId,
    bool downloadedOnly,
  ) async {
    // Collection ids by ref string; null parse means the ref is dropped.
    final collectionIds = <RecentRef, int>{};
    final trackUuids = <String>[];
    final albumIds = <int>[];
    final artistIds = <int>[];
    for (final r in refs) {
      switch (r.type) {
        case RecentEntityType.track:
          trackUuids.add(r.ref);
        case RecentEntityType.album:
        case RecentEntityType.artist:
          final parsed = CollectionRef.tryParse(
            r.ref,
            boundInstanceId: instanceId,
          );
          if (parsed == null) continue;
          collectionIds[r] = parsed.id;
          (r.type == RecentEntityType.album ? albumIds : artistIds).add(
            parsed.id,
          );
      }
    }

    final tracks = trackUuids.isEmpty
        ? const <TrackUI>[]
        : await _browse.getTracksByUuids(trackUuids);
    final albums = albumIds.isEmpty
        ? const <AlbumUI>[]
        : await _browse.getAlbumsByIds(
            albumIds,
            downloadedArtOnly: downloadedOnly,
          );
    final artists = artistIds.isEmpty
        ? const <ArtistUI>[]
        : await _browse.getArtistsByIds(
            artistIds,
            downloadedArtOnly: downloadedOnly,
          );

    final trackByUuid = {for (final t in tracks) t.uuidId: t};
    final albumById = {for (final a in albums) a.id: a};
    final artistById = {for (final a in artists) a.id: a};

    final out = <ResolvedRecent>[];
    for (final r in refs) {
      switch (r.type) {
        case RecentEntityType.track:
          final t = trackByUuid[r.ref];
          if (t == null) continue;
          out.add(ResolvedRecent(ref: r, entity: t));
        case RecentEntityType.album:
          final id = collectionIds[r];
          final a = id == null ? null : albumById[id];
          if (a == null) continue;
          out.add(ResolvedRecent(ref: r, entity: a));
        case RecentEntityType.artist:
          final id = collectionIds[r];
          final a = id == null ? null : artistById[id];
          if (a == null) continue;
          out.add(ResolvedRecent(ref: r, entity: a));
      }
    }
    return out;
  }

  /// Live hydration of exactly [refs], in the given order (See all's loaded
  /// rows: payloads and download badges update, order never does).
  ///
  /// Emits on listen and after every change of the tables eligibility reads.
  /// A ref that no longer passes the SQL eligibility rule (the one
  /// [eligibleRefs] applies, restricted to these refs) or whose collection ref
  /// fails the Dart re-check is dropped, and a dropped ref stays dropped for the life
  /// of this stream: newly eligible rows wait for an explicit Refresh.
  Stream<List<ResolvedRecent>> watchResolved(
    List<RecentRef> refs, {
    bool downloadedOnly = false,
  }) {
    var live = refs.toList();
    return watchTables(_db, _readsFrom, () async {
      final binding = await ServerBindingRepository(_db).current();
      final eligible = await _eligibleAmong(live, downloadedOnly);
      final resolved = await _resolve(
        [
          for (final r in live)
            if (eligible.contains((r.type.name, r.ref))) r,
        ],
        binding?.instanceId ?? '',
        downloadedOnly,
      );
      live = [for (final r in resolved) r.ref];
      return resolved;
    });
  }

  /// The (type name, ref) pairs among [refs] that pass the SQL eligibility
  /// rule now, the same rule as [eligibleRefs] (not sourced from history).
  Future<Set<(String, String)>> _eligibleAmong(
    List<RecentRef> refs,
    bool downloadedOnly,
  ) async {
    final out = <(String, String)>{};
    for (var i = 0; i < refs.length; i += _eligibilityChunk) {
      final chunk = refs.sublist(i, min(i + _eligibilityChunk, refs.length));
      final (sql, vars) = _restrictedEligibilitySql(chunk, downloadedOnly);
      final rows = await _db
          .customSelect(sql, variables: vars, readsFrom: _readsFrom)
          .get();
      for (final row in rows) {
        out.add((row.read<String>('entity_type'), row.read<String>('entity_ref')));
      }
    }
    return out;
  }

  /// Whether any clicked entity passes the eligibility rule without the
  /// download filter: the one SQL stage ([_eligibleRefsSql], limit 1), no
  /// hydration. Emits distinct values, re-evaluated on every write to
  /// [_readsFrom].
  Stream<bool> watchHasEligibleHistory() {
    final (sql, vars) = _eligibleRefsSql(
      boundaryLocalId: null,
      after: null,
      limit: 1,
      downloadedOnly: false,
    );
    return _db
        .customSelect(sql, variables: vars, readsFrom: _readsFrom)
        .watch()
        .map((rows) => rows.isNotEmpty)
        .distinct();
  }

  /// The live Home stream: the newest [limit] hydrated recents, re-read
  /// whenever any table in [_readsFrom] changes (so a rename, art change,
  /// download completion, member delete or readiness flip updates it even with
  /// no new click). Each read runs in one transaction. At most one read is in
  /// flight: updates that arrive meanwhile, or while the subscription is
  /// paused, only mark the stream dirty and fold into one follow-up read, so
  /// the latest state always wins and a burst of writes costs a bounded number
  /// of reads. Nothing is shared between calls; cancelling stops everything.
  Stream<List<ResolvedRecent>> watchRecent({
    int limit = 20,
    bool downloadedOnly = false,
  }) {
    return watchTables(
      _db,
      _readsFrom,
      () => _read(limit: limit, downloadedOnly: downloadedOnly),
    );
  }
}

/// The history event kind recents are built from (the eligibility query and
/// the See all freshness scope both use it).
const recentsEventKind = HistoryKind.clicked;

/// Phase 6 §6: the deduped, eligible recents query. Dedupe ranks clicked
/// events per `(entity_type, entity_ref)` after the optional snapshot
/// boundary. Eligibility is checked before the keyset and LIMIT, so invalid
/// newest rows never starve valid older ones. Collection refs must carry the
/// bound instance prefix (computed here, in SQL) and a canonical positive
/// decimal: the CAST is only an index key, `CAST(id AS TEXT) = id_part`
/// proves the ref is exactly that id. Every value is bound, never interpolated.
(String, List<Variable>) _eligibleRefsSql({
  required int? boundaryLocalId,
  required RecentRef? after,
  required int limit,
  required bool downloadedOnly,
}) {
  final vars = <Variable>[];
  var boundary = '';
  if (boundaryLocalId != null) {
    boundary = ' AND local_id <= ?';
    vars.add(Variable.withInt(boundaryLocalId));
  }
  var afterClause = '';
  if (after != null) {
    afterClause =
        ' AND (r.occurred_at, r.event_uuid, r.entity_type, r.entity_ref) '
        '< (?, ?, ?, ?)';
    vars
      ..add(Variable.withInt(after.occurredAt))
      ..add(Variable.withString(after.eventUuid))
      ..add(Variable.withString(after.type.name))
      ..add(Variable.withString(after.ref));
  }
  vars.add(Variable.withInt(limit));
  final sql =
      'WITH ranked AS ('
      'SELECT entity_type, entity_ref, occurred_at, event_uuid, '
      'ROW_NUMBER() OVER (PARTITION BY entity_type, entity_ref '
      'ORDER BY occurred_at DESC, event_uuid COLLATE BINARY DESC) AS rn '
      'FROM history_events WHERE kind = \'$recentsEventKind\'$boundary'
      '), ${_recentStage()} '
      'SELECT r.entity_type, r.entity_ref, r.occurred_at, r.event_uuid '
      'FROM recent r WHERE ${_eligibilityPredicate(downloadedOnly)}'
      '$afterClause '
      'ORDER BY r.occurred_at DESC, '
      'r.event_uuid COLLATE BINARY DESC, '
      'r.entity_type COLLATE BINARY DESC, '
      'r.entity_ref COLLATE BINARY DESC '
      'LIMIT ?';
  return (sql, vars);
}

/// The `recent` stage of the eligibility rule: the rows of a CTE named
/// `ranked` (columns `entity_type`, `entity_ref`, `rn`; only `rn = 1` rows
/// count) joined with the server binding, computing `id_part` and `bound`.
/// Shared by the history query and the restricted re-check of live refs.
String _recentStage() => 'recent AS ('
    'SELECT r.*, '
    'substr(r.entity_ref, length(sb.instance_id) + 2) AS id_part, '
    '(sb.catalog_reconciled_at_binding = 1 '
    "AND sb.instance_id IS NOT NULL AND sb.instance_id <> '' "
    'AND substr(r.entity_ref, 1, length(sb.instance_id) + 1) '
    "= sb.instance_id || ':') AS bound "
    'FROM ranked r LEFT JOIN server_binding sb ON sb.id = 1 '
    'WHERE r.rn = 1'
    ')';

/// The one eligibility predicate over `recent r`: catalog existence, the
/// bound instance prefix with canonical digits, and (with [downloadedOnly])
/// the download predicates. No bound values.
String _eligibilityPredicate(bool downloadedOnly) {
  final trackDownloaded =
      downloadedOnly ? ' AND $usableDownloadPredicate' : '';
  final albumDownloaded =
      downloadedOnly ? ' AND ${hasDownloadedTrack('album_id', 'a.id')}' : '';
  final artistDownloaded =
      downloadedOnly ? ' AND ${hasDownloadedTrack('artist_id', 'ar.id')}' : '';
  return '('
      "(r.entity_type = 'track' AND EXISTS ("
      'SELECT 1 FROM tracks t '
      'JOIN trackmetadata tm ON tm.uuid_id = t.uuid_id '
      'WHERE t.uuid_id = r.entity_ref$trackDownloaded)) '
      "OR (r.entity_type IN ('album', 'artist') AND r.bound "
      "AND r.id_part GLOB '[1-9]*' AND r.id_part NOT GLOB '*[^0-9]*' AND ("
      "(r.entity_type = 'album' AND EXISTS ("
      'SELECT 1 FROM albums a JOIN artists ar ON a.artist_id = ar.id '
      'WHERE a.id = CAST(r.id_part AS INTEGER) '
      'AND CAST(a.id AS TEXT) = r.id_part$albumDownloaded)) '
      "OR (r.entity_type = 'artist' AND EXISTS ("
      'SELECT 1 FROM artists ar '
      'WHERE ar.id = CAST(r.id_part AS INTEGER) '
      'AND CAST(ar.id AS TEXT) = r.id_part$artistDownloaded))))'
      ')';
}

/// SQLite's default variable limit is far above this; refs are checked in
/// chunks of it, two bound values each.
const _eligibilityChunk = 500;

/// The (type, ref) pairs among [refs] (at most [_eligibilityChunk]) that pass
/// the eligibility rule, by the same stages as [_eligibleRefsSql] over a
/// VALUES source instead of history. All values are bound.
(String, List<Variable>) _restrictedEligibilitySql(
  List<RecentRef> refs,
  bool downloadedOnly,
) {
  final vars = <Variable>[
    for (final r in refs) ...[
      Variable.withString(r.type.name),
      Variable.withString(r.ref),
    ],
  ];
  final values = List.filled(refs.length, '(?, ?)').join(', ');
  final sql = 'WITH ranked AS ('
      'SELECT column1 AS entity_type, column2 AS entity_ref, 1 AS rn '
      'FROM (VALUES $values)'
      '), ${_recentStage()} '
      'SELECT r.entity_type, r.entity_ref '
      'FROM recent r WHERE ${_eligibilityPredicate(downloadedOnly)}';
  return (sql, vars);
}
