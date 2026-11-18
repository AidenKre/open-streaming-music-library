import 'dart:developer' as developer;
import 'dart:math' show min;
import 'package:drift/drift.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

abstract final class QueueItemTypes {
  static const main = 'main';
  static const manual = 'manual';
}

/// Direction in the effective queue order.
enum PlayOrderDirection { forward, backward }

class QueuePlaybackEntry {
  final int itemId;
  final String queueType;
  final int canonicalPosition;
  final int playPosition;
  final String uuidId;

  /// Local download path for this track, if it has a usable download (a
  /// damaged one, Phase 5 decision 6, reads null: it streams). The player
  /// consults this to prefer file:// playback over streaming.
  final String? filePath;

  /// The codec of the downloaded file (null: unknown or no download).
  final String? downloadedCodec;

  /// The source's codec, which an "original" stream passes through (null:
  /// unknown).
  final String? sourceCodec;

  const QueuePlaybackEntry({
    required this.itemId,
    required this.queueType,
    required this.canonicalPosition,
    required this.playPosition,
    required this.uuidId,
    this.filePath,
    this.downloadedCodec,
    this.sourceCodec,
  });
}

/// Columns of a [QueuePlaybackEntry] row (aliases `po`, `qsi`, `t`). The
/// file path is the usable download only (`usableDownloadPredicate`).
const _playbackEntryColumns =
    'po.item_id, qsi.queue_type, qsi.position AS canonical_position, '
    'po.play_position, qsi.uuid_id, '
    'CASE WHEN $usableDownloadPredicate THEN t.file_path END AS file_path, '
    't.downloaded_codec, '
    '(SELECT tm.codec FROM trackmetadata AS tm '
    'WHERE tm.uuid_id = qsi.uuid_id) AS source_codec';

class QueueTrackEntry extends QueuePlaybackEntry {
  final TrackUI track;

  const QueueTrackEntry({
    required super.itemId,
    required super.queueType,
    required super.canonicalPosition,
    required super.playPosition,
    required super.uuidId,
    required this.track,
  });
}

class QueueSessionSnapshot {
  final QueueSession session;
  final int totalCount;
  final QueuePlaybackEntry? currentItem;

  const QueueSessionSnapshot({
    required this.session,
    required this.totalCount,
    required this.currentItem,
  });
}

class QueueTrackRemovalResult {
  final Set<int> affectedSessionIds;

  /// Sessions whose current item was removed at the end of the queue with
  /// no wrap (repeat off or one): their current item now rests on the last
  /// survivor, and playback there must stop rather than go on.
  final Set<int> endedSessionIds;

  /// Every session whose removed current item got a landing decision in
  /// this call (ended or not): the latest verdict on [endedSessionIds] for
  /// these replaces any earlier one.
  final Set<int> relandedSessionIds;

  const QueueTrackRemovalResult({
    required this.affectedSessionIds,
    this.endedSessionIds = const {},
    this.relandedSessionIds = const {},
  });
}

/// The queue store. Every public writer is fenced (SC-01 rule 4, D16): the
/// repository belongs to one session scope, pins the binding token
/// (`local_binding_id`) on its first write, and runs each write in a
/// transaction that asserts the binding row still carries it. After a reset
/// (row deleted) or a re-bind (new row), this instance's writes throw
/// [BindingFencedException] and change nothing.
class QueueRepository {
  final AppDatabase _db;
  final ServerBindingRepository _binding;
  String? _token;
  bool _closed = false;

  QueueRepository(
    this._db, {
    ServerBindingRepository? binding,
  }) : _binding = binding ?? ServerBindingRepository(_db);

  /// Its session scope is gone: every later write is refused, so a lane step
  /// that outlives a reset can't pin the NEXT session's token.
  void close() => _closed = true;

  /// Runs [body] as one fenced write transaction, pinning the token on the
  /// first write. No binding row: refused, nothing pinned.
  Future<T> _fenced<T>(Future<T> Function() body) async {
    if (_closed) throw BindingFencedException('<closed>');
    var token = _token;
    if (token == null) {
      token = (await _binding.current())?.localBindingId;
      if (token == null) throw BindingFencedException('<no binding>');
      _token = token;
    }
    return _binding.runFenced(token, body);
  }

  /// Sessions this instance prepared inactive and has not yet activated or
  /// discarded, each with the play position of the target recorded for it
  /// (null until recorded); their activation is conditional (see
  /// [activateSession]).
  final _prepared = <int, int?>{};

  Future<int> createSessionFromQuery({
    required String sourceType,
    int? sourceArtistId,
    int? sourceAlbumId,
    required String currentUuid,
    List<OrderParameter> orderBy = const [],
    String repeatMode = 'off',
    bool shuffleEnabled = false,
    bool downloadedOnly = false,
    bool activate = true,
  }) {
    return _fenced(() async {
      if (activate) await _deactivateAll();

      final sessionId = await _createSessionRow(
        active: activate,
        sourceType: sourceType,
        sourceArtistId: sourceArtistId,
        sourceAlbumId: sourceAlbumId,
        repeatMode: repeatMode,
        shuffleEnabled: shuffleEnabled,
      );

      final (sql, args) = _buildTrackSessionInsertQuery(
        sessionId: sessionId,
        orderBy: orderBy,
        artistId: sourceArtistId,
        albumId: sourceAlbumId,
        downloadedOnly: downloadedOnly,
      );
      await _db.customStatement(sql, args);

      final count = await _countItems(sessionId);
      if (count == 0) {
        await (_db.delete(
          _db.queueSessions,
        )..where((s) => s.id.equals(sessionId))).go();
        throw StateError('Cannot create a queue session with no tracks');
      }

      await _seedPlayOrderFromCanonical(sessionId);

      final currentRow = await _db
          .customSelect(
            'SELECT item_id FROM queue_session_items '
            'WHERE session_id = ? AND uuid_id = ? '
            'ORDER BY position ASC '
            'LIMIT 1',
            variables: [
              Variable.withInt(sessionId),
              Variable.withString(currentUuid),
            ],
          )
          .getSingleOrNull();
      final currentItemId = currentRow?.read<int>('item_id');
      if (currentItemId == null) {
        throw StateError('Current track was not inserted into the queue');
      }

      await _setCurrentItem(sessionId, currentItemId);
      if (shuffleEnabled) {
        final futureMainIds = await getFutureMainItemIds(
          sessionId,
          currentItemId: currentItemId,
          usePlayOrder: false,
        );
        futureMainIds.shuffle();
        await _rebuildFutureSuffix(
          sessionId,
          currentItemId: currentItemId,
          mainFutureItemIds: futureMainIds,
        );
      }
      if (!activate) _prepared[sessionId] = null;
      return sessionId;
    });
  }

  Future<int> createSessionFromExplicitList({
    required String sourceType,
    int? sourceArtistId,
    int? sourceAlbumId,
    required List<String> trackUuids,
    int currentIndex = 0,
    String repeatMode = 'off',
    bool shuffleEnabled = false,
    bool activate = true,
    List<int>? playOrder,
  }) {
    return _fenced(() async {
      // A given play order is validated before anything is written.
      if (playOrder != null) {
        final seen = <int>{};
        if (playOrder.length != trackUuids.length ||
            !playOrder.every((i) => i >= 0 && i < trackUuids.length && seen.add(i))) {
          throw ArgumentError.value(playOrder, 'playOrder',
              'must be a permutation of 0..${trackUuids.length - 1}');
        }
      }
      if (activate) await _deactivateAll();

      final sessionId = await _createSessionRow(
        active: activate,
        sourceType: sourceType,
        sourceArtistId: sourceArtistId,
        sourceAlbumId: sourceAlbumId,
        repeatMode: repeatMode,
        shuffleEnabled: shuffleEnabled,
      );

      await _db.batch((batch) {
        for (var i = 0; i < trackUuids.length; i++) {
          batch.insert(
            _db.queueSessionItems,
            QueueSessionItemsCompanion.insert(
              sessionId: sessionId,
              queueType: const Value(QueueItemTypes.main),
              position: i,
              uuidId: trackUuids[i],
            ),
          );
        }
      });

      final count = await _countItems(sessionId);
      if (count == 0) {
        await (_db.delete(
          _db.queueSessions,
        )..where((s) => s.id.equals(sessionId))).go();
        throw StateError('Cannot create a queue session with no tracks');
      }

      if (playOrder != null) {
        final itemIdByPosition = {
          for (final row in await (_db.select(_db.queueSessionItems)
                ..where((r) =>
                    r.sessionId.equals(sessionId) &
                    r.queueType.equals(QueueItemTypes.main)))
              .get())
            row.position: row.itemId,
        };
        final orderedItemIds = [for (final i in playOrder) itemIdByPosition[i]!];
        await _replacePlayOrder(sessionId, orderedItemIds);
        await _setCurrentItem(sessionId, orderedItemIds.first);
        if (!activate) _prepared[sessionId] = null;
        return sessionId;
      }

      await _seedPlayOrderFromCanonical(sessionId);

      final safeIndex = currentIndex.clamp(0, count - 1);
      final currentRow = await _db
          .customSelect(
            'SELECT item_id FROM queue_session_items '
            'WHERE session_id = ? AND queue_type = ? AND position = ? '
            'LIMIT 1',
            variables: [
              Variable.withInt(sessionId),
              Variable.withString(QueueItemTypes.main),
              Variable.withInt(safeIndex),
            ],
          )
          .getSingleOrNull();
      final currentItemId = currentRow?.read<int>('item_id');
      if (currentItemId == null) {
        throw StateError('Current track was not inserted into the queue');
      }

      await _setCurrentItem(sessionId, currentItemId);
      if (shuffleEnabled) {
        final futureMainIds = await getFutureMainItemIds(
          sessionId,
          currentItemId: currentItemId,
          usePlayOrder: false,
        );
        futureMainIds.shuffle();
        await _rebuildFutureSuffix(
          sessionId,
          currentItemId: currentItemId,
          mainFutureItemIds: futureMainIds,
        );
      }
      if (!activate) _prepared[sessionId] = null;
      return sessionId;
    });
  }

  Future<QueueSession?> getActiveSession() {
    return (_db.select(_db.queueSessions)
          ..where((s) => s.isActive.equals(true))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<QueueSessionSnapshot?> getActiveSessionSnapshot() async {
    final session = await getActiveSession();
    if (session == null) return null;
    return getSessionSnapshot(session.id);
  }

  Future<QueueSessionSnapshot?> getSessionSnapshot(int sessionId) async {
    final session =
        await (_db.select(_db.queueSessions)
              ..where((s) => s.id.equals(sessionId))
              ..limit(1))
            .getSingleOrNull();
    if (session == null) return null;

    final totalCount = await _countItems(sessionId);
    var currentItem = session.currentItemId == null
        ? null
        : await getPlaybackEntryForItem(sessionId, session.currentItemId!);

    // current_item_id may be null (no current track yet) or dangle at a track
    // that was tombstone-deleted server-side (the INNER JOIN on tracks then
    // resolves it to null). Fall back to the first surviving entry so a queue
    // with remaining tracks stays restorable instead of resolving to null.
    if (currentItem == null && totalCount > 0) {
      final danglingId = session.currentItemId;
      if (danglingId != null) {
        final at = await _db.customSelect(
          'SELECT play_position FROM queue_session_play_order '
          'WHERE session_id = ? AND item_id = ?',
          variables: [Variable.withInt(sessionId), Variable.withInt(danglingId)],
        ).getSingleOrNull();
        if (at != null) {
          final nextId = await _nextSurvivorItemId(
              sessionId, at.read<int>('play_position'));
          if (nextId != null) {
            currentItem = await getPlaybackEntryForItem(sessionId, nextId);
          }
        }
      }
      currentItem ??= await getFirstPlayableEntry(sessionId);
    }

    return QueueSessionSnapshot(
      session: session,
      totalCount: totalCount,
      currentItem: currentItem,
    );
  }

  /// The item id of the first entry after [afterPlayPosition] in play order
  /// whose track row exists and whose track uuid is not in [removedUuids].
  Future<int?> _nextSurvivorItemId(
    int sessionId,
    int afterPlayPosition, {
    List<String> removedUuids = const [],
  }) async {
    final notRemoved = removedUuids.isEmpty
        ? ''
        : ' AND qsi.uuid_id NOT IN (${List.filled(removedUuids.length, '?').join(', ')})';
    final row = await _db.customSelect(
      'SELECT po.item_id AS item_id '
      'FROM queue_session_play_order AS po '
      'INNER JOIN queue_session_items AS qsi ON po.item_id = qsi.item_id '
      'INNER JOIN tracks AS t ON qsi.uuid_id = t.uuid_id '
      'WHERE po.session_id = ? AND po.play_position > ?$notRemoved '
      'ORDER BY po.play_position ASC LIMIT 1',
      variables: [
        Variable.withInt(sessionId),
        Variable.withInt(afterPlayPosition),
        for (final u in removedUuids) Variable.withString(u),
      ],
    ).getSingleOrNull();
    return row?.read<int>('item_id');
  }

  /// The item id of the last surviving entry before [beforePlayPosition] in
  /// play order (same survivor rule as [_nextSurvivorItemId]).
  Future<int?> _previousSurvivorItemId(
    int sessionId,
    int beforePlayPosition,
    List<String> removedUuids,
  ) async {
    final row = await _db.customSelect(
      'SELECT po.item_id AS item_id '
      'FROM queue_session_play_order AS po '
      'INNER JOIN queue_session_items AS qsi ON po.item_id = qsi.item_id '
      'INNER JOIN tracks AS t ON qsi.uuid_id = t.uuid_id '
      'WHERE po.session_id = ? AND po.play_position < ? '
      'AND qsi.uuid_id NOT IN (${List.filled(removedUuids.length, '?').join(', ')}) '
      'ORDER BY po.play_position DESC LIMIT 1',
      variables: [
        Variable.withInt(sessionId),
        Variable.withInt(beforePlayPosition),
        for (final u in removedUuids) Variable.withString(u),
      ],
    ).getSingleOrNull();
    return row?.read<int>('item_id');
  }

  /// The lowest-play-position entry whose track row still exists. Used as a
  /// recovery fallback when a session's `current_item_id` is null or points at
  /// a deleted track.
  Future<QueuePlaybackEntry?> getFirstPlayableEntry(int sessionId) async {
    final entries = await getPlaybackEntries(sessionId, limit: 1);
    return entries.isEmpty ? null : entries.first;
  }

  Future<List<QueuePlaybackEntry>> getPlaybackEntries(
    int sessionId, {
    int startPlayPosition = 0,
    int? limit,
  }) async {
    final variables = <Variable>[
      Variable.withInt(sessionId),
      Variable.withInt(startPlayPosition),
    ];

    var sql =
        'SELECT $_playbackEntryColumns '
        'FROM queue_session_play_order AS po '
        'INNER JOIN queue_session_items AS qsi ON po.item_id = qsi.item_id '
        'INNER JOIN tracks AS t ON qsi.uuid_id = t.uuid_id '
        'WHERE po.session_id = ? AND po.play_position >= ? '
        'ORDER BY po.play_position ASC';

    if (limit != null) {
      sql += ' LIMIT ?';
      variables.add(Variable.withInt(limit));
    }

    final rows = await _db.customSelect(sql, variables: variables).get();
    return rows.map(_playbackEntryFromRow).toList(growable: false);
  }

  Future<List<QueuePlaybackEntry>> getPlaybackEntriesForItemIds(
    int sessionId,
    Iterable<int> itemIds,
  ) async {
    final ids = itemIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const [];

    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await _db
        .customSelect(
          'SELECT $_playbackEntryColumns '
          'FROM queue_session_play_order AS po '
          'INNER JOIN queue_session_items AS qsi ON po.item_id = qsi.item_id '
          'INNER JOIN tracks AS t ON qsi.uuid_id = t.uuid_id '
          'WHERE po.session_id = ? AND po.item_id IN ($placeholders)',
          variables: [
            Variable.withInt(sessionId),
            ...ids.map(Variable.withInt),
          ],
        )
        .get();

    return rows.map(_playbackEntryFromRow).toList(growable: false);
  }

  /// The local-source fields of the tracks [uuids] (any order, duplicates
  /// allowed; unknown uuids are absent): the file path only when the
  /// download is usable, as in a [QueuePlaybackEntry].
  Future<Map<String, ({String? filePath, String? downloadedCodec})>>
      getLocalSourcesForUuids(Iterable<String> uuids) async {
    final unique = uuids.toSet().toList(growable: false);
    final result = <String, ({String? filePath, String? downloadedCodec})>{};
    const chunkSize = 500;
    for (var i = 0; i < unique.length; i += chunkSize) {
      final chunk = unique.sublist(i, min(i + chunkSize, unique.length));
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await _db
          .customSelect(
            'SELECT t.uuid_id, '
            'CASE WHEN $usableDownloadPredicate THEN t.file_path END '
            'AS file_path, t.downloaded_codec '
            'FROM tracks AS t WHERE t.uuid_id IN ($placeholders)',
            variables: chunk.map(Variable.withString).toList(),
          )
          .get();
      for (final row in rows) {
        result[row.read<String>('uuid_id')] = (
          filePath: row.readNullable<String>('file_path'),
          downloadedCodec: row.readNullable<String>('downloaded_codec'),
        );
      }
    }
    return result;
  }

  Future<QueuePlaybackEntry?> getPlaybackEntryForItem(
    int sessionId,
    int itemId,
  ) async {
    final row = await _db
        .customSelect(
          'SELECT $_playbackEntryColumns '
          'FROM queue_session_play_order AS po '
          'INNER JOIN queue_session_items AS qsi ON po.item_id = qsi.item_id '
          'INNER JOIN tracks AS t ON qsi.uuid_id = t.uuid_id '
          'WHERE po.session_id = ? AND po.item_id = ? '
          'LIMIT 1',
          variables: [Variable.withInt(sessionId), Variable.withInt(itemId)],
        )
        .getSingleOrNull();

    return row == null ? null : _playbackEntryFromRow(row);
  }

  Future<Map<int, int>> getPlayPositionsForItemIds(
    int sessionId,
    Iterable<int> itemIds,
  ) async {
    final ids = itemIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const {};

    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await _db
        .customSelect(
          'SELECT item_id, play_position '
          'FROM queue_session_play_order '
          'WHERE session_id = ? AND item_id IN ($placeholders)',
          variables: [
            Variable.withInt(sessionId),
            ...ids.map(Variable.withInt),
          ],
        )
        .get();

    return {
      for (final row in rows)
        row.read<int>('item_id'): row.read<int>('play_position'),
    };
  }

  Future<List<int>> getCanonicalItemIds(int sessionId) async {
    return getQueueTypeItemIds(sessionId, QueueItemTypes.main);
  }

  Future<List<int>> getQueueTypeItemIds(int sessionId, String queueType) async {
    final rows = await _db
        .customSelect(
          'SELECT item_id '
          'FROM queue_session_items '
          'WHERE session_id = ? AND queue_type = ? '
          'ORDER BY position ASC',
          variables: [
            Variable.withInt(sessionId),
            Variable.withString(queueType),
          ],
        )
        .get();
    return rows.map((row) => row.read<int>('item_id')).toList(growable: false);
  }

  Future<List<int>> getPlayOrderItemIds(
    int sessionId, {
    int startPlayPosition = 0,
    int? endPlayPosition,
    int? limit,
  }) async {
    final conditions = ['session_id = ?', 'play_position >= ?'];
    final variables = <Variable>[
      Variable.withInt(sessionId),
      Variable.withInt(startPlayPosition),
    ];

    if (endPlayPosition != null) {
      conditions.add('play_position <= ?');
      variables.add(Variable.withInt(endPlayPosition));
    }

    var sql =
        'SELECT item_id '
        'FROM queue_session_play_order '
        'WHERE ${conditions.join(' AND ')} '
        'ORDER BY play_position ASC';

    if (limit != null) {
      sql += ' LIMIT ?';
      variables.add(Variable.withInt(limit));
    }

    final rows = await _db.customSelect(sql, variables: variables).get();
    return rows.map((row) => row.read<int>('item_id')).toList(growable: false);
  }

  Future<List<int>> getFutureMainItemIds(
    int sessionId, {
    required int currentItemId,
    required bool usePlayOrder,
  }) async {
    final currentEntry = await getPlaybackEntryForItem(
      sessionId,
      currentItemId,
    );
    if (currentEntry == null) return const [];

    return _getFutureQueueTypeItemIds(
      sessionId,
      afterPlayPosition: currentEntry.playPosition,
      queueType: QueueItemTypes.main,
      orderByPlayOrder: usePlayOrder,
    );
  }

  Future<QueueTrackEntry?> getTrackForItem(int sessionId, int itemId) async {
    final rows = await _db
        .customSelect(
          'SELECT po.item_id, qsi.queue_type, qsi.position AS canonical_position, '
          'po.play_position, qsi.uuid_id, $trackSelectColumns '
          'FROM queue_session_play_order AS po '
          'INNER JOIN queue_session_items AS qsi ON po.item_id = qsi.item_id '
          'INNER JOIN trackmetadata AS tm ON qsi.uuid_id = tm.uuid_id '
          'INNER JOIN tracks AS t ON qsi.uuid_id = t.uuid_id '
          'WHERE po.session_id = ? AND po.item_id = ? '
          'LIMIT 1',
          variables: [Variable.withInt(sessionId), Variable.withInt(itemId)],
          readsFrom: {
            _db.queueSessionPlayOrder,
            _db.queueSessionItems,
            _db.trackmetadata,
            _db.tracks,
          },
        )
        .get();

    if (rows.isEmpty) return null;
    return _trackEntryFromRow(rows.first);
  }

  Future<List<QueueTrackEntry>> getSessionTracksInPlayOrder(
    int sessionId,
  ) async {
    final rows = await _db
        .customSelect(
          'SELECT po.item_id, qsi.queue_type, qsi.position AS canonical_position, '
          'po.play_position, qsi.uuid_id, $trackSelectColumns '
          'FROM queue_session_play_order AS po '
          'INNER JOIN queue_session_items AS qsi ON po.item_id = qsi.item_id '
          'INNER JOIN trackmetadata AS tm ON qsi.uuid_id = tm.uuid_id '
          'INNER JOIN tracks AS t ON qsi.uuid_id = t.uuid_id '
          'WHERE po.session_id = ? '
          'ORDER BY po.play_position ASC',
          variables: [Variable.withInt(sessionId)],
          readsFrom: {
            _db.queueSessionPlayOrder,
            _db.queueSessionItems,
            _db.trackmetadata,
            _db.tracks,
          },
        )
        .get();

    return rows.map(_trackEntryFromRow).toList(growable: false);
  }

  Future<List<QueueTrackEntry>> getSessionTracksPage(
    int sessionId, {
    required int startPlayPosition,
    required int limit,
  }) async {
    if (limit <= 0) return const [];

    final rows = await _db
        .customSelect(
          'SELECT po.item_id, qsi.queue_type, qsi.position AS canonical_position, '
          'po.play_position, qsi.uuid_id, $trackSelectColumns '
          'FROM queue_session_play_order AS po '
          'INNER JOIN queue_session_items AS qsi ON po.item_id = qsi.item_id '
          'INNER JOIN trackmetadata AS tm ON qsi.uuid_id = tm.uuid_id '
          'INNER JOIN tracks AS t ON qsi.uuid_id = t.uuid_id '
          'WHERE po.session_id = ? AND po.play_position >= ? '
          'ORDER BY po.play_position ASC '
          'LIMIT ?',
          variables: [
            Variable.withInt(sessionId),
            Variable.withInt(startPlayPosition),
            Variable.withInt(limit),
          ],
          readsFrom: {
            _db.queueSessionPlayOrder,
            _db.queueSessionItems,
            _db.trackmetadata,
            _db.tracks,
          },
        )
        .get();

    return rows.map(_trackEntryFromRow).toList(growable: false);
  }

  Future<void> updatePlaybackCursor({
    required int sessionId,
    required int currentItemId,
    required int positionMs,
  }) {
    // Conditional: a save naming an item that is no longer in the session
    // (the player has not reconciled a sync removal yet) must not write the
    // removed item back over the landing.
    return _fenced(
      () =>
          (_db.update(_db.queueSessions)..where(
                (s) =>
                    s.id.equals(sessionId) &
                    existsQuery(
                      _db.selectOnly(_db.queueSessionItems)
                        ..addColumns([_db.queueSessionItems.itemId])
                        ..where(
                          _db.queueSessionItems.sessionId.equals(sessionId) &
                              _db.queueSessionItems.itemId.equals(
                                currentItemId,
                              ),
                        ),
                    ),
              ))
              .write(
            QueueSessionsCompanion(
              currentItemId: Value(currentItemId),
              currentPositionMs: Value(positionMs),
              updatedAt: Value(_timestampSeconds()),
            ),
          ),
    );
  }

  Future<void> updateRepeatMode(int sessionId, String mode) {
    return _fenced(
      () =>
          (_db.update(
            _db.queueSessions,
          )..where((s) => s.id.equals(sessionId))).write(
            QueueSessionsCompanion(
              repeatMode: Value(mode),
              updatedAt: Value(_timestampSeconds()),
            ),
          ),
    );
  }

  Future<void> updateShuffleEnabled(int sessionId, bool enabled) {
    return _fenced(
      () =>
          (_db.update(
            _db.queueSessions,
          )..where((s) => s.id.equals(sessionId))).write(
            QueueSessionsCompanion(
              shuffleEnabled: Value(enabled),
              updatedAt: Value(_timestampSeconds()),
            ),
          ),
    );
  }

  Future<void> replacePlayOrder(int sessionId, List<int> itemIds) =>
      _fenced(() => _replacePlayOrder(sessionId, itemIds));

  Future<void> _replacePlayOrder(int sessionId, List<int> itemIds) async {
    await (_db.delete(
      _db.queueSessionPlayOrder,
    )..where((row) => row.sessionId.equals(sessionId))).go();

    await _db.batch((batch) {
      for (var i = 0; i < itemIds.length; i++) {
        batch.insert(
          _db.queueSessionPlayOrder,
          QueueSessionPlayOrderCompanion.insert(
            sessionId: sessionId,
            playPosition: i,
            itemId: itemIds[i],
          ),
        );
      }
    });

    await _touchSession(sessionId);
  }

  Future<void> rebuildFutureSuffix(
    int sessionId, {
    required int currentItemId,
    required List<int> mainFutureItemIds,
  }) => _fenced(
    () => _rebuildFutureSuffix(
      sessionId,
      currentItemId: currentItemId,
      mainFutureItemIds: mainFutureItemIds,
    ),
  );

  Future<void> _rebuildFutureSuffix(
    int sessionId, {
    required int currentItemId,
    required List<int> mainFutureItemIds,
  }) async {
    final currentEntry = await getPlaybackEntryForItem(
      sessionId,
      currentItemId,
    );
    if (currentEntry == null) return;

    final prefixIds = await getPlayOrderItemIds(
      sessionId,
      endPlayPosition: currentEntry.playPosition,
    );
    final manualFutureIds = await _getRemainingQueueTypeItemIds(
      sessionId,
      queueType: QueueItemTypes.manual,
      throughPlayPosition: currentEntry.playPosition,
    );

    await _replacePlayOrder(sessionId, [
      ...prefixIds,
      ...manualFutureIds,
      ...mainFutureItemIds,
    ]);
  }

  Future<void> prependManualItems(int sessionId, List<String> uuids) {
    return _fenced(() async {
      if (uuids.isEmpty) return;

      await _shiftSessionItemPositionsUp(
        sessionId: sessionId,
        queueType: QueueItemTypes.manual,
        afterPosition: -1,
        shift: uuids.length,
      );

      await _db.batch((batch) {
        for (var i = 0; i < uuids.length; i++) {
          batch.insert(
            _db.queueSessionItems,
            QueueSessionItemsCompanion.insert(
              sessionId: sessionId,
              queueType: const Value(QueueItemTypes.manual),
              position: i,
              uuidId: uuids[i],
            ),
          );
        }
      });

      final newItemIds = await _getManualItemIdsByPosition(
        sessionId,
        0,
        uuids.length,
      );
      await _appendToPlayOrder(sessionId, newItemIds);
      await _touchSession(sessionId);
    });
  }

  Future<void> appendManualItems(int sessionId, List<String> uuids) {
    return _fenced(() async {
      if (uuids.isEmpty) return;

      final startPosition = await _countQueueTypeItems(
        sessionId,
        QueueItemTypes.manual,
      );

      await _db.batch((batch) {
        for (var i = 0; i < uuids.length; i++) {
          batch.insert(
            _db.queueSessionItems,
            QueueSessionItemsCompanion.insert(
              sessionId: sessionId,
              queueType: const Value(QueueItemTypes.manual),
              position: startPosition + i,
              uuidId: uuids[i],
            ),
          );
        }
      });

      final newItemIds = await _getManualItemIdsByPosition(
        sessionId,
        startPosition,
        uuids.length,
      );
      await _appendToPlayOrder(sessionId, newItemIds);
      await _touchSession(sessionId);
    });
  }

  Future<void> removeItem(int sessionId, int itemId) {
    return _fenced(() async {
      final itemRow = await _db
          .customSelect(
            'SELECT queue_type, position '
            'FROM queue_session_items '
            'WHERE item_id = ? '
            'LIMIT 1',
            variables: [Variable.withInt(itemId)],
          )
          .getSingleOrNull();
      if (itemRow == null) return;

      final playRow = await _db
          .customSelect(
            'SELECT play_position '
            'FROM queue_session_play_order '
            'WHERE session_id = ? AND item_id = ? '
            'LIMIT 1',
            variables: [Variable.withInt(sessionId), Variable.withInt(itemId)],
          )
          .getSingleOrNull();
      if (playRow == null) return;

      final queueType = itemRow.read<String>('queue_type');
      final canonicalPosition = itemRow.read<int>('position');
      final playPosition = playRow.read<int>('play_position');

      await (_db.delete(_db.queueSessionPlayOrder)..where(
            (row) =>
                row.sessionId.equals(sessionId) & row.itemId.equals(itemId),
          ))
          .go();
      await _shiftPlayOrderPositionsDown(
        sessionId: sessionId,
        afterPosition: playPosition,
      );

      await (_db.delete(
        _db.queueSessionItems,
      )..where((row) => row.itemId.equals(itemId))).go();
      await _shiftSessionItemPositionsDown(
        sessionId: sessionId,
        queueType: queueType,
        afterPosition: canonicalPosition,
      );

      await _touchSession(sessionId);
    });
  }

  Future<QueueTrackRemovalResult> removeTrackUuidsFromQueues(
    List<String> uuids,
  ) {
    return _fenced(() => removeTrackUuidsFromQueuesInTransaction(uuids));
  }

  /// Unfenced: runs inside the caller's transaction, which must itself be
  /// fenced (SyncService applies a page under its own binding token).
  Future<QueueTrackRemovalResult> removeTrackUuidsFromQueuesInTransaction(
    List<String> uuids,
  ) async {
    if (uuids.isEmpty) {
      return const QueueTrackRemovalResult(affectedSessionIds: {});
    }

    final affectedSessionIds = await _queueSessionsContainingTracks(uuids);
    if (affectedSessionIds.isEmpty) {
      return const QueueTrackRemovalResult(affectedSessionIds: {});
    }

    final placeholders = List.filled(uuids.length, '?').join(', ');
    final itemIdSubquery =
        'SELECT item_id FROM queue_session_items WHERE uuid_id IN ($placeholders)';

    // Land each session whose current item is being removed, before the
    // play-order rows go (the removed current's play_position is needed).
    final removedCurrents = await _db.customSelect(
      'SELECT s.id AS session_id, s.repeat_mode AS repeat_mode, '
      'po.play_position AS play_position '
      'FROM queue_sessions AS s '
      'LEFT JOIN queue_session_play_order AS po '
      'ON po.session_id = s.id AND po.item_id = s.current_item_id '
      'WHERE s.current_item_id IN ($itemIdSubquery)',
      variables: [for (final u in uuids) Variable.withString(u)],
    ).get();
    final landings = <int, int?>{};
    final endedSessionIds = <int>{};
    for (final row in removedCurrents) {
      final sessionId = row.read<int>('session_id');
      final position = row.readNullable<int>('play_position');
      // A prepared, never-activated session is not playing: losing its
      // current item clears it so activation refuses (6A.1b). A current item
      // without a play-order row has no place to land from: cleared too.
      if (position == null || _prepared.containsKey(sessionId)) {
        landings[sessionId] = null;
        continue;
      }
      var landing = await _nextSurvivorItemId(sessionId, position,
          removedUuids: uuids);
      if (landing == null) {
        if (row.read<String>('repeat_mode') == 'all') {
          landing = await _nextSurvivorItemId(sessionId, -1,
              removedUuids: uuids);
        } else {
          landing = await _previousSurvivorItemId(sessionId, position, uuids);
          if (landing != null) endedSessionIds.add(sessionId);
        }
      }
      landings[sessionId] = landing;
    }

    await _db.customStatement(
      'DELETE FROM queue_session_play_order WHERE item_id IN ($itemIdSubquery)',
      uuids,
    );
    // Sessions whose current item is not removed keep it; removed currents
    // were landed above (NULL when nothing survives).
    for (final entry in landings.entries) {
      await _db.customStatement(
        'UPDATE queue_sessions '
        'SET current_item_id = ?, current_position_ms = 0 WHERE id = ?',
        [entry.value, entry.key],
      );
    }
    await (_db.delete(
      _db.queueSessionItems,
    )..where((t) => t.uuidId.isIn(uuids))).go();
    await _compactQueueSessionPositions(affectedSessionIds.toList());
    await _touchSessions(affectedSessionIds);

    return QueueTrackRemovalResult(
      affectedSessionIds: affectedSessionIds,
      endedSessionIds: endedSessionIds,
      relandedSessionIds: landings.keys.toSet(),
    );
  }

  Future<void> deactivateAll() => _fenced(_deactivateAll);

  /// Makes a prepared (inactive) session the active one (SC-27): in one
  /// fenced transaction the others are deactivated and it is activated. A
  /// session that no longer exists changes nothing and throws. A session
  /// prepared by this instance is activated conditionally: its current item
  /// must still be queued with its track, else (catalog sync removed it)
  /// nothing changes and it throws. Other sessions (the previous one being
  /// reactivated) activate unconditionally.
  Future<void> activateSession(int sessionId) => _fenced(() async {
        await _db.transaction(() async {
          final session = await (_db.select(_db.queueSessions)
                ..where((s) => s.id.equals(sessionId)))
              .getSingleOrNull();
          if (session == null) {
            throw StateError('Prepared session $sessionId is gone');
          }
          if (_prepared.containsKey(sessionId) &&
              !await _currentItemIsQueued(sessionId, session.currentItemId,
                  _prepared[sessionId])) {
            throw StateError(
                'Prepared session $sessionId lost its current item');
          }
          await _deactivateAll();
          await (_db.update(_db.queueSessions)
                ..where((s) => s.id.equals(sessionId)))
              .write(QueueSessionsCompanion(
            isActive: const Value(true),
            updatedAt: Value(_timestampSeconds()),
          ));
        });
        _prepared.remove(sessionId);
      });

  Future<bool> _currentItemIsQueued(
      int sessionId, int? itemId, int? expectedPlayPosition) async {
    if (itemId == null) return false;
    if (expectedPlayPosition != null) {
      final at = await _db.customSelect(
        'SELECT play_position FROM queue_session_play_order '
        'WHERE session_id = ? AND item_id = ?',
        variables: [Variable.withInt(sessionId), Variable.withInt(itemId)],
      ).getSingleOrNull();
      if (at?.read<int>('play_position') != expectedPlayPosition) return false;
    }
    final row = await _db.customSelect(
      'SELECT 1 FROM queue_session_items qsi '
      'INNER JOIN tracks AS t ON qsi.uuid_id = t.uuid_id '
      'WHERE qsi.session_id = ? AND qsi.item_id = ? LIMIT 1',
      variables: [Variable.withInt(sessionId), Variable.withInt(itemId)],
    ).getSingleOrNull();
    return row != null;
  }

  /// Records the landing target resolved for a prepared session as its
  /// current item, before activation, with the play position it was resolved
  /// at (activation is stale if the item has since moved). Throws a
  /// [StateError] (changing nothing) if the session is not one this instance
  /// prepared, or the item no longer belongs to it.
  Future<void> setPreparedCurrentItem(
          int sessionId, int itemId, int expectedPlayPosition) =>
      _fenced(() => _db.transaction(() async {
            final row = await _db.customSelect(
              'SELECT 1 FROM queue_session_items '
              'WHERE session_id = ? AND item_id = ? LIMIT 1',
              variables: [Variable.withInt(sessionId), Variable.withInt(itemId)],
            ).getSingleOrNull();
            if (!_prepared.containsKey(sessionId)) {
              throw StateError('Session $sessionId is not a prepared session');
            }
            if (row == null) {
              throw StateError('Item $itemId is not in session $sessionId');
            }
            await _setCurrentItem(sessionId, itemId);
            _prepared[sessionId] = expectedPlayPosition;
          }));

  /// Deletes a prepared session that was never activated (a rejected or
  /// superseded request). The active session is never discarded.
  Future<bool> discardSession(int sessionId) => _fenced(() async {
        return _db.transaction(() async {
          final session = await (_db.select(_db.queueSessions)
                ..where((s) => s.id.equals(sessionId) & s.isActive.equals(false)))
              .getSingleOrNull();
          if (session == null) return false;
          await _deleteSessions([sessionId]);
          _prepared.remove(sessionId);
          return true;
        });
      });

  /// Deletes every inactive session (at startup: prepared sessions of a
  /// previous run and queues the user replaced). Returns how many.
  Future<int> pruneInactiveSessions() => _fenced(() async {
        return _db.transaction(() async {
          final ids = await (_db.selectOnly(_db.queueSessions)
                ..addColumns([_db.queueSessions.id])
                ..where(_db.queueSessions.isActive.equals(false)))
              .map((row) => row.read(_db.queueSessions.id)!)
              .get();
          await _deleteSessions(ids);
          return ids.length;
        });
      });

  Future<int>? _startupPrune;

  /// The scope's one startup prune (a repository instance lives for one
  /// session scope). Everything that prepares or restores a session awaits
  /// it first, so it can never delete a session prepared in this scope.
  Future<int> pruneInactiveSessionsOnce() =>
      _startupPrune ??= pruneInactiveSessions().catchError((Object error) {
        // Pruning is housekeeping: a failure skips it (retried next time).
        _startupPrune = null;
        developer.log('Pruning inactive queue sessions failed',
            name: 'QueueRepository', error: error);
        return 0;
      });

  Future<void> _deleteSessions(List<int> ids) async {
    if (ids.isEmpty) return;
    await (_db.delete(_db.queueSessionPlayOrder)
          ..where((o) => o.sessionId.isIn(ids)))
        .go();
    await (_db.delete(_db.queueSessionItems)
          ..where((i) => i.sessionId.isIn(ids)))
        .go();
    await (_db.delete(_db.queueSessions)..where((s) => s.id.isIn(ids))).go();
  }

  Future<void> _deactivateAll() {
    return (_db.update(
      _db.queueSessions,
    )..where((s) => s.isActive.equals(true))).write(
      QueueSessionsCompanion(
        isActive: const Value(false),
        updatedAt: Value(_timestampSeconds()),
      ),
    );
  }

  Future<int> _createSessionRow({
    required bool active,
    required String sourceType,
    int? sourceArtistId,
    int? sourceAlbumId,
    required String repeatMode,
    required bool shuffleEnabled,
  }) {
    final now = _timestampSeconds();
    return _db
        .into(_db.queueSessions)
        .insert(
          QueueSessionsCompanion.insert(
            isActive: Value(active),
            createdAt: now,
            updatedAt: now,
            sourceType: sourceType,
            sourceArtistId: Value(sourceArtistId),
            sourceAlbumId: Value(sourceAlbumId),
            repeatMode: Value(repeatMode),
            shuffleEnabled: Value(shuffleEnabled),
          ),
        );
  }

  Future<void> _seedPlayOrderFromCanonical(int sessionId) {
    return _db.customStatement(
      'INSERT INTO queue_session_play_order (session_id, play_position, item_id) '
      'SELECT session_id, ROW_NUMBER() OVER (ORDER BY position ASC) - 1, item_id '
      'FROM queue_session_items '
      'WHERE session_id = ? AND queue_type = ? '
      'ORDER BY position ASC',
      [sessionId, QueueItemTypes.main],
    );
  }

  Future<void> _setCurrentItem(int sessionId, int currentItemId) {
    return (_db.update(
      _db.queueSessions,
    )..where((s) => s.id.equals(sessionId))).write(
      QueueSessionsCompanion(
        currentItemId: Value(currentItemId),
        updatedAt: Value(_timestampSeconds()),
      ),
    );
  }

  Future<int> _countItems(int sessionId) async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS c '
          'FROM queue_session_items '
          'WHERE session_id = ?',
          variables: [Variable.withInt(sessionId)],
        )
        .getSingle();
    return row.read<int>('c');
  }

  Future<int> _countQueueTypeItems(int sessionId, String queueType) async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS c '
          'FROM queue_session_items '
          'WHERE session_id = ? AND queue_type = ?',
          variables: [
            Variable.withInt(sessionId),
            Variable.withString(queueType),
          ],
        )
        .getSingle();
    return row.read<int>('c');
  }

  Future<void> _touchSession(int sessionId) {
    return (_db.update(_db.queueSessions)..where((s) => s.id.equals(sessionId)))
        .write(QueueSessionsCompanion(updatedAt: Value(_timestampSeconds())));
  }

  Future<void> _touchSessions(Set<int> sessionIds) async {
    if (sessionIds.isEmpty) return;
    await (_db.update(_db.queueSessions)..where((s) => s.id.isIn(sessionIds)))
        .write(QueueSessionsCompanion(updatedAt: Value(_timestampSeconds())));
  }

  Future<Set<int>> _queueSessionsContainingTracks(List<String> uuids) async {
    final placeholders = List.filled(uuids.length, '?').join(', ');
    final rows = await _db
        .customSelect(
          'SELECT DISTINCT session_id '
          'FROM queue_session_items '
          'WHERE uuid_id IN ($placeholders) '
          'ORDER BY session_id',
          variables: [for (final uuid in uuids) Variable.withString(uuid)],
        )
        .get();

    return rows.map((row) => row.read<int>('session_id')).toSet();
  }

  Future<void> _compactQueueSessionPositions(List<int> sessionIds) async {
    if (sessionIds.isEmpty) return;

    final placeholders = List.filled(sessionIds.length, '?').join(', ');

    await _db.customStatement(
      'UPDATE queue_session_play_order '
      'SET play_position = -(play_position + 1) '
      'WHERE session_id IN ($placeholders)',
      sessionIds,
    );
    await _db.customStatement(
      'WITH ranked AS ('
      'SELECT session_id, item_id, '
      'ROW_NUMBER() OVER ('
      'PARTITION BY session_id '
      'ORDER BY -play_position ASC, item_id ASC'
      ') - 1 AS new_position '
      'FROM queue_session_play_order '
      'WHERE session_id IN ($placeholders)'
      ') '
      'UPDATE queue_session_play_order '
      'SET play_position = ('
      'SELECT new_position FROM ranked '
      'WHERE ranked.session_id = queue_session_play_order.session_id '
      'AND ranked.item_id = queue_session_play_order.item_id'
      ') '
      'WHERE EXISTS ('
      'SELECT 1 FROM ranked '
      'WHERE ranked.session_id = queue_session_play_order.session_id '
      'AND ranked.item_id = queue_session_play_order.item_id'
      ')',
      sessionIds,
    );

    await _db.customStatement(
      'UPDATE queue_session_items '
      'SET position = -(position + 1) '
      'WHERE session_id IN ($placeholders)',
      sessionIds,
    );
    await _db.customStatement(
      'WITH ranked AS ('
      'SELECT item_id, '
      'ROW_NUMBER() OVER ('
      'PARTITION BY session_id, queue_type '
      'ORDER BY -position ASC, item_id ASC'
      ') - 1 AS new_position '
      'FROM queue_session_items '
      'WHERE session_id IN ($placeholders)'
      ') '
      'UPDATE queue_session_items '
      'SET position = ('
      'SELECT new_position FROM ranked '
      'WHERE ranked.item_id = queue_session_items.item_id'
      ') '
      'WHERE EXISTS ('
      'SELECT 1 FROM ranked '
      'WHERE ranked.item_id = queue_session_items.item_id'
      ')',
      sessionIds,
    );
  }

  Future<List<int>> _getManualItemIdsByPosition(
    int sessionId,
    int startPosition,
    int count,
  ) async {
    final rows = await _db
        .customSelect(
          'SELECT item_id FROM queue_session_items '
          'WHERE session_id = ? AND queue_type = ? '
          'AND position >= ? AND position < ? '
          'ORDER BY position ASC',
          variables: [
            Variable.withInt(sessionId),
            Variable.withString(QueueItemTypes.manual),
            Variable.withInt(startPosition),
            Variable.withInt(startPosition + count),
          ],
        )
        .get();
    return rows.map((row) => row.read<int>('item_id')).toList(growable: false);
  }

  Future<void> _appendToPlayOrder(int sessionId, List<int> itemIds) async {
    if (itemIds.isEmpty) return;
    final maxRow = await _db
        .customSelect(
          'SELECT COALESCE(MAX(play_position), -1) AS m '
          'FROM queue_session_play_order WHERE session_id = ?',
          variables: [Variable.withInt(sessionId)],
        )
        .getSingle();
    final startPos = maxRow.read<int>('m') + 1;
    await _db.batch((batch) {
      for (var i = 0; i < itemIds.length; i++) {
        batch.insert(
          _db.queueSessionPlayOrder,
          QueueSessionPlayOrderCompanion.insert(
            sessionId: sessionId,
            playPosition: startPos + i,
            itemId: itemIds[i],
          ),
        );
      }
    });
  }

  Future<void> _shiftSessionItemPositionsUp({
    required int sessionId,
    required String queueType,
    required int afterPosition,
    required int shift,
  }) async {
    if (shift <= 0) return;

    await _db.customStatement(
      'UPDATE queue_session_items '
      'SET position = -(position + 1) '
      'WHERE session_id = ? AND queue_type = ? AND position > ?',
      [sessionId, queueType, afterPosition],
    );
    await _db.customStatement(
      'UPDATE queue_session_items '
      'SET position = (-position - 1) + ? '
      'WHERE session_id = ? AND queue_type = ? AND position < 0',
      [shift, sessionId, queueType],
    );
  }

  Future<void> _shiftSessionItemPositionsDown({
    required int sessionId,
    required String queueType,
    required int afterPosition,
  }) async {
    await _db.customStatement(
      'UPDATE queue_session_items '
      'SET position = -(position + 1) '
      'WHERE session_id = ? AND queue_type = ? AND position > ?',
      [sessionId, queueType, afterPosition],
    );
    await _db.customStatement(
      'UPDATE queue_session_items '
      'SET position = (-position - 1) - 1 '
      'WHERE session_id = ? AND queue_type = ? AND position < 0',
      [sessionId, queueType],
    );
  }

  Future<void> _shiftPlayOrderPositionsDown({
    required int sessionId,
    required int afterPosition,
  }) async {
    await _db.customStatement(
      'UPDATE queue_session_play_order '
      'SET play_position = -(play_position + 1) '
      'WHERE session_id = ? AND play_position > ?',
      [sessionId, afterPosition],
    );
    await _db.customStatement(
      'UPDATE queue_session_play_order '
      'SET play_position = (-play_position - 1) - 1 '
      'WHERE session_id = ? AND play_position < 0',
      [sessionId],
    );
  }

  Future<List<int>> _getFutureQueueTypeItemIds(
    int sessionId, {
    required int afterPlayPosition,
    required String queueType,
    required bool orderByPlayOrder,
  }) async {
    final orderClause = orderByPlayOrder
        ? 'po.play_position ASC'
        : 'qsi.position ASC';
    final rows = await _db
        .customSelect(
          'SELECT qsi.item_id '
          'FROM queue_session_play_order AS po '
          'INNER JOIN queue_session_items AS qsi ON po.item_id = qsi.item_id '
          'WHERE po.session_id = ? AND po.play_position > ? AND qsi.queue_type = ? '
          'ORDER BY $orderClause',
          variables: [
            Variable.withInt(sessionId),
            Variable.withInt(afterPlayPosition),
            Variable.withString(queueType),
          ],
        )
        .get();

    return rows.map((row) => row.read<int>('item_id')).toList(growable: false);
  }

  Future<List<int>> _getRemainingQueueTypeItemIds(
    int sessionId, {
    required String queueType,
    required int throughPlayPosition,
  }) async {
    final variables = <Variable>[
      Variable.withInt(sessionId),
      Variable.withString(queueType),
      Variable.withInt(sessionId),
      Variable.withInt(throughPlayPosition),
    ];

    // The prefix (play positions up to and including the bound) is
    // excluded by a subquery: a bound id list would pass SQLite's variable
    // limit on a long queue.
    const sql =
        'SELECT item_id '
        'FROM queue_session_items '
        'WHERE session_id = ? AND queue_type = ? '
        'AND item_id NOT IN ('
        'SELECT item_id FROM queue_session_play_order '
        'WHERE session_id = ? AND play_position <= ?) '
        'ORDER BY position ASC';

    final rows = await _db.customSelect(sql, variables: variables).get();
    return rows.map((row) => row.read<int>('item_id')).toList(growable: false);
  }

  (String, List<Object?>) _buildTrackSessionInsertQuery({
    required int sessionId,
    required List<OrderParameter> orderBy,
    int? artistId,
    int? albumId,
    bool downloadedOnly = false,
  }) {
    if (albumId != null && artistId == null) {
      throw ArgumentError('Cannot filter by album without artist');
    }

    final args = <Object?>[sessionId, QueueItemTypes.main];
    final whereClauses = <String>[];

    if (artistId != null) {
      whereClauses.add('tm."artist_id" = ?');
      args.add(artistId);
    }
    if (albumId != null) {
      whereClauses.add('tm."album_id" = ?');
      args.add(albumId);
    }
    if (downloadedOnly) {
      whereClauses.add(usableDownloadPredicate);
    }

    final orderClause = _buildTrackOrderClause(orderBy);

    var sql =
        'INSERT INTO queue_session_items (session_id, queue_type, position, uuid_id) '
        'SELECT ?, ?, ROW_NUMBER() OVER (ORDER BY $orderClause) - 1, tm.uuid_id '
        'FROM trackmetadata AS tm '
        'INNER JOIN tracks AS t ON tm.uuid_id = t.uuid_id';

    if (whereClauses.isNotEmpty) {
      sql += ' WHERE ${whereClauses.join(' AND ')}';
    }

    sql += ' ORDER BY $orderClause';
    return (sql, args);
  }

  String _buildTrackOrderClause(List<OrderParameter> orderBy) {
    if (orderBy.isEmpty) {
      return 'tm."uuid_id" ASC';
    }

    return trackOrderClause(orderBy);
  }

  static QueuePlaybackEntry _playbackEntryFromRow(QueryRow row) {
    return QueuePlaybackEntry(
      itemId: row.read<int>('item_id'),
      queueType: row.read<String>('queue_type'),
      canonicalPosition: row.read<int>('canonical_position'),
      playPosition: row.read<int>('play_position'),
      uuidId: row.read<String>('uuid_id'),
      filePath: row.readNullable<String>('file_path'),
      downloadedCodec: row.readNullable<String>('downloaded_codec'),
      sourceCodec: row.readNullable<String>('source_codec'),
    );
  }

  static QueueTrackEntry _trackEntryFromRow(QueryRow row) {
    final playback = _playbackEntryFromRow(row);
    return QueueTrackEntry(
      itemId: playback.itemId,
      queueType: playback.queueType,
      canonicalPosition: playback.canonicalPosition,
      playPosition: playback.playPosition,
      uuidId: playback.uuidId,
      track: TrackUI.fromQueryRow(row),
    );
  }

  static int _timestampSeconds() =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000;
}
