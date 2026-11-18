import 'package:drift/drift.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/history_snapshot.dart';

/// A toy SC-10 consumer (6-U10: the primitives are generic, proven by a
/// second consumer with no See-all or recents types): plain history events
/// of the kind named by the token's filterKey, newest first by
/// `(occurred_at DESC, event_uuid DESC)`, keyset-paged.
typedef ListenKey = ({int occurredAt, String eventUuid});

class ListenItem {
  const ListenItem(this.eventUuid, this.occurredAt);
  final String eventUuid;
  final int occurredAt;

  @override
  String toString() => '$eventUuid@$occurredAt';
}

class ToyListenPager implements SnapshotPager<ListenItem, ListenKey> {
  ToyListenPager(this._db, this._snapshots);
  final AppDatabase _db;
  final HistorySnapshotService _snapshots;

  /// How many times the keyset query ran (an expired page runs none).
  int fetches = 0;

  /// The fetch limits asked for, in order.
  final fetchLimits = <int>[];

  @override
  Future<SnapshotPageResult<ListenItem, ListenKey>> page(
    HistorySnapshotToken token,
    ListenKey? after,
    int limit,
  ) => _snapshots.readPage<ListenItem, ListenKey>(
    token,
    limit: limit,
    cursorOf: (item) => (occurredAt: item.occurredAt, eventUuid: item.eventUuid),
    fetch: (fetchLimit) async {
      fetches++;
      fetchLimits.add(fetchLimit);
      final rows = await _db.customSelect(
        'SELECT event_uuid, occurred_at FROM history_events '
        'WHERE kind = ? AND local_id <= ? '
        '${after == null ? '' : 'AND (occurred_at < ? OR (occurred_at = ? AND event_uuid < ?)) '}'
        'ORDER BY occurred_at DESC, event_uuid DESC LIMIT ?',
        variables: [
          Variable.withString(token.filterKey as String),
          Variable.withInt(token.boundaryLocalId),
          if (after != null) ...[
            Variable.withInt(after.occurredAt),
            Variable.withInt(after.occurredAt),
            Variable.withString(after.eventUuid),
          ],
          Variable.withInt(fetchLimit),
        ],
        readsFrom: {_db.historyEvents},
      ).get();
      return [
        for (final r in rows)
          ListenItem(r.read<String>('event_uuid'), r.read<int>('occurred_at')),
      ];
    },
  );
}
