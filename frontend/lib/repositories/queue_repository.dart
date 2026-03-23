import 'package:drift/drift.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';

abstract final class QueueItemTypes {
  static const main = 'main';
  static const manual = 'manual';
}

class QueuePlaybackEntry {
  final int itemId;
  final String queueType;
  final int canonicalPosition;
  final int playPosition;
  final String uuidId;

  const QueuePlaybackEntry({
    required this.itemId,
    required this.queueType,
    required this.canonicalPosition,
    required this.playPosition,
    required this.uuidId,
  });
}

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

class QueueRepository {
  final AppDatabase _db;

  QueueRepository(this._db);

  Future<int> createSessionFromQuery({
    required String sourceType,
    int? sourceArtistId,
    int? sourceAlbumId,
    required String currentUuid,
    List<OrderParameter> orderBy = const [],
    String repeatMode = 'off',
    bool shuffleEnabled = false,
  }) {
    return _db.transaction(() async {
      await deactivateAll();

      final sessionId = await _createSessionRow(
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
        await rebuildFutureSuffix(
          sessionId,
          currentItemId: currentItemId,
          mainFutureItemIds: futureMainIds,
        );
      }
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
  }) {
    return _db.transaction(() async {
      await deactivateAll();

      final sessionId = await _createSessionRow(
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
        await rebuildFutureSuffix(
          sessionId,
          currentItemId: currentItemId,
          mainFutureItemIds: futureMainIds,
        );
      }
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
    final currentItem = session.currentItemId == null
        ? null
        : await getPlaybackEntryForItem(sessionId, session.currentItemId!);

    return QueueSessionSnapshot(
      session: session,
      totalCount: totalCount,
      currentItem: currentItem,
    );
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
        'SELECT po.item_id, qsi.queue_type, qsi.position AS canonical_position, '
        'po.play_position, qsi.uuid_id '
        'FROM queue_session_play_order AS po '
        'INNER JOIN queue_session_items AS qsi ON po.item_id = qsi.item_id '
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
          'SELECT po.item_id, qsi.queue_type, qsi.position AS canonical_position, '
          'po.play_position, qsi.uuid_id '
          'FROM queue_session_play_order AS po '
          'INNER JOIN queue_session_items AS qsi ON po.item_id = qsi.item_id '
          'WHERE po.session_id = ? AND po.item_id IN ($placeholders)',
          variables: [
            Variable.withInt(sessionId),
            ...ids.map(Variable.withInt),
          ],
        )
        .get();

    return rows.map(_playbackEntryFromRow).toList(growable: false);
  }

  Future<QueuePlaybackEntry?> getPlaybackEntryForItem(
    int sessionId,
    int itemId,
  ) async {
    final row = await _db
        .customSelect(
          'SELECT po.item_id, qsi.queue_type, qsi.position AS canonical_position, '
          'po.play_position, qsi.uuid_id '
          'FROM queue_session_play_order AS po '
          'INNER JOIN queue_session_items AS qsi ON po.item_id = qsi.item_id '
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
    int? resumeMainItemId,
    bool updateResumeMainItemId = false,
  }) {
    return (_db.update(
      _db.queueSessions,
    )..where((s) => s.id.equals(sessionId))).write(
      QueueSessionsCompanion(
        currentItemId: Value(currentItemId),
        resumeMainItemId: updateResumeMainItemId
            ? Value(resumeMainItemId)
            : const Value.absent(),
        currentPositionMs: Value(positionMs),
        updatedAt: Value(_timestampSeconds()),
      ),
    );
  }

  Future<void> updateRepeatMode(int sessionId, String mode) {
    return (_db.update(
      _db.queueSessions,
    )..where((s) => s.id.equals(sessionId))).write(
      QueueSessionsCompanion(
        repeatMode: Value(mode),
        updatedAt: Value(_timestampSeconds()),
      ),
    );
  }

  Future<void> updateShuffleEnabled(int sessionId, bool enabled) {
    return (_db.update(
      _db.queueSessions,
    )..where((s) => s.id.equals(sessionId))).write(
      QueueSessionsCompanion(
        shuffleEnabled: Value(enabled),
        updatedAt: Value(_timestampSeconds()),
      ),
    );
  }

  Future<void> replacePlayOrder(int sessionId, List<int> itemIds) {
    return _db.transaction(() async {
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
    });
  }

  Future<void> rebuildFutureSuffix(
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
      excludedItemIds: prefixIds,
    );

    await replacePlayOrder(sessionId, [
      ...prefixIds,
      ...manualFutureIds,
      ...mainFutureItemIds,
    ]);
  }

  Future<void> prependManualItems(int sessionId, List<String> uuids) {
    return _db.transaction(() async {
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
        sessionId, 0, uuids.length,
      );
      await _appendToPlayOrder(sessionId, newItemIds);
      await _touchSession(sessionId);
    });
  }

  Future<void> appendManualItems(int sessionId, List<String> uuids) {
    return _db.transaction(() async {
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
        sessionId, startPosition, uuids.length,
      );
      await _appendToPlayOrder(sessionId, newItemIds);
      await _touchSession(sessionId);
    });
  }

  Future<void> removeItem(int sessionId, int itemId) {
    return _db.transaction(() async {
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

  Future<void> deactivateAll() {
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
            isActive: const Value(true),
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
        resumeMainItemId: Value(currentItemId),
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
    return rows
        .map((row) => row.read<int>('item_id'))
        .toList(growable: false);
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
    required List<int> excludedItemIds,
  }) async {
    final variables = <Variable>[
      Variable.withInt(sessionId),
      Variable.withString(queueType),
    ];

    var sql =
        'SELECT item_id '
        'FROM queue_session_items '
        'WHERE session_id = ? AND queue_type = ?';

    if (excludedItemIds.isNotEmpty) {
      final placeholders = List.filled(excludedItemIds.length, '?').join(', ');
      sql += ' AND item_id NOT IN ($placeholders)';
      variables.addAll(excludedItemIds.map(Variable.withInt));
    }

    sql += ' ORDER BY position ASC';

    final rows = await _db.customSelect(sql, variables: variables).get();
    return rows.map((row) => row.read<int>('item_id')).toList(growable: false);
  }

  (String, List<Object?>) _buildTrackSessionInsertQuery({
    required int sessionId,
    required List<OrderParameter> orderBy,
    int? artistId,
    int? albumId,
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

    return orderBy
        .map((order) {
          final alias = aliasMap(order.column);
          final direction = order.isAscending ? 'ASC' : 'DESC';
          return '$alias."${order.column}" $direction';
        })
        .join(', ');
  }

  static QueuePlaybackEntry _playbackEntryFromRow(QueryRow row) {
    return QueuePlaybackEntry(
      itemId: row.read<int>('item_id'),
      queueType: row.read<String>('queue_type'),
      canonicalPosition: row.read<int>('canonical_position'),
      playPosition: row.read<int>('play_position'),
      uuidId: row.read<String>('uuid_id'),
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
