import 'dart:convert';
import 'dart:math' show min;

import 'package:drift/drift.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/sync_service.dart' show ServerRegressedException;

/// The server broke the history protocol (malformed/unexpected ACK, a page
/// that is out of order, has duplicates, a wrong cursor or invalid fields).
/// Nothing was changed.
class HistoryProtocolException implements Exception {
  HistoryProtocolException(this.message);
  final String message;
  @override
  String toString() => 'HistoryProtocolException: $message';
}

/// A downloaded page holds a different payload for events this device
/// already has: the page is not applied and the cursor does not move until
/// the user resolves it ("Keep server version").
class HistoryPayloadConflict implements Exception {
  HistoryPayloadConflict(this.events);
  final List<HistoryServerEvent> events;
  @override
  String toString() =>
      'HistoryPayloadConflict(${events.map((e) => e.payload.eventUuid).toList()})';
}

/// One upload batch: the events and the exact UTF-8 request body.
class HistoryUploadBatch {
  HistoryUploadBatch(this.events, this.body);
  final List<HistoryEventPayload> events;
  final Uint8List body;
  List<String> get eventUuids => [for (final e in events) e.eventUuid];
}

/// Diagnostics counts.
typedef HistorySyncCounts = ({int pending, int quarantined});

/// A durable listen in progress (`active_listens`): the future play event
/// UUID, its queue identity and its persisted credit. A draft whose
/// finalization failed is frozen with its [finalPayload].
class ListenDraft {
  const ListenDraft({
    required this.listenUuid,
    required this.queueSessionId,
    required this.queueItemId,
    required this.trackUuid,
    required this.startedAt,
    required this.durationSeconds,
    required this.accumulatedMicros,
    required this.lastCheckpointAt,
    this.finalPayload,
  });
  final String listenUuid;
  final int queueSessionId;
  final int queueItemId;
  final String trackUuid;
  final int startedAt;
  final double? durationSeconds;
  final int accumulatedMicros;
  final int lastCheckpointAt;
  final HistoryEventPayload? finalPayload;
  bool get finalizing => finalPayload != null;
}

/// How a draft finalization ended.
enum DraftFinalization { inserted, alreadyPresent, conflict }

/// The local history store (Phase 5 §3/§4, SC-01 rule 4, SC-02, SC-11).
/// Every write runs in a transaction fenced by the session binding token.
class HistoryRepository {
  HistoryRepository(this._db, {
    ServerBindingRepository? binding,
    void Function()? onLocalInsert,
  }) : _binding = binding ?? ServerBindingRepository(_db),
       _onLocalInsert = onLocalInsert;

  final AppDatabase _db;
  final ServerBindingRepository _binding;
  final void Function()? _onLocalInsert;

  static const maxBatchEvents = 200;
  static const maxBatchBytes = 256 * 1024;

  // ---- listen drafts (active_listens, Phase 5 §3/§7) ------------------

  /// Creates or checkpoints an accumulating listen draft (fenced). A
  /// frozen (finalizing) draft is never changed: its payload is final.
  Future<void> checkpointDraft(String bindingToken, ListenDraft draft) =>
      _binding.runFenced(bindingToken, () async {
        final existing = await _draftRow(draft.listenUuid);
        if (existing != null && existing.state == 'finalizing') return;
        await _db.into(_db.activeListens).insertOnConflictUpdate(
              ActiveListensCompanion.insert(
                listenUuid: draft.listenUuid,
                queueSessionId: draft.queueSessionId,
                queueItemId: draft.queueItemId,
                trackUuid: draft.trackUuid,
                startedAt: draft.startedAt,
                durationSeconds: Value(draft.durationSeconds),
                accumulatedMicros: draft.accumulatedMicros,
                lastCheckpointAt: draft.lastCheckpointAt,
                state: 'accumulating',
              ),
            );
      });

  /// Freezes a draft whose finalization failed: it keeps exactly this
  /// payload (retried later, never re-accumulated). Several frozen drafts
  /// may coexist; at most one accumulates.
  Future<void> freezeDraft(
          String bindingToken, String listenUuid, HistoryEventPayload play) =>
      _binding.runFenced(bindingToken, () async {
        await (_db.update(_db.activeListens)
              ..where((l) => l.listenUuid.equals(listenUuid)))
            .write(ActiveListensCompanion(
          state: const Value('finalizing'),
          finalPayloadJson: Value(jsonEncode(play.toJson())),
        ));
      });

  /// Inserts the play event (event UUID = listen UUID, pending upload) and
  /// deletes its draft in one fenced transaction. A repeated finalization
  /// (after a crash) is idempotent when the stored event matches; a
  /// different stored payload is a conflict: nothing is overwritten and
  /// the draft is kept.
  Future<DraftFinalization> finalizeDraft(
      String bindingToken, HistoryEventPayload play) async {
    try {
      _validatePayload(play);
    } on HistoryProtocolException catch (e) {
      throw ArgumentError(e.message);
    }
    final result = await _binding.runFenced(bindingToken, () async {
      final stored = await localPayload(play.eventUuid);
      if (stored != null) {
        if (!stored.samePayload(play)) return DraftFinalization.conflict;
        await _deleteDraftRow(play.eventUuid);
        return DraftFinalization.alreadyPresent;
      }
      await _db.into(_db.historyEvents).insert(
            _values(play).copyWith(pendingUpload: const Value(true)),
          );
      await _deleteDraftRow(play.eventUuid);
      return DraftFinalization.inserted;
    });
    if (result == DraftFinalization.inserted) _onLocalInsert?.call();
    return result;
  }

  /// Deletes a draft (a listen that ended without credit).
  Future<void> deleteDraft(String bindingToken, String listenUuid) =>
      _binding.runFenced(bindingToken, () => _deleteDraftRow(listenUuid));

  /// Every draft, oldest start first.
  Future<List<ListenDraft>> drafts() async {
    final rows = await (_db.select(_db.activeListens)
          ..orderBy([(l) => OrderingTerm(expression: l.startedAt)]))
        .get();
    return [
      for (final row in rows)
        ListenDraft(
          listenUuid: row.listenUuid,
          queueSessionId: row.queueSessionId,
          queueItemId: row.queueItemId,
          trackUuid: row.trackUuid,
          startedAt: row.startedAt,
          durationSeconds: row.durationSeconds,
          accumulatedMicros: row.accumulatedMicros,
          lastCheckpointAt: row.lastCheckpointAt,
          finalPayload: row.finalPayloadJson == null
              ? null
              : _payloadFromJson(jsonDecode(row.finalPayloadJson!)),
        ),
    ];
  }

  Future<ActiveListen?> _draftRow(String listenUuid) =>
      (_db.select(_db.activeListens)
            ..where((l) => l.listenUuid.equals(listenUuid)))
          .getSingleOrNull();

  Future<void> _deleteDraftRow(String listenUuid) =>
      (_db.delete(_db.activeListens)
            ..where((l) => l.listenUuid.equals(listenUuid)))
          .go();

  static HistoryEventPayload _payloadFromJson(Object? json) {
    final map = json as Map<String, Object?>;
    return HistoryEventPayload(
      eventUuid: map['event_uuid'] as String,
      kind: map['kind'] as String,
      entityType: map['entity_type'] as String,
      entityRef: map['entity_ref'] as String,
      occurredAt: map['occurred_at'] as int,
      secondsPlayed: (map['seconds_played'] as num?)?.toDouble(),
      trackLength: (map['track_length'] as num?)?.toDouble(),
    );
  }

  /// A locally produced event: inserted pending, atomically.
  Future<void> insertLocal(String bindingToken, HistoryEventPayload event) async {
    await _binding.runFenced(bindingToken, () async {
      try {
        _validatePayload(event);
      } on HistoryProtocolException catch (e) {
        throw ArgumentError(e.message);
      }
      await _db.into(_db.historyEvents).insert(
        _values(event).copyWith(pendingUpload: const Value(true)),
      );
    });
    // Notify only after commit: failures and fenced writes never schedule
    // an upload for data that was not stored.
    _onLocalInsert?.call();
  }

  /// The next upload batch: pending, non-quarantined rows in local_id order,
  /// stopping before [maxEvents] or [maxBytes] of the exact serialized
  /// `{"events":[...]}` UTF-8 body. A single event too large for a batch is
  /// quarantined (reason `oversized`) instead. Null when nothing is pending.
  Future<HistoryUploadBatch?> nextUploadBatch(
    String bindingToken, {
    int maxEvents = maxBatchEvents,
    int maxBytes = maxBatchBytes,
  }) => _binding.runFenced(bindingToken, () async {
    final eventLimit = min(maxEvents, maxBatchEvents);
    final byteLimit = min(maxBytes, maxBatchBytes);
    if (eventLimit <= 0) return null;
    final history = _db.historyEvents;
    final failures = _db.historySyncFailures;
    // At most one batch of rows per read. Oversized rows are quarantined as
    // they are read (and leave the query), so a page holding only them is
    // followed by the next one.
    final query = _db.select(history).join([
      leftOuterJoin(failures, failures.eventUuid.equalsExp(history.eventUuid)),
    ])
      ..where(history.pendingUpload.equals(true) & failures.eventUuid.isNull())
      ..orderBy([OrderingTerm.asc(history.localId)])
      ..limit(eventLimit);
    final events = <HistoryEventPayload>[];
    // The body is `{"events":[e1,e2,...]}`: its size is the frame plus each
    // event's own encoding plus the separating commas.
    var size = _emptyBodyBytes;
    while (events.isEmpty) {
      final rows = await query.get();
      if (rows.isEmpty) return null;
      var full = false;
      for (final row in rows) {
        final event = _payload(row.readTable(history));
        final bytes = _eventBytes(event);
        if (_emptyBodyBytes + bytes > byteLimit) {
          await _recordFailureIn(event.eventUuid, reason: 'oversized');
          continue;
        }
        final next = size + bytes + (events.isEmpty ? 0 : 1);
        if (next > byteLimit) {
          full = true;
          break;
        }
        events.add(event);
        size = next;
      }
      if (full || rows.length < eventLimit) break;
    }
    if (events.isEmpty) return null;
    final body = _encode(events);
    assert(body.length == size, 'batch size accounting drifted');
    return HistoryUploadBatch(events, body);
  });

  /// Clears `pending_upload` only for [submitted] UUIDs the server
  /// acknowledged. A malformed ACK (not a list of strings), a duplicate, or a
  /// UUID that was not submitted is a [HistoryProtocolException] and clears
  /// nothing.
  Future<void> applyAck(
    String bindingToken,
    List<String> submitted,
    Object? acknowledged,
  ) => _binding.runFenced(bindingToken, () async {
    if (acknowledged is! List || acknowledged.any((id) => id is! String)) {
      throw HistoryProtocolException('ACK must be a list of UUID strings');
    }
    final ids = acknowledged.cast<String>().toSet();
    if (ids.length != acknowledged.length || !submitted.toSet().containsAll(ids)) {
      throw HistoryProtocolException('ACK contains duplicate or unexpected UUIDs');
    }
    await (_db.update(_db.historyEvents)
          ..where((t) => t.eventUuid.isIn(ids)))
        .write(const HistoryEventsCompanion(pendingUpload: Value(false)));
  });

  /// Applies one downloaded page and advances the `history` cursor in the
  /// same transaction (to the last returned revision; an empty page leaves
  /// it). Validates the page first ([HistoryProtocolException], nothing
  /// changed); a server whose latestRevision is below [requestedAfter] has
  /// regressed (SC-01 rule 5). Existing events keep their payload and
  /// pending flag; missing server metadata is filled from the echo. A
  /// different payload for a known UUID throws [HistoryPayloadConflict].
  Future<void> applyPage(
    String bindingToken, {
    required int requestedAfter,
    required HistoryPage page,
  }) => _binding.runFenced(bindingToken, () async {
    _validatePage(requestedAfter, page);
    final existing = {
      for (final row in await (_db.select(_db.historyEvents)
            ..where((t) => t.eventUuid.isIn(
              page.events.map((e) => e.payload.eventUuid),
            )))
          .get())
        row.eventUuid: row,
    };
    final conflicts = [
      for (final event in page.events)
        if (existing.containsKey(event.payload.eventUuid) &&
            !_payload(existing[event.payload.eventUuid]!).samePayload(event.payload))
          event,
    ];
    if (conflicts.isNotEmpty) throw HistoryPayloadConflict(conflicts);

    for (final event in page.events) {
      final local = existing[event.payload.eventUuid];
      if (local == null) {
        await _db.into(_db.historyEvents).insert(
          _values(event.payload).copyWith(
            pendingUpload: const Value(false),
            serverRevision: Value(event.revision),
            receivedAt: Value(event.receivedAt),
          ),
        );
      } else {
        await (_db.update(_db.historyEvents)
              ..where((t) => t.eventUuid.equals(event.payload.eventUuid)))
            .write(HistoryEventsCompanion(
              serverRevision: Value(local.serverRevision ?? event.revision),
              receivedAt: Value(local.receivedAt ?? event.receivedAt),
            ));
      }
    }
    if (page.events.isNotEmpty) {
      await SyncCursorStore(_db).write(SyncStream.history, page.events.last.revision);
    }
  });

  /// "Keep server version": archive the local payload, replace it in place
  /// with [server] (UPDATE, so local_id is kept and history_content bumps),
  /// clear pending and any failure record, in one transaction.
  Future<void> keepServerVersion(String bindingToken, HistoryServerEvent server) =>
      _binding.runFenced(bindingToken, () async {
        _validatePayload(server.payload);
        final uuid = server.payload.eventUuid;
        final local = await (_db.select(_db.historyEvents)
              ..where((t) => t.eventUuid.equals(uuid)))
            .getSingle();
        if (_payload(local).samePayload(server.payload)) return;
        await _db.into(_db.historyConflictArchive).insert(
          HistoryConflictArchiveCompanion.insert(
            eventUuid: uuid,
            payloadJson: jsonEncode(_payload(local).toJson()),
            archivedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        await (_db.update(_db.historyEvents)
              ..where((t) => t.eventUuid.equals(uuid)))
            .write(_values(server.payload).copyWith(
              pendingUpload: const Value(false),
              serverRevision: Value(server.revision),
              receivedAt: Value(server.receivedAt),
            ));
        await (_db.delete(_db.historySyncFailures)
              ..where((t) => t.eventUuid.equals(uuid)))
            .go();
      });

  /// Quarantines [eventUuid] (excluded from upload until cleared).
  Future<void> recordFailure(
    String bindingToken,
    String eventUuid, {
    required String reason,
    String? detail,
  }) => _binding.runFenced(bindingToken, () =>
      _recordFailureIn(eventUuid, reason: reason, detail: detail));

  Future<void> _recordFailureIn(
    String eventUuid, {
    required String reason,
    String? detail,
  }) async {
    await _db.into(_db.historySyncFailures).insertOnConflictUpdate(
      HistorySyncFailuresCompanion.insert(
        eventUuid: eventUuid,
        reason: reason,
        detail: Value(detail),
        failedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<HistorySyncCounts> counts() async =>
      _countsFrom(await _countsQuery().getSingle());

  /// Live form of [counts] (diagnostics).
  Stream<HistorySyncCounts> watchCounts() =>
      _countsQuery().watchSingle().map(_countsFrom);

  /// Live count of frozen listen drafts (failed finalizations kept for a
  /// retry).
  Stream<int> watchFrozenListenCount() {
    final count = _db.activeListens.listenUuid.count();
    return (_db.selectOnly(_db.activeListens)
          ..addColumns([count])
          ..where(_db.activeListens.state.equals('finalizing')))
        .map((row) => row.read(count) ?? 0)
        .watchSingle();
  }

  Selectable<QueryRow> _countsQuery() => _db.customSelect(
    'SELECT (SELECT COUNT(*) FROM history_events h '
    'WHERE pending_upload = 1 AND NOT EXISTS '
    '(SELECT 1 FROM history_sync_failures f WHERE f.event_uuid = h.event_uuid)) '
    'AS pending, (SELECT COUNT(*) FROM history_sync_failures) AS quarantined',
    readsFrom: {_db.historyEvents, _db.historySyncFailures},
  );

  static HistorySyncCounts _countsFrom(QueryRow row) =>
      (pending: row.read<int>('pending'), quarantined: row.read<int>('quarantined'));

  /// This device's payload for [eventUuid], or null when it has none.
  Future<HistoryEventPayload?> localPayload(String eventUuid) async {
    final row = await (_db.select(_db.historyEvents)
          ..where((t) => t.eventUuid.equals(eventUuid)))
        .getSingleOrNull();
    return row == null ? null : _payload(row);
  }

  /// Clears every quarantine except conflicts (only "Keep server version"
  /// resolves those), so the events upload again.
  Future<void> clearRetryableFailures(String bindingToken) =>
      _binding.runFenced(bindingToken, () async {
        await (_db.delete(_db.historySyncFailures)
              ..where((t) => t.reason.equals('conflict').not()))
            .go();
      });

  static final _emptyBodyBytes = _encode(const []).length;

  static int _eventBytes(HistoryEventPayload event) =>
      utf8.encode(jsonEncode(event.toJson())).length;

  static Uint8List _encode(List<HistoryEventPayload> events) => Uint8List.fromList(
    utf8.encode(jsonEncode({'events': [for (final event in events) event.toJson()]})),
  );

  static HistoryEventPayload _payload(HistoryEvent row) => HistoryEventPayload(
    eventUuid: row.eventUuid,
    kind: row.kind,
    entityType: row.entityType,
    entityRef: row.entityRef,
    occurredAt: row.occurredAt,
    secondsPlayed: row.secondsPlayed,
    trackLength: row.trackLength,
  );

  static HistoryEventsCompanion _values(HistoryEventPayload event) =>
      HistoryEventsCompanion(
        eventUuid: Value(event.eventUuid),
        kind: Value(event.kind),
        entityType: Value(event.entityType),
        entityRef: Value(event.entityRef),
        occurredAt: Value(event.occurredAt),
        secondsPlayed: Value(event.secondsPlayed),
        trackLength: Value(event.trackLength),
      );

  static void _validatePayload(HistoryEventPayload event) {
    bool validText(String value, int maxLength) =>
        value.isNotEmpty && value.runes.length <= maxLength &&
        !value.runes.any((c) => c < 32 || c == 127);
    final seconds = event.secondsPlayed;
    final length = event.trackLength;
    if (!validText(event.kind, 64) ||
        !validText(event.entityType, 64) ||
        !validText(event.entityRef, 256) ||
        event.occurredAt < 0 || event.occurredAt > 253402300799999 ||
        (seconds != null && (!seconds.isFinite || seconds < 0)) ||
        (length != null && (!length.isFinite || length <= 0))) {
      throw HistoryProtocolException('Invalid history payload fields');
    }
  }

  static void _validatePage(int requestedAfter, HistoryPage page) {
    var previous = requestedAfter;
    final ids = <String>{};
    for (final event in page.events) {
      _validatePayload(event.payload);
      if (event.revision <= previous || !ids.add(event.payload.eventUuid)) {
        throw HistoryProtocolException('History page is unordered or has duplicate UUIDs');
      }
      previous = event.revision;
    }
    if (page.nextCursor != null &&
        (page.events.isEmpty || page.nextCursor != page.events.last.revision)) {
      throw HistoryProtocolException('Invalid history page cursor');
    }
    if (page.latestRevision < requestedAfter) {
      throw ServerRegressedException(
        requestedAfter: requestedAfter, latestRevision: page.latestRevision,
      );
    }
    if (page.events.isNotEmpty && page.latestRevision < page.events.last.revision) {
      throw HistoryProtocolException('History page exceeds its latest revision');
    }
  }
}
