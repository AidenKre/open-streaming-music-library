part of 'database.dart';

// ── Table definitions ──────────────────────────────────────────────────

// name_lower needs no index of its own: its unique() constraint gives it one.
class Artists extends Table {
  IntColumn get id => integer()();
  TextColumn get name => text()();
  TextColumn get nameLower =>
      text().unique().generatedAs(name.lower(), stored: true)();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_albums_name_lower', columns: {#nameLower})
@TableIndex(name: 'idx_albums_artist_id', columns: {#artistId})
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_albums_regular '
  'ON albums (name_lower, artist_id) WHERE is_single_grouping = 0',
)
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_albums_singles '
  'ON albums (artist_id, COALESCE(year, -1)) WHERE is_single_grouping = 1',
)
class Albums extends Table {
  IntColumn get id => integer()();
  TextColumn get name => text().nullable()();
  TextColumn get nameLower =>
      text().nullable().generatedAs(name.lower(), stored: true)();
  IntColumn get artistId => integer().references(Artists, #id)();
  IntColumn get year => integer().nullable()();
  BoolColumn get isSingleGrouping =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class Tracks extends Table {
  TextColumn get uuidId => text()();
  TextColumn get filePath => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get lastUpdated => integer()();
  // Monotonic per-track revision from the server, written on every `/changes`
  // upsert. The conflict-detection base for edits (Option A). The server
  // never sends null and every write sets it; the column is nullable in the
  // schema, and a NULL would read as "unknown base" until the next upsert.
  IntColumn get revision => integer().nullable()();
  // Bitrate of the file actually stored on disk. Null until a download
  // completes. May differ from trackmetadata.bitrate_kbps when downloaded at
  // a lower quality than the server source (e.g. 128 kbps download from a
  // 320 kbps source) or when bitrate passthrough serves the original.
  IntColumn get downloadedBitrateKbps => integer().nullable()();
  IntColumn get fileSizeBytes => integer().nullable()();
  // The quality preset the user/server selected for this download (e.g.
  // 'original', '320'). Independent of `downloadedBitrateKbps`, which is the
  // bitrate actually written to disk. Storing both lets us answer
  // "is the file at the requested quality?" idempotently even when the
  // backend served a passthrough that didn't match the requested bitrate.
  TextColumn get downloadedQuality => text().nullable()();
  // The server revision the downloaded bytes are current as of. Compared
  // against the live `revision` to detect a stale download (the track changed
  // server-side since -- audio, tags or artwork -- but the local file is
  // untouched). Stamped from the stream response's `X-Track-Revision` header;
  // older servers don't send it, so the fallback is the local revision read
  // BEFORE the request (erring early: a harmless false-positive stale beats
  // recording an old-master file as fresh forever), and 0 when even that is
  // unknown so any later revision flags it. Null when no download is
  // recorded (never flagged -- nothing to compare to).
  // Advanced in step with the user's OWN successful edits (see
  // [AppDatabase.recordOwnEditRevision]): the app shows metadata from this DB,
  // not the file's tags, so a self-edit doesn't make the copy outdated.
  IntColumn get downloadedAtRevision => integer().nullable()();
  // The codec actually written to disk. Read off the stream response's
  // `X-Audio-Codec` header (the server passes the source through unchanged
  // when its bitrate is already <= the requested preset, so a non-original
  // download is NOT always AAC). See `TrackDownloader.resolveDownloadedCodec`
  // for the fallback used against servers that don't send it.
  TextColumn get downloadedCodec => text().nullable()();
  // Re-arms (not a bool) when `revision` climbs again after a dismiss, so a
  // SECOND server-side change re-surfaces the stale warning even if the
  // first one was dismissed.
  IntColumn get staleDismissedAtRevision => integer().nullable()();
  // The download at this path failed to play although the device can play
  // audio (damaged; Phase 5 decision 6, marked only with evidence). It is the
  // path in `file_path`, which is kept with the other download columns, so a
  // re-download knows the original quality and Delete knows the file. Every
  // "usable download" rule ([usableDownloadPredicate]) excludes it: online
  // the track streams, offline it is skipped. The file is never deleted
  // automatically; a re-download or the user's Delete removes it. Null = not
  // damaged. (A store from before the 2026-11-09 change may hold a damaged
  // path with `file_path` cleared; cleanup reads both columns.)
  TextColumn get damagedFilePath => text().nullable()();

  @override
  Set<Column> get primaryKey => {uuidId};
}

@TableIndex(name: 'idx_title', columns: {#title})
@TableIndex(name: 'idx_artist', columns: {#artist})
@TableIndex(name: 'idx_album', columns: {#album})
@TableIndex(name: 'idx_album_artist', columns: {#albumArtist})
@TableIndex(name: 'idx_tm_artist_id', columns: {#artistId})
@TableIndex(name: 'idx_tm_album_id', columns: {#albumId})
@TableIndex(name: 'idx_year', columns: {#year})
@TableIndex(name: 'idx_date', columns: {#date})
@TableIndex(name: 'idx_genre', columns: {#genre})
// NOCASE companion to idx_genre (which is BINARY) so the autocomplete prefix
// scan `genre LIKE ?` stays index-backed and case-insensitive.
@TableIndex.sql(
  'CREATE INDEX idx_genre_nocase ON trackmetadata (genre COLLATE NOCASE)',
)
@TableIndex(name: 'idx_track_number', columns: {#trackNumber})
@TableIndex(name: 'idx_disc_number', columns: {#discNumber})
@TableIndex(name: 'idx_codec', columns: {#codec})
@TableIndex(name: 'idx_duration', columns: {#duration})
@TableIndex(name: 'idx_bitrate_kbps', columns: {#bitrateKbps})
@TableIndex(name: 'idx_sample_rate_hz', columns: {#sampleRateHz})
@TableIndex(name: 'idx_channels', columns: {#channels})
@TableIndex(name: 'idx_has_album_art', columns: {#hasAlbumArt})
@TableIndex.sql(
  'CREATE INDEX idx_tm_library_queue_order '
  'ON trackmetadata (artist, album, disc_number, track_number, uuid_id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_tm_artist_queue_order '
  'ON trackmetadata (artist_id, album, disc_number, track_number, uuid_id)',
)
@TableIndex.sql(
  'CREATE INDEX idx_tm_album_queue_order '
  'ON trackmetadata (artist_id, album_id, disc_number, track_number, uuid_id)',
)
class Trackmetadata extends Table {
  TextColumn get uuidId => text().references(Tracks, #uuidId)();
  TextColumn get title => text().nullable()();
  TextColumn get artist => text().nullable()();
  TextColumn get album => text().nullable()();
  TextColumn get albumArtist => text().nullable()();
  IntColumn get artistId => integer().nullable().references(Artists, #id)();
  IntColumn get albumId => integer().nullable().references(Albums, #id)();
  IntColumn get year => integer().nullable()();
  TextColumn get date => text().nullable()();
  TextColumn get genre => text().nullable()();
  IntColumn get trackNumber => integer().nullable()();
  IntColumn get discNumber => integer().nullable()();
  TextColumn get codec => text().nullable()();
  // Audio properties: null = unknown (the server couldn't determine it); 0
  // is a real value, never a stand-in for unknown (SC-16l).
  RealColumn get duration => real().nullable()();
  RealColumn get bitrateKbps => real().nullable()();
  IntColumn get sampleRateHz => integer().nullable()();
  IntColumn get channels => integer().nullable()();
  BoolColumn get hasAlbumArt => boolean().withDefault(const Constant(false))();
  IntColumn get coverArtId => integer().nullable()();

  @override
  Set<Column> get primaryKey => {uuidId};
}

class QueueSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  TextColumn get sourceType => text()(); // library|artist|album|search|single
  IntColumn get sourceArtistId => integer().nullable()();
  IntColumn get sourceAlbumId => integer().nullable()();
  IntColumn get currentItemId => integer().nullable()();
  IntColumn get resumeMainItemId => integer().nullable()();
  IntColumn get currentPositionMs => integer().withDefault(const Constant(0))();
  TextColumn get repeatMode => text().withDefault(const Constant('off'))();
  BoolColumn get shuffleEnabled =>
      boolean().withDefault(const Constant(false))();
}

@TableIndex(
  name: 'idx_queue_session_items_session_position',
  columns: {#sessionId, #queueType, #position},
)
@TableIndex(
  name: 'idx_queue_session_items_session_uuid',
  columns: {#sessionId, #uuidId},
)
class QueueSessionItems extends Table {
  IntColumn get itemId => integer().autoIncrement()();
  IntColumn get sessionId =>
      integer().references(QueueSessions, #id, onDelete: KeyAction.cascade)();
  TextColumn get queueType => text().withDefault(const Constant('main'))();
  IntColumn get position => integer()();
  TextColumn get uuidId => text().references(Tracks, #uuidId)();

  @override
  List<String> get customConstraints => const [
    'UNIQUE(session_id, queue_type, position)',
  ];
}

@TableIndex(
  name: 'idx_queue_session_play_order_session_position',
  columns: {#sessionId, #playPosition},
)
@TableIndex(
  name: 'idx_queue_session_play_order_session_item',
  columns: {#sessionId, #itemId},
)
class QueueSessionPlayOrder extends Table {
  IntColumn get sessionId =>
      integer().references(QueueSessions, #id, onDelete: KeyAction.cascade)();
  IntColumn get playPosition => integer()();
  IntColumn get itemId => integer().references(
    QueueSessionItems,
    #itemId,
    onDelete: KeyAction.cascade,
  )();

  @override
  Set<Column> get primaryKey => {sessionId, playPosition};

  @override
  List<String> get customConstraints => const ['UNIQUE(session_id, item_id)'];
}

/// Outbox of unflushed track metadata edits, one coalesced row per track.
class PendingEdits extends Table {
  TextColumn get uuidId => text()();

  /// The coalesced value-map as JSON: keys present = touched, a `null` value =
  /// an explicit clear (so "cleared" is distinct from "untouched").
  TextColumn get valuesJson => text()();

  /// `db_only` or `db_and_master` — monotonically escalates, never downgrades.
  TextColumn get writeMode => text()();

  /// The track revision captured at the first edit of this batch (Option A
  /// base). Nullable = "unknown base" → forces the conflict path on flush.
  IntColumn get baseRevision => integer().nullable()();

  /// `pending` (awaiting flush), `conflicted` (server returned 409),
  /// `rejected` (permanently refused: a 422 or the track is gone; shown with
  /// [rejectionReason] until dismissed), or `take_server` (resolution chosen;
  /// the authoritative single-track refetch hasn't succeeded yet — retried
  /// after each sync).
  TextColumn get status => text().withDefault(const Constant('pending'))();

  /// The server's current revision, recorded on a 409 so a "keep mine"
  /// resolution can rebase onto it.
  IntColumn get serverRevision => integer().nullable()();

  /// Snapshot of the track's editable columns captured at the first edit of the
  /// batch (JSON). Lets "take server"/discard revert the optimistic local write
  /// without a network round-trip.
  TextColumn get originalValuesJson => text().nullable()();

  /// Short human-readable reason recorded when a flush is permanently rejected
  /// (422 / track gone), surfaced in the pending-edits banner until dismissed.
  TextColumn get rejectionReason => text().nullable()();

  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {uuidId};
}

/// The server this database's catalog belongs to (SC-01). Holds exactly one
/// row whenever a session URL exists; [id] is pinned to 1 so a second row
/// can never be inserted.
class ServerBinding extends Table {
  // drift_dev reads the CHECK statically; the getter is never invoked.
  IntColumn get id =>
      // ignore: recursive_getters
      integer().withDefault(const Constant(1)).check(id.equals(1))();

  /// The server's persistent instance id. The sign-in, the row's one writer,
  /// always stores it; null would mean unknown, never "any server".
  TextColumn get instanceId => text().nullable()();

  /// Random UUID minted when the row is created.
  TextColumn get localBindingId => text()();
  TextColumn get lastBaseUrl => text()();

  /// UTC milliseconds since epoch.
  IntColumn get boundAt => integer()();
  BoolColumn get catalogReconciledAtBinding =>
      boolean().withDefault(const Constant(false))();

  /// The bound user's server id. NULL = unknown user, so the next login
  /// resets (SC-01 Phase M; unknown is never 0).
  IntColumn get userId => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Per-stream sync cursors (SC-02), e.g. the catalog `/changes` cursor.
class SyncCursors extends Table {
  TextColumn get stream => text()();
  IntColumn get value => integer()();

  @override
  Set<Column> get primaryKey => {stream};
}

@TableIndex(
  name: 'idx_history_events_pending',
  columns: {#pendingUpload, #localId},
)
@TableIndex.sql(
  'CREATE INDEX idx_history_events_kind_occurred '
  'ON history_events (kind, occurred_at DESC, event_uuid DESC)',
)
class HistoryEvents extends Table {
  IntColumn get localId => integer().autoIncrement()();
  TextColumn get eventUuid => text().unique()();
  TextColumn get kind => text()();
  TextColumn get entityType => text()();
  TextColumn get entityRef => text()();
  IntColumn get occurredAt => integer()();
  RealColumn get secondsPlayed => real().nullable()();
  RealColumn get trackLength => real().nullable()();
  IntColumn get serverRevision => integer().nullable().unique()();
  IntColumn get receivedAt => integer().nullable()();
  BoolColumn get pendingUpload => boolean()();
}

class LocalCounters extends Table {
  TextColumn get key => text()();
  IntColumn get value => integer()();

  @override
  Set<Column> get primaryKey => {key};
}

class HistorySyncFailures extends Table {
  TextColumn get eventUuid => text()();
  TextColumn get reason => text()();
  TextColumn get detail => text().nullable()();
  IntColumn get failedAt => integer()();

  @override
  Set<Column> get primaryKey => {eventUuid};
}

class HistoryConflictArchive extends Table {
  IntColumn get archiveId => integer().autoIncrement()();
  TextColumn get eventUuid => text()();
  TextColumn get payloadJson => text()();
  IntColumn get archivedAt => integer()();
}

@TableIndex.sql(
  "CREATE UNIQUE INDEX idx_active_listens_accumulating "
  "ON active_listens (state) WHERE state = 'accumulating'",
)
class ActiveListens extends Table {
  TextColumn get listenUuid => text()();
  IntColumn get queueSessionId => integer()();
  IntColumn get queueItemId => integer()();
  TextColumn get trackUuid => text()();
  IntColumn get startedAt => integer()();
  RealColumn get durationSeconds => real().nullable()();
  IntColumn get accumulatedMicros => integer()();
  IntColumn get lastCheckpointAt => integer()();
  TextColumn get state =>
      // ignore: recursive_getters
      text().check(state.isIn(['accumulating', 'finalizing']))();
  TextColumn get finalPayloadJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {listenUuid};
}

/// Client durable-submission rows (SC-14): persisted before sending so a
/// crash or ambiguous response can be resolved by operation id. A raw-stream
/// request has no frozen body (NULL `frozen_body_json`).
@TableIndex(
  name: 'idx_durable_submissions_unresolved',
  columns: {#localBindingId, #kind, #state},
)
@DataClassName('DurableSubmissionRow')
class DurableSubmissions extends Table {
  TextColumn get operationUuid => text()();
  TextColumn get kind => text()();
  TextColumn get localBindingId => text()();

  /// NULL for raw-stream requests (nothing to freeze).
  TextColumn get frozenBodyJson => text().nullable()();

  /// One of the SC-14 states. Raw constraint (not `.check`) so the fresh DDL
  /// is byte-identical to the version-1 schema snapshot's.
  TextColumn get state => text().customConstraint(
    "NOT NULL CHECK (state IN ('prepared', 'sent', 'accepted', 'rejected', "
    "'ambiguous'))",
  )();

  /// NULL until accepted.
  TextColumn get receiptJson => text().nullable()();

  /// NULL unless rejected.
  TextColumn get errorCode => text().nullable()();

  /// UTC milliseconds.
  IntColumn get createdAt => integer()();

  /// UTC milliseconds.
  IntColumn get updatedAt => integer()();

  @override
  List<String> get customConstraints => const ['PRIMARY KEY(operation_uuid)'];
}

/// Phase 8 owned-file cleanup queue: app-owned local files (downloads) whose
/// DB reference was dropped, enqueued in the same transaction that dropped it
/// and deleted later by a worker.
@DataClassName('OwnedFileCleanupRow')
class OwnedFileCleanupEntries extends Table {
  @override
  String get tableName => 'owned_file_cleanup';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get path => text()();

  /// Which owned root the file lives under. Only downloads for now. Raw
  /// constraint (not `.check`) so the fresh DDL is byte-identical to the
  /// version-1 schema snapshot's.
  TextColumn get rootKind => text().customConstraint(
    "NOT NULL CHECK (root_kind IN ('downloads'))",
  )();

  /// Device id of the file; NULL = unknown.
  IntColumn get dev => integer().nullable()();

  /// Inode of the file; NULL = unknown.
  IntColumn get ino => integer().nullable()();

  /// Bytes; NULL = unknown (never 0).
  IntColumn get size => integer().nullable()();

  /// File modification time, UTC microseconds since epoch; NULL = unknown.
  IntColumn get mtime => integer().nullable()();

  /// The SC-01 binding token captured by the enqueuing task; NULL = no
  /// binding row existed.
  TextColumn get localBindingId => text().nullable()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// NULL until a delete attempt fails.
  TextColumn get lastError => text().nullable()();

  /// UTC milliseconds.
  IntColumn get createdAt => integer()();
}

/// Local upload transfer intents (Phase 7 spec section 7), one row per
/// selected file, keyed by the SC-01 `local_binding_id`.
@TableIndex(
  name: 'idx_upload_intents_batch',
  columns: {#localBindingId, #batchUuid, #selectionIndex},
)
class UploadIntents extends Table {
  TextColumn get itemUuid => text()();
  TextColumn get batchUuid => text()();

  /// The ZIP parent's item UUID for a server-expanded child (its review
  /// draft and operation ids live here too); NULL for a selected file.
  TextColumn get parentItemUuid => text().nullable()();
  IntColumn get selectionIndex => integer()();
  TextColumn get displayName => text()();

  /// NULL = the source must be reselected.
  TextColumn get sourceDescriptorJson => text().nullable()();

  /// NULL = unknown (never 0).
  TextColumn get expectedSha256 => text().nullable()();

  /// NULL = unknown (never 0).
  IntColumn get expectedLength => integer().nullable()();

  /// State vocabulary is owned by the upload pipeline, so no CHECK here.
  TextColumn get lastState => text()();
  TextColumn get lastErrorCode => text().nullable()();
  TextColumn get lastErrorMessage => text().nullable()();

  /// The current review action's operation id. The allocation's operation
  /// id is the `batch_uuid` itself (not stored here).
  TextColumn get operationUuid => text().nullable()();

  /// The local operation id of the current content transfer attempt (SC-14
  /// PUT identity is item + digest/length); a fresh one per deliberate
  /// re-send, e.g. after the server returns the item to `allocated`.
  TextColumn get transferOperationUuid => text().nullable()();

  /// The server review version the draft and operation belong to.
  IntColumn get reviewGeneration => integer().nullable()();
  TextColumn get draftJson => text().nullable()();
  TextColumn get localBindingId => text()();

  /// UTC milliseconds.
  IntColumn get createdAt => integer()();

  /// UTC milliseconds.
  IntColumn get updatedAt => integer()();

  @override
  List<String> get customConstraints => const ['PRIMARY KEY(item_uuid)'];
}
