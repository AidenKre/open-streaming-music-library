-- The whole script is one transaction: a crash mid-init leaves no schema.
-- The user_version below must equal Database.LATEST_SCHEMA_VERSION.
BEGIN;

CREATE TABLE IF NOT EXISTS users (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "username" TEXT NOT NULL,
    "username_key" TEXT NOT NULL UNIQUE,
    "password_hash" TEXT NOT NULL,
    "is_admin" INTEGER NOT NULL DEFAULT 0 CHECK (is_admin IN (0,1)),
    "is_master_admin" INTEGER NOT NULL DEFAULT 0 CHECK (is_master_admin IN (0,1)),
    "library_folder" TEXT NOT NULL UNIQUE,
    "created_at" INTEGER NOT NULL,
    "disabled_at" INTEGER,
    "deleting_at" INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS one_master_admin ON users(is_master_admin) WHERE is_master_admin = 1;

CREATE TABLE IF NOT EXISTS user_settings (
    "user_id" INTEGER NOT NULL REFERENCES users("id"),
    "key" TEXT NOT NULL,
    "value" TEXT NOT NULL,
    PRIMARY KEY (user_id, key)
);

-- Used from M.1.
CREATE TABLE IF NOT EXISTS auth_sessions (
    "token_hash" TEXT NOT NULL PRIMARY KEY,
    "media_hash" TEXT NOT NULL UNIQUE,
    "user_id" INTEGER NOT NULL REFERENCES users("id"),
    "created_at" INTEGER NOT NULL,
    "revoked_at" INTEGER
);
CREATE INDEX IF NOT EXISTS idx_auth_sessions_user ON auth_sessions(user_id);

-- Used by the offline `users delete` (M.2b) to remember which cover art the
-- deleted user referenced. Deliberately no FK to cover_arts, so a captured id
-- survives the art row's removal on a resumed delete.
CREATE TABLE IF NOT EXISTS user_delete_art_capture (
    "user_id" INTEGER NOT NULL REFERENCES users("id"),
    "cover_art_id" INTEGER NOT NULL,
    PRIMARY KEY ("user_id", "cover_art_id")
);

CREATE TABLE IF NOT EXISTS artists (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "name" TEXT NOT NULL,
    "name_lower" TEXT NOT NULL GENERATED ALWAYS AS (LOWER("name")) STORED,
    "owner_id" INTEGER NOT NULL REFERENCES users("id"),
    UNIQUE ("owner_id", "name_lower")
);

CREATE INDEX IF NOT EXISTS idx_artists_name_lower ON artists("name_lower");

CREATE TABLE IF NOT EXISTS albums (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "name" TEXT,
    "name_lower" TEXT GENERATED ALWAYS AS (LOWER("name")) STORED,
    "artist_id" INTEGER NOT NULL,
    "year" INTEGER,
    "is_single_grouping" INTEGER NOT NULL DEFAULT 0 CHECK ("is_single_grouping" IN (0,1)),
    FOREIGN KEY ("artist_id") REFERENCES artists("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_albums_regular
    ON albums("name_lower", "artist_id") WHERE "is_single_grouping" = 0;

CREATE UNIQUE INDEX IF NOT EXISTS idx_albums_singles
    ON albums("artist_id", COALESCE("year", -1)) WHERE "is_single_grouping" = 1;

CREATE INDEX IF NOT EXISTS idx_albums_name_lower ON albums("name_lower");
CREATE INDEX IF NOT EXISTS idx_albums_artist_id ON albums("artist_id");

CREATE TABLE IF NOT EXISTS tracks (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "uuid_id" TEXT UNIQUE NOT NULL,
    "file_path" TEXT NOT NULL,
    "created_at" INTEGER NOT NULL DEFAULT (unixepoch()),
    "last_updated" INTEGER NOT NULL DEFAULT (unixepoch()),
    -- Monotonic sync watermark, assigned from revision_counter on add/update.
    "revision" INTEGER NOT NULL DEFAULT 0,
    "owner_id" INTEGER NOT NULL REFERENCES users("id")
);

CREATE INDEX IF NOT EXISTS idx_tracks_revision ON tracks("revision");
CREATE INDEX IF NOT EXISTS idx_tracks_owner_revision ON tracks("owner_id", "revision");

CREATE TABLE IF NOT EXISTS cover_arts (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "sha256" TEXT UNIQUE NOT NULL,
    "phash" TEXT NOT NULL,
    "phash_prefix" TEXT NOT NULL,
    "file_path" TEXT UNIQUE NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_cover_arts_phash_prefix ON cover_arts("phash_prefix");

CREATE TABLE IF NOT EXISTS trackmetadata (
    "track_id" INTEGER UNIQUE NOT NULL,
    "uuid_id" TEXT UNIQUE NOT NULL,
    "title" TEXT,
    "artist" TEXT,
    "album" TEXT,
    "album_artist" TEXT,
    "artist_id" INTEGER,
    "album_id" INTEGER,
    "year" INTEGER,
    "date" TEXT,
    "genre" TEXT,
    "track_number" INTEGER,
    "disc_number" INTEGER,
    "codec" TEXT,
    "duration" FLOAT,
    "bitrate_kbps" FLOAT,
    "sample_rate_hz" INTEGER,
    "channels" INTEGER,
    "has_album_art" INTEGER NOT NULL CHECK ("has_album_art" IN (0,1)),
    "cover_art_id" INTEGER,
    FOREIGN KEY ("track_id") REFERENCES tracks("id"),
    FOREIGN KEY ("uuid_id") REFERENCES tracks("uuid_id"),
    FOREIGN KEY ("artist_id") REFERENCES artists("id"),
    FOREIGN KEY ("album_id") REFERENCES albums("id"),
    FOREIGN KEY ("cover_art_id") REFERENCES cover_arts("id") ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_title ON trackmetadata("title");
CREATE INDEX IF NOT EXISTS idx_artist ON trackmetadata("artist");
CREATE INDEX IF NOT EXISTS idx_album ON trackmetadata("album");
CREATE INDEX IF NOT EXISTS idx_album_artist ON trackmetadata("album_artist");
CREATE INDEX IF NOT EXISTS idx_tm_artist_id ON trackmetadata("artist_id");
CREATE INDEX IF NOT EXISTS idx_tm_album_id ON trackmetadata("album_id");
CREATE INDEX IF NOT EXISTS idx_year ON trackmetadata("year");
CREATE INDEX IF NOT EXISTS idx_date ON trackmetadata("date");
CREATE INDEX IF NOT EXISTS idx_genre ON trackmetadata("genre");
CREATE INDEX IF NOT EXISTS idx_track_number ON trackmetadata("track_number");
CREATE INDEX IF NOT EXISTS idx_disc_number ON trackmetadata("disc_number");
CREATE INDEX IF NOT EXISTS idx_codec ON trackmetadata("codec");
CREATE INDEX IF NOT EXISTS idx_duration ON trackmetadata("duration");
CREATE INDEX IF NOT EXISTS idx_bitrate_kbps ON trackmetadata("bitrate_kbps");
CREATE INDEX IF NOT EXISTS idx_sample_rate_hz ON trackmetadata("sample_rate_hz");
CREATE INDEX IF NOT EXISTS idx_channels ON trackmetadata("channels");
CREATE INDEX IF NOT EXISTS idx_has_album_art ON trackmetadata("has_album_art");
CREATE INDEX IF NOT EXISTS idx_tm_cover_art_id ON trackmetadata("cover_art_id");

CREATE VIRTUAL TABLE IF NOT EXISTS fts_tracks USING fts5(
    title, artist_name, album_name,
    content='', content_rowid='id', tokenize='unicode61'
);

CREATE VIRTUAL TABLE IF NOT EXISTS fts_artists USING fts5(
    name,
    content='', content_rowid='id', tokenize='unicode61'
);

CREATE VIRTUAL TABLE IF NOT EXISTS fts_albums USING fts5(
    name, artist_name,
    content='', content_rowid='id', tokenize='unicode61'
);

CREATE TABLE IF NOT EXISTS app_settings (
    key   TEXT NOT NULL PRIMARY KEY,
    value TEXT NOT NULL
);

-- Tombstones for tracks deleted from the server. The frontend's incremental
-- sync only sees rows currently in `tracks`/`trackmetadata` (hard deletes leave
-- no trace), so without a record of removed uuids the client cannot tell that
-- something disappeared and stale rows linger until a full local reset.
CREATE TABLE IF NOT EXISTS track_tombstones (
    "uuid_id"    TEXT PRIMARY KEY,
    "deleted_at" INTEGER NOT NULL,
    -- Monotonic sync watermark, assigned from revision_counter on delete.
    "revision"   INTEGER NOT NULL DEFAULT 0,
    "owner_id"   INTEGER NOT NULL REFERENCES users("id")
);

CREATE INDEX IF NOT EXISTS idx_track_tombstones_deleted_at
    ON track_tombstones("deleted_at");

CREATE INDEX IF NOT EXISTS idx_track_tombstones_revision
    ON track_tombstones("revision");

CREATE INDEX IF NOT EXISTS idx_track_tombstones_owner_revision
    ON track_tombstones("owner_id", "revision");

-- Single-row monotonic counter (id pinned to 0). Every add/update/delete
-- allocates the next value inside its write transaction, giving incremental
-- sync a gap-free, clock-independent ordering for tracks and tombstones.
CREATE TABLE IF NOT EXISTS revision_counter (
    "id"    INTEGER PRIMARY KEY CHECK ("id" = 0),
    "value" INTEGER NOT NULL
);

INSERT OR IGNORE INTO revision_counter ("id", "value") VALUES (0, 0);

-- Crash-safety journal for master-file edits. A row is written *before* the
-- destructive filesystem step (a relocate move, or an in-place tag overwrite)
-- so a crash in the move<->commit window is finished or reverted by an
-- idempotent reconcile pass at startup. `intent` dispatches the recovery;
-- Phase 2 adds an "intent='convert'" branch on this same table.
CREATE TABLE IF NOT EXISTS edit_journal (
    "id"         INTEGER PRIMARY KEY,
    "intent"     TEXT NOT NULL,
    "uuid_id"    TEXT NOT NULL,
    "old_path"   TEXT,
    "new_path"   TEXT,
    "temp_path"  TEXT,
    "created_at" INTEGER NOT NULL,
    "owner_id"   INTEGER NOT NULL REFERENCES users("id")
);

-- Durable master-type conversion jobs (Phase 2). `status` is one of
-- queued/running/done/failed/cancelled; the actual FS/DB commit for a
-- conversion is guarded by an "intent='convert'" edit_journal row, not this
-- table -- this table is job lifecycle/visibility, not crash-safety.
-- `batch_id` is a nullable hook for a future bulk-conversion feature.
CREATE TABLE IF NOT EXISTS conversion_jobs (
    "id"               INTEGER PRIMARY KEY AUTOINCREMENT,
    "uuid_id"          TEXT NOT NULL,
    "target_codec"     TEXT NOT NULL,
    "target_container" TEXT NOT NULL,
    "target_bitrate"   INTEGER,
    "status"           TEXT NOT NULL DEFAULT 'queued',
    "error_text"       TEXT,
    "batch_id"         TEXT, -- TODO(bulk-jobs): set by a future bulk enqueue
    "created_at"       INTEGER NOT NULL DEFAULT (unixepoch()),
    "updated_at"       INTEGER NOT NULL DEFAULT (unixepoch()),
    "base_revision"    INTEGER,
    "owner_id"         INTEGER NOT NULL REFERENCES users("id")
);

CREATE INDEX IF NOT EXISTS idx_conversion_jobs_uuid ON conversion_jobs("uuid_id");
CREATE INDEX IF NOT EXISTS idx_conversion_jobs_status ON conversion_jobs("status");
CREATE INDEX IF NOT EXISTS idx_conversion_jobs_owner_id ON conversion_jobs("owner_id", "id");

CREATE TABLE IF NOT EXISTS history_events (
    "event_uuid" TEXT NOT NULL PRIMARY KEY,
    "revision" INTEGER NOT NULL UNIQUE CHECK (revision > 0),
    "kind" TEXT NOT NULL CHECK (length(kind) BETWEEN 1 AND 64),
    "entity_type" TEXT NOT NULL CHECK (length(entity_type) BETWEEN 1 AND 64),
    "entity_ref" TEXT NOT NULL CHECK (length(entity_ref) BETWEEN 1 AND 256),
    "occurred_at" INTEGER NOT NULL CHECK (occurred_at BETWEEN 0 AND 253402300799999),
    "seconds_played" REAL CHECK (seconds_played IS NULL OR seconds_played >= 0),
    "track_length" REAL CHECK (track_length IS NULL OR track_length > 0),
    "received_at" INTEGER NOT NULL,
    "owner_id" INTEGER NOT NULL REFERENCES users("id")
);

CREATE INDEX IF NOT EXISTS idx_history_events_owner_revision
    ON history_events("owner_id", "revision");

CREATE TABLE IF NOT EXISTS history_hook_failures (
    "id" INTEGER PRIMARY KEY,
    "subscriber" TEXT NOT NULL,
    "event_uuid" TEXT NOT NULL,
    "error" TEXT NOT NULL,
    "created_at" INTEGER NOT NULL
);

-- Audio identity (Phase 6.5): one row per track; see the 6.5 spec section 6.1.
CREATE TABLE IF NOT EXISTS track_audio_identity (
  uuid_id         TEXT PRIMARY KEY REFERENCES tracks(uuid_id) ON DELETE CASCADE,
  generation      INTEGER NOT NULL DEFAULT 0,
  exact_state     TEXT NOT NULL CHECK (exact_state IN ('pending','current','failed','unsupported')),
  exact_kind      TEXT CHECK (exact_kind IN ('pcm_sha256','pcm_float_sha256','packets_sha256')),
  exact_digest    TEXT,
  sample_rate_hz  INTEGER, channels INTEGER, bits_per_sample INTEGER,
  fp_state        TEXT NOT NULL CHECK (fp_state IN
                    ('pending','current','unavailable','too_short','low_information','failed')),
  fp_algorithm    TEXT,
  match_state     TEXT NOT NULL DEFAULT 'pending' CHECK (match_state IN ('pending','current')),
  matcher_version TEXT,
  failure_reason  TEXT,
  attempts        INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER,
  priority        INTEGER NOT NULL DEFAULT 1,
  stat_size       INTEGER, stat_mtime_ns INTEGER, stat_inode INTEGER,
  computed_at     INTEGER,
  tool_versions   TEXT
);
CREATE INDEX IF NOT EXISTS idx_tai_exact ON track_audio_identity(exact_kind, exact_digest)
  WHERE exact_digest IS NOT NULL AND exact_state IN ('current','pending');
CREATE INDEX IF NOT EXISTS idx_tai_work  ON track_audio_identity(priority, next_attempt_at)
  WHERE exact_state = 'pending' OR fp_state = 'pending' OR match_state = 'pending';

-- Separate table: ~3.8 KB blobs stay out of identity scans.
-- data = raw little-endian uint32 items, first 120 s.
CREATE TABLE IF NOT EXISTS track_audio_fingerprint (
  uuid_id     TEXT PRIMARY KEY REFERENCES track_audio_identity(uuid_id) ON DELETE CASCADE,
  backend     TEXT NOT NULL, algorithm TEXT NOT NULL,
  duration_s  REAL NOT NULL CHECK (duration_s > 0), item_count INTEGER NOT NULL,
  data        BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_taf_duration ON track_audio_fingerprint(duration_s);

-- The composite FKs below need a UNIQUE parent key, so this index comes first.
CREATE UNIQUE INDEX IF NOT EXISTS idx_tracks_uuid_owner ON tracks(uuid_id, owner_id);

-- band_rank: 0 exact / 1 strong / 2 possible. sort_score is 1.0 for exact and never NULL (keyset-safe).
-- The composite FKs back the per-owner rule (SC-28): both partners are that owner's tracks.
CREATE TABLE IF NOT EXISTS track_duplicate_candidates (
  owner_id   INTEGER NOT NULL REFERENCES users(id),
  uuid_a     TEXT NOT NULL,
  uuid_b     TEXT NOT NULL,
  kind       TEXT NOT NULL CHECK (kind IN ('exact','fingerprint')),
  band_rank  INTEGER NOT NULL CHECK (band_rank IN (0,1,2)),
  sort_score REAL NOT NULL,
  matcher_version TEXT NOT NULL,
  detected_at INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','dismissed')),
  status_changed_at INTEGER,
  PRIMARY KEY (uuid_a, uuid_b),
  CHECK (uuid_a < uuid_b),
  FOREIGN KEY (uuid_a, owner_id) REFERENCES tracks(uuid_id, owner_id) ON DELETE CASCADE,
  FOREIGN KEY (uuid_b, owner_id) REFERENCES tracks(uuid_id, owner_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_tdc_b    ON track_duplicate_candidates(uuid_b);
-- idx_tdc_list serves Phase 8's per-owner keyset list.
CREATE INDEX IF NOT EXISTS idx_tdc_list ON track_duplicate_candidates(owner_id, status, band_rank, sort_score DESC, uuid_a, uuid_b);

-- One liveness definition (SC-25): the finder, the candidate refresh and Phase 8's list join through this view; Phase 8 adds its pending-deletion marker here, and no consumer writes its own predicate.
CREATE VIEW IF NOT EXISTS live_tracks AS SELECT id, uuid_id, owner_id, file_path FROM tracks;

-- Phase 7 (v15) upload tables. Client uuids are unique per owner only (decision O2);
-- a batch's status is derived from its items, never stored.
CREATE TABLE IF NOT EXISTS upload_batches (
  owner_id   INTEGER NOT NULL REFERENCES users(id),
  batch_uuid TEXT NOT NULL,
  label      TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (owner_id, batch_uuid)
);
CREATE INDEX IF NOT EXISTS idx_upload_batches_list ON upload_batches(owner_id, created_at, batch_uuid);

-- upload_items: one row per client file or ZIP member (spec §3 states). ZIP children name
-- their member and never nest; terminal receipts carry the track.
CREATE TABLE IF NOT EXISTS upload_items (
  owner_id             INTEGER NOT NULL REFERENCES users(id),
  item_uuid            TEXT NOT NULL,
  batch_uuid           TEXT NOT NULL,
  parent_item_uuid     TEXT,
  kind                 TEXT CHECK (kind IN ('audio','zip')),
  filename             TEXT NOT NULL,
  selection_index      INTEGER NOT NULL CHECK (selection_index >= 0),
  member_order_key     TEXT NOT NULL DEFAULT '',
  expected_bytes       INTEGER CHECK (expected_bytes >= 0),
  expected_sha256      TEXT CHECK (length(expected_sha256) = 64 AND expected_sha256 NOT GLOB '*[^0-9a-f]*'),
  received_bytes       INTEGER NOT NULL DEFAULT 0 CHECK (received_bytes >= 0),
  received_sha256      TEXT CHECK (length(received_sha256) = 64 AND received_sha256 NOT GLOB '*[^0-9a-f]*'),
  part_path            TEXT,
  source_path          TEXT,
  detected_metadata    TEXT,
  review_version       INTEGER NOT NULL DEFAULT 0 CHECK (review_version >= 0),
  state                TEXT NOT NULL CHECK (state IN ('allocated','receiving','validating','review_ready','committing','imported','duplicate','expanded','failed','duplicate_conflict','expired','cancelled')),
  error_code           TEXT,
  error_message        TEXT,
  error_retryable      INTEGER CHECK (error_retryable IN (0,1)),
  cancel_requested     INTEGER NOT NULL DEFAULT 0 CHECK (cancel_requested IN (0,1)),
  lease_boot_id        TEXT,
  duplicate_report     TEXT,
  conflict_track_uuids TEXT,
  skipped_members      INTEGER CHECK (skipped_members >= 0),
  reserved_track_uuid  TEXT,
  final_path           TEXT,
  result_track_uuid    TEXT,
  result_revision      INTEGER,
  duplicate_kind       TEXT CHECK (duplicate_kind IN ('exact','fingerprint')),
  created_at           INTEGER NOT NULL,
  updated_at           INTEGER NOT NULL,
  progress_at          INTEGER NOT NULL,
  PRIMARY KEY (owner_id, item_uuid),
  UNIQUE (owner_id, batch_uuid, item_uuid),
  FOREIGN KEY (owner_id, batch_uuid) REFERENCES upload_batches(owner_id, batch_uuid) ON DELETE CASCADE,
  FOREIGN KEY (owner_id, batch_uuid, parent_item_uuid) REFERENCES upload_items(owner_id, batch_uuid, item_uuid) ON DELETE CASCADE,
  CHECK (parent_item_uuid IS NULL OR parent_item_uuid <> item_uuid),
  CHECK ((parent_item_uuid IS NULL) = (member_order_key = '')),
  CHECK (parent_item_uuid IS NOT NULL OR (expected_bytes IS NOT NULL AND expected_sha256 IS NOT NULL)),
  CHECK (kind IS NOT 'zip' OR parent_item_uuid IS NULL),
  CHECK (state <> 'expanded' OR kind IS 'zip'),
  CHECK (state <> 'failed' OR error_code IS NOT NULL),
  CHECK (state NOT IN ('imported','duplicate') OR result_track_uuid IS NOT NULL),
  CHECK (state <> 'imported' OR result_revision IS NOT NULL),
  CHECK ((duplicate_kind IS NOT NULL) = (state = 'duplicate'))
);
CREATE INDEX IF NOT EXISTS idx_upload_items_list ON upload_items(owner_id, batch_uuid, selection_index, member_order_key, item_uuid);
CREATE INDEX IF NOT EXISTS idx_upload_items_parent ON upload_items(owner_id, batch_uuid, parent_item_uuid);
-- idx_upload_items_state serves the workers and the janitor across owners (ANY_OWNER by design).
CREATE INDEX IF NOT EXISTS idx_upload_items_state ON upload_items(state, updated_at);
-- idx_upload_items_result serves the acknowledgement rule.
CREATE INDEX IF NOT EXISTS idx_upload_items_result ON upload_items(owner_id, result_track_uuid) WHERE result_track_uuid IS NOT NULL;

-- upload_item_audio_identity: the SC-25 serializer's columns (IDENTITY_COLUMNS + FINGERPRINT_COLUMNS
-- in services/audio_identity.py) plus fp_failure_reason. A test fails if the columns diverge from
-- the serializer. The writer sets fp_state 'unavailable'/'failed' itself when there is no print.
-- A staged identity is always computed, never pending.
CREATE TABLE IF NOT EXISTS upload_item_audio_identity (
  owner_id          INTEGER NOT NULL REFERENCES users(id),
  item_uuid         TEXT NOT NULL,
  exact_state       TEXT NOT NULL CHECK (exact_state IN ('current','failed','unsupported')),
  exact_kind        TEXT CHECK (exact_kind IN ('pcm_sha256','pcm_float_sha256','packets_sha256')),
  exact_digest      TEXT,
  sample_rate_hz    INTEGER, channels INTEGER, bits_per_sample INTEGER,
  failure_reason    TEXT,
  computed_at       INTEGER NOT NULL,
  tool_versions     TEXT,
  fp_state          TEXT NOT NULL CHECK (fp_state IN ('current','unavailable','too_short','low_information','failed')),
  fp_algorithm      TEXT,
  fp_backend        TEXT,
  fp_duration_s     REAL CHECK (fp_duration_s > 0),
  fp_item_count     INTEGER,
  fp_data           BLOB,
  fp_failure_reason TEXT,
  PRIMARY KEY (owner_id, item_uuid),
  FOREIGN KEY (owner_id, item_uuid) REFERENCES upload_items(owner_id, item_uuid) ON DELETE CASCADE,
  CHECK (exact_state <> 'current' OR (exact_kind IS NOT NULL AND exact_digest IS NOT NULL)),
  CHECK (fp_state NOT IN ('current','low_information') OR (fp_data IS NOT NULL AND fp_duration_s IS NOT NULL AND fp_backend IS NOT NULL AND fp_algorithm IS NOT NULL))
);

-- operation_receipts: SC-16c. Canonical request hash; a replay returns result_ref; the same uuid with a
-- different hash is 409 operation_conflict. Keyed (owner_id, operation_uuid) so another user's uuid is
-- invisible (O2). kind is an open set (Phase 8/9D add kinds). Never pruned in Phases 7-9.
CREATE TABLE IF NOT EXISTS operation_receipts (
  owner_id       INTEGER NOT NULL REFERENCES users(id),
  operation_uuid TEXT NOT NULL,
  kind           TEXT NOT NULL CHECK (kind <> ''),
  request_hash   TEXT NOT NULL CHECK (length(request_hash) = 64 AND request_hash NOT GLOB '*[^0-9a-f]*'),
  created_at     INTEGER NOT NULL,
  result_ref     TEXT,
  PRIMARY KEY (owner_id, operation_uuid)
);

-- storage_reservations: SC-16g ledger table. owner_id is SC-16g's owner_ref (Phase M note); subject_ref
-- names the job or item holding the bytes. AUTOINCREMENT so a released id is never reused. Logic arrives in 7A.2a.
-- The index leads with owner_id because subject_ref (an item uuid) is unique only per owner.
CREATE TABLE IF NOT EXISTS storage_reservations (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_id      INTEGER NOT NULL REFERENCES users(id),
  purpose       TEXT NOT NULL CHECK (purpose <> ''),
  subject_ref   TEXT,
  bytes         INTEGER NOT NULL CHECK (bytes >= 0),
  lease_boot_id TEXT,
  created_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_storage_reservations_owner ON storage_reservations(owner_id, purpose, subject_ref);

-- upload_item_acknowledgements: the frozen acknowledgements of an accepted commit (spec 3). Kept as long
-- as the item, because a later item's commit guard reads them (spec 6 step 3; the symmetric rule uses
-- the subject index).
CREATE TABLE IF NOT EXISTS upload_item_acknowledgements (
  owner_id     INTEGER NOT NULL REFERENCES users(id),
  item_uuid    TEXT NOT NULL,
  subject_kind TEXT NOT NULL CHECK (subject_kind IN ('library_track','staged_item')),
  subject_ref  TEXT NOT NULL,
  PRIMARY KEY (owner_id, item_uuid, subject_kind, subject_ref),
  FOREIGN KEY (owner_id, item_uuid) REFERENCES upload_items(owner_id, item_uuid) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_upload_acks_subject ON upload_item_acknowledgements(owner_id, subject_kind, subject_ref);

-- upload_commit_journal: the spec 6 publication journal, keyed by (owner_id, operation_uuid); it needs its
-- receipt. The identity columns are the SC-25 serializer's (IDENTITY_COLUMNS + FINGERPRINT_COLUMNS), NULL
-- until prepared; a NULL fp_state means the print is recomputed. cover_art_id has no FK: shared art may be
-- released and recovery re-resolves it (SC-16h). The item FK has no cascade, so an item cannot vanish
-- under its recovery record.
CREATE TABLE IF NOT EXISTS upload_commit_journal (
  owner_id                INTEGER NOT NULL REFERENCES users(id),
  operation_uuid          TEXT NOT NULL,
  item_uuid               TEXT NOT NULL,
  state                   TEXT NOT NULL CHECK (state IN ('committing','prepared','moved','imported','duplicate_conflict','failed')),
  base_review_version     INTEGER NOT NULL CHECK (base_review_version >= 0),
  reserved_track_uuid     TEXT NOT NULL,
  edits                   TEXT NOT NULL,
  write_tags              INTEGER NOT NULL CHECK (write_tags IN (0,1)),
  acknowledged_duplicates TEXT NOT NULL,
  source_path             TEXT NOT NULL,
  work_path               TEXT,
  final_path              TEXT,
  final_metadata          TEXT,
  cover_art_id            INTEGER,
  cover_art_created       INTEGER CHECK (cover_art_created IN (0,1)),
  exact_state             TEXT CHECK (exact_state IN ('current','failed','unsupported')),
  exact_kind              TEXT CHECK (exact_kind IN ('pcm_sha256','pcm_float_sha256','packets_sha256')),
  exact_digest            TEXT,
  sample_rate_hz          INTEGER, channels INTEGER, bits_per_sample INTEGER,
  failure_reason          TEXT,
  computed_at             INTEGER,
  tool_versions           TEXT,
  fp_state                TEXT CHECK (fp_state IN ('current','unavailable','too_short','low_information','failed')),
  fp_algorithm            TEXT,
  fp_backend              TEXT,
  fp_duration_s           REAL CHECK (fp_duration_s > 0),
  fp_item_count           INTEGER,
  fp_data                 BLOB,
  digest_check            TEXT CHECK (digest_check IN ('verified','changed','computed','unverified')),
  error_code              TEXT,
  lease_boot_id           TEXT,
  created_at              INTEGER NOT NULL,
  updated_at              INTEGER NOT NULL,
  PRIMARY KEY (owner_id, operation_uuid),
  FOREIGN KEY (owner_id, operation_uuid) REFERENCES operation_receipts(owner_id, operation_uuid),
  FOREIGN KEY (owner_id, item_uuid) REFERENCES upload_items(owner_id, item_uuid)
);
CREATE INDEX IF NOT EXISTS idx_upload_journal_item ON upload_commit_journal(owner_id, item_uuid);

PRAGMA user_version = 15;
COMMIT;
