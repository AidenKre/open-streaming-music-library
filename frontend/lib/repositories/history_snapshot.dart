import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/clock.dart';

/// SC-10: an immutable marker of "what history looked like" when a view
/// captured it. Compared by value; a token is never mutated, a new one is
/// captured on entry, refresh or filter change.
class HistorySnapshotToken {
  const HistorySnapshotToken({
    required this.boundaryLocalId,
    required this.historyContentVersion,
    this.catalogAttributionVersion,
    required this.capturedNowUtcMs,
    required this.filterKey,
  });

  /// `MAX(history_events.local_id)` at capture; 0 means "before every event"
  /// (the table was empty).
  final int boundaryLocalId;

  /// SC-11 `history_content` counter at capture; 0 means never bumped.
  final int historyContentVersion;

  /// SC-11 `catalog_attribution` counter, or null when the capturing phase
  /// does not track it. Null (unknown) is not the same as 0.
  final int? catalogAttributionVersion;

  /// SC-20 clock reading (UTC ms) at capture.
  final int capturedNowUtcMs;

  /// Opaque view selector (chip / range / policy) the token was captured for.
  /// Must have value equality (a record, enum, string or value class): the
  /// token keys provider families, so an identity-equal key churns watchers.
  final Object filterKey;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HistorySnapshotToken &&
          other.boundaryLocalId == boundaryLocalId &&
          other.historyContentVersion == historyContentVersion &&
          other.catalogAttributionVersion == catalogAttributionVersion &&
          other.capturedNowUtcMs == capturedNowUtcMs &&
          other.filterKey == filterKey;

  @override
  int get hashCode => Object.hash(
    boundaryLocalId,
    historyContentVersion,
    catalogAttributionVersion,
    capturedNowUtcMs,
    filterKey,
  );

  @override
  String toString() =>
      'HistorySnapshotToken(boundary: $boundaryLocalId, '
      'content: $historyContentVersion, '
      'attribution: $catalogAttributionVersion, '
      'now: $capturedNowUtcMs, filter: $filterKey)';
}

/// The outcome of one snapshot page read: a [SnapshotPage] or [SnapshotExpired].
sealed class SnapshotPageResult<T, K> {
  const SnapshotPageResult();
}

/// One keyset page. [nextCursor] is null on the final page (and on an empty
/// first page), which is the settled end state.
final class SnapshotPage<T, K> extends SnapshotPageResult<T, K> {
  const SnapshotPage(this.items, this.nextCursor);
  final List<T> items;
  final K? nextCursor;
  bool get hasMore => nextCursor != null;
}

/// The token's counters no longer match, so the snapshot is stale; the caller
/// must capture a new token. No rows were fetched.
final class SnapshotExpired<T, K> extends SnapshotPageResult<T, K> {
  const SnapshotExpired();
}

/// Reads one page of a snapshot-bound list, starting after the keyset cursor
/// [after] (null for the first page).
abstract interface class SnapshotPager<T, K> {
  Future<SnapshotPageResult<T, K>> page(
    HistorySnapshotToken token,
    K? after,
    int limit,
  );
}

const _historyContentKey = 'history_content';
const _catalogAttributionKey = 'catalog_attribution';

/// A counter value by bound key; an absent row reads as 0.
const _counterExpr =
    'COALESCE((SELECT value FROM local_counters WHERE key = ?), 0)';

/// The one SELECT shared by capture, page re-validation and freshness.
/// Columns: `b` (MAX(local_id), 0 when empty) if [boundary], `h`
/// (history_content), and `a` (catalog_attribution) if [attribution]. A
/// non-empty [kinds] restricts `b` to events of those kinds (bound, never
/// interpolated).
Selectable<QueryRow> _snapshotSelect(
  AppDatabase db, {
  required bool boundary,
  required bool attribution,
  Set<String>? kinds,
}) {
  final kindList = kinds?.toList(growable: false) ?? const <String>[];
  final kindFilter = kindList.isEmpty
      ? ''
      : ' WHERE kind IN (${List.filled(kindList.length, '?').join(', ')})';
  final cols = <String>[
    if (boundary)
      '(SELECT COALESCE(MAX(local_id), 0) FROM history_events$kindFilter) AS b',
    '$_counterExpr AS h',
    if (attribution) '$_counterExpr AS a',
  ];
  return db.customSelect(
    'SELECT ${cols.join(', ')}',
    variables: [
      if (boundary) for (final kind in kindList) Variable.withString(kind),
      Variable.withString(_historyContentKey),
      if (attribution) Variable.withString(_catalogAttributionKey),
    ],
    readsFrom: {if (boundary) db.historyEvents, db.localCounters},
  );
}

/// Whether the counters the token carries differ from [row] (a
/// [_snapshotSelect] row). The attribution counter is compared only when the
/// token carries it.
bool _countersChanged(HistorySnapshotToken token, QueryRow row) {
  final attribution = token.catalogAttributionVersion;
  return row.read<int>('h') != token.historyContentVersion ||
      (attribution != null && row.read<int>('a') != attribution);
}

/// Captures [HistorySnapshotToken]s from local history.
class HistorySnapshotService {
  HistorySnapshotService(this._db, {required Clock clock}) : _clock = clock;

  final AppDatabase _db;
  final Clock _clock;

  /// Captures a token for [filterKey]. The boundary and the content counter
  /// are read in one read transaction so a writer cannot yield a mixed view.
  /// `catalogAttributionVersion` is left null.
  Future<HistorySnapshotToken> capture(Object filterKey) async {
    final row = await _db.transaction(
      () => _snapshotSelect(
        _db,
        boundary: true,
        attribution: false,
      ).getSingle(),
    );
    return HistorySnapshotToken(
      boundaryLocalId: row.read<int>('b'),
      historyContentVersion: row.read<int>('h'),
      capturedNowUtcMs: _clock.nowUtcMs(),
      filterKey: filterKey,
    );
  }

  /// Reads one keyset page bound to [token]. In ONE read transaction it first
  /// re-reads the counters the token names and returns [SnapshotExpired]
  /// (without calling [fetch]) on any mismatch; otherwise it calls [fetch]
  /// with `limit + 1` rows, returns the first [limit] and a cursor (from
  /// [cursorOf] on the last returned item) only when a further row exists.
  ///
  /// [fetch] runs inside that transaction: it must issue all of its own
  /// reads from within the callback (never await a future or stream started
  /// outside it, which would wait on this transaction forever), and it must
  /// return rows that are already eligible (filtered and hydrated), because
  /// `hasMore` and the cursor are derived from what it returns.
  /// Throws [ArgumentError] when [limit] is not positive.
  Future<SnapshotPageResult<T, K>> readPage<T, K>(
    HistorySnapshotToken token, {
    required int limit,
    required Future<List<T>> Function(int fetchLimit) fetch,
    required K Function(T item) cursorOf,
  }) async {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'must be positive');
    }
    return _db.transaction<SnapshotPageResult<T, K>>(() async {
      final row = await _snapshotSelect(
        _db,
        boundary: false,
        attribution: token.catalogAttributionVersion != null,
      ).getSingle();
      if (_countersChanged(token, row)) return SnapshotExpired<T, K>();
      final rows = await fetch(limit + 1);
      final items = List<T>.unmodifiable(rows.take(limit));
      return SnapshotPage<T, K>(
        items,
        rows.length > limit ? cursorOf(items.last) : null,
      );
    });
  }
}

final historySnapshotServiceProvider = Provider<HistorySnapshotService>(
  (ref) => HistorySnapshotService(
    ref.read(databaseProvider),
    clock: ref.read(clockProvider),
  ),
);

/// How a token compares with current local history.
enum SnapshotStaleness {
  /// Nothing relevant changed since capture.
  fresh,

  /// Events were inserted after the token's boundary.
  newActivity,

  /// A counter named by the token changed (content rewritten); takes
  /// precedence over [newActivity].
  historyChanged,
}

/// Watches local history against a [HistorySnapshotToken].
class SnapshotFreshness {
  SnapshotFreshness(this._db);

  final AppDatabase _db;

  /// Emits the token's staleness whenever it changes (distinct values only).
  /// Compares the insertion boundary (MAX local_id) and the counters the
  /// token carries; an uncarried counter is ignored.
  ///
  /// With [kinds], the boundary is the MAX local_id over events of those
  /// kinds only, compared with the token's global boundary (local ids only
  /// grow, so a scoped max above it is a new event of those kinds); events
  /// of other kinds leave the scope fresh. Counters are unscoped. An empty
  /// [kinds] throws [ArgumentError].
  Stream<SnapshotStaleness> watch(HistorySnapshotToken token,
      {Set<String>? kinds}) {
    if (kinds != null && kinds.isEmpty) {
      throw ArgumentError.value(kinds, 'kinds', 'must not be empty');
    }
    return _snapshotSelect(
      _db,
      boundary: true,
      kinds: kinds,
      attribution: token.catalogAttributionVersion != null,
    ).watchSingle().map((row) {
      if (_countersChanged(token, row)) return SnapshotStaleness.historyChanged;
      return row.read<int>('b') > token.boundaryLocalId
          ? SnapshotStaleness.newActivity
          : SnapshotStaleness.fresh;
    }).distinct();
  }
}

final snapshotFreshnessProvider = Provider<SnapshotFreshness>(
  (ref) => SnapshotFreshness(ref.read(databaseProvider)),
);
