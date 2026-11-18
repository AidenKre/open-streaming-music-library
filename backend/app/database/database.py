import dataclasses
import fcntl
import json
import logging
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import unicodedata
import uuid
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass
from enum import Flag, auto
from pathlib import Path
from time import time_ns
from urllib.parse import quote
from typing import Any, Callable, List, Literal, Mapping, Optional

from app.core.operator_log import operator_logger
from app.database.operation_receipts import (
    New as OpNew,
    OperationConflict,
    Replay as OpReplay,
    request_hash,
)
from app.database.table_registry import REGISTRY, owner_predicate
from app.models.album import Album
from app.models.artist import Artist
from app.models.cover_art import CoverArt
from app.models.edit_fields import EDIT_FIELD_SPECS
from app.models.history import HistoryEvent
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData

logger = logging.getLogger(__name__)

# TODO: catch specific sqlite3 exceptions rather than broad Exception

ALLOWED_METADATA_COLUMNS = [
    "title",
    "artist",
    "album",
    "album_artist",
    "year",
    "date",
    "genre",
    "track_number",
    "disc_number",
    "codec",
    "duration",
    "bitrate_kbps",
    "sample_rate_hz",
    "channels",
    "has_album_art",
    "cover_art_id",
]

# Track tag fields a user may edit via Get Info / PATCH — derived from the
# single field-spec table (see app/models/edit_fields.py). Deliberately NOT
# ``ALLOWED_METADATA_COLUMNS`` — that list includes audio-derived columns
# (codec/duration/bitrate_kbps/sample_rate_hz/channels/has_album_art/
# cover_art_id) which must never be hand-edited.
EDITABLE_METADATA_COLUMNS = [spec.key for spec in EDIT_FIELD_SPECS]

ALLOWED_TRACK_COLUMNS = ["uuid_id", "created_at", "last_updated"]

# Why a track's audio identity went stale (see _mark_audio_identity_stale_in).
STALE_REASONS = frozenset({"tag_write", "conversion", "settle"})

ALLOWED_ALBUM_COLUMNS = ["id", "name", "artist", "artist_id", "year", "is_single_grouping"]
ALBUM_TEXT_COLUMNS = {"name", "artist"}
ALBUM_INTEGER_COLUMNS = {"id", "artist_id", "year", "is_single_grouping"}

ALLOWED_ARTIST_COLUMNS = ["id", "name"]
ARTIST_TEXT_COLUMNS = {"name"}

ALLOWED_OPERATORS = ["=", ">=", "<=", "<", ">"]


DELETION_ITEM_TERMINAL_STATES = ("deleted", "already_deleted", "conflict", "busy", "failed")


class _AnyOwner:
    """Sentinel for the few reads that deliberately span all owners."""

    def __repr__(self) -> str:
        return "ANY_OWNER"


ANY_OWNER = _AnyOwner()

# An owner argument: a real user id, or ANY_OWNER where a method allows it.
Owner = int | _AnyOwner


def _is_real_owner(owner_id: object) -> bool:
    return isinstance(owner_id, int) and not isinstance(owner_id, bool)


MATCHER_VERSION_SETTING = "matcher_version"
FINGERPRINT_DURATION_RULE_SETTING = "fingerprint_duration_rule"
FINGERPRINT_CLASSIFIER_VERSION_SETTING = "fingerprint_classifier_version"

# Layer states that mean "this track can definitively not be compared on that
# layer". A track that settles into one of them keeps no open duplicate pairs of
# that kind. 'failed' is not one of them: it means unknown, and unknown is not
# "no match", so a failed layer keeps its pairs as they are.
EXACT_NOT_COMPARABLE_STATES = frozenset({"unsupported"})
FINGERPRINT_NOT_COMPARABLE_STATES = frozenset({"too_short", "low_information"})


@dataclass(frozen=True)
class StorageTotals:
    """Bytes held by the storage ledger: all rows, staged purposes, and one owner's staged."""

    reserved: int
    staged: int
    user_staged: int


def _require_owner(owner_id: object) -> int:
    """Validate the owner of an insert/write: only a real int is accepted."""
    if not _is_real_owner(owner_id):
        raise TypeError(f"owner_id must be an int, got {owner_id!r}")
    return owner_id  # type: ignore[return-value]


def _and_owner(column: str, owner_id: object) -> tuple[str, tuple]:
    """``_owner_predicate`` as a suffix to append to an existing WHERE."""
    clause, params = _owner_predicate(column, owner_id)
    return (f" AND {clause}" if clause else ""), params


def _owner_predicate(column: str, owner_id: object) -> tuple[str, tuple]:
    """SQL predicate and params scoping a read to an owner (none for ANY_OWNER)."""
    if owner_id is ANY_OWNER:
        return "", ()
    return f"{column} = ?", (_require_owner(owner_id),)


# The v14 objects, created by the 13 -> 14 step. Each statement's text matched
# init.sql's v14 (minus IF NOT EXISTS); since v16 the 15 -> 16 step replaces
# live_tracks, and the fresh-vs-migrated parity tests compare the end result.
SCHEMA_V14_DDL = (
    """CREATE TABLE track_audio_identity (
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
)""",
    """CREATE INDEX idx_tai_exact ON track_audio_identity(exact_kind, exact_digest)
  WHERE exact_digest IS NOT NULL AND exact_state IN ('current','pending')""",
    """CREATE INDEX idx_tai_work  ON track_audio_identity(priority, next_attempt_at)
  WHERE exact_state = 'pending' OR fp_state = 'pending' OR match_state = 'pending'""",
    """CREATE TABLE track_audio_fingerprint (
  uuid_id     TEXT PRIMARY KEY REFERENCES track_audio_identity(uuid_id) ON DELETE CASCADE,
  backend     TEXT NOT NULL, algorithm TEXT NOT NULL,
  duration_s  REAL NOT NULL CHECK (duration_s > 0), item_count INTEGER NOT NULL,
  data        BLOB NOT NULL
)""",
    """CREATE INDEX idx_taf_duration ON track_audio_fingerprint(duration_s)""",
    """CREATE UNIQUE INDEX idx_tracks_uuid_owner ON tracks(uuid_id, owner_id)""",
    """CREATE TABLE track_duplicate_candidates (
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
)""",
    """CREATE INDEX idx_tdc_b    ON track_duplicate_candidates(uuid_b)""",
    """CREATE INDEX idx_tdc_list ON track_duplicate_candidates(owner_id, status, band_rank, sort_score DESC, uuid_a, uuid_b)""",
    """CREATE VIEW live_tracks AS SELECT id, uuid_id, owner_id, file_path FROM tracks""",
)


# The v15 objects, created by the 14 -> 15 step. Each statement's text must match
# init.sql's (minus IF NOT EXISTS); the fresh-vs-migrated parity test in
# tests/test_schema_upgrade_v15.py enforces it.
SCHEMA_V15_DDL: tuple[str, ...] = (
    """CREATE TABLE upload_batches (
  owner_id   INTEGER NOT NULL REFERENCES users(id),
  batch_uuid TEXT NOT NULL,
  label      TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (owner_id, batch_uuid)
)""",
    "CREATE INDEX idx_upload_batches_list ON upload_batches(owner_id, created_at, batch_uuid)",
    """CREATE TABLE upload_items (
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
)""",
    "CREATE INDEX idx_upload_items_list ON upload_items(owner_id, batch_uuid, selection_index, member_order_key, item_uuid)",
    "CREATE INDEX idx_upload_items_parent ON upload_items(owner_id, batch_uuid, parent_item_uuid)",
    "CREATE INDEX idx_upload_items_state ON upload_items(state, updated_at)",
    "CREATE INDEX idx_upload_items_result ON upload_items(owner_id, result_track_uuid) WHERE result_track_uuid IS NOT NULL",
    """CREATE TABLE upload_item_audio_identity (
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
)""",
    """CREATE TABLE operation_receipts (
  owner_id       INTEGER NOT NULL REFERENCES users(id),
  operation_uuid TEXT NOT NULL,
  kind           TEXT NOT NULL CHECK (kind <> ''),
  request_hash   TEXT NOT NULL CHECK (length(request_hash) = 64 AND request_hash NOT GLOB '*[^0-9a-f]*'),
  created_at     INTEGER NOT NULL,
  result_ref     TEXT,
  PRIMARY KEY (owner_id, operation_uuid)
)""",
    """CREATE TABLE storage_reservations (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_id      INTEGER NOT NULL REFERENCES users(id),
  purpose       TEXT NOT NULL CHECK (purpose <> ''),
  subject_ref   TEXT,
  bytes         INTEGER NOT NULL CHECK (bytes >= 0),
  lease_boot_id TEXT,
  created_at    INTEGER NOT NULL
)""",
    "CREATE INDEX idx_storage_reservations_owner ON storage_reservations(owner_id, purpose, subject_ref)",
    """CREATE TABLE upload_item_acknowledgements (
  owner_id     INTEGER NOT NULL REFERENCES users(id),
  item_uuid    TEXT NOT NULL,
  subject_kind TEXT NOT NULL CHECK (subject_kind IN ('library_track','staged_item')),
  subject_ref  TEXT NOT NULL,
  PRIMARY KEY (owner_id, item_uuid, subject_kind, subject_ref),
  FOREIGN KEY (owner_id, item_uuid) REFERENCES upload_items(owner_id, item_uuid) ON DELETE CASCADE
)""",
    "CREATE INDEX idx_upload_acks_subject ON upload_item_acknowledgements(owner_id, subject_kind, subject_ref)",
    """CREATE TABLE upload_commit_journal (
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
)""",
    "CREATE INDEX idx_upload_journal_item ON upload_commit_journal(owner_id, item_uuid)",
)


# The v16 objects, created by the 15 -> 16 step. Each statement's text must match
# init.sql's (minus IF NOT EXISTS); the fresh-vs-migrated parity test in
# tests/test_schema_upgrade_v16.py enforces it. The DROP VIEW is migration-only
# (init.sql has no DROP); the parity test compares the resulting sqlite_master.
SCHEMA_V16_DDL: tuple[str, ...] = (
    """CREATE TABLE deletion_jobs (
  owner_id       INTEGER NOT NULL REFERENCES users(id),
  operation_uuid TEXT NOT NULL,
  created_at     INTEGER NOT NULL,
  status         TEXT NOT NULL CHECK (status IN ('accepted','completed')),
  PRIMARY KEY (owner_id, operation_uuid),
  FOREIGN KEY (owner_id, operation_uuid) REFERENCES operation_receipts(owner_id, operation_uuid)
)""",
    "CREATE INDEX idx_deletion_jobs_list ON deletion_jobs(owner_id, created_at, operation_uuid)",
    """CREATE TABLE deletion_job_items (
  owner_id           INTEGER NOT NULL REFERENCES users(id),
  operation_uuid     TEXT NOT NULL,
  uuid_id            TEXT NOT NULL,
  position           INTEGER NOT NULL CHECK (position >= 0),
  base_revision      INTEGER NOT NULL,
  status             TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','running','deleted','already_deleted','conflict','busy','failed')),
  error_code         TEXT,
  tombstone_revision INTEGER,
  detail_json        TEXT,
  lease_boot_id      TEXT,
  cancel_requested   INTEGER NOT NULL DEFAULT 0 CHECK (cancel_requested IN (0,1)),
  PRIMARY KEY (owner_id, operation_uuid, uuid_id),
  UNIQUE (owner_id, operation_uuid, position),
  FOREIGN KEY (owner_id, operation_uuid) REFERENCES deletion_jobs(owner_id, operation_uuid),
  CHECK (status <> 'failed' OR error_code IS NOT NULL),
  CHECK (status NOT IN ('deleted','already_deleted') OR tombstone_revision IS NOT NULL)
)""",
    """CREATE TABLE deletion_journal (
  owner_id        INTEGER NOT NULL REFERENCES users(id),
  operation_uuid  TEXT NOT NULL,
  uuid_id         TEXT NOT NULL UNIQUE,
  original_path   TEXT NOT NULL,
  quarantine_path TEXT,
  base_revision   INTEGER NOT NULL,
  src_dev         INTEGER,
  src_ino         INTEGER,
  src_size        INTEGER,
  src_mtime_ns    INTEGER,
  exact_digest    TEXT,
  cover_art_id    INTEGER,
  master_missing  INTEGER NOT NULL CHECK (master_missing IN (0,1)),
  stage           TEXT NOT NULL CHECK (stage IN ('intent','moved','committed')),
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (owner_id, operation_uuid, uuid_id),
  FOREIGN KEY (owner_id, operation_uuid, uuid_id) REFERENCES deletion_job_items(owner_id, operation_uuid, uuid_id),
  CHECK (master_missing = 1 OR (quarantine_path IS NOT NULL AND src_dev IS NOT NULL AND src_ino IS NOT NULL AND src_size IS NOT NULL)),
  CHECK (master_missing = 0 OR quarantine_path IS NULL)
)""",
    """CREATE TRIGGER deletion_journal_names_own_track BEFORE INSERT ON deletion_journal
WHEN NOT EXISTS (SELECT 1 FROM tracks WHERE uuid_id = NEW.uuid_id AND owner_id = NEW.owner_id)
BEGIN
  SELECT RAISE(ABORT, 'deletion_journal must name a track of its owner');
END""",
    """CREATE TRIGGER deletion_journal_keeps_its_track BEFORE UPDATE OF owner_id, uuid_id ON deletion_journal
WHEN NEW.owner_id IS NOT OLD.owner_id OR NEW.uuid_id IS NOT OLD.uuid_id
BEGIN
  SELECT RAISE(ABORT, 'deletion_journal owner and track never change');
END""",
    "DROP VIEW live_tracks",
    """CREATE VIEW live_tracks AS SELECT id, uuid_id, owner_id, file_path FROM tracks
  WHERE NOT EXISTS (SELECT 1 FROM deletion_journal d WHERE d.uuid_id = tracks.uuid_id)""",
)


class SchemaVersionRefused(Exception):
    """Fatal startup error: the database file is not at the supported schema."""

    def __init__(
        self,
        found_version: int,
        supported_version: int,
        minimum_version: int | None = None,
    ):
        self.found_version = found_version
        if minimum_version is None:
            minimum_version = supported_version
        if minimum_version <= found_version < supported_version:
            message = (
                f"This database is at schema {found_version}; start the server once "
                f"to upgrade it to schema {supported_version}, then run this command again."
            )
        elif found_version < minimum_version:
            message = (
                f"This database predates multi-user support (schema {found_version}). "
                "Back it up, start with a fresh APP_DATA_DIR, and re-import your music."
            )
        else:
            message = (
                f"This database was written by a newer OSML server (schema {found_version}); "
                f"it is newer than this server (schema {supported_version} supported). "
                "Upgrade the server or start with a fresh APP_DATA_DIR."
            )
        super().__init__(message)


def _fold_path(p):
    if p is None:
        return None
    nfd = unicodedata.normalize
    return nfd("NFD", nfd("NFD", p).casefold())

class DatabaseUnreadable(Exception):
    """Fatal: the database path holds a file SQLite cannot read."""


class DatabaseMissing(Exception):
    """There is no database file yet (the CLI never creates one)."""


class CoverArtGone(Exception):
    """A track insert referenced a cover_art_id whose row was released after the
    id was handed out; the caller must re-register the art and retry."""


class OwnerMismatch(Exception):
    """A track's artist or album row belongs to a different owner than the track.

    Raised by the post-upsert consistency check; it means an owner predicate was
    missed somewhere, never a normal condition.
    """


class UsernameTaken(Exception):
    """Another user already owns the requested username key."""


class HistoryEventConflict(Exception):
    def __init__(self, event_uuids: list[str]):
        self.event_uuids = event_uuids
        super().__init__("History event payload conflict")


# Item columns the API may read; server-internal ones (part_path, source_path,
# final_path, lease_boot_id) are deliberately absent so a path cannot leak.
_UPLOAD_ITEM_API_COLUMNS = (
    "item_uuid", "batch_uuid", "parent_item_uuid", "filename", "selection_index",
    "member_order_key", "state", "expected_bytes", "expected_sha256",
    "received_bytes", "review_version", "error_code", "error_message",
    "error_retryable", "created_at", "updated_at", "detected_metadata", "duplicate_report",
    "kind", "skipped_members",
    "result_track_uuid", "result_revision", "duplicate_kind", "conflict_track_uuids",
)


# Columns a state transition may set besides state/updated_at. Never
# interpolate a name that is not listed here.
_UPLOAD_TRANSITION_FIELDS = frozenset(
    {"error_code", "error_message", "error_retryable", "cancel_requested", "reserved_track_uuid",
     "result_track_uuid", "result_revision", "final_path", "lease_boot_id",
     "conflict_track_uuids", "duplicate_kind", "progress_at"}
)


# Item states a worker holds (a transfer or a validation): cancelling one sets
# the durable flag.
_LEASED_STATES = frozenset({"receiving", "validating"})


class UploadItemsInUse(Exception):
    def __init__(self, item_uuids: list[str]):
        self.item_uuids = item_uuids
        super().__init__("Upload item IDs already in use")


class TrackNotFound(Exception):
    """Raised when a metadata edit targets a uuid that no longer exists."""


class DeletionRecheckFailed(Exception):
    """The owner's track no longer matches what the deletion worker journaled
    (gone, another revision or another path); nothing was changed."""


class TrackAlreadyDeleted(Exception):
    """``_delete_track_in`` met the owner's own tombstone for the uuid: the
    track is already deleted, and its tombstone revision is not bumped again."""

    def __init__(self, uuid_id: str, revision: int):
        self.uuid_id = uuid_id
        self.revision = revision
        super().__init__(f"track {uuid_id} is already deleted (revision {revision})")


class TrackPendingDeletion(Exception):
    """A mutator met the pending-deletion marker (a ``deletion_journal`` row)
    under the track lock. Retryable: a rolled-back deletion leaves a healthy
    track."""

    def __init__(self, uuid_id: str):
        self.uuid_id = uuid_id
        super().__init__(f"track {uuid_id} is pending deletion")


class EmptyTrackEdit(Exception):
    """Raised when an edit would blank a track's whole identity (title, artist,
    and album all empty). Distinct from ``add_track``'s ``is_empty`` audio-field
    check — this guards the human-meaningful fields."""


class RevisionConflict(Exception):
    """Raised when an edit's ``base_revision`` no longer matches the stored
    revision — the row moved on under the editor (Option A 409)."""

    def __init__(self, uuid_id: str, base_revision: Optional[int], current_revision: int):
        self.uuid_id = uuid_id
        self.base_revision = base_revision
        self.current_revision = current_revision
        super().__init__(
            f"revision conflict on {uuid_id}: base={base_revision} "
            f"current={current_revision}"
        )


class ConversionJobActive(Exception):
    """A conversion is already queued or running for this uuid."""

    def __init__(self, uuid_id: str, job_id: int):
        self.uuid_id = uuid_id
        self.job_id = job_id
        super().__init__(f"conversion job {job_id} already active for {uuid_id}")


class ConversionJobNotRunning(Exception):
    """The job left 'running' (e.g. cancelled) before its result committed."""


# Leading 4-digit year prefix of a `date` string (e.g. "2019-05-01" -> "2019").
_YEAR_PREFIX = re.compile(r"^\s*(\d{4})")


def normalize_edit_fields(fields: dict) -> dict:
    """Canonicalize a validated edit-field dict before it is applied or used to
    derive file/tag/path state. Idempotent; returns a new dict; an untouched
    field stays untouched.

    - NFC-normalizes every string value: the identity upsert is keyed on
      ``LOWER(name)`` (which doesn't fold Unicode composition), and the on-disk
      layout must be derived from the same bytes the DB stores.
    - Keeps ``year``/``date`` consistent, with ``date`` canonical: editing
      ``date`` re-derives ``year`` from its leading 4 digits (unparseable /
      cleared -> ``year`` cleared); editing only ``year`` sets ``date`` to the
      bare year.

    Lives in the spine so every caller of ``apply_track_metadata_edit`` (PATCH
    today; conversion and bulk edit later) gets the invariants without knowing
    about them."""
    out = {
        k: unicodedata.normalize("NFC", v) if isinstance(v, str) else v
        for k, v in fields.items()
    }
    if "date" in out:
        d = out["date"]
        m = _YEAR_PREFIX.match(d) if isinstance(d, str) else None
        out["year"] = int(m.group(1)) if m else None
    elif "year" in out:
        y = out["year"]
        out["date"] = str(y) if y is not None else None
    return out


def effective_artist(album_artist: Optional[str], artist: Optional[str]) -> Optional[str]:
    """The artist that owns a track's library identity: album_artist wins, then
    artist, else None. Shared by ``add_track``, the metadata-edit spine, and the
    organizer's ``sanitized_destination_path`` so DB identity and on-disk layout are
    computed one way everywhere and can't diverge."""
    if album_artist and album_artist.strip():
        return album_artist.strip()
    if artist and artist.strip():
        return artist.strip()
    return None


class SearchEntityType(Flag):
    TRACKS = auto()
    ARTISTS = auto()
    ALBUMS = auto()


@dataclass(frozen=True)
class SearchResults:
    tracks: List[Track]
    artists: List[Artist]
    albums: List[Album]


@dataclass(frozen=True)
class TrackChange:
    """One ordered entry in the revision-based change stream. ``track`` is the
    hydrated row for ``type == "upsert"`` and ``None`` for ``type == "delete"``."""

    type: Literal["upsert", "delete"]
    revision: int
    uuid_id: str
    track: Optional[Track] = None


@dataclass(frozen=True)
class DatabaseContext:
    database_path: Path
    init_sql_path: Path


@dataclass(frozen=True)
class SearchParameter:
    column: str
    operator: str
    value: Optional[str]

    def __post_init__(self):
        if self.operator not in ALLOWED_OPERATORS:
            raise ValueError("operator must be in ALLOWED_OPERATORS")

        if self.column not in set(ALLOWED_TRACK_COLUMNS + ALLOWED_METADATA_COLUMNS):
            raise ValueError(
                "column must be in ALLOWED_TRACK_COLUMNS or ALLOWED_METADATA_COLUMNS"
            )


@dataclass(frozen=True)
class OrderParameter:
    column: str
    isAscending: bool = True

    def __post_init__(self):
        if self.column not in set(ALLOWED_TRACK_COLUMNS + ALLOWED_METADATA_COLUMNS):
            raise ValueError(
                "column must be in ALLOWED_TRACK_COLUMNS or ALLOWED_METADATA_COLUMNS"
            )


@dataclass(frozen=True)
class RowFilterParameter:
    column: str
    value: Optional[str]

    def __post_init__(self):
        if self.column not in set(ALLOWED_TRACK_COLUMNS + ALLOWED_METADATA_COLUMNS):
            raise ValueError(
                "column must be in ALLOWED_TRACK_COLUMNS or ALLOWED_METADATA_COLUMNS"
            )


@dataclass(frozen=True)
class AlbumOrderParameter:
    column: str
    isAscending: bool = True
    nullsLast: bool = False

    def __post_init__(self):
        if self.column not in ALLOWED_ALBUM_COLUMNS:
            raise ValueError("column must be in ALLOWED_ALBUM_COLUMNS")


@dataclass(frozen=True)
class AlbumRowFilterParameter:
    column: str
    value: Optional[str]

    def __post_init__(self):
        if self.column not in ALLOWED_ALBUM_COLUMNS:
            raise ValueError("column must be in ALLOWED_ALBUM_COLUMNS")


@dataclass(frozen=True)
class ArtistOrderParameter:
    column: str
    isAscending: bool = True

    def __post_init__(self):
        if self.column not in ALLOWED_ARTIST_COLUMNS:
            raise ValueError("column must be in ALLOWED_ARTIST_COLUMNS")


@dataclass(frozen=True)
class ArtistRowFilterParameter:
    column: str
    value: Optional[str]

    def __post_init__(self):
        if self.column not in ALLOWED_ARTIST_COLUMNS:
            raise ValueError("column must be in ALLOWED_ARTIST_COLUMNS")


def _row_to_track(row) -> Track:
    metadata = TrackMetaData(
        title=row["title"],
        artist=row["artist"],
        album=row["album"],
        album_artist=row["album_artist"],
        artist_id=row["artist_id"],
        album_id=row["album_id"],
        year=row["year"],
        date=row["date"],
        genre=row["genre"],
        track_number=row["track_number"],
        disc_number=row["disc_number"],
        codec=row["codec"],
        duration=row["duration"],
        bitrate_kbps=row["bitrate_kbps"],
        sample_rate_hz=row["sample_rate_hz"],
        channels=row["channels"],
        has_album_art=bool(row["has_album_art"]),
        cover_art_id=row["cover_art_id"],
    )
    keys = row.keys()
    return Track(
        uuid_id=row["uuid_id"],
        file_path=Path(row["file_path"]),
        metadata=metadata,
        created_at=row["created_at"],
        last_updated=row["last_updated"],
        revision=row["revision"] if "revision" in keys else 0,
        owner_id=row["owner_id"] if "owner_id" in keys else None,
    )


TRACK_SELECT_COLUMNS = (
    "tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, "
    'tm.artist_id, tm.album_id, tm."year", tm."date", tm.genre, '
    "tm.track_number, tm.disc_number, tm.codec, tm.duration, "
    "tm.bitrate_kbps, tm.sample_rate_hz, tm.channels, "
    "tm.has_album_art, tm.cover_art_id, t.file_path, "
    "t.created_at, t.last_updated, t.revision, t.owner_id"
)


def _track_select_columns(*extra_columns: str) -> str:
    columns = TRACK_SELECT_COLUMNS
    if extra_columns:
        columns += ", " + ", ".join(extra_columns)
    return columns


class Database:
    def __init__(self, context: DatabaseContext):
        self.context = context

    @contextmanager
    def _connection(self, *, commit: bool = False, timeout: float = 5, immediate: bool = False):
        conn = sqlite3.connect(self.context.database_path, timeout=timeout)
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA foreign_keys=ON")
            conn.row_factory = sqlite3.Row
            if immediate:
                # Acquire SQLite's write lock up front, before the caller reads
                # anything: a plain SELECT (the default, non-immediate mode)
                # holds no lock, so a check-then-write sequence built on it is
                # not atomic across connections -- a second connection's own
                # check can pass against the same stale value before the first
                # connection's write lands. immediate=True closes that gap by
                # making a concurrent caller's own BEGIN IMMEDIATE block until
                # this transaction commits or rolls back.
                conn.execute("BEGIN IMMEDIATE")
            yield conn
            if commit:
                conn.commit()
        except BaseException:
            if commit:
                conn.rollback()
            raise
        finally:
            conn.close()

    # Schema version a freshly-initialized database lands on. ``initialize``
    # accepts MINIMUM_SCHEMA_VERSION..LATEST_SCHEMA_VERSION (upgrading in place);
    # the admin CLI accepts only LATEST. Keep LATEST in sync with ``init.sql``.
    LATEST_SCHEMA_VERSION = 16
    MINIMUM_SCHEMA_VERSION = 13

    def _existing_schema_version(self) -> int | None:
        """Version of the existing file, or None when there is no schema yet.

        Read-only and pragma-free: ``_connection()``'s WAL pragma would rewrite
        the header of a non-WAL file, so a refused file must never reach it.
        """
        path = self.context.database_path
        if not path.exists():
            return None
        # Three cases, none of which may touch the refused file's bytes,
        # mtimes or sidecars:
        # - no -wal: nothing is pending and the main file is exact; a WAL-mode
        #   file cannot open ro without sidecars, so read it immutable.
        # - -wal and -shm: pending frames must be read; readonly_shm=1 stops
        #   sqlite rewriting the -shm index.
        # - -wal but no -shm: sqlite would create the -shm, so read a copy of
        #   the main file and -wal in a temp dir that is removed afterwards.
        wal = path.with_name(path.name + "-wal")
        shm = path.with_name(path.name + "-shm")
        read_path, mode = path, "ro&immutable=1"
        try:
            with ExitStack() as stack:
                if wal.exists() and shm.exists():
                    mode = "ro&readonly_shm=1"
                elif wal.exists():
                    tmp = Path(stack.enter_context(tempfile.TemporaryDirectory()))
                    read_path = tmp / path.name
                    shutil.copyfile(path, read_path)
                    shutil.copyfile(wal, tmp / wal.name)
                    mode = "ro"
                conn = sqlite3.connect(
                    f"file:{quote(str(read_path))}?mode={mode}", uri=True
                )
                stack.callback(conn.close)  # runs before the temp dir goes
                version = conn.execute("PRAGMA user_version").fetchone()[0]
                tables = conn.execute("SELECT count(*) FROM sqlite_master").fetchone()[0]
        except (sqlite3.DatabaseError, OSError) as exc:  # OperationalError is a subclass
            if "not a database" in str(exc):
                reason = "is not a SQLite database"
            else:
                reason = f"cannot be read as a SQLite database ({exc})"
            raise DatabaseUnreadable(
                f"{path} {reason}. Back it up and start with a fresh APP_DATA_DIR."
            ) from exc
        if version == 0 and tables == 0:
            return None
        return version

    def _refuse_unless_current(self, version: int) -> None:
        if version != self.LATEST_SCHEMA_VERSION:
            raise SchemaVersionRefused(
                version, self.LATEST_SCHEMA_VERSION, self.MINIMUM_SCHEMA_VERSION
            )

    def _refuse_unless_upgradable(self, version: int) -> None:
        if not self.MINIMUM_SCHEMA_VERSION <= version <= self.LATEST_SCHEMA_VERSION:
            raise SchemaVersionRefused(
                version, self.LATEST_SCHEMA_VERSION, self.MINIMUM_SCHEMA_VERSION
            )

    def require_current_schema(self) -> None:
        """Read-only check for the admin CLI: never creates, never migrates."""
        version = self._existing_schema_version()
        if version is None:
            raise DatabaseMissing(
                f"No database at {self.context.database_path}; "
                "start the server once to create it."
            )
        self._refuse_unless_current(version)

    def initialize(self) -> bool:
        version = self._existing_schema_version()
        if version is None:
            with open(self.context.init_sql_path, "r") as f:
                init_script = f.read()
            with self._connection(commit=True) as conn:
                conn.executescript(init_script)
                self._ensure_server_instance_id(conn)
            return True
        self._refuse_unless_upgradable(version)
        self._migrate()
        return True

    def _migrate(self):
        with self._connection(commit=True, immediate=True) as conn:
            # Re-read inside the write transaction: the outer read may be stale.
            current = start = conn.execute("PRAGMA user_version").fetchone()[0]
            # Ladder: each step upgrades from the version it is keyed by.
            # Later phases add (version -> step) entries and bump LATEST.
            steps = {
                13: self._migrate_13_to_14,
                14: self._migrate_14_to_15,
                15: self._migrate_15_to_16,
            }
            if not self.MINIMUM_SCHEMA_VERSION <= current <= self.LATEST_SCHEMA_VERSION:
                raise SchemaVersionRefused(
                    current, self.LATEST_SCHEMA_VERSION, self.MINIMUM_SCHEMA_VERSION
                )
            while current in steps:
                steps[current](conn)
                advanced = conn.execute("PRAGMA user_version").fetchone()[0]
                if advanced <= current:
                    raise RuntimeError(
                        f"Schema step {current} did not advance user_version"
                    )
                current = advanced
            if current != self.LATEST_SCHEMA_VERSION:
                raise RuntimeError(
                    f"Schema steps stop at schema {current}; "
                    f"this server needs schema {self.LATEST_SCHEMA_VERSION}"
                )
            self._ensure_server_instance_id(conn)
        if current > start:
            operator_logger.info("database schema upgraded from %d to %d", start, current)

    def _migrate_13_to_14(self, conn) -> None:
        # Individual conn.execute calls only: executescript would COMMIT first.
        # Creates the v14 objects (SCHEMA_V14_DDL), then backfills one pending
        # identity row per existing track, then stamps the version.
        for statement in SCHEMA_V14_DDL:
            conn.execute(statement)
        conn.execute(
            "INSERT INTO track_audio_identity "
            "(uuid_id, exact_state, fp_state, match_state, priority) "
            "SELECT uuid_id, 'pending', 'pending', 'pending', 1 FROM tracks"
        )
        conn.execute("PRAGMA user_version = 14")

    def _migrate_14_to_15(self, conn) -> None:
        # Individual conn.execute calls only: executescript would COMMIT first.
        for statement in SCHEMA_V15_DDL:
            conn.execute(statement)
        conn.execute("PRAGMA user_version = 15")

    def _migrate_15_to_16(self, conn) -> None:
        # Individual conn.execute calls only: executescript would COMMIT first.
        for statement in SCHEMA_V16_DDL:
            conn.execute(statement)
        conn.execute("PRAGMA user_version = 16")

    @staticmethod
    def _with_operation_in(conn, *, owner_id, operation_uuid, kind, request_model, now):
        """Record or replay an operation receipt (SC-16c).

        The caller must hold BEGIN IMMEDIATE, so the check-then-insert is atomic
        across connections; without an open transaction this raises RuntimeError.
        The request model must carry every target id the operation acts on (for
        example, the path's item uuid), because the receipt is keyed by owner +
        operation uuid alone. Without that, reusing one operation uuid on a
        second target with the same body would replay instead of conflicting.
        """
        owner = _require_owner(owner_id)
        if not conn.in_transaction:
            raise RuntimeError("operation receipts require the caller's write transaction")
        digest = request_hash(request_model)
        key = str(uuid.UUID(str(operation_uuid)))
        row = conn.execute(
            "SELECT kind, request_hash, result_ref FROM operation_receipts "
            "WHERE owner_id = ? AND operation_uuid = ?",
            (owner, key),
        ).fetchone()
        if row is None:
            conn.execute(
                "INSERT INTO operation_receipts "
                "(owner_id, operation_uuid, kind, request_hash, created_at, result_ref) "
                "VALUES (?, ?, ?, ?, ?, NULL)",
                (owner, key, kind, digest, now),
            )
            return OpNew()
        if row[0] == kind and row[1] == digest:
            return OpReplay(row[2])
        raise OperationConflict(
            f"operation {key} was already used for a different request"
        )

    @staticmethod
    def _set_operation_result_in(conn, *, owner_id, operation_uuid, result_ref):
        """Store the result of an operation; the caller must hold BEGIN IMMEDIATE."""
        owner = _require_owner(owner_id)
        if not conn.in_transaction:
            raise RuntimeError("operation receipts require the caller's write transaction")
        key = str(uuid.UUID(str(operation_uuid)))
        cur = conn.execute(
            "UPDATE operation_receipts SET result_ref = ? "
            "WHERE owner_id = ? AND operation_uuid = ?",
            (result_ref, owner, key),
        )
        if cur.rowcount != 1:
            raise LookupError(f"no operation receipt for {operation_uuid}")

    @staticmethod
    def _storage_totals_in(conn, owner_id: int, quota_purposes, on_disk_purposes) -> StorageTotals:
        """``reserved`` leaves out on-disk purposes: their bytes are already off the free count."""

        def in_list(column, purposes):
            return f"{column} IN ({','.join('?' * len(purposes))})" if purposes else "0"

        quota = tuple(quota_purposes)
        on_disk = tuple(on_disk_purposes)
        in_staged = in_list("purpose", quota)
        row = conn.execute(
            f"SELECT COALESCE(SUM(CASE WHEN {in_list('purpose', on_disk)} THEN 0 ELSE bytes END), 0),"
            f" COALESCE(SUM(CASE WHEN {in_staged} THEN bytes ELSE 0 END), 0),"
            f" COALESCE(SUM(CASE WHEN {in_staged} AND owner_id = ? THEN bytes ELSE 0 END), 0)"
            " FROM storage_reservations",
            (*on_disk, *quota, *quota, owner_id),
        ).fetchone()
        return StorageTotals(reserved=row[0], staged=row[1], user_staged=row[2])

    def reserve_storage(
        self,
        *,
        owner_id,
        purpose,
        nbytes,
        subject_ref,
        lease_boot_id,
        quota_purposes,
        on_disk_purposes,
        admit,
    ) -> int:
        """Admit and insert one reservation inside a single write transaction.

        ``admit(totals)`` runs under the write lock and raises to refuse; a
        refusal rolls back, so no row is stored.
        """
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            admit(self._storage_totals_in(conn, owner, quota_purposes, on_disk_purposes))
            cursor = conn.execute(
                "INSERT INTO storage_reservations"
                " (owner_id, purpose, subject_ref, bytes, lease_boot_id, created_at)"
                " VALUES (?, ?, ?, ?, ?, unixepoch())",
                (owner, purpose, subject_ref, nbytes, lease_boot_id),
            )
            return cursor.lastrowid

    def storage_totals(self, *, owner_id, quota_purposes, on_disk_purposes) -> StorageTotals:
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            return self._storage_totals_in(conn, owner, quota_purposes, on_disk_purposes)

    @staticmethod
    def _settle_storage_in(conn, reservation_id: int, *, purpose: str) -> bool:
        """Turn a reservation into a durable (unleased) row of ``purpose``; never opens
        or commits a transaction. False when nothing changed (unknown id, already settled)."""
        cursor = conn.execute(
            "UPDATE storage_reservations SET purpose = ?, lease_boot_id = NULL"
            " WHERE id = ? AND (purpose <> ? OR lease_boot_id IS NOT NULL)",
            (purpose, reservation_id, purpose),
        )
        return cursor.rowcount > 0

    def settle_storage(self, reservation_id: int, *, purpose: str) -> bool:
        with self._connection(commit=True, immediate=True) as conn:
            return self._settle_storage_in(conn, reservation_id, purpose=purpose)

    def release_storage_leases_except(self, boot_id: str) -> int:
        """Delete reservations leased by any boot other than ``boot_id``; unleased rows stay."""
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "DELETE FROM storage_reservations"
                " WHERE lease_boot_id IS NOT NULL AND lease_boot_id <> ?",
                (boot_id,),
            )
            return cursor.rowcount

    def release_storage(self, reservation_id: int) -> bool:
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "DELETE FROM storage_reservations WHERE id = ?", (reservation_id,)
            )
            return cursor.rowcount > 0

    # ── upload receipt reconcile (startup; server-wide, owner taken from each row) ──

    def list_upload_receipts_to_reconcile(self, *, boot_id: str) -> list[dict]:
        """Receiving rows whose lease is not ``boot_id``, and non-receiving rows
        that still name a part file."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT owner_id, item_uuid, batch_uuid, state, expected_bytes, expected_sha256,"
                " part_path, source_path FROM upload_items"
                " WHERE (state = 'receiving' AND (lease_boot_id IS NULL OR lease_boot_id <> ?))"
                " OR (state <> 'receiving' AND part_path IS NOT NULL)"
                " ORDER BY owner_id, item_uuid",
                (boot_id,),
            ).fetchall()
        return [dict(row) for row in rows]

    # ── upload validation (background worker; server-wide, owner taken from each row) ──

    def claim_upload_validation(self, *, boot_id: str) -> dict | None:
        """Claim the next ``validating`` item whose lease is not ``boot_id``
        (oldest ``progress_at``, then ``item_uuid``), stamping ``boot_id``.
        None when there is none or a cancel is already requested."""
        # Deferred: the services package imports this module.
        from app.services import job_runtime

        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT owner_id, item_uuid, batch_uuid, parent_item_uuid, source_path, review_version,"
                " detected_metadata FROM upload_items"
                " WHERE state = 'validating' AND cancel_requested = 0"
                " AND (lease_boot_id IS NULL OR lease_boot_id <> ?)"
                " AND (parent_item_uuid IS NULL OR EXISTS (SELECT 1 FROM upload_items p"
                " WHERE p.owner_id = upload_items.owner_id AND p.item_uuid = upload_items.parent_item_uuid"
                " AND p.state = 'expanded'))"
                " ORDER BY progress_at, item_uuid LIMIT 1",
                (boot_id,),
            ).fetchone()
            if row is None:
                return None
            item_key = {"owner_id": row["owner_id"], "item_uuid": row["item_uuid"]}
            if not job_runtime.claim(
                conn, "upload_items", item_key,
                boot_id=boot_id, from_state="validating", to_state="validating",
            ):
                return None
            if job_runtime.cancel_requested(conn, "upload_items", item_key):
                conn.rollback()
                return None
            has_identity = conn.execute(
                "SELECT 1 FROM upload_item_audio_identity WHERE owner_id = ? AND item_uuid = ?",
                (row["owner_id"], row["item_uuid"]),
            ).fetchone() is not None
            return {**dict(row), "has_identity": has_identity}

    def finish_upload_validation(
        self, *, owner_id: int, item_uuid: str, boot_id: str, review_version: int,
        detected_metadata: str, identity_columns: dict | None, check, now: int,
    ) -> bool:
        """validating -> review_ready in one transaction, guarded by this boot's
        lease and the claimed review_version (False, nothing written, when it no
        longer holds). Stores the identity (when given), runs
        ``check(conn, own_identity_row, extra_subject_rows) -> report_json``
        and stores the report and detected metadata."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            held = conn.execute(
                "SELECT 1 FROM upload_items WHERE owner_id = ? AND item_uuid = ?"
                " AND state = 'validating' AND lease_boot_id = ? AND review_version = ?",
                (owner, key, boot_id, review_version),
            ).fetchone()
            if held is None:
                return False
            if identity_columns is not None:
                names = list(identity_columns)
                from app.services.audio_identity import FINGERPRINT_COLUMNS, IDENTITY_COLUMNS

                allowed = {*IDENTITY_COLUMNS, *FINGERPRINT_COLUMNS, "fp_failure_reason"}
                if not set(names) <= allowed:
                    raise ValueError("unknown upload identity column")
                conn.execute(
                    f"INSERT OR REPLACE INTO upload_item_audio_identity"
                    f" (owner_id, item_uuid, {', '.join(names)})"
                    f" VALUES (?, ?, {', '.join('?' * len(names))})",
                    (owner, key, *(identity_columns[n] for n in names)),
                )
            own = conn.execute(
                "SELECT * FROM upload_item_audio_identity WHERE owner_id = ? AND item_uuid = ?",
                (owner, key),
            ).fetchone()
            extra = conn.execute(
                "SELECT i.* FROM upload_item_audio_identity i JOIN upload_items u"
                " ON u.owner_id = i.owner_id AND u.item_uuid = i.item_uuid"
                " WHERE i.owner_id = ? AND i.item_uuid <> ?"
                " AND u.state IN ('review_ready', 'committing', 'duplicate_conflict')"
                " ORDER BY i.item_uuid",
                (owner, key),
            ).fetchall()
            report_json = check(conn, own, extra)
            conn.execute(
                "UPDATE upload_items SET state = 'review_ready', kind = 'audio',"
                " detected_metadata = ?, duplicate_report = ?, lease_boot_id = NULL,"
                " error_code = NULL, error_message = NULL, error_retryable = NULL,"
                " updated_at = ?, progress_at = ? WHERE owner_id = ? AND item_uuid = ?",  # reviewable is progress
                (detected_metadata, report_json, now, now, owner, key),
            )
            self._touch_upload_batch_in(conn, owner, key, now)
            return True

    def fail_upload_validation(
        self, *, owner_id: int, item_uuid: str, boot_id: str, review_version: int,
        error_code: str, error_message: str, error_retryable: bool, now: int
    ) -> list[dict] | None:
        """validating -> failed, guarded by this boot's lease and the claimed
        review_version (False, nothing written, when it no longer holds). The
        source path and its quota row are kept; giving them back is a separate
        guarded step once the file is gone. The item's archive children (a failed
        archive was never expanded, so they hold no source or quota rows) are
        deleted and its skipped count cleared in the same transaction; the deleted
        children (item_uuid, batch_uuid) are returned, or None when the guard failed."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET state = 'failed', error_code = ?, error_message = ?,"
                " error_retryable = ?, lease_boot_id = NULL, updated_at = ?,"
                " progress_at = ?"  # validation ending is progress: the retry window starts now
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'validating'"
                " AND lease_boot_id = ? AND review_version = ?",
                (error_code, error_message, int(bool(error_retryable)), now, now,
                 owner, key, boot_id, review_version),
            )
            if cur.rowcount != 1:
                return None
            children = [dict(r) for r in conn.execute(
                "SELECT item_uuid, batch_uuid FROM upload_items WHERE owner_id = ? AND parent_item_uuid = ?",
                (owner, key))]
            conn.execute(
                "DELETE FROM upload_items WHERE owner_id = ? AND parent_item_uuid = ?", (owner, key))
            conn.execute(
                "UPDATE upload_items SET skipped_members = NULL WHERE owner_id = ? AND item_uuid = ?",
                (owner, key))
            self._touch_upload_batch_in(conn, owner, key, now)
            return children

    def advance_dead_upload_receipt(
        self, *, owner_id: int, item_uuid: str, boot_id: str, source_path: str,
        received_bytes: int, received_sha256: str, receive_purpose: str,
        settled_purpose: str, now: int, keep_part: bool = False,
    ) -> bool:
        """A dead transfer's complete source: receiving -> validating, and its
        quota row becomes a durable on-disk row (restored if it was lost).
        ``keep_part`` keeps a part path recorded that could not be removed."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET state = 'validating', source_path = ?, received_bytes = ?,"
                " received_sha256 = ?, part_path = CASE WHEN ? THEN part_path ELSE NULL END,"
                " lease_boot_id = NULL, error_code = NULL,"
                " error_message = NULL, error_retryable = NULL, progress_at = ?, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'receiving'"
                " AND (lease_boot_id IS NULL OR lease_boot_id <> ?)",
                (source_path, received_bytes, received_sha256, int(keep_part), now, now,
                 owner, item_uuid, boot_id),
            )
            if cur.rowcount != 1:
                return False
            self._touch_upload_batch_in(conn, owner, item_uuid, now)
            self._settle_upload_quota_in(
                conn, owner, item_uuid, settled_purpose=settled_purpose,
                nbytes=received_bytes, receive_purpose=receive_purpose,
            )
            return True

    def return_dead_upload_receipt(
        self, *, owner_id: int, item_uuid: str, boot_id: str, receive_purpose: str,
        error_code: str, error_message: str, now: int,
    ) -> bool:
        """A dead transfer without a complete source: receiving -> allocated with a
        retryable error, and its in-flight quota rows released."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET state = 'allocated', error_code = ?, error_message = ?,"
                " error_retryable = 1, received_bytes = 0, received_sha256 = NULL, part_path = NULL,"
                " source_path = NULL, lease_boot_id = NULL, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'receiving'"
                " AND (lease_boot_id IS NULL OR lease_boot_id <> ?)",
                (error_code, error_message, now, owner, item_uuid, boot_id),
            )
            if cur.rowcount != 1:
                return False
            self._touch_upload_batch_in(conn, owner, item_uuid, now)
            conn.execute(
                "DELETE FROM storage_reservations WHERE owner_id = ? AND subject_ref = ?"
                " AND purpose = ?",
                (owner, item_uuid, receive_purpose),
            )
            return True

    def fail_dead_upload_receipt(
        self, *, owner_id: int, item_uuid: str, boot_id: str, error_code: str,
        error_message: str, now: int,
    ) -> bool:
        """A dead transfer whose partial could not be removed: receiving -> failed,
        part path kept so the next start retries the removal."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET state = 'failed', error_code = ?, error_message = ?,"
                " error_retryable = 0, received_bytes = 0, lease_boot_id = NULL, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'receiving'"
                " AND (lease_boot_id IS NULL OR lease_boot_id <> ?)",
                (error_code, error_message, now, owner, item_uuid, boot_id),
            )
            if cur.rowcount != 1:
                return False
            self._touch_upload_batch_in(conn, owner, item_uuid, now)
            return True

    def clear_upload_part(self, *, owner_id: int, item_uuid: str) -> None:
        """Forget the part path and lease of a row that is no longer receiving."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            conn.execute(
                "UPDATE upload_items SET part_path = NULL, lease_boot_id = NULL"
                " WHERE owner_id = ? AND item_uuid = ? AND state <> 'receiving'",
                (owner, item_uuid),
            )

    def list_upload_source_reservations(self, *, purpose: str) -> list[dict]:
        """Each reservation of ``purpose`` with its owner and its item's state and
        source path (None when the item does not exist)."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT r.id AS id, r.owner_id AS owner_id, i.state AS state, i.source_path AS source_path"
                " FROM storage_reservations r"
                " LEFT JOIN upload_items i ON i.owner_id = r.owner_id AND i.item_uuid = r.subject_ref"
                " WHERE r.purpose = ? ORDER BY r.id",
                (purpose,),
            ).fetchall()
        return [dict(row) for row in rows]

    def list_users(self) -> list[dict]:
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT u.*, (SELECT count(*) FROM tracks t WHERE t.owner_id = u.id) "
                "AS track_count FROM users u ORDER BY u.id"
            ).fetchall()
        return [dict(row) for row in rows]

    def get_master_admin(self) -> dict | None:
        with self._connection() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE is_master_admin = 1"
            ).fetchone()
        return dict(row) if row else None

    def get_user(self, user_id: int) -> dict | None:
        with self._connection() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE id = ?", (user_id,)
            ).fetchone()
        return dict(row) if row else None

    def get_library_folders(self) -> list[str]:
        with self._connection() as conn:
            rows = conn.execute("SELECT library_folder FROM users").fetchall()
        return [row["library_folder"] for row in rows]

    def list_user_folders(self) -> list[dict]:
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT id, username, library_folder, deleting_at FROM users"
            ).fetchall()
        return [dict(row) for row in rows]

    def create_master_admin(
        self,
        username: str,
        username_key: str,
        password_hash: str,
        library_folder: str,
        created_at: int,
    ) -> int:
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "INSERT INTO users (username, username_key, password_hash, is_admin, "
                "is_master_admin, library_folder, created_at) "
                "VALUES (?, ?, ?, 1, 1, ?, ?)",
                (username, username_key, password_hash, library_folder, created_at),
            )
            return cursor.lastrowid

    def start_login_session(
        self,
        *,
        user_id: int,
        verified_hash: str,
        new_hash: str | None,
        token_hash: str,
        media_hash: str,
        created_at: int,
    ) -> bool:
        """Insert the login session (and an optional rehash) only if the user
        still has the verified hash and is neither disabled nor deleting."""
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT password_hash, disabled_at, deleting_at FROM users WHERE id = ?",
                (user_id,),
            ).fetchone()
            if (
                row is None
                or row["password_hash"] != verified_hash
                or row["disabled_at"] is not None
                or row["deleting_at"] is not None
            ):
                return False
            if new_hash is not None:
                conn.execute(
                    "UPDATE users SET password_hash = ? WHERE id = ?",
                    (new_hash, user_id),
                )
            self._insert_auth_session_in(
                conn, token_hash, media_hash, user_id, created_at
            )
            return True

    def get_user_by_username_key(self, username_key: str) -> dict | None:
        with self._connection() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE username_key = ?", (username_key,)
            ).fetchone()
        return dict(row) if row else None

    def rename_user(self, user_id: int, username: str, username_key: str) -> None:
        with self._connection(commit=True, immediate=True) as conn:
            taken = conn.execute(
                "SELECT 1 FROM users WHERE username_key = ? AND id != ?",
                (username_key, user_id),
            ).fetchone()
            if taken:
                raise UsernameTaken(username_key)
            conn.execute(
                "UPDATE users SET username = ?, username_key = ? WHERE id = ?",
                (username, username_key, user_id),
            )

    def register_user(
        self,
        *,
        username: str,
        username_key: str,
        password_hash: str,
        created_at: int,
        token_hash: str,
        media_hash: str,
        check,
        choose_folder,
    ) -> dict:
        with self._connection(commit=True, immediate=True) as conn:
            check(conn)
            if conn.execute(
                "SELECT 1 FROM users WHERE username_key = ?", (username_key,)
            ).fetchone():
                raise UsernameTaken(username_key)
            folders = [r[0] for r in conn.execute("SELECT library_folder FROM users")]
            folder = choose_folder(folders)
            cursor = conn.execute(
                "INSERT INTO users (username, username_key, password_hash, is_admin, "
                "is_master_admin, library_folder, created_at) "
                "VALUES (?, ?, ?, 0, 0, ?, ?)",
                (username, username_key, password_hash, folder, created_at),
            )
            user_id = cursor.lastrowid
            self._insert_auth_session_in(
                conn, token_hash, media_hash, user_id, created_at
            )
            return dict(
                conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
            )

    def set_password_hash(self, user_id: int, password_hash: str) -> None:
        with self._connection(commit=True) as conn:
            conn.execute(
                "UPDATE users SET password_hash = ? WHERE id = ?",
                (password_hash, user_id),
            )

    def set_password_hash_and_revoke_sessions(
        self, user_id: int, password_hash: str, revoked_at: int
    ) -> None:
        with self._connection(commit=True) as conn:
            conn.execute(
                "UPDATE users SET password_hash = ? WHERE id = ?",
                (password_hash, user_id),
            )
            conn.execute(
                "UPDATE auth_sessions SET revoked_at = ? "
                "WHERE user_id = ? AND revoked_at IS NULL",
                (revoked_at, user_id),
            )

    def set_user_disabled(self, user_id: int, disabled: bool, now: int) -> None:
        with self._connection(commit=True) as conn:
            conn.execute(
                "UPDATE users SET disabled_at = ? WHERE id = ?",
                (now if disabled else None, user_id),
            )
            if disabled:
                conn.execute(
                    "UPDATE auth_sessions SET revoked_at = ? "
                    "WHERE user_id = ? AND revoked_at IS NULL",
                    (now, user_id),
                )

    def mark_user_deleting(self, user_id: int, now: int) -> None:
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "UPDATE users SET deleting_at = COALESCE(deleting_at, ?) WHERE id = ?",
                (now, user_id),
            )
            conn.execute("DELETE FROM auth_sessions WHERE user_id = ?", (user_id,))
            conn.execute(
                "INSERT OR IGNORE INTO user_delete_art_capture (user_id, cover_art_id) "
                "SELECT DISTINCT ?, tm.cover_art_id FROM trackmetadata tm "
                "JOIN tracks t ON t.id = tm.track_id "
                "WHERE t.owner_id = ? AND tm.cover_art_id IS NOT NULL",
                (user_id, user_id),
            )

    def purge_user_rows(self, user_id: int, table_order: list[str]) -> None:
        """Step 3 of ``users delete``: one transaction; any error rolls back."""
        with self._connection(commit=True, immediate=True) as conn:
            # FTS first: the album derivation joins artists.
            for row in conn.execute(
                "SELECT tm.track_id, tm.title, tm.artist, tm.album, tm.album_artist "
                "FROM trackmetadata tm JOIN tracks t ON t.id = tm.track_id "
                "WHERE t.owner_id = ?",
                (user_id,),
            ).fetchall():
                self._fts_delete_track_in(conn, row)
            for (album_id,) in conn.execute(
                "SELECT al.id FROM albums al JOIN artists ar ON ar.id = al.artist_id "
                "WHERE ar.owner_id = ?",
                (user_id,),
            ).fetchall():
                self._fts_delete_album_in(conn, album_id)
            for (artist_id,) in conn.execute(
                "SELECT id FROM artists WHERE owner_id = ?", (user_id,)
            ).fetchall():
                self._fts_delete_artist_in(conn, artist_id)
            for table in table_order:
                if table in ("users", "user_delete_art_capture"):
                    continue
                entry = REGISTRY[table]
                if entry.fts_rowid:
                    continue
                conn.execute(
                    f"DELETE FROM {table} WHERE {owner_predicate(table)}", (user_id,)
                )
            for (art_id,) in conn.execute(
                "SELECT cover_art_id FROM user_delete_art_capture WHERE user_id = ?",
                (user_id,),
            ).fetchall():
                self._delete_cover_art_if_unreferenced_in(conn, art_id)

    def get_cover_art_file_paths(self) -> set[str]:
        with self._connection() as conn:
            rows = conn.execute("SELECT file_path FROM cover_arts").fetchall()
        return {row[0] for row in rows}

    def delete_user_row(self, user_id: int) -> None:
        with self._connection(commit=True) as conn:
            conn.execute(
                "DELETE FROM user_delete_art_capture WHERE user_id = ?", (user_id,)
            )
            conn.execute("DELETE FROM users WHERE id = ?", (user_id,))

    @staticmethod
    def _insert_auth_session_in(
        conn, token_hash: str, media_hash: str, user_id: int, created_at: int
    ) -> None:
        conn.execute(
            "INSERT INTO auth_sessions (token_hash, media_hash, user_id, created_at) "
            "VALUES (?, ?, ?, ?)",
            (token_hash, media_hash, user_id, created_at),
        )

    def _live_session_by(self, column: str, value: str) -> dict | None:
        if column not in ("token_hash", "media_hash"):
            raise ValueError(f"unsupported session column: {column!r}")
        with self._connection() as conn:
            row = conn.execute(
                "SELECT auth_sessions.token_hash AS session_hash, "
                "users.id AS user_id, users.is_admin, users.is_master_admin "
                "FROM auth_sessions JOIN users ON users.id = auth_sessions.user_id "
                f"WHERE auth_sessions.{column} = ? "
                "AND auth_sessions.revoked_at IS NULL "
                "AND users.disabled_at IS NULL AND users.deleting_at IS NULL",
                (value,),
            ).fetchone()
        return dict(row) if row else None

    def get_live_session(self, token_hash: str) -> dict | None:
        return self._live_session_by("token_hash", token_hash)

    def get_live_session_by_media_hash(self, media_hash: str) -> dict | None:
        return self._live_session_by("media_hash", media_hash)

    def revoke_auth_session(self, token_hash: str, revoked_at: int) -> None:
        with self._connection(commit=True) as conn:
            conn.execute(
                "UPDATE auth_sessions SET revoked_at = ? "
                "WHERE token_hash = ? AND revoked_at IS NULL",
                (revoked_at, token_hash),
            )

    def seed_user_setting(self, *, owner_id: int, key: str, value: str) -> None:
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            conn.execute(
                "INSERT OR IGNORE INTO user_settings (user_id, key, value) "
                "VALUES (?, ?, ?)",
                (owner_id, key, value),
            )

    def get_user_setting(self, key: str, *, owner_id: int) -> str | None:
        _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT value FROM user_settings WHERE user_id = ? AND key = ?",
                (owner_id, key),
            ).fetchone()
        return row[0] if row else None

    def set_user_setting(self, key: str, value: str, *, owner_id: int) -> None:
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            conn.execute(
                "INSERT INTO user_settings (user_id, key, value) VALUES (?, ?, ?) "
                "ON CONFLICT(user_id, key) DO UPDATE SET value = excluded.value",
                (owner_id, key, value),
            )

    def get_history_changes(
        self, after: int, limit: int, *, owner_id: int
    ) -> tuple[list[dict[str, Any]], int, int | None]:
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            # A connection context alone does not give SELECTs a shared snapshot.
            conn.execute("BEGIN")
            rows = conn.execute(
                "SELECT event_uuid, revision, kind, entity_type, entity_ref, "
                "occurred_at, seconds_played, track_length, received_at "
                "FROM history_events WHERE owner_id = ? AND revision > ? "
                "ORDER BY revision ASC LIMIT ?",
                (owner_id, after, limit + 1),
            ).fetchall()
            latest_revision = conn.execute(
                "SELECT COALESCE(MAX(revision), 0) FROM history_events "
                "WHERE owner_id = ?",
                (owner_id,),
            ).fetchone()[0]
        next_cursor = rows[limit - 1]["revision"] if len(rows) > limit else None
        return [dict(row) for row in rows[:limit]], latest_revision, next_cursor

    def insert_history_events(
        self, events: list[HistoryEvent], *, owner_id: int
    ) -> list[str]:
        _require_owner(owner_id)
        # Import here because the services package itself depends on Database.
        from app.services.history_hooks import on_history_events_inserted

        with self._connection(commit=True, immediate=True) as conn:
            payloads = {}
            conflicts = set()
            for event in events:
                payload = event.model_dump()
                if event.event_uuid in payloads and payloads[event.event_uuid] != payload:
                    conflicts.add(event.event_uuid)
                payloads[event.event_uuid] = payload
            if conflicts:
                raise HistoryEventConflict(sorted(conflicts))

            columns = tuple(HistoryEvent.model_fields)
            placeholders = ",".join("?" for _ in payloads)
            existing = {}
            existing_owner = {}
            for row in conn.execute(
                f"SELECT {', '.join(columns)}, owner_id FROM history_events "
                f"WHERE event_uuid IN ({placeholders})",
                tuple(payloads),
            ):
                existing[row["event_uuid"]] = {c: row[c] for c in columns}
                existing_owner[row["event_uuid"]] = row["owner_id"]
            conflicts = {
                uid for uid, payload in payloads.items()
                if uid in existing
                and (existing_owner[uid] != owner_id or existing[uid] != payload)
            }
            if conflicts:
                raise HistoryEventConflict(sorted(conflicts))

            new_events = []
            for uid, payload in payloads.items():
                if uid in existing:
                    continue
                row = {
                    **payload,
                    "revision": self._next_revision(conn),
                    "received_at": time_ns() // 1_000_000,
                    "owner_id": owner_id,
                }
                conn.execute(
                    f"INSERT INTO history_events ({', '.join(row)}) "
                    f"VALUES ({', '.join('?' for _ in row)})",
                    tuple(row.values()),
                )
                new_events.append(row)
            on_history_events_inserted(conn, new_events)
        return list(payloads)

    # ── uploads (7A.1d) ────────────────────────────────────────────────────

    def allocate_upload_batch(self, request, *, owner_id: int, now: int) -> bool:
        """True for a new allocation, False for an exact replay."""
        owner = _require_owner(owner_id)
        batch_uuid = str(request.batch_uuid)
        with self._connection(commit=True, immediate=True) as conn:
            outcome = self._with_operation_in(
                conn,
                owner_id=owner,
                operation_uuid=batch_uuid,
                kind="upload_allocation",
                request_model=request,
                now=now,
            )
            if isinstance(outcome, OpReplay):
                return False
            item_uuids = [str(item.item_uuid) for item in request.items]
            taken = set()
            for start in range(0, len(item_uuids), 500):
                chunk = item_uuids[start : start + 500]
                marks = ",".join("?" for _ in chunk)
                taken.update(
                    row[0]
                    for row in conn.execute(
                        "SELECT item_uuid FROM upload_items "
                        f"WHERE owner_id = ? AND item_uuid IN ({marks})",
                        (owner, *chunk),
                    )
                )
            if taken:
                raise UploadItemsInUse(sorted(taken))
            conn.execute(
                "INSERT INTO upload_batches (owner_id, batch_uuid, label, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (owner, batch_uuid, request.label, now, now),
            )
            conn.executemany(
                "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, filename, "
                "selection_index, member_order_key, expected_bytes, expected_sha256, "
                "state, created_at, updated_at, progress_at) "
                "VALUES (?, ?, ?, ?, ?, '', ?, ?, 'allocated', ?, ?, ?)",
                [
                    (owner, str(item.item_uuid), batch_uuid, item.filename, index,
                     item.byte_length, item.sha256, now, now, now)
                    for index, item in enumerate(request.items)
                ],
            )
            self._set_operation_result_in(
                conn, owner_id=owner, operation_uuid=batch_uuid, result_ref=batch_uuid
            )
        return True

    def get_upload_batch(self, batch_uuid, *, owner_id: int) -> dict | None:
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(batch_uuid)))
        with self._connection() as conn:
            row = conn.execute(
                "SELECT batch_uuid, label, created_at, updated_at FROM upload_batches "
                "WHERE owner_id = ? AND batch_uuid = ?",
                (owner, key),
            ).fetchone()
            if row is None:
                return None
            counts = self._upload_state_counts_in(conn, owner, [key])
        return self._with_counts(dict(row), counts.get(key, {}))

    @staticmethod
    def _upload_state_counts_in(conn, owner: int, batch_uuids: list[str]) -> dict:
        """{batch_uuid: {state: count}} for the caller's batches (non-zero only)."""
        marks = ",".join("?" for _ in batch_uuids)
        counts: dict[str, dict[str, int]] = {}
        for batch_uuid, state, count in conn.execute(
            "SELECT batch_uuid, state, count(*) FROM upload_items "
            f"WHERE owner_id = ? AND batch_uuid IN ({marks}) "
            "GROUP BY batch_uuid, state",
            (owner, *batch_uuids),
        ):
            counts.setdefault(batch_uuid, {})[state] = count
        return counts

    @staticmethod
    def _with_counts(batch: dict, counts: dict) -> dict:
        batch["item_count"] = sum(counts.values())
        batch["state_counts"] = counts
        return batch

    def list_upload_batches(
        self, *, owner_id: int, after: tuple[int, str] | None, limit: int
    ) -> list[dict]:
        """Keyset page ascending by (created_at, batch_uuid)."""
        owner = _require_owner(owner_id)
        sql = (
            "SELECT batch_uuid, label, created_at, updated_at FROM upload_batches "
            "WHERE owner_id = ?"
        )
        params: list = [owner]
        if after is not None:
            sql += " AND (created_at, batch_uuid) > (?, ?)"
            params += [after[0], after[1]]
        sql += " ORDER BY created_at, batch_uuid LIMIT ?"
        params.append(limit)
        with self._connection() as conn:
            batches = [dict(row) for row in conn.execute(sql, params)]
            counts = (
                self._upload_state_counts_in(
                    conn, owner, [b["batch_uuid"] for b in batches]
                )
                if batches
                else {}
            )
        return [self._with_counts(b, counts.get(b["batch_uuid"], {})) for b in batches]

    def list_upload_items(
        self,
        batch_uuid,
        *,
        owner_id: int,
        top_level_only: bool = False,
        after: tuple[int, str, str] | None = None,
        limit: int | None = None,
    ) -> list[dict]:
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(batch_uuid)))
        sql = (
            f"SELECT {', '.join(_UPLOAD_ITEM_API_COLUMNS)} FROM upload_items "
            "WHERE owner_id = ? AND batch_uuid = ?"
        )
        params: list = [owner, key]
        if top_level_only:
            sql += " AND parent_item_uuid IS NULL"
        if after is not None:
            sql += " AND (selection_index, member_order_key, item_uuid) > (?, ?, ?)"
            params += list(after)
        sql += " ORDER BY selection_index, member_order_key, item_uuid"
        if limit is not None:
            sql += " LIMIT ?"
            params.append(limit)
        with self._connection() as conn:
            rows = conn.execute(sql, params).fetchall()
        return [self._upload_item_dict(row) for row in rows]

    def get_upload_item(self, item_uuid, *, owner_id: int) -> dict | None:
        with self._connection() as conn:
            return self._upload_item_in(conn, owner_id=owner_id, item_uuid=item_uuid)

    @staticmethod
    def _upload_item_in(conn, *, owner_id: int, item_uuid) -> dict | None:
        """THE owner-scoped upload item lookup; reuse inside transactions."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        row = conn.execute(
            f"SELECT {', '.join(_UPLOAD_ITEM_API_COLUMNS)} FROM upload_items "
            "WHERE owner_id = ? AND item_uuid = ?",
            (owner, key),
        ).fetchone()
        return None if row is None else Database._upload_item_dict(row)

    @staticmethod
    def _transition_upload_item_in(
        conn, *, owner_id: int, item_uuid, from_states, to_state: str, now: int,
        fields: dict | None = None, progress_at_most: int | None = None,
    ) -> bool:
        """THE item compare-and-swap: move an owned item between states only if
        it is still in one of from_states. The caller holds the write
        transaction. Does not touch progress_at; ``progress_at_most`` also requires the
        item's progress to be no newer than that."""
        owner = _require_owner(owner_id)
        fields = fields or {}
        unknown = set(fields) - _UPLOAD_TRANSITION_FIELDS
        if unknown:
            raise ValueError(f"unsupported transition fields: {sorted(unknown)}")
        states = tuple(from_states)
        if not states:
            return False
        key = str(uuid.UUID(str(item_uuid)))
        names = sorted(fields)
        assignments = "".join(f", {name} = ?" for name in names)
        marks = ",".join("?" for _ in states)
        bound = "" if progress_at_most is None else " AND progress_at <= ?"
        cur = conn.execute(
            f"UPDATE upload_items SET state = ?, updated_at = ?{assignments} "
            f"WHERE owner_id = ? AND item_uuid = ? AND state IN ({marks}){bound}",
            (to_state, now, *(fields[n] for n in names), owner, key, *states,
             *(() if progress_at_most is None else (progress_at_most,))),
        )
        if cur.rowcount != 1:
            return False
        Database._touch_upload_batch_in(conn, owner, key, now)
        return True

    @staticmethod
    def _touch_upload_batch_in(conn, owner: int, item_uuid: str, now: int) -> None:
        """Bump ``updated_at`` of the batch holding an item; the caller holds the transaction."""
        conn.execute(
            "UPDATE upload_batches SET updated_at = ? WHERE owner_id = ? AND batch_uuid = "
            "(SELECT batch_uuid FROM upload_items WHERE owner_id = ? AND item_uuid = ?)",
            (now, owner, owner, item_uuid),
        )

    def cancel_upload_item(
        self, item_uuid, *, owner_id: int, from_states, now: int
    ) -> tuple[bool, dict | None, list[str]]:
        """Cancel an owned item in one write transaction. An item that a worker
        holds (``receiving`` or ``validating``, with any lease) also gets the durable
        ``cancel_requested`` flag; an ``allocated`` one does not. An archive that
        is then ``cancelled`` or ``expanded`` also cancels its children that are
        in ``from_states``; their uuids are the third value."""

        def cancel_one(conn, uuid_):
            for state in from_states:
                flag = {"cancel_requested": 1} if state in _LEASED_STATES else None
                if self._transition_upload_item_in(
                    conn, owner_id=owner_id, item_uuid=uuid_, from_states=(state,),
                    to_state="cancelled", now=now, fields=flag,
                ):
                    return True
            return False

        cancelled_children: list[str] = []
        with self._connection(commit=True, immediate=True) as conn:
            changed = cancel_one(conn, item_uuid)
            row = self._upload_item_in(conn, owner_id=owner_id, item_uuid=item_uuid)
            if row is not None and row["state"] in ("cancelled", "expanded"):
                children = conn.execute(
                    "SELECT item_uuid FROM upload_items WHERE owner_id = ? AND parent_item_uuid = ?"
                    " ORDER BY item_uuid",
                    (_require_owner(owner_id), row["item_uuid"]),
                ).fetchall()
                cancelled_children = [c["item_uuid"] for c in children if cancel_one(conn, c["item_uuid"])]
        return changed, row, cancelled_children

    def retry_upload_item(
        self, item_uuid, *, owner_id: int, expected_review_version: int, source_present, now: int
    ) -> tuple[str, dict | None]:
        """Retry a ``duplicate_conflict`` or retryable ``failed`` item in one
        transaction, by compare-and-swap on ``review_version``. Outcomes:
        ``not_found``, ``version_conflict``, ``not_retryable`` (nothing written),
        ``validating`` or ``allocated`` (``review_version`` + 1). ``source_present``
        is called with the recorded source path."""
        from app.services.storage_ledger import UPLOAD_SOURCE  # deferred, as above

        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            row = self._upload_item_in(conn, owner_id=owner, item_uuid=key)
            if row is None:
                return "not_found", None
            if row["review_version"] != expected_review_version:
                return "version_conflict", row
            state = row["state"]
            if state == "duplicate_conflict":
                target = "validating"
            elif state == "failed" and row["error_retryable"] == 1:
                recorded = conn.execute(
                    "SELECT source_path FROM upload_items WHERE owner_id = ? AND item_uuid = ?",
                    (owner, key),
                ).fetchone()["source_path"]
                present = recorded is not None and bool(source_present(recorded))
                if not present and row["parent_item_uuid"] is not None:
                    return "not_retryable", row  # a child cannot be re-sent
                target = "validating" if present else "allocated"
            else:
                return "not_retryable", row
            common = (
                "state = ?, review_version = review_version + 1, error_code = NULL,"
                " error_message = NULL, error_retryable = NULL, lease_boot_id = NULL,"
                " cancel_requested = 0, updated_at = ?, progress_at = ?"  # a retry is progress
            )
            if state == "duplicate_conflict":
                conn.execute(
                    f"UPDATE upload_items SET {common}, duplicate_report = NULL"
                    " WHERE owner_id = ? AND item_uuid = ?",
                    (target, now, now, owner, key),
                )
            elif target == "validating":
                conn.execute(
                    "DELETE FROM upload_item_audio_identity WHERE owner_id = ? AND item_uuid = ?",
                    (owner, key),
                )
                conn.execute(
                    f"UPDATE upload_items SET {common}, detected_metadata = NULL,"
                    " duplicate_report = NULL, kind = NULL WHERE owner_id = ? AND item_uuid = ?",
                    (target, now, now, owner, key),
                )
            else:
                conn.execute(
                    "DELETE FROM upload_item_audio_identity WHERE owner_id = ? AND item_uuid = ?",
                    (owner, key),
                )
                conn.execute(
                    f"UPDATE upload_items SET {common}, detected_metadata = NULL,"
                    " duplicate_report = NULL, kind = NULL, source_path = NULL,"
                    " received_sha256 = NULL, received_bytes = 0"
                    " WHERE owner_id = ? AND item_uuid = ?",
                    (target, now, now, owner, key),
                )
                conn.execute(
                    "DELETE FROM storage_reservations WHERE owner_id = ? AND subject_ref = ?"
                    " AND purpose = ?",
                    (owner, key, UPLOAD_SOURCE),
                )
            self._touch_upload_batch_in(conn, owner, key, now)
            return target, self._upload_item_in(conn, owner_id=owner, item_uuid=key)

    def accept_upload_commit(
        self, item_uuid, *, owner_id: int, request_model, decide, now: int
    ) -> tuple[str, dict | None]:
        """Accept a commit in one write transaction (spec section 6 step 1).

        ``request_model`` carries the path item uuid and the request; its
        receipt is keyed by the operation uuid. Outcomes: ``not_found``;
        ``replay`` (row is the item plus ``journal_state``); ``accepted``
        (the item, now ``committing``). ``decide(row)`` either raises to refuse
        (rolling everything back) or returns the journal fields to freeze.
        ``OperationConflict`` propagates."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        operation = str(request_model.request.operation_uuid)
        with self._connection(commit=True, immediate=True) as conn:
            item = self._upload_item_in(conn, owner_id=owner, item_uuid=key)
            if item is None:
                return "not_found", None
            outcome = self._with_operation_in(
                conn, owner_id=owner, operation_uuid=operation, kind="upload_commit",
                request_model=request_model, now=now,
            )
            if isinstance(outcome, OpReplay):
                journal = conn.execute(
                    "SELECT state FROM upload_commit_journal WHERE owner_id = ? AND operation_uuid = ?",
                    (owner, operation),
                ).fetchone()
                return "replay", {**item, "journal_state": None if journal is None else journal["state"]}
            private = conn.execute(
                "SELECT source_path, detected_metadata FROM upload_items "
                "WHERE owner_id = ? AND item_uuid = ?",
                (owner, key),
            ).fetchone()
            fields = decide({**item, "source_path": private["source_path"],
                             "detected_metadata": private["detected_metadata"]})
            if not self._transition_upload_item_in(
                conn, owner_id=owner, item_uuid=key, from_states=("review_ready",),
                to_state="committing", now=now,
                fields={"reserved_track_uuid": fields["reserved_track_uuid"], "error_code": None,
                        "error_message": None, "error_retryable": None,
                        "progress_at": now},  # an accepted commit is progress
            ):
                raise RuntimeError("upload item left review_ready under the write lock")
            conn.execute(
                "INSERT INTO upload_commit_journal (owner_id, operation_uuid, item_uuid, state, "
                "base_review_version, reserved_track_uuid, edits, write_tags, acknowledged_duplicates, "
                "source_path, work_path, created_at, updated_at) "
                "VALUES (?, ?, ?, 'committing', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (owner, operation, key, fields["base_review_version"], fields["reserved_track_uuid"],
                 fields["edits"], fields["write_tags"], fields["acknowledged_duplicates"],
                 fields["source_path"], fields["work_path"], now, now),
            )
            self._set_operation_result_in(
                conn, owner_id=owner, operation_uuid=operation, result_ref=key)
            return "accepted", self._upload_item_in(conn, owner_id=owner, item_uuid=key)

    def resolve_upload_duplicate(
        self, item_uuid, *, owner_id: int, request_model, decide, now: int
    ) -> tuple[str, dict | None]:
        """Close an item as a terminal ``duplicate`` in one write transaction.

        Outcomes: ``not_found``; ``replay`` (the current item); ``resolved``
        (the item, now ``duplicate``). ``decide(row, is_live)`` either raises to
        refuse (rolling everything back, so no receipt is written) or returns
        ``(existing_track_uuid, duplicate_kind)``; ``is_live(uuid)`` is true for
        one of the owner's live tracks. Tracks, metadata, identity and the commit
        journal are never touched. ``OperationConflict`` propagates."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        operation = str(request_model.request.operation_uuid)
        with self._connection(commit=True, immediate=True) as conn:
            item = self._upload_item_in(conn, owner_id=owner, item_uuid=key)
            if item is None:
                return "not_found", None
            outcome = self._with_operation_in(
                conn, owner_id=owner, operation_uuid=operation, kind="upload_resolve_duplicate",
                request_model=request_model, now=now,
            )
            if isinstance(outcome, OpReplay):
                return "replay", item

            def is_live(track_uuid: str) -> bool:
                return conn.execute(
                    "SELECT 1 FROM live_tracks WHERE owner_id = ? AND uuid_id = ?",
                    (owner, track_uuid),
                ).fetchone() is not None

            track_uuid, kind = decide(item, is_live)
            if not self._transition_upload_item_in(
                conn, owner_id=owner, item_uuid=key,
                from_states=("review_ready", "duplicate_conflict"), to_state="duplicate", now=now,
                fields={"result_track_uuid": track_uuid, "duplicate_kind": kind,
                        "error_code": None, "error_message": None, "error_retryable": None,
                        "lease_boot_id": None},
            ):
                raise RuntimeError("upload item left a resolvable state under the write lock")
            self._set_operation_result_in(
                conn, owner_id=owner, operation_uuid=operation, result_ref=key)
            return "resolved", self._upload_item_in(conn, owner_id=owner, item_uuid=key)

    def claim_upload_commit(self, *, boot_id: str) -> dict | None:
        """Claim the oldest ``committing`` journal row (any owner, server-wide
        like the validation worker) whose item is ``committing`` and whose lease
        is not ``boot_id``; stamp ``boot_id`` on the journal and the item. Returns
        the journal row plus the item's batch_uuid, filename, detected_metadata
        and the staged identity row (or None)."""
        from app.services import job_runtime  # deferred: the services package imports this module

        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT j.*, i.batch_uuid AS batch_uuid, i.filename AS filename,"
                " i.detected_metadata AS detected_metadata"
                " FROM upload_commit_journal j JOIN upload_items i"
                " ON i.owner_id = j.owner_id AND i.item_uuid = j.item_uuid"
                " WHERE j.state = 'committing' AND i.state = 'committing'"
                " AND (j.lease_boot_id IS NULL OR j.lease_boot_id <> ?)"
                " ORDER BY j.created_at, j.operation_uuid LIMIT 1",
                (boot_id,),
            ).fetchone()
            if row is None:
                return None
            owner, item = row["owner_id"], row["item_uuid"]
            if not job_runtime.claim(
                conn, "upload_items", {"owner_id": owner, "item_uuid": item},
                boot_id=boot_id, from_state="committing", to_state="committing",
            ):
                return None
            conn.execute(
                "UPDATE upload_commit_journal SET lease_boot_id = ? "
                "WHERE owner_id = ? AND operation_uuid = ?",
                (boot_id, owner, row["operation_uuid"]),
            )
            identity = conn.execute(
                "SELECT * FROM upload_item_audio_identity WHERE owner_id = ? AND item_uuid = ?",
                (owner, item),
            ).fetchone()
            return {**dict(row), "lease_boot_id": boot_id,
                    "identity": None if identity is None else dict(identity)}

    def release_upload_commit_lease(self, *, owner_id: int, operation_uuid: str, boot_id: str) -> None:
        """Give a claimed, unfinished commit back (journal and item leases of
        ``boot_id``), so the next claim can take it again."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "UPDATE upload_items SET lease_boot_id = NULL WHERE owner_id = ? AND lease_boot_id = ?"
                " AND item_uuid = (SELECT item_uuid FROM upload_commit_journal"
                " WHERE owner_id = ? AND operation_uuid = ? AND state = 'committing')",
                (owner, boot_id, owner, key),
            )
            conn.execute(
                "UPDATE upload_commit_journal SET lease_boot_id = NULL WHERE owner_id = ?"
                " AND operation_uuid = ? AND state = 'committing' AND lease_boot_id = ?",
                (owner, key, boot_id),
            )

    def fail_upload_commit(
        self, *, owner_id: int, operation_uuid: str, boot_id: str, error_code: str,
        error_message: str, item_state: str, reservation_id: int | None, now: int,
        keep_reservation: bool = False,
    ) -> bool:
        """End a commit that failed before ``prepared`` in one transaction,
        guarded by journal state ``committing`` and this boot's lease (False,
        nothing written, otherwise). The journal becomes ``failed``; the item
        goes to ``item_state`` (``review_ready`` or ``failed``) with a new
        review version and a retryable error; the work reservation row is
        deleted, or, with ``keep_reservation`` (the work copy could not be removed),
        settled into the durable ``upload_work`` row so it stays counted. The staged source and its quota row are never touched."""
        if item_state not in ("review_ready", "failed"):
            raise ValueError("item_state must be review_ready or failed")
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            held = conn.execute(
                "SELECT item_uuid FROM upload_commit_journal WHERE owner_id = ? AND operation_uuid = ?"
                " AND state = 'committing' AND lease_boot_id = ?",
                (owner, key, boot_id),
            ).fetchone()
            if held is None:
                return False
            item = held["item_uuid"]
            conn.execute(
                "UPDATE upload_commit_journal SET state = 'failed', error_code = ?,"
                " lease_boot_id = NULL, updated_at = ? WHERE owner_id = ? AND operation_uuid = ?",
                (error_code, now, owner, key),
            )
            cursor = conn.execute(
                "UPDATE upload_items SET state = ?, review_version = review_version + 1,"
                " error_code = ?, error_message = ?, error_retryable = 1, lease_boot_id = NULL,"
                " updated_at = ? WHERE owner_id = ? AND item_uuid = ? AND state = 'committing'",
                (item_state, error_code, error_message, now, owner, item),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("commit item left committing under the write lock")
            if reservation_id is not None and keep_reservation:
                from app.services.storage_ledger import UPLOAD_WORK

                self._settle_storage_in(conn, reservation_id, purpose=UPLOAD_WORK)
            elif reservation_id is not None:
                conn.execute(
                    "DELETE FROM storage_reservations WHERE id = ? AND owner_id = ?",
                    (reservation_id, owner),
                )
            self._touch_upload_batch_in(conn, owner, item, now)
            return True

    def record_upload_commit_art(
        self, *, owner_id: int, operation_uuid: str, boot_id: str, cover_art_id: int,
        cover_art_created: bool, now: int,
    ) -> bool:
        """Journal the registered cover art and whether this operation created
        it, guarded by state ``committing`` and this boot's lease."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE upload_commit_journal SET cover_art_id = ?, cover_art_created = ?,"
                " updated_at = ? WHERE owner_id = ? AND operation_uuid = ?"
                " AND state = 'committing' AND lease_boot_id = ?",
                (cover_art_id, 1 if cover_art_created else 0, now, owner, key, boot_id),
            )
            return cursor.rowcount == 1

    def adopt_upload_commit_art(
        self, *, owner_id: int, operation_uuid: str, cover_art_id: int, now: int
    ) -> bool:
        """Startup: journal ``cover_art_id`` as created by this operation when its
        journal is still ``committing`` with no art recorded and no track and no
        other commit journal references that art (checked in this transaction).
        False: nothing written; shared art is never adopted."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE upload_commit_journal SET cover_art_id = ?, cover_art_created = 1,"
                " updated_at = ? WHERE owner_id = ? AND operation_uuid = ?"
                " AND state = 'committing' AND cover_art_id IS NULL"
                " AND NOT EXISTS (SELECT 1 FROM trackmetadata WHERE cover_art_id = ?)"
                " AND NOT EXISTS (SELECT 1 FROM upload_commit_journal o WHERE o.cover_art_id = ?"
                "                 AND NOT (o.owner_id = ? AND o.operation_uuid = ?))",
                (cover_art_id, now, owner, key, cover_art_id, cover_art_id, owner, key),
            )
            return cursor.rowcount == 1

    @staticmethod
    def _exact_library_matches_in(
        conn, *, owner_id: int, item_uuid: str, identity, acknowledged: dict,
        exclude=frozenset(),
    ) -> tuple[list[str], list[str]]:
        """SC-16a helper (never opens, commits or closes a connection): the
        owner's live library tracks with ``identity``'s exact audio identity
        (``find_duplicates`` exact layer only, uncapped, finder order), split
        into (acknowledged, unacknowledged) for the committing ``item_uuid``.
        Acknowledged: listed in ``acknowledged['library_tracks']``; published
        by an imported item listed in ``['staged_items']``; or published by an
        imported item whose persisted acknowledgements list ``item_uuid``."""
        # Local import: app.services' package init imports this module (cycle).
        from app.services.duplicate_detection import TrackRef, find_duplicates

        report = find_duplicates(
            conn, dataclasses.replace(identity, fingerprint=None),
            owner_id=owner_id, exclude=frozenset(exclude),
        )
        matches = [
            m.subject.uuid_id for m in report.matches
            if isinstance(m.subject, TrackRef) and m.kind == "exact"
        ]
        listed = set(acknowledged.get("library_tracks", ()))
        staged = set(acknowledged.get("staged_items", ()))
        published: set[str] = set()
        rest = [t for t in matches if t not in listed]
        if rest:
            marks = ", ".join("?" * len(rest))
            rows = conn.execute(
                "SELECT i.result_track_uuid, i.item_uuid, EXISTS ("
                " SELECT 1 FROM upload_item_acknowledgements a"
                " WHERE a.owner_id = i.owner_id AND a.item_uuid = i.item_uuid"
                " AND a.subject_kind = 'staged_item' AND a.subject_ref = ?) AS acks_us"
                " FROM upload_items i WHERE i.owner_id = ? AND i.state = 'imported'"
                f" AND i.result_track_uuid IN ({marks})",
                (item_uuid, owner_id, *rest),
            ).fetchall()
            published = {r[0] for r in rows if r[1] in staged or r[2]}
        yes = [t for t in matches if t in listed or t in published]
        no = [t for t in matches if t not in listed and t not in published]
        return yes, no

    def upload_commit_preflight(self, *, owner_id: int, operation_uuid: str) -> list[str] | None:
        """Uuids of the owner's live library tracks that exactly match a
        ``prepared`` commit's journaled identity and are not acknowledged
        (finder order); None when there is no prepared journal row. Writes
        nothing."""
        from app.services.audio_identity import identity_from_columns

        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection() as conn:
            row = conn.execute(
                "SELECT * FROM upload_commit_journal"
                " WHERE owner_id = ? AND operation_uuid = ? AND state = 'prepared'",
                (owner, key),
            ).fetchone()
            if row is None:
                return None
            _, unacknowledged = self._exact_library_matches_in(
                conn, owner_id=owner, item_uuid=row["item_uuid"],
                identity=identity_from_columns(dict(row)),
                acknowledged=json.loads(row["acknowledged_duplicates"]),
                exclude=frozenset({row["reserved_track_uuid"]}),
            )
        return unacknowledged

    @staticmethod
    def _record_upload_conflict_in(
        conn, *, owner_id: int, operation_uuid: str, item_uuid: str, track_uuids, now: int,
        clear_final_path: bool, drop_work_reservation: bool,
    ) -> bool:
        """The one recording of a ``duplicate_conflict`` (never opens or commits):
        journal and item (``committing`` only) end there listing ``track_uuids``;
        source, review version and review data are untouched. ``clear_final_path``
        NULLs the journal's final path (no file was placed); the work reservation
        row is dropped when ``drop_work_reservation``."""
        from app.services.storage_ledger import UPLOAD_WORK

        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        if not Database._transition_upload_item_in(
            conn, owner_id=owner, item_uuid=item_uuid, from_states=("committing",),
            to_state="duplicate_conflict", now=now,
            fields={"conflict_track_uuids": json.dumps(list(track_uuids)), "lease_boot_id": None,
                    "error_code": None, "error_message": None, "error_retryable": None},
        ):
            return False
        conn.execute(
            "UPDATE upload_commit_journal SET state = 'duplicate_conflict', updated_at = ?"
            + (", final_path = NULL" if clear_final_path else "")
            + " WHERE owner_id = ? AND operation_uuid = ?",
            (now, owner, key),
        )
        if drop_work_reservation:
            conn.execute(
                "DELETE FROM storage_reservations WHERE owner_id = ? AND purpose = ? AND subject_ref = ?",
                (owner, UPLOAD_WORK, key),
            )
        return True

    def record_upload_commit_conflict(
        self, *, owner_id: int, operation_uuid: str, track_uuids, now: int,
        placed: bool = False,
    ) -> bool:
        """Step 3: a ``prepared`` (or ``moved``) commit with unacknowledged exact
        matches ends ``duplicate_conflict`` in one transaction. False when the
        journal is in neither state. ``final_path`` is kept when ``moved`` or when
        ``placed`` (a prepared journal whose final name is the work file's own link). The work reservation stays until
        ``release_upload_work``."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT item_uuid, state FROM upload_commit_journal"
                " WHERE owner_id = ? AND operation_uuid = ? AND state IN ('prepared', 'moved')",
                (owner, key),
            ).fetchone()
            if row is None:
                return False
            return self._record_upload_conflict_in(
                conn, owner_id=owner, operation_uuid=key, item_uuid=row["item_uuid"],
                track_uuids=track_uuids, now=now, clear_final_path=row["state"] == "prepared" and not placed,
                drop_work_reservation=False)

    def release_upload_work(self, *, owner_id: int, operation_uuid: str) -> None:
        """Drop the operation's durable ``upload_work`` reservation row."""
        from app.services.storage_ledger import UPLOAD_WORK

        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "DELETE FROM storage_reservations WHERE owner_id = ? AND purpose = ? AND subject_ref = ?",
                (owner, UPLOAD_WORK, key),
            )

    def fail_upload_publish(
        self, *, owner_id: int, operation_uuid: str, error_code: str, error_message: str, now: int,
        placed: bool = False, retryable: bool = True,
    ) -> bool:
        """A commit that failed in steps 3-5 (not a duplicate conflict) ends in
        one transaction guarded on journal state ``prepared`` or ``moved`` (False,
        nothing written, otherwise): journal ``failed`` (``final_path`` NULL unless this
        operation placed a file there: ``placed``, or a ``moved`` journal), item back to ``review_ready``
        with a new review version and a retryable error. Reservations, the
        source and its quota row are untouched."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT item_uuid, state FROM upload_commit_journal"
                " WHERE owner_id = ? AND operation_uuid = ? AND state IN ('prepared', 'moved')",
                (owner, key),
            ).fetchone()
            if row is None:
                return False
            conn.execute(
                "UPDATE upload_commit_journal SET state = 'failed', error_code = ?, updated_at = ?"
                + (", final_path = NULL" if row["state"] == "prepared" and not placed else "")
                + " WHERE owner_id = ? AND operation_uuid = ?",
                (error_code, now, owner, key),
            )
            cursor = conn.execute(
                "UPDATE upload_items SET state = 'review_ready', review_version = review_version + 1,"
                " error_code = ?, error_message = ?, error_retryable = ?, lease_boot_id = NULL,"
                " updated_at = ? WHERE owner_id = ? AND item_uuid = ? AND state = 'committing'",
                (error_code, error_message, int(retryable), now, owner, row["item_uuid"]),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("commit item left committing under the write lock")
            self._touch_upload_batch_in(conn, owner, row["item_uuid"], now)
            return True

    def record_upload_publish_art(
        self, *, owner_id: int, operation_uuid: str, cover_art_id: int, cover_art_created: bool, now: int
    ) -> bool:
        """Journal re-registered cover art, guarded on journal state ``moved``."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE upload_commit_journal SET cover_art_id = ?, cover_art_created = ?,"
                " updated_at = ? WHERE owner_id = ? AND operation_uuid = ? AND state = 'moved'",
                (cover_art_id, 1 if cover_art_created else 0, now, owner, key),
            )
            return cursor.rowcount == 1

    def mark_upload_commit_moved(self, *, owner_id: int, operation_uuid: str, now: int) -> bool:
        """journal prepared -> moved in one transaction; False when it was not prepared."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE upload_commit_journal SET state = 'moved', updated_at = ?"
                " WHERE owner_id = ? AND operation_uuid = ? AND state = 'prepared'",
                (now, owner, key),
            )
            return cursor.rowcount == 1

    def publish_upload_commit(
        self, *, owner_id: int, operation_uuid: str, track, stat, fingerprinter_present: bool,
        work_removed: bool, now: int,
    ) -> tuple[str, object]:
        """Step 5, one BEGIN IMMEDIATE transaction guarded on journal state
        ``moved``: repeat the exact-match rule, then insert the track, mark the
        item and journal ``imported`` and, when the work link is gone, drop the
        work reservation. Returns ("imported", revision), ("duplicate_conflict",
        uuids) with nothing written, or ("not_moved", None)."""
        from app.services.audio_identity import identity_from_columns
        from app.services.storage_ledger import UPLOAD_WORK

        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT * FROM upload_commit_journal"
                " WHERE owner_id = ? AND operation_uuid = ? AND state = 'moved'",
                (owner, key),
            ).fetchone()
            if row is None:
                return "not_moved", None
            frozen = json.loads(row["acknowledged_duplicates"])
            acknowledged, unacknowledged = self._exact_library_matches_in(
                conn, owner_id=owner, item_uuid=row["item_uuid"],
                identity=identity_from_columns(dict(row)),
                acknowledged=frozen,
                exclude=frozenset({row["reserved_track_uuid"]}),
            )
            if unacknowledged:
                if not self._record_upload_conflict_in(
                    conn, owner_id=owner, operation_uuid=key, item_uuid=row["item_uuid"],
                    track_uuids=unacknowledged, now=now, clear_final_path=False,
                    drop_work_reservation=work_removed,
                ):
                    raise RuntimeError("upload item is not committing")
                return "duplicate_conflict", unacknowledged
            revision = self._insert_track_in(
                conn, track, owner_id=owner, fingerprinter_present=fingerprinter_present, stat=stat)
            self._seed_dismissed_candidates_in(conn, track.uuid_id, acknowledged)
            for kind, table, column, refs in (
                ("library_track", "tracks", "uuid_id", frozen.get("library_tracks", ())),
                ("staged_item", "upload_items", "item_uuid", frozen.get("staged_items", ())),
            ):
                if refs:
                    conn.execute(
                        "INSERT OR IGNORE INTO upload_item_acknowledgements"
                        " (owner_id, item_uuid, subject_kind, subject_ref)"
                        f" SELECT ?, ?, ?, {column} FROM {table}"
                        f" WHERE owner_id = ? AND {column} IN ({', '.join('?' * len(refs))})",
                        (owner, row["item_uuid"], kind, owner, *refs),
                    )
            if row["digest_check"] == "unverified":
                self._mark_audio_identity_stale_in(conn, track.uuid_id, "tag_write")
            if not self._transition_upload_item_in(
                conn, owner_id=owner, item_uuid=row["item_uuid"], from_states=("committing",),
                to_state="imported", now=now,
                fields={"result_track_uuid": track.uuid_id, "result_revision": revision,
                        "final_path": row["final_path"], "lease_boot_id": None,
                        "error_code": None, "error_message": None, "error_retryable": None},
            ):
                raise RuntimeError("upload item is not committing")
            conn.execute(
                "UPDATE upload_commit_journal SET state = 'imported', updated_at = ?"
                " WHERE owner_id = ? AND operation_uuid = ?",
                (now, owner, key),
            )
            if work_removed:
                conn.execute(
                    "DELETE FROM storage_reservations"
                    " WHERE owner_id = ? AND purpose = ? AND subject_ref = ?",
                    (owner, UPLOAD_WORK, key),
                )
            return "imported", revision

    def prepare_upload_commit(
        self, *, owner_id: int, operation_uuid: str, boot_id: str, final_path: str,
        final_metadata: str, identity_columns: dict, digest_check: str,
        reservation_id: int, now: int,
    ) -> dict | None:
        """committing -> prepared in one transaction, guarded by this boot's
        lease (None, nothing written, when it no longer holds). Settles the
        work-copy reservation into the durable ``upload_work`` row and clears
        the item's lease. Returns the prepared journal row."""
        from app.services.audio_identity import FINGERPRINT_COLUMNS, IDENTITY_COLUMNS
        from app.services.storage_ledger import UPLOAD_WORK

        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        if not set(identity_columns) <= {*IDENTITY_COLUMNS, *FINGERPRINT_COLUMNS}:
            raise ValueError("unknown commit identity column")
        # A fingerprint column the identity does not carry is NULL = recompute.
        values = {**dict.fromkeys(FINGERPRINT_COLUMNS), **identity_columns}
        names = sorted(values)
        with self._connection(commit=True, immediate=True) as conn:
            held = conn.execute(
                "SELECT item_uuid FROM upload_commit_journal WHERE owner_id = ? AND operation_uuid = ?"
                " AND state = 'committing' AND lease_boot_id = ?",
                (owner, key, boot_id),
            ).fetchone()
            if held is None:
                return None
            assignments = "".join(f", {n} = ?" for n in names)
            conn.execute(
                "UPDATE upload_commit_journal SET state = 'prepared', final_path = ?,"
                " final_metadata = ?, digest_check = ?, lease_boot_id = NULL, updated_at = ?"
                f"{assignments} WHERE owner_id = ? AND operation_uuid = ?",
                (final_path, final_metadata, digest_check, now,
                 *(values[n] for n in names), owner, key),
            )
            self._settle_storage_in(conn, reservation_id, purpose=UPLOAD_WORK)
            conn.execute(
                "UPDATE upload_items SET lease_boot_id = NULL WHERE owner_id = ? AND item_uuid = ?"
                " AND lease_boot_id = ?",
                (owner, held["item_uuid"], boot_id),
            )
            return dict(conn.execute(
                "SELECT * FROM upload_commit_journal WHERE owner_id = ? AND operation_uuid = ?",
                (owner, key),
            ).fetchone())

    def get_upload_preview(self, item_uuid, *, owner_id: int) -> dict | None:
        """``source_path`` and ``detected_metadata`` of the owner's ``review_ready``
        item; None for anything else (unknown, foreign, other state)."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection() as conn:
            row = conn.execute(
                "SELECT source_path, detected_metadata FROM upload_items"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'review_ready'",
                (owner, key),
            ).fetchone()
        return None if row is None else dict(row)

    def get_upload_item_source_path(self, item_uuid, *, owner_id: int) -> str | None:
        """The recorded source path of an owned item (server-internal, never an API field)."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection() as conn:
            row = conn.execute(
                "SELECT source_path FROM upload_items WHERE owner_id = ? AND item_uuid = ?",
                (owner, key),
            ).fetchone()
        return None if row is None else row["source_path"]

    def release_cancelled_upload_source(
        self, item_uuid, *, owner_id: int, source_path: str, now: int,
        from_states=("cancelled",),
    ) -> bool:
        """After an ended item's source file is gone: clear ``source_path`` and
        delete its ``upload_source`` quota row in one transaction, guarded on the
        item being in one of ``from_states`` (``cancelled``, ``failed``, ``expanded``,
        ``imported``, ``duplicate`` or ``expired``) and on that path."""
        from app.services.storage_ledger import UPLOAD_SOURCE  # deferred, as in fail_upload_validation

        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        states = tuple(from_states)
        allowed = {"cancelled", "failed", "expanded", "imported", "duplicate", "expired"}
        if not states or not set(states) <= allowed:
            raise ValueError("from_states must be among " + ", ".join(sorted(allowed)))
        marks = ",".join("?" for _ in states)
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET source_path = NULL, updated_at = ?"
                f" WHERE owner_id = ? AND item_uuid = ? AND state IN ({marks}) AND source_path = ?",
                (now, owner, key, *states, source_path),
            )
            if cur.rowcount != 1:
                return False
            conn.execute(
                "DELETE FROM storage_reservations WHERE owner_id = ? AND subject_ref = ?"
                " AND purpose = ?",
                (owner, key, UPLOAD_SOURCE),
            )
            self._touch_upload_batch_in(conn, owner, key, now)
            return True

    def upload_child_usage(self, *, owner_id: int, batch_uuid: str, parent_item_uuid: str) -> tuple[int, int]:
        """Count and declared bytes of the batch's archive children of other archives."""
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT COUNT(*) AS n, COALESCE(SUM(expected_bytes), 0) AS b FROM upload_items"
                " WHERE owner_id = ? AND batch_uuid = ? AND parent_item_uuid IS NOT NULL"
                " AND parent_item_uuid <> ?",
                (owner, batch_uuid, parent_item_uuid),
            ).fetchone()
        return row["n"], row["b"]

    def ensure_upload_manifest(
        self, *, owner_id: int, item_uuid: str, boot_id: str, review_version: int,
        members: list, skipped: int, now: int,
    ) -> list[dict] | None:
        """Create the archive's ordered child rows once (fresh item uuids) and
        return them; an archive that already has children gets those back.
        None, nothing written, when the parent is no longer ``validating`` under
        this boot's lease and review_version."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            parent = conn.execute(
                "SELECT batch_uuid, selection_index FROM upload_items WHERE owner_id = ? AND item_uuid = ?"
                " AND state = 'validating' AND lease_boot_id = ? AND review_version = ?",
                (owner, key, boot_id, review_version),
            ).fetchone()
            if parent is None:
                return None
            existing = conn.execute(
                "SELECT 1 FROM upload_items WHERE owner_id = ? AND parent_item_uuid = ? LIMIT 1",
                (owner, key),
            ).fetchone()
            if existing is None:
                for name, declared in members:
                    conn.execute(
                        "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, parent_item_uuid,"
                        " filename, selection_index, member_order_key, expected_bytes, state,"
                        " created_at, updated_at, progress_at)"
                        " VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'validating', ?, ?, ?)",
                        (owner, str(uuid.uuid4()), parent["batch_uuid"], key, name,
                         parent["selection_index"], name, declared, now, now, now),
                    )
                conn.execute(
                    "UPDATE upload_items SET kind = 'zip', skipped_members = ?, updated_at = ?"
                    " WHERE owner_id = ? AND item_uuid = ?",
                    (skipped, now, owner, key),
                )
            rows = conn.execute(
                "SELECT item_uuid, batch_uuid, member_order_key, state FROM upload_items"
                " WHERE owner_id = ? AND parent_item_uuid = ? ORDER BY member_order_key",
                (owner, key),
            ).fetchall()
            return [dict(row) for row in rows]

    def finish_upload_expansion(
        self, *, owner_id: int, item_uuid: str, boot_id: str, review_version: int,
        staged: list, reservation_id: int, source_purpose: str, now: int,
    ) -> set | bool:
        """Publish the staged children and end the archive as ``expanded`` in
        one transaction, guarded as ``ensure_upload_manifest`` the set of child uuids
        it published, or False, nothing written, when the guard fails)."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            held = conn.execute(
                "SELECT 1 FROM upload_items WHERE owner_id = ? AND item_uuid = ?"
                " AND state = 'validating' AND lease_boot_id = ? AND review_version = ?",
                (owner, key, boot_id, review_version),
            ).fetchone()
            if held is None:
                return False
            published = set()
            for child, source_path, nbytes, sha256 in staged:
                cur = conn.execute(
                    "UPDATE upload_items SET source_path = ?, received_bytes = ?, received_sha256 = ?,"
                    " progress_at = ?, updated_at = ? WHERE owner_id = ? AND item_uuid = ?"
                    " AND parent_item_uuid = ? AND state = 'validating'",
                    (source_path, nbytes, sha256, now, now, owner, child, key),
                )
                if cur.rowcount == 1:
                    published.add(child)
                    conn.execute(
                        "INSERT INTO storage_reservations"
                        " (owner_id, purpose, subject_ref, bytes, lease_boot_id, created_at)"
                        " VALUES (?, ?, ?, ?, NULL, unixepoch())",
                        (owner, source_purpose, child, nbytes),
                    )
            conn.execute("DELETE FROM storage_reservations WHERE id = ?", (reservation_id,))
            conn.execute(
                "UPDATE upload_items SET state = 'expanded', lease_boot_id = NULL, error_code = NULL,"
                " error_message = NULL, error_retryable = NULL, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ?",
                (now, owner, key),
            )
            self._touch_upload_batch_in(conn, owner, key, now)
            return published

    def list_upload_children(self, *, owner_id: int, item_uuid: str) -> list[dict]:
        """An archive's child rows (ids and state only)."""
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT item_uuid, batch_uuid, state FROM upload_items"
                " WHERE owner_id = ? AND parent_item_uuid = ? ORDER BY member_order_key",
                (owner, str(uuid.UUID(str(item_uuid)))),
            ).fetchall()
        return [dict(row) for row in rows]

    def list_upload_commit_journals_to_resume(
        self, states: tuple = ("prepared", "moved")
    ) -> list[dict]:
        """Startup: every owner's commit journal in ``states`` (default still
        ``prepared`` or ``moved``)."""
        allowed = {"committing", "prepared", "moved"}
        if not states or not set(states) <= allowed:
            raise ValueError("states must be among " + ", ".join(sorted(allowed)))
        marks = ",".join("?" for _ in states)
        with self._connection() as conn:
            rows = conn.execute(
                f"SELECT * FROM upload_commit_journal WHERE state IN ({marks})"
                " ORDER BY created_at, operation_uuid",
                tuple(states),
            ).fetchall()
        return [dict(row) for row in rows]

    def list_finished_upload_commit_journals(self, *, updated_before: int | None = None) -> list[dict]:
        """Startup and janitor: every owner's commit journal that ended (``imported``,
        ``duplicate_conflict`` or ``failed``) and still waits for its clean-up;
        with ``updated_before``, only those last updated at or before it."""
        bound = "" if updated_before is None else " AND updated_at <= ?"
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT * FROM upload_commit_journal"
                " WHERE state IN ('imported', 'duplicate_conflict', 'failed')" + bound
                + " ORDER BY created_at, operation_uuid",
                () if updated_before is None else (updated_before,),
            ).fetchall()
        return [dict(row) for row in rows]

    def delete_finished_upload_commit_journal(
        self, *, owner_id: int, operation_uuid: str, state: str
    ) -> bool:
        """Delete a cleaned-up journal row, guarded on its finished ``state`` and on
        the operation holding no ``upload_work`` reservation. The receipt stays."""
        from app.services.storage_ledger import UPLOAD_WORK

        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        if state not in ("imported", "duplicate_conflict", "failed"):
            raise ValueError("state must be a finished journal state")
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "DELETE FROM upload_commit_journal WHERE owner_id = ? AND operation_uuid = ?"
                " AND state = ? AND NOT EXISTS (SELECT 1 FROM storage_reservations"
                " WHERE owner_id = ? AND purpose = ? AND subject_ref = ?)",
                (owner, key, state, owner, UPLOAD_WORK, key),
            )
            return cur.rowcount == 1

    def list_expirable_upload_items(self, *, progress_before: int) -> list[dict]:
        """Janitor: every owner's unconfirmed item (``allocated``, ``review_ready``,
        ``duplicate_conflict``, ``failed``) whose last progress is at or before
        ``progress_before``."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT owner_id, item_uuid, state FROM upload_items WHERE state IN"
                " ('allocated', 'review_ready', 'duplicate_conflict', 'failed')"
                " AND progress_at <= ? ORDER BY owner_id, item_uuid",
                (progress_before,),
            ).fetchall()
        return [dict(row) for row in rows]

    def expire_upload_item(
        self, item_uuid, *, owner_id: int, from_state: str, progress_before: int, now: int
    ) -> bool:
        """Janitor: an owned unconfirmed item becomes ``expired`` only if it is
        still in ``from_state`` and its progress is still at or before ``progress_before``
        (a concurrent user action wins)."""
        if from_state not in ("allocated", "review_ready", "duplicate_conflict", "failed"):
            raise ValueError("from_state must be an unconfirmed item state")
        with self._connection(commit=True, immediate=True) as conn:
            return self._transition_upload_item_in(
                conn, owner_id=owner_id, item_uuid=item_uuid, from_states=(from_state,),
                to_state="expired", now=now, fields={"lease_boot_id": None},
                progress_at_most=progress_before)

    def list_ended_upload_items(self) -> list[dict]:
        """Janitor: every owner's item in an ended state with its recorded paths."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT owner_id, item_uuid, batch_uuid, state, source_path, part_path"
                " FROM upload_items WHERE state IN"
                " ('cancelled', 'expired', 'imported', 'duplicate', 'expanded')"
                " ORDER BY owner_id, batch_uuid, item_uuid"
            ).fetchall()
        return [dict(row) for row in rows]

    def count_live_upload_items(self, *, owner_id: int, batch_uuid: str) -> int:
        """Items of an owned batch that are not in an ended state."""
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            return conn.execute(
                "SELECT count(*) FROM upload_items WHERE owner_id = ? AND batch_uuid = ?"
                " AND state NOT IN ('cancelled', 'expired', 'imported', 'duplicate', 'expanded')",
                (owner, str(uuid.UUID(str(batch_uuid)))),
            ).fetchone()[0]

    def list_upload_batches_for_retention(self, *, updated_before: int) -> list[dict]:
        """Janitor: every owner's batch last updated at or before ``updated_before``,
        with its item uuids. A candidate list only; ``prune_upload_batch`` decides."""
        with self._connection() as conn:
            batches = conn.execute(
                "SELECT owner_id, batch_uuid FROM upload_batches WHERE updated_at <= ?"
                " ORDER BY owner_id, batch_uuid",
                (updated_before,),
            ).fetchall()
            out = []
            for b in batches:
                items = conn.execute(
                    "SELECT item_uuid FROM upload_items WHERE owner_id = ? AND batch_uuid = ?"
                    " ORDER BY item_uuid",
                    (b["owner_id"], b["batch_uuid"]),
                ).fetchall()
                out.append({"owner_id": b["owner_id"], "batch_uuid": b["batch_uuid"],
                            "item_uuids": [i["item_uuid"] for i in items]})
        return out

    def prune_upload_batch(
        self, *, owner_id: int, batch_uuid: str, updated_before: int, dry_run: bool = False
    ) -> bool:
        """Retention: delete an owned batch and its items (identity and
        acknowledgement rows cascade) when, checked in this one write
        transaction, every item is ended and last updated at or before
        ``updated_before``, so is the batch, no item records a source or part
        path, no reservation names an item or its commit operation, and no
        commit journal remains. Receipts are never touched. False: kept.
        ``dry_run`` only answers whether it would prune."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(batch_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            batch = conn.execute(
                "SELECT 1 FROM upload_batches WHERE owner_id = ? AND batch_uuid = ?"
                " AND updated_at <= ?",
                (owner, key, updated_before),
            ).fetchone()
            if batch is None:
                return False
            kept = conn.execute(
                "SELECT 1 FROM upload_items WHERE owner_id = ? AND batch_uuid = ? AND ("
                " state NOT IN ('imported', 'duplicate', 'expanded', 'expired', 'cancelled')"
                " OR updated_at > ? OR source_path IS NOT NULL OR part_path IS NOT NULL"
                " OR EXISTS (SELECT 1 FROM storage_reservations r WHERE r.owner_id = upload_items.owner_id"
                "            AND r.subject_ref = upload_items.item_uuid)"
                " OR EXISTS (SELECT 1 FROM upload_commit_journal j WHERE j.owner_id = upload_items.owner_id"
                "            AND j.item_uuid = upload_items.item_uuid)"
                ") LIMIT 1",
                (owner, key, updated_before),
            ).fetchone()
            if kept is not None:
                return False
            if dry_run:
                return True
            conn.execute(
                "DELETE FROM upload_batches WHERE owner_id = ? AND batch_uuid = ?", (owner, key))
            return True

    def list_expanded_upload_archives(self) -> list[dict]:
        """Startup: expanded archives that still record their source file."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT owner_id, item_uuid, source_path FROM upload_items"
                " WHERE state = 'expanded' AND source_path IS NOT NULL ORDER BY owner_id, item_uuid"
            ).fetchall()
        return [dict(row) for row in rows]

    def list_ended_upload_children(self) -> list[dict]:
        """Startup: cancelled or failed archive children that record no source."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT owner_id, item_uuid, batch_uuid FROM upload_items"
                " WHERE parent_item_uuid IS NOT NULL AND state IN ('cancelled', 'failed')"
                " AND source_path IS NULL ORDER BY owner_id, item_uuid"
            ).fetchall()
        return [dict(row) for row in rows]

    def reconcile_upload_validation(self, *, boot_id: str) -> int:
        """Startup: ``validating`` items leased by another boot go back to the
        queue (lease cleared). Idempotent; returns how many."""
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET lease_boot_id = NULL WHERE state = 'validating'"
                " AND lease_boot_id IS NOT NULL AND lease_boot_id <> ?",
                (boot_id,),
            )
            return cur.rowcount

    def release_upload_validation_lease(self, *, owner_id: int, item_uuid: str, boot_id: str) -> bool:
        """A step that ends without a result clears this boot's lease: a still
        ``validating`` item goes back to the queue, a ``cancelled`` one carries no
        stale lease."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET lease_boot_id = NULL WHERE owner_id = ? AND item_uuid = ?"
                " AND state IN ('validating', 'cancelled') AND lease_boot_id = ?",
                (owner, key, boot_id),
            )
            return cur.rowcount == 1

    @staticmethod
    def _settle_upload_quota_in(
        conn, owner: int, item_uuid: str, *, settled_purpose: str, nbytes: int,
        reservation_id: int | None = None, receive_purpose: str | None = None,
    ) -> None:
        """A received file always ends with exactly one durable quota row: settle
        the item's receive row (the given one, else those of ``receive_purpose``),
        and restore the row if none exists. The bytes are on disk: no admission."""
        if reservation_id is not None:
            ids = [reservation_id]
        else:
            ids = [
                row["id"]
                for row in conn.execute(
                    "SELECT id FROM storage_reservations WHERE owner_id = ? AND subject_ref = ?"
                    " AND purpose IN (?, ?) ORDER BY id",
                    (owner, item_uuid, receive_purpose, settled_purpose),
                )
            ]
        if ids:
            Database._settle_storage_in(conn, ids[0], purpose=settled_purpose)
            for extra in ids[1:]:
                conn.execute("DELETE FROM storage_reservations WHERE id = ?", (extra,))
        has_row = conn.execute(
            "SELECT 1 FROM storage_reservations WHERE owner_id = ? AND subject_ref = ?"
            " AND purpose = ?",
            (owner, item_uuid, settled_purpose),
        ).fetchone()
        if has_row is None:
            conn.execute(
                "INSERT INTO storage_reservations"
                " (owner_id, purpose, subject_ref, bytes, lease_boot_id, created_at)"
                " VALUES (?, ?, ?, ?, NULL, unixepoch())",
                (owner, settled_purpose, item_uuid, nbytes),
            )

    def begin_upload_receipt(
        self, item_uuid, *, owner_id: int, boot_id: str, part_path: str, now: int
    ) -> bool:
        """Claim an allocated item for receiving (allocated -> receiving, leased to
        ``boot_id``) and record its part path before the file exists. False when
        the claim was lost or a cancel is already requested (nothing changes)."""
        # Deferred: the services package imports this module.
        from app.services import job_runtime

        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        item_key = {"owner_id": owner, "item_uuid": key}
        with self._connection(commit=True, immediate=True) as conn:
            if not job_runtime.claim(
                conn, "upload_items", item_key,
                boot_id=boot_id, from_state="allocated", to_state="receiving",
            ):
                return False
            # A claim ignores the cancel flag on purpose; look at it now.
            if job_runtime.cancel_requested(conn, "upload_items", item_key):
                conn.rollback()
                return False
            conn.execute(
                "UPDATE upload_items SET part_path = ?, received_bytes = 0,"
                " received_sha256 = NULL, error_code = NULL, error_message = NULL,"
                " error_retryable = NULL, updated_at = ?, progress_at = ?"
                " WHERE owner_id = ? AND item_uuid = ?",
                (part_path, now, now, owner, key),
            )
            self._touch_upload_batch_in(conn, owner, key, now)
            return True

    def record_upload_progress(
        self, item_uuid, *, owner_id: int, boot_id: str, part_path: str,
        received_bytes: int, now: int,
    ) -> bool:
        """Persist how many bytes a receipt has written. False when the guard no
        longer holds (not receiving, another lease or part, or a cancel is requested)."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET received_bytes = ?, progress_at = ?, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'receiving'"
                " AND lease_boot_id = ? AND part_path = ? AND cancel_requested = 0",
                (received_bytes, now, now, owner, key, boot_id, part_path),
            )
            return cur.rowcount == 1

    def complete_upload_receipt(
        self, item_uuid, *, owner_id: int, boot_id: str, part_path: str, source_path: str,
        received_bytes: int, received_sha256: str, reservation_id: int,
        settled_purpose: str, now: int,
    ) -> bool:
        """receiving -> validating, guarded by this boot's lease and part path,
        with the upload's reservation settled in the same transaction. False
        (nothing changed) when the guard no longer holds."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET state = 'validating', source_path = ?,"
                " received_bytes = ?, received_sha256 = ?, part_path = NULL,"
                " lease_boot_id = NULL, progress_at = ?, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'receiving'"
                " AND lease_boot_id = ? AND part_path = ?",
                (source_path, received_bytes, received_sha256, now, now,
                 owner, key, boot_id, part_path),
            )
            if cur.rowcount != 1:
                return False
            self._touch_upload_batch_in(conn, owner, key, now)
            self._settle_upload_quota_in(
                conn, owner, key, settled_purpose=settled_purpose,
                nbytes=received_bytes, reservation_id=reservation_id,
            )
            return True

    def end_upload_receipt(
        self, item_uuid, *, owner_id: int, boot_id: str, part_path: str, to_state: str,
        error_code: str, error_message: str, error_retryable: bool, now: int,
        keep_part: bool = False,
    ) -> bool:
        """An uncommitted receipt ends: receiving -> ``to_state`` with an error,
        guarded by lease and part path. Where the part path is still this
        receipt's, it and the lease are cleared even if the state already moved.
        ``keep_part`` keeps the part path recorded (a leftover that could not be
        removed): only the lease is cleared."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET state = ?, error_code = ?, error_message = ?,"
                " error_retryable = ?, received_bytes = 0,"
                " part_path = CASE WHEN ? THEN part_path ELSE NULL END,"
                " lease_boot_id = NULL, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'receiving'"
                " AND lease_boot_id = ? AND part_path = ?",
                (to_state, error_code, error_message, int(error_retryable), int(keep_part), now,
                 owner, key, boot_id, part_path),
            )
            changed = cur.rowcount == 1
            if changed:
                self._touch_upload_batch_in(conn, owner, key, now)
            else:
                conn.execute(
                    "UPDATE upload_items SET lease_boot_id = NULL,"
                    " part_path = CASE WHEN ? THEN part_path ELSE NULL END"
                    " WHERE owner_id = ? AND item_uuid = ? AND part_path = ?",
                    (int(keep_part), owner, key, part_path),
                )
            return changed

    def transition_upload_item(
        self, item_uuid, *, owner_id: int, from_states, to_state: str, now: int,
        fields: dict | None = None,
    ) -> tuple[bool, dict | None]:
        with self._connection(commit=True, immediate=True) as conn:
            changed = self._transition_upload_item_in(
                conn, owner_id=owner_id, item_uuid=item_uuid, from_states=from_states,
                to_state=to_state, now=now, fields=fields,
            )
            row = self._upload_item_in(conn, owner_id=owner_id, item_uuid=item_uuid)
        return changed, row

    @staticmethod
    def _upload_item_dict(row) -> dict:
        return {column: row[column] for column in _UPLOAD_ITEM_API_COLUMNS}

    @staticmethod
    def _next_revision(conn) -> int:
        """Allocate the next monotonic revision on ``conn``'s open transaction.

        Safe under SQLite's single-writer serialization — the increment and
        read-back happen inside the caller's exclusive write transaction, so
        no two writers can observe the same value. Must be called before the
        row write that stores the returned revision."""
        conn.execute("UPDATE revision_counter SET value = value + 1 WHERE id = 0")
        return conn.execute(
            "SELECT value FROM revision_counter WHERE id = 0"
        ).fetchone()[0]

    @staticmethod
    def _bump_track_revision(conn, uuid_id: str) -> int:
        """Bump the track to the next monotonic revision; returns the value
        written so callers don't need a redundant read-back."""
        revision = Database._next_revision(conn)
        conn.execute(
            "UPDATE tracks SET revision = ?, last_updated = unixepoch() "
            "WHERE uuid_id = ?",
            (revision, uuid_id),
        )
        return revision

    @staticmethod
    def _identity_column_values(identity) -> dict[str, Any]:
        """Identity -> ``track_audio_identity`` value columns. A computed ``failed``
        hash and a missing identity are both ``exact_state='pending'`` with every
        identity value NULL (unknown, not failed). Only ``IDENTITY_COLUMNS`` are
        returned: a carried fingerprint (fp_* keys) is never an identity-table value."""
        # Local import: app.services' package init imports this module (cycle).
        from app.services.audio_identity import IDENTITY_COLUMNS, ExactUnavailable, identity_to_columns
        if identity is None or (
            isinstance(identity.exact, ExactUnavailable) and identity.exact.state == "failed"
        ):
            values: dict[str, Any] = dict.fromkeys(IDENTITY_COLUMNS)
            values["exact_state"] = "pending"
            return values
        columns = identity_to_columns(identity)
        return {name: columns[name] for name in IDENTITY_COLUMNS}

    @staticmethod
    def _drop_open_pairs_in(conn, uuid_id: str, kind: str) -> None:
        """Delete the track's ``open`` duplicate pairs of ``kind`` ('exact' or
        'fingerprint'), scoped to the track's owner, on the caller's connection
        (never commits). Dismissed pairs are never touched: they record the
        user's decision."""
        conn.execute(
            "DELETE FROM track_duplicate_candidates WHERE (uuid_a = ? OR uuid_b = ?) "
            "AND kind = ? AND status = 'open' "
            "AND owner_id = (SELECT owner_id FROM tracks WHERE uuid_id = ?)",
            (uuid_id, uuid_id, kind, uuid_id),
        )

    @staticmethod
    def _requeue_match_in(conn, uuid_ids) -> int:
        """Send these tracks' matching back to pending on the caller's
        connection (never commits). Only ``match_state`` changes, and only on
        rows not already pending: the audio bytes did not change, so nothing is
        re-hashed. Returns the number of rows requeued."""
        uuid_ids = list(uuid_ids)
        if not uuid_ids:
            return 0
        return conn.execute(
            "UPDATE track_audio_identity SET match_state = 'pending' "
            f"WHERE match_state <> 'pending' AND uuid_id IN ({', '.join('?' * len(uuid_ids))})",
            uuid_ids,
        ).rowcount

    @staticmethod
    def _stat_columns(exact_state: str, stat: Optional[tuple[int, int, int]]) -> dict[str, Any]:
        """The stat columns to store with an identity: the snapshot only when an
        identity value is written (exact state not 'pending'), else all NULL."""
        if stat is None or exact_state == "pending":
            stat = (None, None, None)
        return dict(zip(("stat_size", "stat_mtime_ns", "stat_inode"), stat))

    @staticmethod
    def _insert_audio_identity_in(
        conn, uuid_id: str, identity, *, fingerprinter_present: bool,
        stat: Optional[tuple[int, int, int]] = None,
    ) -> None:
        """SC-16a primitive: (re)write a track's audio-identity row on the caller's
        connection (never opens, commits or closes one). A computed ``failed`` hash
        and a missing identity are both stored as ``exact_state='pending'`` with
        every identity value NULL (unknown, not failed); the worker retries. A
        precomputed print (``identity.fingerprint`` is a ``FingerprintIdentity``,
        e.g. Phase 7's staged identity) is stored in the same transaction through
        ``_write_fingerprint_in``; otherwise fp_state is 'pending' with a
        fingerprinter, else 'unavailable'. match_state is 'pending' either way.
        A track written as exact 'unsupported' loses its open exact pairs in the
        same transaction (it can no longer be compared; dismissed pairs stay).
        ``stat`` (size, mtime_ns, inode of the master the identity describes) is
        stored only when an identity value is written; otherwise, or when None,
        the stat columns are NULL (unknown)."""
        # Local import: app.services' package init imports this module (cycle).
        from app.services.audio_identity import FingerprintIdentity, fingerprint_to_columns

        values = Database._identity_column_values(identity)
        values["fp_state"] = "pending" if fingerprinter_present else "unavailable"
        values["fp_algorithm"] = None
        values.update(match_state="pending", priority=0, attempts=0, next_attempt_at=None)
        values.update(Database._stat_columns(values["exact_state"], stat))
        names = list(values)
        conn.execute(
            f"INSERT INTO track_audio_identity (uuid_id, generation, {', '.join(names)}) "
            f"VALUES (?, 1, {', '.join('?' * len(names))}) "
            f"ON CONFLICT(uuid_id) DO UPDATE SET generation = generation + 1, "
            f"{', '.join(f'{n} = excluded.{n}' for n in names)}",
            (uuid_id, *values.values()),
        )
        if values["exact_state"] in EXACT_NOT_COMPARABLE_STATES:
            Database._drop_open_pairs_in(conn, uuid_id, "exact")
        if identity is not None and isinstance(identity.fingerprint, FingerprintIdentity):
            Database._write_fingerprint_in(conn, uuid_id, fingerprint_to_columns(identity.fingerprint))

    @staticmethod
    def _mark_audio_identity_stale_in(conn, uuid_id: str, reason: str) -> bool:
        """SC-16a primitive: the audio bytes changed, so bump ``generation`` and
        send the exact layer and the match back to pending (digest kept). A
        'conversion' / 'settle' reason also re-pends the fingerprint, unless it
        is 'unavailable' (a mark never claims a fingerprinter exists). Returns
        whether a row existed; never inserts one."""
        if reason not in STALE_REASONS:
            raise ValueError(f"unknown audio identity stale reason {reason!r}")
        fp_state = (
            "fp_state"
            if reason == "tag_write"
            else "CASE WHEN fp_state = 'unavailable' THEN fp_state ELSE 'pending' END"
        )
        cursor = conn.execute(
            "UPDATE track_audio_identity SET generation = generation + 1, "
            "exact_state = 'pending', match_state = 'pending', priority = 0, "
            "attempts = 0, next_attempt_at = NULL, failure_reason = NULL, "
            f"fp_state = {fp_state} WHERE uuid_id = ?",
            (uuid_id,),
        )
        return cursor.rowcount > 0

    def mark_audio_identity_stale(self, uuid_id: str, reason: str, *, owner_id: int) -> bool:
        """Owner-scoped mark; used by the in-place edit after ``os.replace`` and by
        journal recovery. False (nothing changed) for a track the owner lacks."""
        _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            if conn.execute(
                "SELECT 1 FROM tracks WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner_id),
            ).fetchone() is None:
                return False
            return self._mark_audio_identity_stale_in(conn, uuid_id, reason)

    @staticmethod
    def _write_conversion_identity_in(
        conn, uuid_id: str, identity, *, audio_unchanged: bool,
        stat: Optional[tuple[int, int, int]] = None,
    ) -> bool:
        """SC-16a primitive: store the identity a conversion computed. UPDATE only
        (False if there is no row). Bumps ``generation``, keeps the fingerprint
        when the audio is unchanged (except a print failed only with the exact
        hash, which is re-pended), else re-pends it unless 'unavailable'; and
        sends the match back to pending. A fingerprint carried by ``identity`` is
        ignored (``_identity_column_values`` returns identity columns only). When
        the stored exact state is 'unsupported' the track's open exact pairs are
        removed in the same transaction (dismissed pairs stay). The old stat
        snapshot described the old master: it is replaced by ``stat`` (the new
        master's, stored only when an identity value is written), else NULL."""
        values = Database._identity_column_values(identity)
        values.update(match_state="pending", priority=0, attempts=0, next_attempt_at=None)
        values.update(Database._stat_columns(values["exact_state"], stat))
        sets = [f"{n} = ?" for n in values]
        if not audio_unchanged:
            sets.append("fp_state = CASE WHEN fp_state = 'unavailable' THEN fp_state ELSE 'pending' END")
        else:
            # DEV-6.5-12: a print failed only because the exact hash could not be made
            # (stored exact 'failed', or 'pending' again after a tag-edit mark) is retried
            # now that a current exact hash is written, as the worker's own exact compute
            # would (``_fp_after_exact``). SET reads the old row, so exact_state is the
            # stored one. A print that failed on its own (exact 'current') is kept.
            sets.append(
                "fp_state = CASE WHEN fp_state = 'failed' AND exact_state IN ('failed', 'pending') "
                "THEN 'pending' ELSE fp_state END"
            )
        cursor = conn.execute(
            f"UPDATE track_audio_identity SET generation = generation + 1, {', '.join(sets)} "
            "WHERE uuid_id = ?",
            (*values.values(), uuid_id),
        )
        if cursor.rowcount > 0 and values["exact_state"] in EXACT_NOT_COMPARABLE_STATES:
            Database._drop_open_pairs_in(conn, uuid_id, "exact")
        return cursor.rowcount > 0

    def write_conversion_identity(
        self, uuid_id: str, identity, *, audio_unchanged: bool = False, owner_id: int,
        stat: Optional[tuple[int, int, int]] = None,
    ) -> bool:
        """Owner-scoped short transaction for the in-place conversion, after
        ``os.replace``; ``stat`` is the new master's snapshot. False (nothing
        changed) for a track the owner lacks."""
        _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            if conn.execute(
                "SELECT 1 FROM tracks WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner_id),
            ).fetchone() is None:
                return False
            return self._write_conversion_identity_in(
                conn, uuid_id, identity, audio_unchanged=audio_unchanged, stat=stat
            )

    def get_audio_identity(self, uuid_id: str, *, owner_id: int) -> Optional[dict]:
        """The ``track_audio_identity`` row as a dict, for a track the owner owns."""
        _require_owner(owner_id)
        with self._connection() as conn:
            cursor = conn.execute(
                "SELECT i.* FROM track_audio_identity i JOIN tracks t ON t.uuid_id = i.uuid_id "
                "WHERE i.uuid_id = ? AND t.owner_id = ?",
                (uuid_id, owner_id),
            )
            row = cursor.fetchone()
            if row is None:
                return None
            return dict(zip([d[0] for d in cursor.description], tuple(row)))

    # Columns the identity worker may write; never generation, priority or match_state.
    _IDENTITY_WORKER_COLUMNS = frozenset({
        "exact_state", "exact_kind", "exact_digest", "sample_rate_hz", "channels",
        "bits_per_sample", "fp_state", "failure_reason", "attempts", "next_attempt_at",
        "stat_size", "stat_mtime_ns", "stat_inode", "computed_at", "tool_versions",
    })

    # Work is: (a) a due pending exact layer; (b) only for the fingerprint variant, a due pending
    # fingerprint whose exact layer is settled (current/unsupported; a failed exact
    # never queues its fingerprint); (c) pending matching once exact is not pending,
    # NOT gated by next_attempt_at (that backoff belongs to the exact/fingerprint
    # layer and never holds back matching). ORDER BY follows idx_tai_work
    # (priority, next_attempt_at); rows never backed off (NULL) keep rowid order,
    # due retries follow them.
    _IDENTITY_QUEUE_SQL_TEMPLATE = (
        "SELECT uuid_id, generation FROM track_audio_identity i "
        "WHERE ((exact_state = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= ?1)) "
        "OR (FP_CLAUSE fp_state = 'pending' AND exact_state IN ('current', 'unsupported') "
        "AND (next_attempt_at IS NULL OR next_attempt_at <= ?1)) "
        "OR (match_state = 'pending' AND exact_state <> 'pending')) "
        # Redundant; it states idx_tai_work's own predicate so the planner may use it.
        "AND (exact_state = 'pending' OR fp_state = 'pending' OR match_state = 'pending') "
        "AND NOT EXISTS (SELECT 1 FROM edit_journal j WHERE j.uuid_id = i.uuid_id) "
        "AND EXISTS (SELECT 1 FROM live_tracks lt WHERE lt.uuid_id = i.uuid_id) "
        "ORDER BY priority, next_attempt_at, rowid"
    )
    # Two fixed texts (one bound parameter, ?1 = now): without a fingerprinter the
    # fingerprint branch is constant false.
    _IDENTITY_QUEUE_SQL = _IDENTITY_QUEUE_SQL_TEMPLATE.replace("FP_CLAUSE", "0 = 1 AND")
    _IDENTITY_QUEUE_FP_SQL = _IDENTITY_QUEUE_SQL_TEMPLATE.replace("FP_CLAUSE", "1 = 1 AND")

    def next_identity_work(
        self, now: int, *, skip: Mapping[str, int], owner_id: Owner, fingerprint: bool = False
    ) -> Optional[str]:
        """The next due uuid by (priority, rowid), skipping any with an edit_journal
        row or a pending deletion (not in live_tracks) and any in ``skip``
        (uuid -> generation) while its generation still matches. Pending
        fingerprints count as work only when ``fingerprint`` is true (see
        ``_IDENTITY_QUEUE_SQL``). The queue spans every owner, so only
        ANY_OWNER is accepted."""
        if owner_id is not ANY_OWNER:
            raise TypeError("next_identity_work requires owner_id=ANY_OWNER")
        with self._connection() as conn:
            cursor = conn.execute(
                self._IDENTITY_QUEUE_FP_SQL if fingerprint else self._IDENTITY_QUEUE_SQL, (now,)
            )
            for uuid_id, generation in cursor:
                if skip.get(uuid_id) != generation:
                    return uuid_id
            return None

    def get_identity_subject(self, uuid_id: str, *, owner_id: Owner) -> Optional[dict]:
        """Identity row joined with its track's owner, path and codec, for any owner."""
        if owner_id is not ANY_OWNER:
            raise TypeError("get_identity_subject requires owner_id=ANY_OWNER")
        with self._connection() as conn:
            row = conn.execute(
                "SELECT i.uuid_id, t.owner_id, i.generation, t.file_path, m.codec, "
                "i.exact_state, i.exact_kind, i.exact_digest, i.fp_state, i.attempts, "
                "i.match_state, i.sample_rate_hz, i.channels, i.bits_per_sample, "
                "i.next_attempt_at, i.fp_algorithm, m.duration AS duration "
                "FROM track_audio_identity i JOIN tracks t ON t.uuid_id = i.uuid_id "
                "LEFT JOIN trackmetadata m ON m.uuid_id = i.uuid_id WHERE i.uuid_id = ?",
                (uuid_id,),
            ).fetchone()
            return dict(row) if row is not None else None

    def update_identity_if_unchanged(
        self,
        uuid_id: str,
        *,
        generation: int,
        file_path: str,
        values: Mapping[str, Any],
        verify: Optional[Callable[[], bool]] = None,
        owner_id: int,
        fingerprint: Optional[Mapping[str, Any]] = None,
    ) -> bool:
        """The worker's compare-and-set write: one transaction that writes ``values``
        only if the row still has ``generation``, the track still has this owner and
        path, no edit_journal row exists, the track is not pending deletion (refused
        like an edit journal), and ``verify()`` (run inside the
        transaction) is true. Otherwise changes nothing and returns False.

        ``fingerprint`` (optional) is the fingerprint layer's result, a mapping
        with the ``audio_identity.FINGERPRINT_COLUMNS`` keys (fp_state is one of
        current, low_information, too_short, failed). It is validated before
        anything is written, then written in the same transaction: the identity
        row's fp_state and fp_algorithm, ``match_state = 'pending'`` only when
        fp_state is 'current', and the ``track_audio_fingerprint`` row (upsert
        for current/low_information with duration_s > 0, deleted for
        too_short/failed). ``values`` may then be empty but must not contain
        fp_state. Any database error rolls the whole write back.

        Layers that settle as not comparable drop the track's open duplicate
        pairs of that kind in the same transaction: exact 'unsupported' in
        ``values`` drops exact pairs; a fingerprint of too_short or
        low_information drops fingerprint pairs. A failed layer (unknown) keeps
        its pairs. Dismissed pairs are kept."""
        _require_owner(owner_id)
        unknown = set(values) - self._IDENTITY_WORKER_COLUMNS
        if unknown or (not values and fingerprint is None):
            raise ValueError(f"not writable by the identity worker: {sorted(unknown)}")
        if fingerprint is not None:
            if "fp_state" in values:
                raise ValueError("fp_state must come from fingerprint, not values")
            self._check_fingerprint(fingerprint)
        with self._connection(commit=True, immediate=True) as conn:
            current = conn.execute(
                "SELECT 1 FROM track_audio_identity i JOIN live_tracks t ON t.uuid_id = i.uuid_id "
                "WHERE i.uuid_id = ? AND i.generation = ? AND t.owner_id = ? AND t.file_path = ? "
                "AND NOT EXISTS (SELECT 1 FROM edit_journal j WHERE j.uuid_id = i.uuid_id)",
                (uuid_id, generation, owner_id, file_path),
            ).fetchone()
            if current is None or (verify is not None and not verify()):
                return False
            if values:
                assignments = ", ".join(f"{column} = ?" for column in values)
                conn.execute(
                    f"UPDATE track_audio_identity SET {assignments} WHERE uuid_id = ?",
                    (*values.values(), uuid_id),
                )
                if values.get("exact_state") in EXACT_NOT_COMPARABLE_STATES:
                    self._drop_open_pairs_in(conn, uuid_id, "exact")
            if fingerprint is not None:
                self._write_fingerprint_in(conn, uuid_id, fingerprint)
            return True

    _FINGERPRINT_WRITE_STATES = frozenset({"current", "low_information", "too_short", "failed"})

    @classmethod
    def _check_fingerprint(cls, fp: Mapping[str, Any]) -> None:
        """ValueError unless ``fp`` is a writable fingerprint-layer result."""
        state = fp.get("fp_state")
        if state not in cls._FINGERPRINT_WRITE_STATES:
            raise ValueError(f"fp_state not writable: {state!r}")
        if not fp.get("fp_algorithm"):
            raise ValueError("fingerprint needs fp_algorithm")
        if state in ("current", "low_information"):
            duration = fp.get("fp_duration_s")
            if (not fp.get("fp_backend") or not isinstance(fp.get("fp_data"), (bytes, bytearray))
                    or fp.get("fp_item_count") is None
                    or isinstance(duration, bool) or not isinstance(duration, (int, float))
                    or not duration > 0):
                raise ValueError("malformed fingerprint")

    @classmethod
    def _write_fingerprint_in(cls, conn, uuid_id: str, fp: Mapping[str, Any]) -> None:
        """Validate, then write the identity row's fp_state/fp_algorithm (and
        match_state = 'pending' when the state is 'current') and the
        track_audio_fingerprint row, on ``conn`` (the caller's transaction). A
        state of too_short or low_information also removes the track's open
        fingerprint pairs; a failed print (unknown) keeps them. Dismissed pairs
        stay, and matching recreates open ones if the print becomes current again."""
        cls._check_fingerprint(fp)
        state = fp["fp_state"]
        conn.execute(
            "UPDATE track_audio_identity SET fp_state = ?, fp_algorithm = ?, "
            "match_state = CASE WHEN ? = 'current' THEN 'pending' ELSE match_state END WHERE uuid_id = ?",
            (state, fp["fp_algorithm"], state, uuid_id),
        )
        if state in ("current", "low_information"):
            conn.execute(
                "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
                "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(uuid_id) DO UPDATE SET backend = excluded.backend, "
                "algorithm = excluded.algorithm, duration_s = excluded.duration_s, "
                "item_count = excluded.item_count, data = excluded.data",
                (uuid_id, fp["fp_backend"], fp["fp_algorithm"], float(fp["fp_duration_s"]),
                 fp["fp_item_count"], bytes(fp["fp_data"])),
            )
        else:
            conn.execute("DELETE FROM track_audio_fingerprint WHERE uuid_id = ?", (uuid_id,))
        if state in FINGERPRINT_NOT_COMPARABLE_STATES:
            cls._drop_open_pairs_in(conn, uuid_id, "fingerprint")

    def find_duplicates_for_track(self, uuid_id: str, identity, *, owner_id: int):
        """The worker's read: ``find_duplicates`` for one library track against its
        owner's live library, uncapped, excluding the track itself. ``owner_id`` is
        the track's real owner, never ANY_OWNER."""
        # Local import: app.services' package init imports this module (cycle).
        from app.services import duplicate_detection

        owner = _require_owner(owner_id)
        with self._connection() as conn:
            return duplicate_detection.find_duplicates(
                conn, identity, owner_id=owner, exclude=frozenset({uuid_id})
            )

    def get_identity_fingerprint(self, uuid_id: str, *, owner_id: int):
        """The stored print of one of ``owner_id``'s tracks as a ``FingerprintIdentity``.

        ``owner_id`` is a real owner, never ANY_OWNER. Returns None when the
        track has no fingerprint row or is not that owner's. The state is the
        identity row's ``fp_state``; the rest comes from the fingerprint row.
        """
        # Local imports: app.services' package init imports this module (cycle).
        from app.services.audio_identity import FingerprintIdentity
        from app.services.fingerprinter import unpack_fingerprint

        owner = _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT i.fp_state, f.backend, f.algorithm, f.duration_s, f.data "
                "FROM track_audio_fingerprint f "
                "JOIN track_audio_identity i ON i.uuid_id = f.uuid_id "
                "JOIN tracks t ON t.uuid_id = f.uuid_id "
                "WHERE f.uuid_id = ? AND t.owner_id = ?",
                (uuid_id, owner),
            ).fetchone()
        if row is None:
            return None
        return FingerprintIdentity(row[0], row[1], row[2], row[3], unpack_fingerprint(row[4]))

    # The store's delete rule: this track's open exact pairs whose partner is a
    # live, exact-current track of the same owner (?1 = uuid, ?2 = owner).
    # The unary plus on status/owner_id disables idx_tdc_list for them, so SQLite uses
    # the primary key (uuid_a) and idx_tdc_b instead of reading every open pair of the
    # owner inside the write lock. Semantics are unchanged.
    _CANDIDATE_PARTNERS_SQL = (
        "SELECT c.uuid_a, c.uuid_b, i.exact_kind, i.exact_digest, "
        "i.sample_rate_hz, i.channels, i.bits_per_sample "
        "FROM track_duplicate_candidates c "
        "JOIN live_tracks lt ON lt.uuid_id = CASE WHEN c.uuid_a = ?1 THEN c.uuid_b ELSE c.uuid_a END "
        "JOIN track_audio_identity i ON i.uuid_id = lt.uuid_id "
        "WHERE (c.uuid_a = ?1 OR c.uuid_b = ?1) AND +c.status = 'open' AND c.kind = 'exact' "
        "AND +c.owner_id = ?2 AND lt.owner_id = ?2 AND i.exact_state = 'current'"
    )

    # The fingerprint twin of the rule above (?1 = uuid, ?2 = owner, ?3 = the subject's
    # print algorithm): open fingerprint pairs whose partner is a live same-owner track,
    # fp-'current' with a stored print of that algorithm. Same index steering.
    _FINGERPRINT_PARTNERS_SQL = (
        "SELECT c.uuid_a, c.uuid_b, lt.uuid_id "
        "FROM track_duplicate_candidates c "
        "JOIN live_tracks lt ON lt.uuid_id = CASE WHEN c.uuid_a = ?1 THEN c.uuid_b ELSE c.uuid_a END "
        "JOIN track_audio_identity i ON i.uuid_id = lt.uuid_id "
        "JOIN track_audio_fingerprint f ON f.uuid_id = lt.uuid_id "
        "WHERE (c.uuid_a = ?1 OR c.uuid_b = ?1) AND +c.status = 'open' AND c.kind = 'fingerprint' "
        "AND +c.owner_id = ?2 AND lt.owner_id = ?2 AND i.fp_state = 'current' AND f.algorithm = ?3"
    )

    def store_duplicate_candidates(
        self,
        uuid_id: str,
        *,
        generation: int,
        exact_state: str,
        fp_state: str,
        matches,
        matcher_version: str,
        now: int,
        owner_id: int,
    ) -> bool:
        """Store one subject track's duplicate matches (the worker's matching step).

        Opens its own immediate transaction. It writes only if the subject's
        identity row is unchanged since it was read: same ``generation``,
        ``exact_state`` and ``fp_state``, ``match_state`` still 'pending', the
        track belongs to ``owner_id``, is live (no deletion journal) and has no
        ``edit_journal`` row. Otherwise it returns False
        and changes nothing.

        Each ``TrackRef`` match is upserted in canonical (min, max) uuid order.
        An existing row gets its kind, band, score and matcher version updated;
        ``status`` (e.g. dismissed) is never changed. A partner that is no
        longer a live track of the same owner is skipped. Tracks of different
        owners are never paired. ``StagedRef`` matches are ignored.

        When the subject is exact-'current', an open exact row is deleted only
        if the partner is a live same-owner track that is also exact-'current'
        and the two hashes no longer match (compared, did not match). Unknown
        is not 'no match': pending, failed, non-live or identity-less partners,
        dismissed rows and fingerprint rows are kept. Finally ``match_state``
        becomes 'current' and ``matcher_version`` is stored. Returns True.

        When the subject is fp-'current', an open fingerprint row is likewise
        deleted only if the partner is a live same-owner track that is
        fp-'current' with a print of the subject's algorithm and is absent from
        ``matches`` (``matches`` holds every current same-algorithm print in the
        duration window that matched, so an absent one was compared and did not
        match). Pending, failed, other-algorithm, non-live partners and
        dismissed rows are kept.

        Separately from this step, a track whose layer settles as not
        comparable (exact unsupported; fingerprint too_short or
        low_information) has its open pairs of that kind removed when
        that state is written; dismissed pairs are never removed that way.
        """
        owner = _require_owner(owner_id)
        # Local import: app.services' package init imports this module (cycle).
        from app.services.audio_identity import ExactAudioHash, exact_match
        from app.services.duplicate_detection import BAND_RANK, TrackRef

        with self._connection(commit=True, immediate=True) as conn:
            subject_row = conn.execute(
                "SELECT i.exact_kind, i.exact_digest, i.sample_rate_hz, i.channels, i.bits_per_sample, "
                "i.fp_algorithm "
                "FROM track_audio_identity i JOIN live_tracks t ON t.uuid_id = i.uuid_id "
                "WHERE i.uuid_id = ? AND i.generation = ? AND i.exact_state = ? "
                "AND i.fp_state = ? AND i.match_state = 'pending' AND t.owner_id = ? "
                "AND NOT EXISTS (SELECT 1 FROM edit_journal j WHERE j.uuid_id = i.uuid_id)",
                (uuid_id, generation, exact_state, fp_state, owner),
            ).fetchone()
            if subject_row is None:
                return False
            for match in matches:
                if not isinstance(match.subject, TrackRef) or match.subject.uuid_id == uuid_id:
                    continue
                partner = match.subject.uuid_id
                uuid_a, uuid_b = min(uuid_id, partner), max(uuid_id, partner)
                score = 1.0 if match.score is None else match.score
                conn.execute(
                    "INSERT INTO track_duplicate_candidates "
                    "(owner_id, uuid_a, uuid_b, kind, band_rank, sort_score, matcher_version, detected_at) "
                    "SELECT ?, ?, ?, ?, ?, ?, ?, ? "
                    "WHERE EXISTS (SELECT 1 FROM live_tracks WHERE uuid_id = ? AND owner_id = ?) "
                    "ON CONFLICT(uuid_a, uuid_b) DO UPDATE SET kind = excluded.kind, "
                    "band_rank = excluded.band_rank, sort_score = excluded.sort_score, "
                    "matcher_version = excluded.matcher_version",
                    (owner, uuid_a, uuid_b, match.kind, BAND_RANK[match.band], score,
                     matcher_version, now, partner, owner),
                )
            if exact_state == "current":
                subject = ExactAudioHash(*subject_row[:5])
                rows = conn.execute(self._CANDIDATE_PARTNERS_SQL, (uuid_id, owner)).fetchall()
                for row in rows:
                    if not exact_match(subject, ExactAudioHash(*row[2:])):
                        conn.execute(
                            "DELETE FROM track_duplicate_candidates WHERE uuid_a = ? AND uuid_b = ?",
                            (row[0], row[1]),
                        )
            if fp_state == "current":
                matched = {
                    m.subject.uuid_id for m in matches if isinstance(m.subject, TrackRef)
                }
                for a, b, partner in conn.execute(
                    self._FINGERPRINT_PARTNERS_SQL, (uuid_id, owner, subject_row[5])
                ).fetchall():
                    if partner not in matched:
                        conn.execute(
                            "DELETE FROM track_duplicate_candidates WHERE uuid_a = ? AND uuid_b = ?",
                            (a, b),
                        )
            conn.execute(
                "UPDATE track_audio_identity SET match_state = 'current', matcher_version = ? "
                "WHERE uuid_id = ?",
                (matcher_version, uuid_id),
            )
            return True

    @staticmethod
    def _seed_dismissed_candidates_in(conn, uuid_id: str, partner_uuids) -> int:
        """Mark ``uuid_id`` and each partner as "keep both" (spec section 7).

        Runs on the caller's connection and inside its transaction; it never
        opens, commits or closes anything. Inserts canonical exact pairs as
        ``dismissed``, or sets an existing open pair to dismissed (its kind,
        band and score are kept). Only live partners of the subject's owner
        count; an unknown or non-live subject changes nothing. Returns the
        number of rows inserted or dismissed.
        """
        # Local import: app.services' package init imports this module (cycle).
        from app.services.duplicate_detection import SEEDED_MATCHER_VERSION

        owner_row = conn.execute(
            "SELECT owner_id FROM live_tracks WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()
        if owner_row is None:
            return 0
        owner = owner_row[0]
        changed = 0
        for partner in sorted(set(partner_uuids) - {uuid_id}):
            uuid_a, uuid_b = min(uuid_id, partner), max(uuid_id, partner)
            changed += conn.execute(
                "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
                "sort_score, matcher_version, detected_at, status, status_changed_at) "
                "SELECT ?, ?, ?, 'exact', 0, 1.0, ?, unixepoch(), 'dismissed', unixepoch() "
                "WHERE EXISTS (SELECT 1 FROM live_tracks WHERE uuid_id = ? AND owner_id = ?) "
                "ON CONFLICT(uuid_a, uuid_b) DO UPDATE SET status = 'dismissed', "
                "status_changed_at = excluded.status_changed_at "
                "WHERE track_duplicate_candidates.status = 'open'",
                (owner, uuid_a, uuid_b, SEEDED_MATCHER_VERSION, partner, owner),
            ).rowcount
        return changed

    def set_duplicate_candidate_status(
        self, uuid_a: str, uuid_b: str, status: str, *, owner_id: int
    ) -> bool:
        """Dismiss ('dismissed') or restore ('open') one duplicate pair.

        The pair may be given in either order. Only the owner's own pair of
        live tracks is found: a foreign or unknown pair is "not found" and
        returns False with nothing changed. Setting the status it already has
        returns True and writes nothing. Opens its own transaction.

        A restore that reopens a dismissed pair also sends both tracks'
        matching back to pending in the same transaction: the matcher never
        re-checks a dismissed pair, so it may be stale (a track changed while
        dismissed), and only a new match run removes or re-types it. The
        caller wakes the identity worker after the commit.

        The not-comparable rule (DEV-6.5-15) runs when a track's state is
        written and skips dismissed pairs, so a pair restored after one of its
        tracks became not comparable for the pair's kind is dropped here, in
        the same transaction (with that track's other open pairs of the kind).
        A track that becomes not comparable later is handled by the
        write-time rule.
        """
        if status not in ("open", "dismissed"):
            raise ValueError(f"status must be 'open' or 'dismissed', got {status!r}")
        owner = _require_owner(owner_id)
        a, b = min(uuid_a, uuid_b), max(uuid_a, uuid_b)
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT c.status, c.kind FROM track_duplicate_candidates c "
                "WHERE c.uuid_a = ? AND c.uuid_b = ? AND c.owner_id = ? "
                "AND EXISTS (SELECT 1 FROM live_tracks WHERE uuid_id = c.uuid_a AND owner_id = ?) "
                "AND EXISTS (SELECT 1 FROM live_tracks WHERE uuid_id = c.uuid_b AND owner_id = ?)",
                (a, b, owner, owner, owner),
            ).fetchone()
            if row is None:
                return False
            if row[0] != status:
                conn.execute(
                    "UPDATE track_duplicate_candidates SET status = ?, status_changed_at = unixepoch() "
                    "WHERE uuid_a = ? AND uuid_b = ?",
                    (status, a, b),
                )
                if status == "open":
                    self._requeue_match_in(conn, (a, b))
                    self._drop_restored_not_comparable_in(conn, (a, b), row[1])
            return True

    @staticmethod
    def _drop_restored_not_comparable_in(conn, uuid_ids, kind: str) -> None:
        """For a just-restored pair of ``kind``: each track whose layer of that
        kind is not comparable loses its open pairs of that kind (the pair
        included), on the caller's connection (never commits). A track without
        an identity row has nothing to drop."""
        column, not_comparable = {
            "exact": ("exact_state", EXACT_NOT_COMPARABLE_STATES),
            "fingerprint": ("fp_state", FINGERPRINT_NOT_COMPARABLE_STATES),
        }[kind]
        for uuid_id in uuid_ids:
            state = conn.execute(
                f"SELECT {column} FROM track_audio_identity WHERE uuid_id = ?", (uuid_id,)
            ).fetchone()
            if state is not None and state[0] in not_comparable:
                Database._drop_open_pairs_in(conn, uuid_id, kind)

    def list_duplicate_candidates(
        self,
        *,
        owner_id: int,
        status: str,
        after: tuple[int, float, str, str] | None,
        limit: int,
    ) -> list[dict]:
        """One keyset page of the owner's duplicate pairs with the given status.

        Ordered by (band_rank, sort_score DESC, uuid_a, uuid_b); ``after`` is
        the last row's (band_rank, sort_score, uuid_a, uuid_b) and the page
        starts strictly after it. Returns at most ``limit`` rows. Both members
        join through ``live_tracks``, so a pair with a pending-deletion member
        is omitted. Each row carries both tracks' summaries (``file_path`` is
        for the service layer); a NULL audio property stays None.
        """
        owner = _require_owner(owner_id)
        params: dict[str, object] = {
            "owner": owner,
            "status": status,
            "min_band": after[0] if after is not None else 0,
            "limit": limit,
        }
        keyset = ""
        if after is not None:
            params.update(r=after[0], s=after[1], a=after[2], b=after[3])
            keyset = (
                "AND (c.band_rank > :r OR (c.band_rank = :r AND (c.sort_score < :s "
                "OR (c.sort_score = :s AND (c.uuid_a > :a OR (c.uuid_a = :a AND c.uuid_b > :b))))))"
            )

        def cols(p: str) -> str:
            return (
                f"t{p}.uuid_id AS {p}_uuid_id, t{p}.revision AS {p}_revision, "
                f"m{p}.title AS {p}_title, m{p}.artist AS {p}_artist, m{p}.album AS {p}_album, "
                f"m{p}.codec AS {p}_codec, m{p}.bitrate_kbps AS {p}_bitrate_kbps, "
                f"m{p}.sample_rate_hz AS {p}_sample_rate_hz, m{p}.channels AS {p}_channels, "
                f"m{p}.duration AS {p}_duration_s, t{p}.created_at AS {p}_added_at, "
                f"l{p}.file_path AS {p}_file_path"
            )

        def join(p: str) -> str:
            return (
                f"CROSS JOIN live_tracks l{p} ON l{p}.uuid_id = c.uuid_{p} AND l{p}.owner_id = c.owner_id "
                f"CROSS JOIN tracks t{p} ON t{p}.id = l{p}.id "
                f"LEFT JOIN trackmetadata m{p} ON m{p}.uuid_id = c.uuid_{p} "
            )

        sql = (
            "SELECT c.uuid_a, c.uuid_b, c.kind, c.band_rank, c.sort_score, c.detected_at, c.status, "
            f"{cols('a')}, {cols('b')} "
            f"FROM track_duplicate_candidates c {join('a')}{join('b')}"
            "WHERE c.owner_id = :owner AND c.status = :status AND c.band_rank >= :min_band "
            f"{keyset} "
            "ORDER BY c.band_rank, c.sort_score DESC, c.uuid_a, c.uuid_b LIMIT :limit"
        )
        with self._connection() as conn:
            rows = conn.execute(sql, params).fetchall()

        def side(row, p: str) -> dict:
            return {
                k: row[f"{p}_{k}"]
                for k in (
                    "uuid_id", "revision", "title", "artist", "album", "codec",
                    "bitrate_kbps", "sample_rate_hz", "channels", "duration_s",
                    "added_at", "file_path",
                )
            }

        return [
            {
                "uuid_a": r["uuid_a"],
                "uuid_b": r["uuid_b"],
                "kind": r["kind"],
                "band_rank": r["band_rank"],
                "sort_score": r["sort_score"],
                "detected_at": r["detected_at"],
                "status": r["status"],
                "track_a": side(r, "a"),
                "track_b": side(r, "b"),
            }
            for r in rows
        ]

    def count_duplicate_candidates(self, *, owner_id: int) -> dict:
        """Open/dismissed pair counts per band for one owner.

        Returns ``{band: {"open": n, "dismissed": n}}`` for every band, with a
        real 0 where there are no pairs. Both members join through
        ``live_tracks`` (same owner), so a pair with a pending-deletion member
        is not counted.
        """
        from app.services.duplicate_detection import BAND_RANK  # import cycle

        owner = _require_owner(owner_id)
        counts = {band: {"open": 0, "dismissed": 0} for band in BAND_RANK}
        band_of = {rank: band for band, rank in BAND_RANK.items()}
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT c.band_rank, c.status, COUNT(*) FROM track_duplicate_candidates c "
                "CROSS JOIN live_tracks la ON la.uuid_id = c.uuid_a AND la.owner_id = c.owner_id "
                "CROSS JOIN live_tracks lb ON lb.uuid_id = c.uuid_b AND lb.owner_id = c.owner_id "
                "WHERE c.owner_id = ? GROUP BY c.band_rank, c.status",
                (owner,),
            ).fetchall()
        for rank, status, n in rows:
            counts[band_of[rank]][status] = n
        return counts

    def get_identity_coverage_summary(self, *, owner_id: int) -> dict:
        """Per-layer state counts over one owner's live tracks.

        Returns ``{"exact": {...}, "fingerprint": {...}, "match": {...}}`` with
        every state key present (a real 0 when none). ``exact``: pending,
        current, failed, unsupported. ``fingerprint``: pending, current,
        unavailable, too_short, low_information, failed. ``match``: pending,
        current. A live track with no identity row counts as pending in all
        three layers (unknown, never checked). The active fingerprinter is not
        part of this summary; the caller adds it from app state.
        """
        owner = _require_owner(owner_id)
        layers = {
            "exact": ("exact_state", ("pending", "current", "failed", "unsupported")),
            "fingerprint": (
                "fp_state",
                ("pending", "current", "unavailable", "too_short", "low_information", "failed"),
            ),
            "match": ("match_state", ("pending", "current")),
        }
        summary = {name: dict.fromkeys(states, 0) for name, (_, states) in layers.items()}
        with self._connection() as conn:
            for name, (column, _) in layers.items():
                for state, count in conn.execute(
                    f"SELECT COALESCE(i.{column}, 'pending'), COUNT(*) "
                    "FROM live_tracks lt LEFT JOIN track_audio_identity i ON i.uuid_id = lt.uuid_id "
                    "WHERE lt.owner_id = ? GROUP BY 1",
                    (owner,),
                ):
                    summary[name][state] = count
        return summary

    # --- identity startup reconcile (spec §6.4): maintenance over every owner's rows ---

    @staticmethod
    def _require_any_owner(method: str, owner_id: object) -> None:
        if owner_id is not ANY_OWNER:
            raise TypeError(f"{method} requires owner_id=ANY_OWNER")

    def insert_missing_identity_rows(self, *, fingerprinter_present: bool, owner_id: Owner) -> int:
        """A pending, priority-0 identity row for every track lacking one."""
        self._require_any_owner("insert_missing_identity_rows", owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            return conn.execute(
                "INSERT INTO track_audio_identity "
                "(uuid_id, exact_state, fp_state, match_state, priority) "
                "SELECT uuid_id, 'pending', ?, 'pending', 0 FROM tracks t WHERE NOT EXISTS "
                "(SELECT 1 FROM track_audio_identity i WHERE i.uuid_id = t.uuid_id)",
                ("pending" if fingerprinter_present else "unavailable",),
            ).rowcount

    # attempts / next_attempt_at / failure_reason belong to the fingerprint layer only
    # while the exact layer is settled; otherwise they are the exact layer's.
    _FP_OWNS_ATTEMPTS = "exact_state IN ('current', 'unsupported')"
    _FP_RESET_ATTEMPTS_SQL = (
        f"attempts = CASE WHEN {_FP_OWNS_ATTEMPTS} THEN 0 ELSE attempts END, "
        f"next_attempt_at = CASE WHEN {_FP_OWNS_ATTEMPTS} THEN NULL ELSE next_attempt_at END, "
        f"failure_reason = CASE WHEN {_FP_OWNS_ATTEMPTS} THEN NULL ELSE failure_reason END"
    )

    # The worker never fingerprints a row whose exact layer failed (an unreadable
    # file), so reconcile marks such a print 'failed' (it is retried when the exact
    # layer is revived) instead of 'pending', which would strand it.
    _EXACT_FAILED = "exact_state = 'failed'"

    @classmethod
    def _print_again_state_sql(cls, fingerprinter_present: bool) -> str:
        """SQL value for the fp_state of a row whose print is to be computed again:
        'pending' (or 'failed' when its exact layer failed) with a fingerprinter,
        else 'unavailable'."""
        if not fingerprinter_present:
            return "'unavailable'"
        return f"CASE WHEN {cls._EXACT_FAILED} THEN 'failed' ELSE 'pending' END"

    @classmethod
    def _delete_failed_print_blobs(cls, conn, where: str, params: tuple) -> None:
        """A 'failed' print stores no blob: drop the fingerprint rows of the identity
        rows matching ``where`` (run BEFORE the UPDATE that changes their state)."""
        conn.execute(
            "DELETE FROM track_audio_fingerprint WHERE uuid_id IN "
            f"(SELECT uuid_id FROM track_audio_identity WHERE {where})",
            params,
        )

    def set_fingerprint_availability(
        self, present: bool, *, algorithm: Optional[str] = None, owner_id: Owner
    ) -> int:
        """With a fingerprinter 'unavailable' becomes 'pending' (rows whose exact layer
        failed, whether unavailable or pending, become 'failed' with ``algorithm``
        when it is given; without it they stay as they are); without one 'pending'
        becomes 'unavailable' (clearing the attempt columns where the fingerprint
        owns them). Stored prints are kept. Returns the rows changed."""
        self._require_any_owner("set_fingerprint_availability", owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            if present:
                if algorithm is None:
                    return conn.execute(
                        "UPDATE track_audio_identity SET fp_state = 'pending' "
                        f"WHERE fp_state = 'unavailable' AND NOT ({self._EXACT_FAILED})"
                    ).rowcount
                self._delete_failed_print_blobs(
                    conn, f"{self._EXACT_FAILED} AND fp_state IN ('unavailable', 'pending')", ())
                return conn.execute(
                    f"UPDATE track_audio_identity SET fp_state = CASE WHEN {self._EXACT_FAILED} "
                    "THEN 'failed' ELSE 'pending' END, "
                    f"fp_algorithm = CASE WHEN {self._EXACT_FAILED} THEN ? ELSE fp_algorithm END "
                    f"WHERE fp_state = 'unavailable' OR (fp_state = 'pending' AND {self._EXACT_FAILED})",
                    (algorithm,),
                ).rowcount
            return conn.execute(
                f"UPDATE track_audio_identity SET fp_state = 'unavailable', {self._FP_RESET_ATTEMPTS_SQL} "
                "WHERE fp_state = 'pending'"
            ).rowcount

    def requeue_fingerprint_algorithm(self, algorithm: str, *, owner_id: Owner) -> int:
        """Send every stored print (current, too_short, low_information, failed) whose
        fp_algorithm differs from ``algorithm`` back to pending. A print leaving
        'current' re-queues matching in the same statement. A row whose exact layer
        failed becomes 'failed' with ``algorithm`` (no blob) instead of 'pending'."""
        self._require_any_owner("requeue_fingerprint_algorithm", owner_id)
        stale = "fp_state NOT IN ('pending', 'unavailable') AND fp_algorithm IS NOT ?"
        with self._connection(commit=True, immediate=True) as conn:
            self._delete_failed_print_blobs(conn, f"{self._EXACT_FAILED} AND {stale}", (algorithm,))
            return conn.execute(
                "UPDATE track_audio_identity SET "
                "match_state = CASE WHEN fp_state = 'current' THEN 'pending' ELSE match_state END, "
                f"fp_state = CASE WHEN {self._EXACT_FAILED} THEN 'failed' ELSE 'pending' END, "
                f"fp_algorithm = CASE WHEN {self._EXACT_FAILED} THEN ? ELSE fp_algorithm END, "
                f"{self._FP_RESET_ATTEMPTS_SQL} WHERE {stale}",
                (algorithm, algorithm),
            ).rowcount

    def requeue_matching(self, matcher_version: str, *, owner_id: Owner) -> int:
        """Re-match everything when the matcher version changed (spec 6.4 reconcile).

        If ``app_settings`` already holds ``matcher_version`` this does nothing
        and returns 0. Otherwise, in one transaction, every row not already
        pending gets ``match_state='pending'`` (no decoding; no other column
        changes) and the new version is stored, so a crash cannot keep the
        version without the requeue. Returns the number of rows requeued.
        """
        self._require_any_owner("requeue_matching", owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT value FROM app_settings WHERE key = ?", (MATCHER_VERSION_SETTING,)
            ).fetchone()
            if row is not None and row[0] == matcher_version:
                return 0
            count = conn.execute(
                "UPDATE track_audio_identity SET match_state = 'pending' WHERE match_state <> 'pending'"
            ).rowcount
            conn.execute(
                "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
                (MATCHER_VERSION_SETTING, matcher_version),
            )
            return count

    def requeue_unknown_duration_prints(self, rule_version: str, *, owner_id: Owner) -> int:
        """Retry prints that gave up with ``duration_unknown`` when the duration
        rule version changed (reconcile).

        If ``app_settings`` already holds ``rule_version`` this does nothing and
        returns 0. Otherwise, in one transaction, those rows go back to
        ``fp_state='pending'`` with attempts, backoff and failure reason cleared
        (``match_state`` and the exact columns are untouched) and the version is
        stored. Returns the number of rows requeued.
        """
        self._require_any_owner("requeue_unknown_duration_prints", owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT value FROM app_settings WHERE key = ?", (FINGERPRINT_DURATION_RULE_SETTING,)
            ).fetchone()
            if row is not None and row[0] == rule_version:
                return 0
            count = conn.execute(
                "UPDATE track_audio_identity SET fp_state = 'pending', attempts = 0, "
                "next_attempt_at = NULL, failure_reason = NULL "
                "WHERE failure_reason = 'duration_unknown' AND fp_state IN ('failed', 'pending') "
                f"AND {self._FP_OWNS_ATTEMPTS}"
            ).rowcount
            conn.execute(
                "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
                (FINGERPRINT_DURATION_RULE_SETTING, rule_version),
            )
            return count

    # Prints reclassified per transaction (also bounds the rows held in memory).
    RECLASSIFY_BATCH_SIZE = 500

    def reclassify_fingerprints(
        self,
        classifier_version: str,
        algorithm: Optional[str],
        classify: Callable[[tuple], str],
        *,
        owner_id: Owner,
        fingerprinter_present: bool = True,
    ) -> int:
        """Apply a changed print classification to stored prints (reconcile).

        If ``app_settings`` already holds ``classifier_version`` this does
        nothing and returns 0. Otherwise the work is done in bounded batches,
        each in its own short transaction, and the new version is stored last,
        so a crash or error part-way leaves the finished batches valid and the
        rest still due (a rerun repeats nothing harmful):

        - when a version was stored before, every 'too_short' row of
          ``algorithm`` goes back to 'pending' with a fingerprinter (to 'failed'
          when its exact layer failed, as the worker never prints such a row),
          else to 'unavailable' (its print is computed again when one is
          present, since a too_short row keeps no print); matching is untouched,
          and the attempt columns are reset only where the fingerprint layer
          owns them;
        - every 'current' or 'low_information' row of ``algorithm`` with a
          stored print of that algorithm is classified again from the stored
          items by ``classify(items)``. A row whose class changed is written
          with its new class (too_short keeps no print; a class that cannot be
          compared drops the row's open pairs) and gets ``match_state =
          'pending'``. Rows whose class did not change are not touched. A print
          that cannot be decoded is deleted and re-pended like a too_short row
          (its pairs are kept) and logged; any other error propagates.

        ``algorithm`` None means any: classification does not depend on the
        algorithm, so without a fingerprinter every stored print is handled; each
        row keeps its own algorithm and backend.

        Returns the number of rows changed."""
        self._require_any_owner("reclassify_fingerprints", owner_id)
        # Local import: app.services' package init imports this module (cycle).
        from app.services.fingerprinter import unpack_fingerprint

        with self._connection() as conn:
            row = conn.execute(
                "SELECT value FROM app_settings WHERE key = ?", (FINGERPRINT_CLASSIFIER_VERSION_SETTING,)
            ).fetchone()
        if row is not None and row[0] == classifier_version:
            return 0
        again_state = self._print_again_state_sql(fingerprinter_present)
        changed = 0
        if row is not None:
            with self._connection(commit=True, immediate=True) as conn:
                changed += conn.execute(
                    f"UPDATE track_audio_identity SET fp_state = {again_state}, "
                    f"{self._FP_RESET_ATTEMPTS_SQL} "
                    "WHERE fp_state = 'too_short' AND (? IS NULL OR fp_algorithm = ?)",
                    (algorithm, algorithm),
                ).rowcount
        last_rowid = 0
        while True:
            with self._connection(commit=True, immediate=True) as conn:
                prints = conn.execute(
                    "SELECT i.rowid, i.uuid_id, i.fp_state, f.backend, f.algorithm, f.duration_s, "
                    "f.item_count, f.data "
                    "FROM track_audio_identity i JOIN track_audio_fingerprint f ON f.uuid_id = i.uuid_id "
                    "WHERE i.fp_state IN ('current', 'low_information') AND i.fp_algorithm = f.algorithm "
                    "AND (? IS NULL OR f.algorithm = ?) AND i.rowid > ? ORDER BY i.rowid LIMIT ?",
                    (algorithm, algorithm, last_rowid, self.RECLASSIFY_BATCH_SIZE),
                ).fetchall()
                for rowid, uuid_id, old_state, backend, row_algorithm, duration_s, item_count, data in prints:
                    last_rowid = rowid
                    try:
                        raw = unpack_fingerprint(data)
                    except ValueError:
                        logger.warning("stored print for %s is undecodable; computing it again", uuid_id)
                        conn.execute("DELETE FROM track_audio_fingerprint WHERE uuid_id = ?", (uuid_id,))
                        conn.execute(
                            "UPDATE track_audio_identity SET "
                            "match_state = CASE WHEN fp_state = 'current' THEN 'pending' ELSE match_state END, "
                            f"fp_state = {again_state}, {self._FP_RESET_ATTEMPTS_SQL} WHERE uuid_id = ?",
                            (uuid_id,),
                        )
                        changed += 1
                        continue
                    new_state = classify(raw)
                    if new_state == old_state:
                        continue
                    self._write_fingerprint_in(conn, uuid_id, {
                        "fp_state": new_state, "fp_algorithm": row_algorithm, "fp_backend": backend,
                        "fp_duration_s": duration_s, "fp_item_count": item_count, "fp_data": data,
                    })
                    conn.execute(
                        "UPDATE track_audio_identity SET match_state = 'pending' WHERE uuid_id = ?",
                        (uuid_id,),
                    )
                    changed += 1
            if len(prints) < self.RECLASSIFY_BATCH_SIZE:
                break
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
                (FINGERPRINT_CLASSIFIER_VERSION_SETTING, classifier_version),
            )
        return changed

    # The stored tool_versions split at the first "; " (mirror of
    # audio_identity.split_tool_versions): the ffmpeg part, and the fingerprinter
    # part (NULL when absent). Exact string comparison, never LIKE.
    _TV_SEP = "instr(tool_versions, '; ')"
    _TV_FFMPEG_SQL = f"CASE WHEN {_TV_SEP} > 0 THEN substr(tool_versions, 1, {_TV_SEP} - 1) ELSE tool_versions END"
    _TV_FINGERPRINTER_SQL = f"CASE WHEN {_TV_SEP} > 0 THEN substr(tool_versions, {_TV_SEP} + 2) END"

    def reset_failed_identity_rows(
        self, tool_versions: str, *, owner_id: Owner, fingerprint: bool = False
    ) -> int:
        """Make every failed exact layer eligible again when its ffmpeg version differs;
        with ``fingerprint`` also every failed print the fingerprint owns whose
        fingerprinter version differs. Each layer compares only its own part of
        ``tool_versions`` (``audio_identity.split_tool_versions``), except that a print
        failed for ``duration_unknown`` also follows the ffmpeg part (the decoded
        duration comes from ffmpeg)."""
        self._require_any_owner("reset_failed_identity_rows", owner_id)
        # Local import: app.services' package init imports this module (cycle).
        from app.services.audio_identity import split_tool_versions

        ffmpeg_part, fingerprinter_part = split_tool_versions(tool_versions)
        # Any path that sends a settled exact layer back to pending re-queues matching.
        with self._connection(commit=True, immediate=True) as conn:
            count = conn.execute(
                "UPDATE track_audio_identity SET exact_state = 'pending', match_state = 'pending', "
                "attempts = 0, next_attempt_at = NULL, failure_reason = NULL "
                f"WHERE exact_state = 'failed' AND ({self._TV_FFMPEG_SQL}) IS NOT ?",
                (ffmpeg_part,),
            ).rowcount
            if fingerprint:
                count += conn.execute(
                    "UPDATE track_audio_identity SET fp_state = 'pending', "
                    "attempts = 0, next_attempt_at = NULL, failure_reason = NULL "
                    f"WHERE fp_state = 'failed' AND ({self._TV_FINGERPRINTER_SQL}) IS NOT ? "
                    f"AND {self._FP_OWNS_ATTEMPTS}",
                    (fingerprinter_part,),
                ).rowcount
                # The decoded duration (third source) comes from ffmpeg, so a
                # duration_unknown print is also retried on an ffmpeg change.
                count += conn.execute(
                    "UPDATE track_audio_identity SET fp_state = 'pending', "
                    "attempts = 0, next_attempt_at = NULL, failure_reason = NULL "
                    "WHERE fp_state = 'failed' AND failure_reason = 'duration_unknown' "
                    f"AND ({self._TV_FFMPEG_SQL}) IS NOT ? AND {self._FP_OWNS_ATTEMPTS}",
                    (ffmpeg_part,),
                ).rowcount
            return count

    _FP_MASTER_MISSING_SQL = (
        f"failure_reason = 'master_missing' AND {_FP_OWNS_ATTEMPTS} AND fp_state IN ('failed', 'pending')"
    )

    def list_master_missing_identity(
        self, *, owner_id: Owner, fingerprint: bool = False
    ) -> list[tuple[str, str]]:
        """(uuid_id, file_path) of rows whose exact layer failed for a missing master;
        with ``fingerprint`` also rows whose print failed for one."""
        self._require_any_owner("list_master_missing_identity", owner_id)
        with self._connection() as conn:
            return [
                (row[0], row[1])
                for row in conn.execute(
                    "SELECT i.uuid_id, t.file_path FROM track_audio_identity i "
                    "JOIN tracks t ON t.uuid_id = i.uuid_id "
                    "WHERE (i.failure_reason = 'master_missing' "
                    "AND i.exact_state IN ('failed', 'pending'))"
                    + (f" OR ({self._FP_MASTER_MISSING_SQL})" if fingerprint else "")
                )
            ]

    def reset_master_missing_identity(
        self, uuids: List[str], *, owner_id: Owner, fingerprint: bool = False
    ) -> int:
        """Make the given master_missing rows eligible again (exact layer, and with
        ``fingerprint`` the print when the fingerprint owns the failure)."""
        self._require_any_owner("reset_master_missing_identity", owner_id)
        # Any path that sends a settled exact layer back to pending re-queues matching.
        if not uuids:
            return 0
        in_list = f"uuid_id IN ({', '.join('?' * len(uuids))})"
        with self._connection(commit=True, immediate=True) as conn:
            count = conn.execute(
                "UPDATE track_audio_identity SET exact_state = 'pending', match_state = 'pending', "
                "attempts = 0, next_attempt_at = NULL, failure_reason = NULL "
                f"WHERE {in_list} "
                "AND failure_reason = 'master_missing' AND exact_state IN ('failed', 'pending')",
                tuple(uuids),
            ).rowcount
            if fingerprint:
                count += conn.execute(
                    "UPDATE track_audio_identity SET fp_state = 'pending', "
                    "attempts = 0, next_attempt_at = NULL, failure_reason = NULL "
                    f"WHERE {in_list} AND {self._FP_MASTER_MISSING_SQL}",
                    tuple(uuids),
                ).rowcount
            return count

    def _find_cover_art_by_id(self, cover_art_id: int) -> CoverArt | None:
        """Like ``get_cover_art_by_id``, but a database error raises."""
        with self._connection() as conn:
            row = conn.execute(
                "SELECT id, sha256, phash, phash_prefix, file_path FROM cover_arts WHERE id = ?",
                (cover_art_id,),
            ).fetchone()
            if row is None:
                return None
            return CoverArt(
                id=row["id"], sha256=row["sha256"], phash=row["phash"],
                phash_prefix=row["phash_prefix"], file_path=Path(row["file_path"]),
            )

    def get_cover_art_by_id(self, cover_art_id: int) -> CoverArt | None:
        try:
            return self._find_cover_art_by_id(cover_art_id)
        except Exception as e:
            print(f"Failed to get cover art by id {cover_art_id}: {e}")
            return None

    def get_cover_art_by_sha256(self, sha256: str) -> CoverArt | None:
        try:
            with self._connection() as conn:
                row = conn.execute(
                    "SELECT id, sha256, phash, phash_prefix, file_path FROM cover_arts WHERE sha256 = ?",
                    (sha256,),
                ).fetchone()
                if row is None:
                    return None
                return CoverArt(
                    id=row["id"], sha256=row["sha256"], phash=row["phash"],
                    phash_prefix=row["phash_prefix"], file_path=Path(row["file_path"]),
                )
        except Exception as e:
            print(f"Failed to get cover art by sha256: {e}")
            return None

    def get_cover_arts_by_phash_prefix(self, prefix: str) -> list[CoverArt]:
        try:
            with self._connection() as conn:
                rows = conn.execute(
                    "SELECT id, sha256, phash, phash_prefix, file_path FROM cover_arts WHERE phash_prefix = ?",
                    (prefix,),
                ).fetchall()
                return [
                    CoverArt(
                        id=row["id"], sha256=row["sha256"], phash=row["phash"],
                        phash_prefix=row["phash_prefix"], file_path=Path(row["file_path"]),
                    )
                    for row in rows
                ]
        except Exception as e:
            print(f"Failed to get cover arts by phash prefix: {e}")
            return []

    def insert_cover_art(self, sha256: str, phash: str, phash_prefix: str, file_path: str) -> int:
        try:
            with self._connection(commit=True) as conn:
                cursor = conn.execute(
                    'INSERT INTO cover_arts (sha256, phash, phash_prefix, file_path) VALUES (?, ?, ?, ?)',
                    (sha256, phash, phash_prefix, file_path),
                )
                return cursor.lastrowid  # type: ignore[return-value]
        except Exception as e:
            print(f"Error inserting cover art: {e}")
            raise

    def delete_cover_art(
        self, cover_art_id: int, *, owner_id: Owner,
        remove_file: Optional[Callable[[], None]] = None,
    ) -> bool:
        """Delete the row only when no trackmetadata references it. The check
        spans every owner, so only ANY_OWNER is accepted. When the row matched,
        ``remove_file`` runs inside the same write transaction before the
        commit; if it raises, the deletion rolls back (the row stays) and the
        exception propagates."""
        if owner_id is not ANY_OWNER:
            raise TypeError("delete_cover_art requires owner_id=ANY_OWNER")
        with self._connection(commit=True, immediate=True) as conn:
            deleted = self._delete_cover_art_if_unreferenced_in(conn, cover_art_id)
            if deleted and remove_file is not None:
                remove_file()
            return deleted

    @staticmethod
    def _delete_cover_art_if_unreferenced_in(conn, cover_art_id: int) -> bool:
        cursor = conn.execute(
            "DELETE FROM cover_arts WHERE id = ? AND NOT EXISTS "
            "(SELECT 1 FROM trackmetadata WHERE cover_art_id = ?)",
            (cover_art_id, cover_art_id),
        )
        return cursor.rowcount > 0

    def owns_cover_art(self, cover_art_id: int, *, owner_id: int) -> bool:
        """True when a track owned by owner_id references this cover art."""
        _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT EXISTS (SELECT 1 FROM trackmetadata tm "
                "JOIN tracks t ON t.uuid_id = tm.uuid_id "
                "WHERE tm.cover_art_id = ? AND t.owner_id = ?)",
                (cover_art_id, owner_id),
            ).fetchone()
        return bool(row[0])

    def get_owned_cover_art(self, cover_art_id: int, *, owner_id: int) -> CoverArt | None:
        """The cover art row when a track of owner_id references it, else None
        (foreign and unknown ids alike). A database error raises."""
        if not self.owns_cover_art(cover_art_id, owner_id=owner_id):
            return None
        return self._find_cover_art_by_id(cover_art_id)

    def get_tracks_missing_cover_art(self, *, owner_id: Owner) -> List[Track]:
        """Return tracks where has_album_art=1 AND cover_art_id IS NULL."""
        suffix, params = _and_owner("t.owner_id", owner_id)
        try:
            with self._connection() as conn:
                rows = conn.execute(
                    f"SELECT {_track_select_columns()} "
                    "FROM trackmetadata AS tm "
                    "JOIN tracks AS t ON tm.uuid_id = t.uuid_id "
                    "WHERE tm.has_album_art = 1 AND tm.cover_art_id IS NULL" + suffix,
                    params,
                ).fetchall()
                return [_row_to_track(row) for row in rows]
        except Exception as e:
            print(f"Failed to get tracks missing cover art: {e}")
            return []

    def update_track_cover_art_id(
        self, uuid_id: str, cover_art_id: int, *, owner_id: int
    ) -> bool:
        """Set cover_art_id for a specific track identified by uuid_id.

        Allocates a fresh revision so the frontend's incremental sync sees the
        cover-art assignment — without it, a backfill-only change would never
        appear in a ``GET /changes`` page.
        """
        _require_owner(owner_id)
        suffix, params = _and_owner("owner_id", owner_id)
        try:
            with self._connection(commit=True) as conn:
                cursor = conn.execute(
                    "UPDATE trackmetadata SET cover_art_id = ? WHERE uuid_id = ? "
                    "AND uuid_id IN (SELECT uuid_id FROM live_tracks WHERE uuid_id = ?"
                    + suffix
                    + ")",
                    (cover_art_id, uuid_id, uuid_id, *params),
                )
                if cursor.rowcount > 0:
                    self._bump_track_revision(conn, uuid_id)
                return cursor.rowcount > 0
        except Exception as e:
            print(f"Failed to update cover_art_id for track {uuid_id}: {e}")
            return False

    def _insert_track_in(
        self, conn, track: Track, *, owner_id: int, fingerprinter_present: bool,
        stat: Optional[tuple[int, int, int]],
    ) -> int:
        """Insert a track and its dependent rows inside the caller's transaction.

        Never opens, commits, rolls back or closes a connection; raises on any
        failure. Returns the allocated revision.
        """
        _require_owner(owner_id)
        metadata = track.metadata

        # Determine effective artist: album_artist takes priority
        effective = effective_artist(
            metadata.album_artist, metadata.artist
        )

        artist_id = None
        if effective:
            artist_id = self._upsert_artist(conn, effective, owner_id)

        # Determine album type
        album_name = metadata.album
        has_album = album_name is not None and album_name.strip() != ""
        album_id = None

        if artist_id is not None and effective is not None:
            album_id = self._upsert_album(
                conn, album_name if has_album else None,
                artist_id, metadata.year, effective,
            )

        self._assert_parents_owned(conn, owner_id, artist_id, album_id)

        # Clear any stale tombstone so a re-added uuid is not also
        # streamed as a delete; the fresh row's higher revision would
        # supersede it anyway, but dropping it keeps the stream clean.
        conn.execute(
            "DELETE FROM track_tombstones WHERE uuid_id = ?",
            (track.uuid_id,),
        )

        # Insert track with a freshly allocated monotonic revision.
        revision = self._next_revision(conn)
        track.revision = revision
        track.owner_id = owner_id
        tracks_entry = (
            track.uuid_id,
            str(track.file_path),
            track.created_at,
            track.last_updated,
            revision,
            owner_id,
        )
        tracks_sql_query = (
            "INSERT INTO tracks "
            "(uuid_id, file_path, created_at, last_updated, revision, owner_id) "
            "VALUES (?, ?, ?, ?, ?, ?)"
        )
        temp = conn.cursor().execute(tracks_sql_query, tracks_entry)
        track_db_id = temp.lastrowid

        # The write lock is held now: the art row cannot vanish between
        # this check and the commit.
        if metadata.cover_art_id is not None and conn.execute(
            "SELECT 1 FROM cover_arts WHERE id = ?", (metadata.cover_art_id,)
        ).fetchone() is None:
            raise CoverArtGone(metadata.cover_art_id)

        # Insert trackmetadata
        trackmetadata_entry = (
            track_db_id,
            track.uuid_id,
            metadata.title,
            metadata.artist,
            metadata.album,
            metadata.album_artist,
            artist_id,
            album_id,
            metadata.year,
            metadata.date,
            metadata.genre,
            metadata.track_number,
            metadata.disc_number,
            metadata.codec,
            metadata.duration,
            metadata.bitrate_kbps,
            metadata.sample_rate_hz,
            metadata.channels,
            metadata.has_album_art,
            metadata.cover_art_id,
        )
        trackmetadata_sql_query = (
            "INSERT INTO trackmetadata (track_id, uuid_id, title, artist, album, album_artist, "
            'artist_id, album_id, "year", "date", genre, track_number, disc_number, codec, duration, '
            "bitrate_kbps, sample_rate_hz, channels, has_album_art, cover_art_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        )
        conn.cursor().execute(trackmetadata_sql_query, trackmetadata_entry)

        # Insert into FTS for tracks
        fts_title = metadata.title or ""
        fts_artist = effective or ""
        fts_album = album_name if has_album else ""
        conn.execute(
            "INSERT INTO fts_tracks(rowid, title, artist_name, album_name) VALUES (?, ?, ?, ?)",
            (track_db_id, fts_title, fts_artist, fts_album),
        )

        self._insert_audio_identity_in(
            conn, track.uuid_id, track.audio_identity,
            fingerprinter_present=fingerprinter_present,
            stat=stat,
        )
        return revision

    def add_track(
        self, track: Track, timeout: float = 5, *, owner_id: int,
        fingerprinter_present: bool = False,
    ) -> bool:
        _require_owner(owner_id)
        if track.metadata.is_empty():
            print(
                f"empty metadata track passed to Database.add_track(): {track.metadata}"
            )
            return False

        try:
            # Local import: app.services' package init imports this module (cycle).
            from app.services.audio_identity import stat_snapshot

            # Stat before taking the write lock.
            stat = stat_snapshot(track.file_path)
            with self._connection(commit=True, timeout=timeout) as conn:
                self._insert_track_in(
                    conn, track, owner_id=owner_id,
                    fingerprinter_present=fingerprinter_present, stat=stat,
                )

            return True
        except CoverArtGone:
            raise
        except Exception as e:
            print(f"Failed to add track {track}. {e}")
            return False

    @staticmethod
    def _assert_parents_owned(conn, owner_id: int, artist_id, album_id) -> None:
        """Raise OwnerMismatch unless the linked artist/album belong to owner_id."""
        if artist_id is not None and conn.execute(
            "SELECT 1 FROM artists WHERE id = ? AND owner_id = ?",
            (artist_id, owner_id),
        ).fetchone() is None:
            raise OwnerMismatch(f"artist {artist_id} is not owned by {owner_id}")
        if album_id is not None and conn.execute(
            "SELECT 1 FROM albums JOIN artists ON artists.id = albums.artist_id "
            "WHERE albums.id = ? AND artists.owner_id = ?",
            (album_id, owner_id),
        ).fetchone() is None:
            raise OwnerMismatch(f"album {album_id} is not owned by {owner_id}")

    def _upsert_artist(self, conn, effective_artist: str, owner_id: int) -> int:
        conn.execute(
            'INSERT OR IGNORE INTO artists ("name", "owner_id") VALUES (?, ?)',
            (effective_artist, owner_id),
        )
        was_new_artist = conn.execute("SELECT changes()").fetchone()[0] > 0
        row = conn.execute(
            "SELECT id FROM artists WHERE owner_id = ? AND name_lower = LOWER(?)",
            (owner_id, effective_artist),
        ).fetchone()
        artist_id = row["id"]

        if was_new_artist:
            conn.execute(
                "INSERT INTO fts_artists(rowid, name) VALUES (?, ?)",
                (artist_id, effective_artist),
            )

        return artist_id

    def _upsert_album(
        self, conn, album_name: str | None, artist_id: int, year: int | None, effective_artist: str
    ) -> int:
        if album_name is not None:
            # Regular album
            conn.execute(
                'INSERT OR IGNORE INTO albums ("name", "artist_id", "year", "is_single_grouping") '
                "VALUES (?, ?, ?, 0)",
                (album_name, artist_id, year),
            )
            was_new_album = conn.execute("SELECT changes()").fetchone()[0] > 0
            # Update year if new track's year is higher
            conn.execute(
                "UPDATE albums SET year = ? "
                "WHERE name_lower = LOWER(?) AND artist_id = ? AND is_single_grouping = 0 "
                "AND (year IS NULL OR year < ?)",
                (year, album_name, artist_id, year),
            )
            row = conn.execute(
                "SELECT id FROM albums WHERE name_lower = LOWER(?) AND artist_id = ? AND is_single_grouping = 0",
                (album_name, artist_id),
            ).fetchone()
            album_id = row["id"]

            if was_new_album:
                conn.execute(
                    "INSERT INTO fts_albums(rowid, name, artist_name) VALUES (?, ?, ?)",
                    (album_id, album_name, effective_artist),
                )
        else:
            # Single grouping
            conn.execute(
                'INSERT OR IGNORE INTO albums ("name", "artist_id", "year", "is_single_grouping") '
                "VALUES (NULL, ?, ?, 1)",
                (artist_id, year),
            )
            was_new_album = conn.execute("SELECT changes()").fetchone()[0] > 0
            row = conn.execute(
                "SELECT id FROM albums WHERE artist_id = ? AND COALESCE(year, -1) = COALESCE(?, -1) AND is_single_grouping = 1",
                (artist_id, year),
            ).fetchone()
            album_id = row["id"]

            if was_new_album:
                conn.execute(
                    "INSERT INTO fts_albums(rowid, name, artist_name) VALUES (?, ?, ?)",
                    (album_id, "", effective_artist),
                )

        return album_id

    @staticmethod
    def _orphan_gc_album(conn, album_id: Optional[int]) -> None:
        """Delete ``album_id`` and its FTS row iff no trackmetadata references
        it. The FTS ``'delete'`` values are derived from the album's own
        artist join, so they always match what ``_upsert_album`` inserted."""
        if album_id is None:
            return
        remaining = conn.execute(
            "SELECT COUNT(*) FROM trackmetadata WHERE album_id = ?", (album_id,)
        ).fetchone()[0]
        if remaining != 0:
            return
        Database._fts_delete_album_in(conn, album_id)
        conn.execute("DELETE FROM albums WHERE id = ?", (album_id,))

    @staticmethod
    def _fts_delete_album_in(conn, album_id: int) -> None:
        row = conn.execute(
            "SELECT a.name AS album_name, ar.name AS artist_name "
            "FROM albums a JOIN artists ar ON ar.id = a.artist_id "
            "WHERE a.id = ?",
            (album_id,),
        ).fetchone()
        album_name = (row["album_name"] or "") if row else ""
        artist_name = (row["artist_name"] or "") if row else ""
        conn.execute(
            "INSERT INTO fts_albums(fts_albums, rowid, name, artist_name) "
            "VALUES('delete', ?, ?, ?)",
            (album_id, album_name, artist_name),
        )

    @staticmethod
    def _orphan_gc_artist(conn, artist_id: Optional[int]) -> None:
        """Delete ``artist_id`` and its FTS row iff no trackmetadata references
        it. Call after ``_orphan_gc_album`` — an album row references an artist."""
        if artist_id is None:
            return
        remaining = conn.execute(
            "SELECT COUNT(*) FROM trackmetadata WHERE artist_id = ?", (artist_id,)
        ).fetchone()[0]
        if remaining != 0:
            return
        Database._fts_delete_artist_in(conn, artist_id)
        conn.execute("DELETE FROM artists WHERE id = ?", (artist_id,))

    @staticmethod
    def _fts_delete_artist_in(conn, artist_id: int) -> None:
        row = conn.execute(
            "SELECT name FROM artists WHERE id = ?", (artist_id,)
        ).fetchone()
        artist_name = (row["name"] or "") if row else ""
        conn.execute(
            "INSERT INTO fts_artists(fts_artists, rowid, name) VALUES('delete', ?, ?)",
            (artist_id, artist_name),
        )

    @staticmethod
    def _recompute_named_album_year(conn, album_id: Optional[int]) -> None:
        """Reset a *named* album's year to MAX over its remaining members.
        ``_upsert_album`` only ever raises an album's year, so a downward edit
        (a member lowering/clearing its year, or leaving the album) needs this.
        Single-grouping albums carry year as identity and are reconciled by the
        normal upsert path, so they are excluded."""
        if album_id is None:
            return
        conn.execute(
            'UPDATE albums SET "year" = '
            '(SELECT MAX("year") FROM trackmetadata WHERE album_id = ?) '
            "WHERE id = ? AND is_single_grouping = 0",
            (album_id, album_id),
        )

    def _update_track_metadata(
        self, conn, uuid_id: str, fields: dict, new_file_path: Optional[str] = None
    ) -> int:
        """Pure-DB metadata edit — no file I/O. ``fields`` is the validated,
        present subset of ``EDITABLE_METADATA_COLUMNS`` (an explicit ``None``
        means "clear"). Reassigns artist/album identity, reconciles orphaned
        parents + FTS, and bumps the track revision. When ``new_file_path`` is
        given (a master relocation already moved the file), the ``tracks.file_path``
        is updated to match — still pure-DB. Reused by the PATCH orchestration
        and (future) bulk edit, all inside one caller txn."""
        cur = conn.execute(
            "SELECT track_id, artist_id, album_id, title, artist, album, "
            'album_artist, "year", "date", genre, track_number, disc_number '
            "FROM trackmetadata WHERE uuid_id = ?",
            (uuid_id,),
        ).fetchone()
        if cur is None:
            raise TrackNotFound(uuid_id)

        track_db_id = cur["track_id"]
        owner_id = conn.execute(
            "SELECT owner_id FROM tracks WHERE id = ?", (track_db_id,)
        ).fetchone()["owner_id"]
        old_artist_id = cur["artist_id"]
        old_album_id = cur["album_id"]

        # Merge present edits over current values, then NFC-normalize the
        # identity strings before they reach the LOWER()-keyed upsert
        # (otherwise canonically-equivalent spellings won't dedup).
        def pick(col):
            return fields[col] if col in fields else cur[col]

        new = {col: pick(col) for col in EDITABLE_METADATA_COLUMNS}
        for col in ("artist", "album", "album_artist"):
            if isinstance(new[col], str):
                new[col] = unicodedata.normalize("NFC", new[col])

        # Don't let an edit blank the whole track — checked on the *merged*
        # post-edit state so a partial clear (e.g. just the title) is fine as
        # long as some identity survives. album_artist counts: effective_artist
        # prefers it over artist, so a compilation track whose album_artist
        # remains keeps full library identity.
        def _blank(v):
            return v is None or (isinstance(v, str) and not v.strip())

        if (
            _blank(new["title"])
            and _blank(new["artist"])
            and _blank(new["album"])
            and _blank(new["album_artist"])
        ):
            raise EmptyTrackEdit(uuid_id)

        effective = effective_artist(new["album_artist"], new["artist"])
        new_artist_id = None
        new_album_id = None
        if effective is not None:
            new_artist_id = self._upsert_artist(conn, effective, owner_id)
            has_album = bool(new["album"] and new["album"].strip())
            new_album_id = self._upsert_album(
                conn,
                new["album"] if has_album else None,
                new_artist_id,
                new["year"],
                effective,
            )
        # effective is None ⇒ artist cleared; both ids stay None (an album row
        # requires a non-null artist).
        self._assert_parents_owned(conn, owner_id, new_artist_id, new_album_id)

        conn.execute(
            "UPDATE trackmetadata SET title = ?, artist = ?, album = ?, "
            'album_artist = ?, "year" = ?, "date" = ?, genre = ?, '
            "track_number = ?, disc_number = ?, artist_id = ?, album_id = ? "
            "WHERE uuid_id = ?",
            (
                new["title"], new["artist"], new["album"], new["album_artist"],
                new["year"], new["date"], new["genre"], new["track_number"],
                new["disc_number"], new_artist_id, new_album_id, uuid_id,
            ),
        )

        # Reconcile parents with the row already reassigned: GC the old ones if
        # now empty, then recompute year for any surviving named album whose
        # membership changed.
        if old_album_id != new_album_id:
            self._orphan_gc_album(conn, old_album_id)
        if old_artist_id != new_artist_id:
            self._orphan_gc_artist(conn, old_artist_id)
        # Only recompute the old album's year when this edit could actually
        # move it: membership changed, or year/date was itself touched.
        if old_album_id is not None and (
            old_album_id != new_album_id
            or not fields.keys().isdisjoint(("year", "date"))
        ):
            self._recompute_named_album_year(conn, old_album_id)
        if new_album_id != old_album_id:
            self._recompute_named_album_year(conn, new_album_id)

        # Rewrite this track's own FTS row: delete old terms, insert new ones.
        old_effective = effective_artist(cur["album_artist"], cur["artist"])
        conn.execute(
            "INSERT INTO fts_tracks(fts_tracks, rowid, title, artist_name, album_name) "
            "VALUES('delete', ?, ?, ?, ?)",
            (track_db_id, cur["title"] or "", old_effective or "", cur["album"] or ""),
        )
        new_fts_album = new["album"] if (new["album"] and new["album"].strip()) else ""
        conn.execute(
            "INSERT INTO fts_tracks(rowid, title, artist_name, album_name) "
            "VALUES (?, ?, ?, ?)",
            (track_db_id, new["title"] or "", effective or "", new_fts_album),
        )

        if new_file_path is not None:
            conn.execute(
                "UPDATE tracks SET file_path = ? WHERE uuid_id = ?",
                (new_file_path, uuid_id),
            )

        return self._bump_track_revision(conn, uuid_id)

    def apply_track_metadata_edit(
        self,
        uuid_id: str,
        fields: dict,
        base_revision: Optional[int],
        new_file_path: Optional[str] = None,
        timeout: float = 5,
        *,
        owner_id: int,
        master_rewritten: bool = False,
    ) -> int:
        """DB orchestration for a track metadata edit. Opens one write txn
        with ``BEGIN IMMEDIATE`` (so the revision check below actually holds
        SQLite's write lock -- a plain read holds none, so without this a
        second concurrent call could pass the same check against the same
        stale revision before either has written), enforces the Option-A 409
        (``base_revision`` vs the stored revision) *before* the bump, runs the
        pure-DB spine, and commits. ``new_file_path`` (set by the
        master-relocation path after it has moved the file) is written to
        ``tracks.file_path`` in the same txn. ``master_rewritten`` (the master's
        bytes were rewritten) also marks the audio identity stale ('tag_write') in
        the same txn. Returns the new revision. Raises
        ``TrackNotFound`` / ``RevisionConflict``; lets
        ``sqlite3.OperationalError`` ("database is locked") propagate so the
        caller can surface a retryable error rather than a silent failure."""
        _require_owner(owner_id)
        fields = normalize_edit_fields(fields)
        with self._connection(commit=True, timeout=timeout, immediate=True) as conn:
            suffix, params = _and_owner("owner_id", owner_id)
            row = conn.execute(
                "SELECT revision FROM tracks WHERE uuid_id = ?" + suffix,
                (uuid_id, *params),
            ).fetchone()
            if row is None:
                raise TrackNotFound(uuid_id)
            current_revision = row["revision"]
            if base_revision is None or base_revision != current_revision:
                raise RevisionConflict(uuid_id, base_revision, current_revision)

            revision = self._update_track_metadata(conn, uuid_id, fields, new_file_path)
            if master_rewritten:
                self._mark_audio_identity_stale_in(conn, uuid_id, "tag_write")
            return revision

    # ── Edit journal (crash-safety for master-file writes) ──────────────────

    def insert_journal_entry(
        self,
        intent: str,
        uuid_id: str,
        old_path: Optional[str] = None,
        new_path: Optional[str] = None,
        temp_path: Optional[str] = None,
        *,
        owner_id: int,
    ) -> int:
        """Record a pending destructive FS step *before* performing it. Returns
        the journal row id so the caller can clear it once the step is durably
        finished (or reverted)."""
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "INSERT INTO edit_journal "
                "(intent, uuid_id, old_path, new_path, temp_path, created_at, owner_id) "
                "VALUES (?, ?, ?, ?, ?, unixepoch(), ?)",
                (intent, uuid_id, old_path, new_path, temp_path, owner_id),
            )
            return cursor.lastrowid  # type: ignore[return-value]

    def list_journal_entries(self, *, owner_id: Owner) -> List[dict]:
        """All outstanding journal rows, oldest first. Read once at startup by
        the reconcile pass."""
        clause, params = _owner_predicate("owner_id", owner_id)
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT id, intent, uuid_id, old_path, new_path, temp_path, "
                "created_at, owner_id FROM edit_journal"
                + (f" WHERE {clause}" if clause else "")
                + " ORDER BY id",
                params,
            ).fetchall()
            return [dict(row) for row in rows]

    def has_journal_entry_for_uuid(self, uuid_id: str, *, owner_id: Owner) -> bool:
        """Whether a destructive FS step on this track is still awaiting
        reconcile (e.g. a same-path replace that failed in-process)."""
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection() as conn:
            return conn.execute(
                "SELECT 1 FROM edit_journal WHERE uuid_id = ?" + suffix + " LIMIT 1",
                (uuid_id, *params),
            ).fetchone() is not None

    def delete_journal_entry(self, entry_id: int, *, owner_id: int) -> None:
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            conn.execute(
                "DELETE FROM edit_journal WHERE id = ? AND owner_id = ?",
                (entry_id, owner_id),
            )

    def get_track_by_uuid(self, uuid_id: str, *, owner_id: Owner) -> Optional[Track]:
        """The hydrated track for a uuid, or None. The one lookup shared by
        the editor, the streaming source resolver, and GET /tracks/{uuid}."""
        rows = self.get_tracks(
            search_parameters=[
                SearchParameter(column="uuid_id", operator="=", value=uuid_id)
            ],
            owner_id=owner_id,
        )
        return rows[0] if rows else None

    @staticmethod
    def _is_pending_deletion_in(conn, uuid_id: str, owner: int) -> bool:
        row = conn.execute(
            "SELECT EXISTS(SELECT 1 FROM tracks WHERE uuid_id = ? AND owner_id = ?)"
            " AND NOT EXISTS(SELECT 1 FROM live_tracks WHERE uuid_id = ? AND owner_id = ?)",
            (uuid_id, owner, uuid_id, owner),
        ).fetchone()
        return bool(row[0])

    def is_pending_deletion(self, uuid_id: str, *, owner_id: int) -> bool:
        """True when the owner's track exists but is missing from ``live_tracks``.

        The marker is a ``deletion_journal`` row, which ``live_tracks`` excludes.
        A tombstoned, unknown or foreign track is not pending (it answers like
        unknown)."""
        owner_id = _require_owner(owner_id)
        with self._connection() as conn:
            return self._is_pending_deletion_in(conn, uuid_id, owner_id)

    @staticmethod
    def _deletion_busy_in(conn, uuid_id: str, owner: int) -> bool:
        """True when the owner's track is mid-operation and must not be deleted
        now: an active conversion, an edit journal row, a non-terminal upload
        commit journal row naming it, or a pending deletion. Owner-scoped."""
        if conn.execute(
            "SELECT 1 FROM conversion_jobs WHERE uuid_id = ? AND owner_id = ?"
            " AND status IN ('queued','running') LIMIT 1",
            (uuid_id, owner),
        ).fetchone():
            return True
        if conn.execute(
            "SELECT 1 FROM edit_journal WHERE uuid_id = ? AND owner_id = ? LIMIT 1",
            (uuid_id, owner),
        ).fetchone():
            return True
        if conn.execute(
            "SELECT 1 FROM upload_commit_journal WHERE reserved_track_uuid = ?"
            " AND owner_id = ? AND state IN ('committing','prepared','moved') LIMIT 1",
            (uuid_id, owner),
        ).fetchone():
            return True
        return Database._is_pending_deletion_in(conn, uuid_id, owner)

    def get_deletion_preview_facts(
        self, uuid_ids: list[str], *, owner_id: int
    ) -> dict[str, dict]:
        """What the deletion preview needs per requested UUID, for the owner only:
        a live track (state, revision, title, artist, album, file_path, busy), an
        own tombstone (state, revision), else absent. Writes nothing."""
        owner = _require_owner(owner_id)
        facts: dict[str, dict] = {}
        with self._connection() as conn:
            for start in range(0, len(uuid_ids), 500):
                chunk = uuid_ids[start : start + 500]
                marks = ",".join("?" * len(chunk))
                for r in conn.execute(
                    "SELECT t.uuid_id, t.revision, t.file_path, m.title, m.artist, m.album"
                    " FROM tracks t LEFT JOIN trackmetadata m ON m.uuid_id = t.uuid_id"
                    f" WHERE t.owner_id = ? AND t.uuid_id IN ({marks})",
                    (owner, *chunk),
                ):
                    facts[r["uuid_id"]] = {
                        "state": "live",
                        "revision": r["revision"],
                        "title": r["title"],
                        "artist": r["artist"],
                        "album": r["album"],
                        "file_path": str(r["file_path"]),
                        "busy": self._deletion_busy_in(conn, r["uuid_id"], owner),
                    }
                for r in conn.execute(
                    "SELECT uuid_id, revision FROM track_tombstones"
                    f" WHERE owner_id = ? AND uuid_id IN ({marks})",
                    (owner, *chunk),
                ):
                    facts.setdefault(
                        r["uuid_id"], {"state": "tombstone", "revision": r["revision"]}
                    )
        return facts

    def read_deletion_target(self, uuid_id: str, *, owner_id: int) -> dict:
        """What the deletion worker revalidates under the track lock, for the
        owner only: a live track (state, revision, file_path, cover_art_id, busy),
        an own tombstone (state, revision), else absent. Writes nothing."""
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT t.revision, t.file_path, m.cover_art_id FROM tracks t"
                " LEFT JOIN trackmetadata m ON m.uuid_id = t.uuid_id"
                " WHERE t.uuid_id = ? AND t.owner_id = ?",
                (uuid_id, owner),
            ).fetchone()
            if row is not None:
                return {
                    "state": "live",
                    "revision": row["revision"],
                    "file_path": str(row["file_path"]),
                    "cover_art_id": row["cover_art_id"],
                    "busy": self._deletion_busy_in(conn, uuid_id, owner),
                }
            tomb = conn.execute(
                "SELECT revision FROM track_tombstones WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner),
            ).fetchone()
            if tomb is not None:
                return {"state": "tombstone", "revision": tomb["revision"]}
        return {"state": "absent"}

    def create_deletion_job(self, request, *, owner_id: int, now: int) -> bool:
        """True for a new job, False for an exact replay. The operation hash is
        order-normalised (plan D6); the job keeps the request order. Targets are
        stored as given: nothing is looked up."""
        owner = _require_owner(owner_id)
        op = str(request.operation_uuid)
        targets = [(str(t.uuid_id), t.base_revision) for t in request.targets]
        with self._connection(commit=True, immediate=True) as conn:
            outcome = self._with_operation_in(
                conn,
                owner_id=owner,
                operation_uuid=op,
                kind="track_deletion",
                request_model=request.receipt_model(),
                now=now,
            )
            if isinstance(outcome, OpReplay):
                return False
            conn.execute(
                "INSERT INTO deletion_jobs (owner_id, operation_uuid, created_at, status)"
                " VALUES (?, ?, ?, 'accepted')",
                (owner, op, now),
            )
            conn.executemany(
                "INSERT INTO deletion_job_items (owner_id, operation_uuid, uuid_id,"
                " position, base_revision, status) VALUES (?, ?, ?, ?, ?, 'pending')",
                [
                    (owner, op, uuid_id, index, revision)
                    for index, (uuid_id, revision) in enumerate(targets)
                ],
            )
            self._set_operation_result_in(
                conn, owner_id=owner, operation_uuid=op, result_ref=op
            )
        return True

    def claim_next_deletion_item(self, *, boot_id: str) -> dict | None:
        """Claim the first pending deletion item of any owner (job created_at,
        operation_uuid, item position) by a pending -> running CAS stamping
        ``boot_id`` (SC-16d). None when nothing is pending."""
        # Deferred: the services package imports this module.
        from app.services import job_runtime

        job_runtime.register_job_table(
            "deletion_job_items",
            key_columns=("owner_id", "operation_uuid", "uuid_id"),
            state_column="status",
            terminal_states=DELETION_ITEM_TERMINAL_STATES,
        )
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT i.owner_id, i.operation_uuid, i.uuid_id, i.base_revision"
                " FROM deletion_job_items i JOIN deletion_jobs j"
                " ON j.owner_id = i.owner_id AND j.operation_uuid = i.operation_uuid"
                " JOIN users u ON u.id = i.owner_id"
                " WHERE i.status = 'pending' AND u.deleting_at IS NULL"
                " ORDER BY j.created_at, i.operation_uuid, i.position LIMIT 1"
            ).fetchone()
            if row is None:
                return None
            key = {
                "owner_id": row["owner_id"],
                "operation_uuid": row["operation_uuid"],
                "uuid_id": row["uuid_id"],
            }
            if not job_runtime.claim(conn, "deletion_job_items", key, boot_id=boot_id):
                return None
            return {**key, "base_revision": row["base_revision"]}

    def finish_deletion_item(
        self,
        *,
        owner_id: int,
        operation_uuid: str,
        uuid_id: str,
        boot_id: str,
        status: str,
        error_code: str | None = None,
        tombstone_revision: int | None = None,
        details=(),
    ) -> bool:
        """Terminalize a running item this boot leased; True iff the row changed.
        The job completes once none of its items is non-terminal."""
        from app.services import deletion_errors  # deferred, as above

        details = list(details)
        if status not in DELETION_ITEM_TERMINAL_STATES:
            raise ValueError("status must be a terminal item state")
        if error_code is not None and error_code not in deletion_errors.ITEM_ERROR_CODES:
            raise ValueError("unknown item error code")
        if any(d not in deletion_errors.ITEM_DETAIL_CODES for d in details):
            raise ValueError("unknown item detail code")
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE deletion_job_items SET status = ?, error_code = ?,"
                " tombstone_revision = ?, detail_json = ?"
                " WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?"
                " AND status = 'running' AND lease_boot_id = ?",
                (
                    status, error_code, tombstone_revision, json.dumps(details),
                    owner_id, operation_uuid, uuid_id, boot_id,
                ),
            )
            if cursor.rowcount != 1:
                return False
            self._complete_deletion_job_if_done_in(conn, owner_id, operation_uuid)
            return True

    @staticmethod
    def _complete_deletion_job_if_done_in(conn, owner: int, operation_uuid: str) -> None:
        open_items = conn.execute(
            "SELECT 1 FROM deletion_job_items WHERE owner_id = ?"
            " AND operation_uuid = ? AND status IN ('pending','running') LIMIT 1",
            (owner, operation_uuid),
        ).fetchone()
        if open_items is None:
            conn.execute(
                "UPDATE deletion_jobs SET status = 'completed'"
                " WHERE owner_id = ? AND operation_uuid = ?",
                (owner, operation_uuid),
            )

    def begin_track_deletion(
        self,
        *,
        owner_id: int,
        operation_uuid: str,
        uuid_id: str,
        boot_id: str,
        base_revision: int,
        original_path: str,
        quarantine_path: str | None,
        identity,
        cover_art_id: int | None,
        master_missing: bool,
        now: int,
    ) -> str:
        """Write the deletion journal row (stage 'intent') before any move.
        "ok", or "gone" (the item is not ours and running), "conflict" (the
        track changed) or "busy". Nothing is written unless "ok"."""
        owner = _require_owner(owner_id)
        src = tuple(identity) if identity is not None else (None, None, None, None)
        with self._connection(commit=True, immediate=True) as conn:
            leased = conn.execute(
                "SELECT 1 FROM deletion_job_items WHERE owner_id = ? AND operation_uuid = ?"
                " AND uuid_id = ? AND status = 'running' AND lease_boot_id = ?",
                (owner, operation_uuid, uuid_id, boot_id),
            ).fetchone()
            if leased is None:
                return "gone"
            track = conn.execute(
                "SELECT revision, file_path FROM tracks WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner),
            ).fetchone()
            if (
                track is None
                or track["revision"] != base_revision
                or str(track["file_path"]) != str(original_path)
            ):
                return "conflict"
            if self._deletion_busy_in(conn, uuid_id, owner):
                return "busy"
            conn.execute(
                "INSERT INTO deletion_journal (owner_id, operation_uuid, uuid_id,"
                " original_path, quarantine_path, base_revision, src_dev, src_ino,"
                " src_size, src_mtime_ns, exact_digest, cover_art_id, master_missing,"
                " stage, created_at, updated_at)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, 'intent', ?, ?)",
                (
                    owner, operation_uuid, uuid_id, str(original_path), quarantine_path,
                    base_revision, *src, cover_art_id, 1 if master_missing else 0, now, now,
                ),
            )
        return "ok"

    def mark_deletion_moved(
        self, *, owner_id: int, operation_uuid: str, uuid_id: str, now: int
    ) -> None:
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "UPDATE deletion_journal SET stage = 'moved', updated_at = ?"
                " WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?"
                " AND stage = 'intent'",
                (now, owner, operation_uuid, uuid_id),
            )

    def commit_track_deletion(
        self,
        *,
        owner_id: int,
        operation_uuid: str,
        uuid_id: str,
        boot_id: str,
        base_revision: int,
        original_path: str,
        details,
        now: int,
    ) -> int:
        """The one transaction of a deletion: recheck, tombstone and delete the
        catalog rows, mark the item deleted, complete the job, journal
        'committed'. Returns the tombstone revision."""
        from app.services import deletion_errors  # deferred, as above

        owner = _require_owner(owner_id)
        details = list(details)
        if any(d not in deletion_errors.ITEM_DETAIL_CODES for d in details):
            raise ValueError("unknown item detail code")
        with self._connection(commit=True, immediate=True) as conn:
            track = conn.execute(
                "SELECT revision, file_path FROM tracks WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner),
            ).fetchone()
            if (
                track is None
                or track["revision"] != base_revision
                or str(track["file_path"]) != str(original_path)
            ):
                raise DeletionRecheckFailed(uuid_id)
            revision = self._delete_track_in(conn, uuid_id, owner_id=owner)
            cursor = conn.execute(
                "UPDATE deletion_job_items SET status = 'deleted', tombstone_revision = ?,"
                " detail_json = ? WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?"
                " AND status = 'running' AND lease_boot_id = ?",
                (revision, json.dumps(details), owner, operation_uuid, uuid_id, boot_id),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("deletion item is not running under this boot")
            self._complete_deletion_job_if_done_in(conn, owner, operation_uuid)
            cursor = conn.execute(
                "UPDATE deletion_journal SET stage = 'committed', updated_at = ?"
                " WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?",
                (now, owner, operation_uuid, uuid_id),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("deletion journal row is missing")
        return revision

    def clear_deletion_journal(
        self, *, owner_id: int, operation_uuid: str, uuid_id: str
    ) -> bool:
        """Drop an uncommitted journal row (never a committed one); True iff
        one row went."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "DELETE FROM deletion_journal WHERE owner_id = ? AND operation_uuid = ?"
                " AND uuid_id = ? AND stage IN ('intent','moved')",
                (owner, operation_uuid, uuid_id),
            )
            return cursor.rowcount == 1

    def get_deletion_journal(
        self, *, owner_id: int, operation_uuid: str, uuid_id: str
    ) -> dict | None:
        """The owner's journal row for one item, or None. Writes nothing."""
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT * FROM deletion_journal WHERE owner_id = ?"
                " AND operation_uuid = ? AND uuid_id = ?",
                (owner, operation_uuid, uuid_id),
            ).fetchone()
        return None if row is None else dict(row)

    def release_deletion_item(
        self, *, owner_id: int, operation_uuid: str, uuid_id: str, boot_id: str
    ) -> bool:
        """Put a running item this boot holds back to pending, only while it has
        no journal row. True iff the item changed."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE deletion_job_items SET status = 'pending', lease_boot_id = NULL"
                " WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?"
                " AND status = 'running' AND lease_boot_id = ?"
                " AND NOT EXISTS (SELECT 1 FROM deletion_journal d"
                " WHERE d.owner_id = deletion_job_items.owner_id"
                " AND d.operation_uuid = deletion_job_items.operation_uuid"
                " AND d.uuid_id = deletion_job_items.uuid_id)",
                (owner, operation_uuid, uuid_id, boot_id),
            )
            return cursor.rowcount == 1

    def finish_deletion_cleanup(
        self, *, owner_id: int, operation_uuid: str, uuid_id: str, details
    ) -> None:
        """After storage cleanup: drop the committed journal row and set the
        item's final details."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "DELETE FROM deletion_journal WHERE owner_id = ? AND operation_uuid = ?"
                " AND uuid_id = ? AND stage = 'committed'",
                (owner, operation_uuid, uuid_id),
            )
            conn.execute(
                "UPDATE deletion_job_items SET detail_json = ? WHERE owner_id = ?"
                " AND operation_uuid = ? AND uuid_id = ? AND status = 'deleted'",
                (json.dumps(list(details)), owner, operation_uuid, uuid_id),
            )

    def make_durable(self, *, timeout: float = 1) -> bool:
        """True only when every transaction committed before this call is in
        the database file and that file was synced (OPEN-8-01 part B). A reader
        on an older snapshot or a writer that outlasts ``timeout`` answers
        False (a FULL checkpoint holds the write lock while it waits for
        readers; the next pass retries). Exceptions propagate."""
        with self._connection(timeout=timeout) as conn:
            conn.execute("PRAGMA fullfsync=ON")
            busy, log, checkpointed = conn.execute("PRAGMA wal_checkpoint(FULL)").fetchone()
            synchronous = conn.execute("PRAGMA synchronous").fetchone()[0]
        if not (busy == 0 and log >= 0 and log == checkpointed):
            return False
        # The last connection to close checkpoints the WAL itself with a plain
        # fsync (no F_FULLFSYNC on macOS), so the checkpoint above often finds
        # nothing to do and issues no full flush. Flush the main file here:
        # F_FULLFSYNC flushes the drive cache, covering the earlier plain syncs.
        # synchronous OFF means no durability is configured (test process only).
        if synchronous != 0:
            fd = os.open(self.context.database_path, os.O_RDONLY)
            try:
                if sys.platform == "darwin":
                    try:
                        fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
                    except OSError as exc:
                        # A file system without F_FULLFSYNC: SQLite's own fallback.
                        logger.warning(
                            "full flush refused (%s); the database file got a plain fsync",
                            type(exc).__name__,
                        )
                        os.fsync(fd)
                else:
                    os.fsync(fd)
            finally:
                os.close(fd)
        return True

    def deletion_job_has_pending_items(self, *, owner_id: int, operation_uuid: str) -> bool:
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT 1 FROM deletion_job_items WHERE owner_id = ? AND operation_uuid = ?"
                " AND status = 'pending' LIMIT 1",
                (owner, operation_uuid),
            ).fetchone()
        return row is not None

    def reclaim_deletion_items(self, *, boot_id: str) -> int:
        """Startup reclaim, server-wide: requeue running items left by another
        boot (or with no lease) that have no deletion journal row, since a
        journal-backed item waits for journal recovery. Then complete accepted
        jobs that have no open item left. Returns the number of items requeued.
        Idempotent: a second call with nothing left to do changes nothing."""
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE deletion_job_items SET status = 'pending', lease_boot_id = NULL"
                " WHERE status = 'running'"
                " AND (lease_boot_id IS NULL OR lease_boot_id <> ?)"
                " AND NOT EXISTS (SELECT 1 FROM deletion_journal d"
                " WHERE d.owner_id = deletion_job_items.owner_id"
                " AND d.operation_uuid = deletion_job_items.operation_uuid"
                " AND d.uuid_id = deletion_job_items.uuid_id)",
                (boot_id,),
            )
            requeued = cursor.rowcount
            conn.execute(
                "UPDATE deletion_jobs SET status = 'completed' WHERE status = 'accepted'"
                " AND NOT EXISTS (SELECT 1 FROM deletion_job_items i"
                " WHERE i.owner_id = deletion_jobs.owner_id"
                " AND i.operation_uuid = deletion_jobs.operation_uuid"
                " AND i.status IN ('pending','running'))"
            )
            return requeued

    def list_deletion_journals(self, *, stages) -> list[dict]:
        """Every deletion journal row (all owners) whose stage is in ``stages``,
        ordered by owner, operation and track. Writes nothing."""
        stages = tuple(stages)
        if any(st not in ("intent", "moved", "committed") for st in stages):
            raise ValueError("unknown deletion journal stage")
        if not stages:
            return []
        marks = ",".join("?" for _ in stages)
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT * FROM deletion_journal WHERE stage IN (" + marks + ")"
                " ORDER BY owner_id, operation_uuid, uuid_id",
                stages,
            ).fetchall()
        return [dict(r) for r in rows]

    def mark_deletion_recovery_required(
        self, *, owner_id: int, operation_uuid: str, uuid_id: str, boot_id: str
    ) -> bool:
        """Startup recovery could not resolve a journal: fail the item left
        running by another boot with ``recovery_required`` (the journal stays)
        and complete its job when nothing is open. A terminal item is never
        rewritten. True iff the item changed."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE deletion_job_items SET status = 'failed',"
                " error_code = 'recovery_required'"
                " WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?"
                " AND status = 'running'"
                " AND (lease_boot_id IS NULL OR lease_boot_id <> ?)",
                (owner, operation_uuid, uuid_id, boot_id),
            )
            if cursor.rowcount != 1:
                return False
            self._complete_deletion_job_if_done_in(conn, owner, operation_uuid)
            return True

    def get_deletion_job(self, operation_uuid, *, owner_id: int) -> dict | None:
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection() as conn:
            row = conn.execute(
                "SELECT operation_uuid, created_at FROM deletion_jobs"
                " WHERE owner_id = ? AND operation_uuid = ?",
                (owner, key),
            ).fetchone()
            if row is None:
                return None
            items = conn.execute(
                "SELECT uuid_id, position, base_revision, status, error_code,"
                " tombstone_revision, detail_json FROM deletion_job_items"
                " WHERE owner_id = ? AND operation_uuid = ? ORDER BY position",
                (owner, key),
            ).fetchall()
        return {
            "operation_uuid": row["operation_uuid"],
            "created_at": row["created_at"],
            "items": [dict(i) for i in items],
        }

    def list_deletion_jobs(
        self, *, owner_id: int, after: tuple[int, str] | None, limit: int
    ) -> list[dict]:
        """Keyset page ascending by (created_at, operation_uuid), each job with
        its non-zero per-status item counts. Jobs are kept, never pruned."""
        owner = _require_owner(owner_id)
        sql = "SELECT operation_uuid, created_at FROM deletion_jobs WHERE owner_id = ?"
        params: list = [owner]
        if after is not None:
            sql += " AND (created_at, operation_uuid) > (?, ?)"
            params += [after[0], after[1]]
        sql += " ORDER BY created_at, operation_uuid LIMIT ?"
        params.append(limit)
        with self._connection() as conn:
            jobs = [dict(row) for row in conn.execute(sql, params)]
            counts: dict[str, dict[str, int]] = {}
            if jobs:
                marks = ",".join("?" for _ in jobs)
                for row in conn.execute(
                    "SELECT operation_uuid, status, count(*) FROM deletion_job_items"
                    f" WHERE owner_id = ? AND operation_uuid IN ({marks})"
                    " GROUP BY operation_uuid, status",
                    (owner, *[j["operation_uuid"] for j in jobs]),
                ):
                    counts.setdefault(row[0], {})[row[1]] = row[2]
        return [{**j, "state_counts": counts.get(j["operation_uuid"], {})} for j in jobs]

    def get_track_file_path(self, uuid_id: str, *, owner_id: Owner) -> Optional[str]:
        """Current ``tracks.file_path`` for a uuid, or None if the track is gone.
        Used by journal reconcile to tell whether a relocate's DB commit landed."""
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT file_path FROM tracks WHERE uuid_id = ?" + suffix,
                (uuid_id, *params),
            ).fetchone()
            return row["file_path"] if row is not None else None

    def track_path_in_use(
        self, path: str, *, owner_id: Owner, exclude_uuid: Optional[str] = None
    ) -> bool:
        """True when a track (of ``owner_id``, or of any owner with ``ANY_OWNER``)
        other than ``exclude_uuid`` has ``path`` as its master file. Paths compare
        by canonical caseless form (NFD, casefold, NFD): APFS folds Unicode case and ignores the NFC/NFD
        difference (SQLite's NOCASE folds ASCII only), and ingest paths are not
        NFC-normalised, so two spellings can be the same file. Answering "in use"
        too often is the safe side."""
        suffix, params = _and_owner("owner_id", owner_id)
        if exclude_uuid is not None:
            suffix += " AND uuid_id != ?"
            params = (*params, exclude_uuid)
        with self._connection() as conn:
            conn.create_function("osml_path_fold", 1, _fold_path, deterministic=True)
            return conn.execute(
                "SELECT 1 FROM tracks WHERE osml_path_fold(file_path) = ?" + suffix + " LIMIT 1",
                (_fold_path(path), *params),
            ).fetchone() is not None

    def track_identities_in_folder(self, folder: str, *, owner_id: Owner) -> list[dict]:
        """Every track (of ``owner_id``, or of any owner with ``ANY_OWNER``) whose
        master file sits directly in ``folder``, with its stored exact audio hash
        (None columns when it has no identity row). Folders compare by the same
        canonical caseless form as ``track_path_in_use``."""
        suffix, params = _and_owner("t.owner_id", owner_id)

        def parent_fold(p):
            return None if p is None else _fold_path(str(Path(p).parent))

        with self._connection() as conn:
            conn.create_function("osml_parent_fold", 1, parent_fold, deterministic=True)
            rows = conn.execute(
                "SELECT t.file_path, i.exact_state, i.exact_kind, i.exact_digest, "
                "i.sample_rate_hz, i.channels, i.bits_per_sample "
                "FROM tracks t LEFT JOIN track_audio_identity i ON i.uuid_id = t.uuid_id "
                "WHERE osml_parent_fold(t.file_path) = ?" + suffix,
                (_fold_path(folder), *params),
            ).fetchall()
            return [dict(row) for row in rows]

    # ── Conversion jobs (Phase 2 master-type conversion) ─────────────────────

    _CONVERSION_JOB_COLUMNS = (
        "id, uuid_id, target_codec, target_container, target_bitrate, "
        "base_revision, status, error_text, batch_id, created_at, updated_at, owner_id"
    )

    def insert_conversion_job(
        self,
        uuid_id: str,
        target_codec: str,
        target_container: str,
        target_bitrate: Optional[int],
        base_revision: Optional[int] = None,
        *,
        owner_id: int,
    ) -> int:
        """Persist a new queued conversion job. Returns its id. Raises
        ``ConversionJobActive`` instead if the uuid already has a queued or
        running job -- checked in the same write transaction, so two racing
        POSTs can't both get in."""
        _require_owner(owner_id)
        # TODO(bulk-jobs): a bulk conversion enqueue sets batch_id here (uploads
        # are not jobs: /tracks/uploads, Phase 7).
        with self._connection(commit=True, immediate=True) as conn:
            active = conn.execute(
                "SELECT id FROM conversion_jobs WHERE uuid_id = ? "
                "AND status IN ('queued', 'running') ORDER BY id LIMIT 1",
                (uuid_id,),
            ).fetchone()
            if active is not None:
                raise ConversionJobActive(uuid_id, active["id"])
            cursor = conn.execute(
                "INSERT INTO conversion_jobs "
                "(uuid_id, target_codec, target_container, target_bitrate, "
                "base_revision, status, created_at, updated_at, owner_id) "
                "VALUES (?, ?, ?, ?, ?, 'queued', unixepoch(), unixepoch(), ?)",
                (
                    uuid_id, target_codec, target_container, target_bitrate,
                    base_revision, owner_id,
                ),
            )
            return cursor.lastrowid  # type: ignore[return-value]

    def get_conversion_job(self, job_id: int, *, owner_id: Owner) -> Optional[dict]:
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection() as conn:
            row = conn.execute(
                f"SELECT {self._CONVERSION_JOB_COLUMNS} FROM conversion_jobs "
                "WHERE id = ?" + suffix,
                (job_id, *params),
            ).fetchone()
            return dict(row) if row is not None else None

    def list_conversion_jobs_with_status(
        self, status: str, *, owner_id: Owner
    ) -> List[dict]:
        """Every job in ``status``, oldest first -- read once at startup to
        fail orphaned ``running`` rows and resubmit ``queued`` ones (no
        worker thread or in-memory queue survives a restart)."""
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection() as conn:
            rows = conn.execute(
                f"SELECT {self._CONVERSION_JOB_COLUMNS} FROM conversion_jobs "
                "WHERE status = ?" + suffix + " ORDER BY id",
                (status, *params),
            ).fetchall()
            return [dict(row) for row in rows]

    def list_conversion_jobs(
        self,
        *,
        uuid_id: Optional[str] = None,
        statuses: Optional[List[str]] = None,
        batch_id: Optional[str] = None,
        after_id: int = 0,
        limit: int = 50,
        owner_id: Owner,
    ) -> tuple[List[dict], Optional[int]]:
        """Jobs with id > after_id (ascending), optionally filtered. Returns
        (jobs, next_cursor) -- next_cursor is the highest id consumed when the
        page filled exactly `limit` (more rows may exist), else None. Mirrors
        get_changes' "page-fullness implies more" cursor convention."""
        clauses = ["id > ?"]
        params: List[Any] = [after_id]
        if uuid_id is not None:
            clauses.append("uuid_id = ?")
            params.append(uuid_id)
        if statuses:
            clauses.append(f"status IN ({', '.join('?' for _ in statuses)})")
            params.extend(statuses)
        if batch_id is not None:
            clauses.append("batch_id = ?")
            params.append(batch_id)
        owner_clause, owner_params = _owner_predicate("owner_id", owner_id)
        if owner_clause:
            clauses.append(owner_clause)
            params.extend(owner_params)
        where = " AND ".join(clauses)
        with self._connection() as conn:
            rows = conn.execute(
                f"SELECT {self._CONVERSION_JOB_COLUMNS} FROM conversion_jobs "
                f"WHERE {where} ORDER BY id ASC LIMIT ?",
                (*params, limit),
            ).fetchall()
        jobs = [dict(row) for row in rows]
        next_cursor = jobs[-1]["id"] if len(jobs) == limit else None
        return jobs, next_cursor

    def mark_conversion_job_running(self, job_id: int, *, owner_id: int) -> bool:
        """Transition queued->running. Returns False if the job already lost
        a race (e.g. cancelled while queued) -- the caller should no-op."""
        _require_owner(owner_id)
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "UPDATE conversion_jobs SET status = 'running', "
                "updated_at = unixepoch() WHERE id = ? AND status = 'queued'" + suffix,
                (job_id, *params),
            )
            return cursor.rowcount > 0

    def mark_conversion_job_failed(
        self, job_id: int, error_text: str, *, owner_id: int, after_commit: bool = False
    ) -> bool:
        """Transition queued/running->failed (queued: the worker died before
        it could even claim the job). Never touches a terminal job, so one
        already cancelled by an external request is never clobbered.

        With ``after_commit`` it moves only a ``done`` job instead: a same-file
        conversion that committed but whose final file swap failed (the next
        start puts the file in place and settles the job)."""
        _require_owner(owner_id)
        suffix, params = _and_owner("owner_id", owner_id)
        status_clause = "status = 'done'" if after_commit else "status IN ('queued', 'running')"
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "UPDATE conversion_jobs SET status = 'failed', "
                "error_text = ?, updated_at = unixepoch() "
                "WHERE id = ? AND " + status_clause + suffix,
                (error_text, job_id, *params),
            )
            return cursor.rowcount > 0

    def settle_swapped_conversion_job(
        self, job_id: int, uuid_id: str, *, owner_id: int, error_text: Optional[str] = None
    ) -> bool:
        """Settle a same-file conversion job whose swap startup recovery finished:
        done (text cleared) when ``error_text`` is None, else failed with that
        text. Only a failed or done job of ``uuid_id`` moves. Returns whether a
        row moved."""
        _require_owner(owner_id)
        suffix, params = _and_owner("owner_id", owner_id)
        status = "done" if error_text is None else "failed"
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "UPDATE conversion_jobs SET status = ?, error_text = ?, "
                "updated_at = unixepoch() "
                "WHERE id = ? AND uuid_id = ? AND status IN ('failed', 'done')" + suffix,
                (status, error_text, job_id, uuid_id, *params),
            )
            return cursor.rowcount > 0

    def bump_track_revision(self, uuid_id: str, *, owner_id: int) -> Optional[int]:
        """Bump an owned track to the next revision in one transaction (its file's
        bytes changed with no column change, so clients see the track as
        changed). Returns the new revision, or None when the owner has no such
        track."""
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            owned = conn.execute(
                "SELECT 1 FROM tracks WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner_id),
            ).fetchone()
            if owned is None:
                return None
            return self._bump_track_revision(conn, uuid_id)

    def mark_conversion_job_cancelled(self, job_id: int, *, owner_id: int) -> bool:
        """Transition queued or running -> cancelled. Returns False if the
        job was already terminal (done/failed/cancelled)."""
        _require_owner(owner_id)
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "UPDATE conversion_jobs SET status = 'cancelled', "
                "updated_at = unixepoch() "
                "WHERE id = ? AND status IN ('queued', 'running')" + suffix,
                (job_id, *params),
            )
            return cursor.rowcount > 0

    def complete_conversion_job(
        self,
        job_id: int,
        uuid_id: str,
        codec: str,
        bitrate_kbps: Optional[float],
        sample_rate_hz: Optional[int],
        channels: Optional[int],
        file_path: Optional[str] = None,
        inplace_journal: Optional[tuple[str, str]] = None,
        *,
        owner_id: int,
        identity=None,
        audio_unchanged: bool = False,
        stat: Optional[tuple[int, int, int]] = None,
    ) -> tuple[int, Optional[int]]:
        """One transaction: mark the job done and write the probed intrinsic
        fields (+ file_path if the path changed). Raises
        ``ConversionJobNotRunning`` -- rolling back, so the track is untouched
        -- when the job is no longer 'running' (cancelled out-of-band), so a
        cancel the client saw succeed can never be followed by the conversion
        landing anyway.

        ``inplace_journal=(old_path, temp_path)`` also writes the same-path
        "convert" journal row on this commit, so for that case a journal row
        exists iff the DB advanced -- the invariant ``_reconcile_inplace``
        relies on to redo the pending replace. A non-None ``identity`` is written
        in the same transaction (None leaves it untouched) with ``stat``, the
        new master's snapshot (None stores NULL). Returns
        ``(revision, journal_id)``."""
        _require_owner(owner_id)
        suffix, params = _and_owner("owner_id", owner_id)
        with self._connection(commit=True) as conn:
            cursor = conn.execute(
                "UPDATE conversion_jobs SET status = 'done', "
                "updated_at = unixepoch() WHERE id = ? AND status = 'running'" + suffix,
                (job_id, *params),
            )
            if cursor.rowcount == 0:
                raise ConversionJobNotRunning(job_id)
            revision = self._apply_conversion_result(
                conn, uuid_id, codec, bitrate_kbps, sample_rate_hz, channels, file_path
            )
            if identity is not None:
                self._write_conversion_identity_in(
                    conn, uuid_id, identity, audio_unchanged=audio_unchanged, stat=stat
                )
            journal_id = None
            if inplace_journal is not None:
                old_path, temp_path = inplace_journal
                journal_id = conn.execute(
                    "INSERT INTO edit_journal "
                    "(intent, uuid_id, old_path, new_path, temp_path, created_at, "
                    "owner_id) "
                    "SELECT 'convert', ?, ?, NULL, ?, unixepoch(), owner_id "
                    "FROM conversion_jobs WHERE id = ?",
                    (uuid_id, old_path, temp_path, job_id),
                ).lastrowid
            return revision, journal_id

    def _apply_conversion_result(
        self,
        conn,
        uuid_id: str,
        codec: str,
        bitrate_kbps: Optional[float],
        sample_rate_hz: Optional[int],
        channels: Optional[int],
        file_path: Optional[str] = None,
        duration: Optional[float] = None,
    ) -> int:
        """Pure-DB sibling of ``_update_track_metadata``: writes only the
        intrinsic audio fields a conversion (re)probed, plus ``file_path`` if
        the extension changed. Shares ``_bump_track_revision`` but does no
        artist/album reconciliation and no FTS update (codec/bitrate aren't
        FTS-indexed) -- those columns are untouched by a conversion. These
        columns are deliberately NOT part of ``EDITABLE_METADATA_COLUMNS``;
        only ingestion or conversion may (re)write them."""
        row = conn.execute(
            "SELECT track_id FROM trackmetadata WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()
        if row is None:
            raise TrackNotFound(uuid_id)

        conn.execute(
            "UPDATE trackmetadata SET codec = ?, bitrate_kbps = ?, "
            "sample_rate_hz = ?, channels = ? WHERE uuid_id = ?",
            (codec, bitrate_kbps, sample_rate_hz, channels, uuid_id),
        )
        if duration is not None:
            conn.execute(
                "UPDATE trackmetadata SET duration = ? WHERE uuid_id = ?",
                (duration, uuid_id),
            )
        if file_path is not None:
            conn.execute(
                "UPDATE tracks SET file_path = ? WHERE uuid_id = ?",
                (file_path, uuid_id),
            )
        return self._bump_track_revision(conn, uuid_id)

    def refresh_track_audio_properties(
        self,
        uuid_id: str,
        *,
        codec: Optional[str],
        bitrate_kbps: Optional[float],
        sample_rate_hz: Optional[int],
        channels: Optional[int],
        duration: Optional[float],
        owner_id: int,
        file_path: Optional[str] = None,
    ) -> Optional[int]:
        """Re-write the file-derived fields of an owned track (settle check,
        m-L-08) in one transaction and bump its revision. Unknown stays None.
        The audio identity is marked stale ('settle') in the same transaction.
        Returns the new revision, or None when the owner has no such track."""
        _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            owned = conn.execute(
                "SELECT 1 FROM tracks WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner_id),
            ).fetchone()
            if owned is None:
                return None
            revision = self._apply_conversion_result(
                conn, uuid_id, codec, bitrate_kbps, sample_rate_hz, channels,
                file_path=file_path, duration=duration,
            )
            # The file changed after import: every identity layer is stale.
            self._mark_audio_identity_stale_in(conn, uuid_id, "settle")
            return revision

    @staticmethod
    def _fts_delete_track_in(conn, meta_row) -> None:
        track_db_id = meta_row["track_id"]
        fts_title = meta_row["title"] or ""

        # Determine effective artist and album for FTS delete
        effective_artist = ""
        if meta_row["album_artist"] and meta_row["album_artist"].strip():
            effective_artist = meta_row["album_artist"].strip()
        elif meta_row["artist"] and meta_row["artist"].strip():
            effective_artist = meta_row["artist"].strip()

        fts_album = meta_row["album"] or ""
        conn.execute(
            "INSERT INTO fts_tracks(fts_tracks, rowid, title, artist_name, album_name) "
            "VALUES('delete', ?, ?, ?, ?)",
            (track_db_id, fts_title, effective_artist, fts_album),
        )

    def _delete_track_in(self, conn, uuid_id: str, *, owner_id: int) -> int:
        """Delete the owner's track inside the caller's transaction.

        Runs inside the caller's ``BEGIN IMMEDIATE``; never opens, commits,
        rolls back or closes a connection. Records a tombstone (a plain INSERT,
        never a replace, so an existing tombstone is not re-bumped), deletes
        trackmetadata/tracks/FTS rows and prunes orphaned album/artist parents.
        Returns the tombstone revision. Does not touch ``deletion_journal``.

        Raises ``TrackAlreadyDeleted(uuid, revision)`` when the owner's own
        tombstone exists for the uuid, and ``TrackNotFound`` otherwise when no
        live track of this owner has it (an unknown uuid, another user's live
        track and another user's tombstone are indistinguishable). Nothing is
        written in either case.

        The deletion worker must hold the track's ``TrackLocks`` lock (lock
        order: track -> directory -> DB).
        """
        _require_owner(owner_id)
        # Fetch metadata before deletion for FTS cleanup
        meta_row = conn.execute(
            "SELECT tm.track_id, tm.artist_id, tm.album_id, tm.title, "
            "tm.artist, tm.album, tm.album_artist "
            "FROM trackmetadata tm JOIN tracks t ON t.uuid_id = tm.uuid_id "
            "WHERE tm.uuid_id = ? AND t.owner_id = ?",
            (uuid_id, owner_id),
        ).fetchone()

        if meta_row is None:
            tomb = conn.execute(
                "SELECT revision FROM track_tombstones "
                "WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner_id),
            ).fetchone()
            if tomb is not None:
                raise TrackAlreadyDeleted(uuid_id, tomb["revision"])
            raise TrackNotFound(uuid_id)

        artist_id = meta_row["artist_id"]
        album_id = meta_row["album_id"]

        # Record a tombstone before the hard delete so incremental
        # sync clients can reconcile the removal — the row is about to
        # vanish from `tracks`/`trackmetadata`, leaving the frontend no
        # other signal that it ever existed.
        revision = self._next_revision(conn)
        conn.execute(
            "INSERT INTO track_tombstones "
            "(uuid_id, deleted_at, revision, owner_id) "
            "VALUES (?, unixepoch(), ?, ?)",
            (uuid_id, revision, owner_id),
        )

        # Delete trackmetadata and tracks
        conn.execute("DELETE FROM trackmetadata WHERE uuid_id = ?", (uuid_id,))
        conn.execute("DELETE FROM tracks WHERE uuid_id = ?", (uuid_id,))

        # Delete from FTS for tracks
        self._fts_delete_track_in(conn, meta_row)

        # Cleanup now-orphaned parents (album before artist — an album
        # row references an artist). Shared with the metadata-edit
        # spine so add/update/delete reconcile orphans one way.
        self._orphan_gc_album(conn, album_id)
        self._orphan_gc_artist(conn, artist_id)
        return revision

    def delete_track(
        self, uuid_id: str, timeout: float = 5, *, owner_id: int
    ) -> bool:
        _require_owner(owner_id)
        try:
            with self._connection(
                commit=True, timeout=timeout, immediate=True
            ) as conn:
                self._delete_track_in(conn, uuid_id, owner_id=owner_id)
            return True
        except Exception as e:
            print(f"Failed to delete track {uuid_id}. {e}")
            return False

    def get_tracks(
        self,
        search_parameters: List[SearchParameter] | None = None,
        order_parameters: List[OrderParameter] | None = None,
        row_filter_parameters: List[RowFilterParameter] | None = None,
        artist_id: Optional[int] = None,
        album_id: Optional[int] = None,
        timeout: float = 5,
        limit: int = 100,
        offset: int = 0,
        *,
        owner_id: Owner,
    ) -> List[Track]:
        if search_parameters is None:
            search_parameters = []
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        if album_id is not None and artist_id is None:
            raise ValueError("Cannot filter by album without artist")

        if limit <= 0 or limit > 1000 or offset < 0:
            print(
                f"Limit {limit} or Offset {offset} was set incorrectly for database.get_tracks"
            )
            raise ValueError

        allowed_columns = set(ALLOWED_TRACK_COLUMNS + ALLOWED_METADATA_COLUMNS)
        search_columns = set([param.column for param in search_parameters])
        order_columns = set([order.column for order in order_parameters])
        invalid_search_columns = search_columns - allowed_columns
        invalid_order_columns = order_columns - allowed_columns

        if invalid_search_columns:
            print(
                f"columns {invalid_search_columns} are not allowed as a search parameter"
            )
            raise ValueError

        if invalid_order_columns:
            print(
                f"columns {invalid_order_columns} are not allowed as a search parameter"
            )
            raise ValueError

        search_query = (
            f"SELECT {_track_select_columns()} "
            "FROM trackmetadata AS tm "
            "JOIN tracks AS t ON "
            " tm.uuid_id = t.uuid_id"
        )
        search_clauses = []
        search_values: list = []

        for param in search_parameters:
            column = param.column
            value = param.value
            operator = param.operator
            alias = alias_map(column)
            if value is None:
                search_clauses.append(f'{alias}."{column}" IS NULL')
            else:
                search_clauses.append(f'{alias}."{column}" {operator} ?')
                search_values.append(value)

        owner_clause, owner_values = _owner_predicate("t.owner_id", owner_id)
        if owner_clause:
            search_clauses.append(owner_clause)
            search_values.extend(owner_values)

        if artist_id is not None:
            search_clauses.append('tm."artist_id" = ?')
            search_values.append(artist_id)
        if album_id is not None:
            search_clauses.append('tm."album_id" = ?')
            search_values.append(album_id)

        if row_filter_parameters and order_parameters:
            cursor_clause, cursor_values = filter_for_cursor(
                row_filter_parameters, order_parameters
            )
            if cursor_clause:
                search_clauses.append("(" + cursor_clause + ")")
                search_values.extend(cursor_values)

        if search_clauses:
            search_query += " WHERE " + " AND ".join(search_clauses)

        order_clauses = []

        for order in order_parameters:
            column = order.column
            value = "ASC" if order.isAscending else "DESC"
            alias = alias_map(column)
            order_clauses.append(f'{alias}."{column}" {value.upper()}')

        if order_clauses:
            search_query += " ORDER BY " + " , ".join(order_clauses)

        search_query += " LIMIT " + str(limit) + " OFFSET " + str(offset)

        try:
            with self._connection(timeout=timeout) as conn:
                rows = (
                    conn.cursor().execute(search_query, tuple(search_values)).fetchall()
                )
        except Exception as e:
            print(
                f"Failed to search database. search_parameters: {search_parameters}. Exception: {e}"
            )
            return []

        tracks: List[Track] = [_row_to_track(row) for row in rows]

        return tracks

    def get_changes(
        self, after_revision: int, limit: int, timeout: float = 5, *, owner_id: int
    ) -> tuple[List[TrackChange], int, Optional[int]]:
        """Return up to ``limit`` change entries with ``revision >
        after_revision`` (ascending), the current latest revision, and the
        next cursor (the highest revision consumed when the raw stream filled
        the page, else ``None``).

        Upserts (live ``tracks``) and deletes (``track_tombstones``) share one
        revision space and interleave by revision, so a single ordered stream
        carries both — deletes are no longer a first-page side channel and
        surface on whichever page their revision lands on.

        ``next_cursor`` is derived from the *raw* stream length, not the
        returned ``changes``: an upsert whose track was concurrently deleted
        between this query and the hydration JOIN is dropped from ``changes``,
        which would otherwise shrink the page below ``limit`` and falsely
        signal "caught up", stranding higher-revision rows until the next
        sync. Advancing past the consumed revision is safe — the dropped
        row's delete carries a higher revision and arrives on a later page.

        Only the owner's rows stream, and ``latest`` is the owner's highest
        revision (the revision counter itself stays global)."""
        _require_owner(owner_id)
        try:
            with self._connection(timeout=timeout) as conn:
                latest = conn.execute(
                    "SELECT COALESCE(MAX(revision), 0) FROM ("
                    "SELECT revision FROM tracks WHERE owner_id = ? "
                    "UNION ALL "
                    "SELECT revision FROM track_tombstones WHERE owner_id = ?)",
                    (owner_id, owner_id),
                ).fetchone()[0]
                stream = conn.execute(
                    "SELECT 'upsert' AS change_type, revision, uuid_id FROM tracks "
                    "WHERE revision > ? AND owner_id = ? "
                    "UNION ALL "
                    "SELECT 'delete' AS change_type, revision, uuid_id "
                    "FROM track_tombstones WHERE revision > ? AND owner_id = ? "
                    "ORDER BY revision ASC LIMIT ?",
                    (after_revision, owner_id, after_revision, owner_id, limit),
                ).fetchall()

                upsert_uuids = [
                    r["uuid_id"] for r in stream if r["change_type"] == "upsert"
                ]
                track_by_uuid: dict[str, Track] = {}
                if upsert_uuids:
                    placeholders = ",".join("?" * len(upsert_uuids))
                    hydrated = conn.execute(
                        f"SELECT {_track_select_columns()} "
                        "FROM trackmetadata AS tm "
                        "JOIN tracks AS t ON tm.uuid_id = t.uuid_id "
                        f"WHERE t.uuid_id IN ({placeholders}) AND t.owner_id = ?",
                        (*upsert_uuids, owner_id),
                    ).fetchall()
                    track_by_uuid = {
                        row["uuid_id"]: _row_to_track(row) for row in hydrated
                    }

                changes: List[TrackChange] = []
                for r in stream:
                    if r["change_type"] == "upsert":
                        track = track_by_uuid.get(r["uuid_id"])
                        if track is None:
                            # Raced with a concurrent delete; the delete entry
                            # carries a higher revision and will be streamed.
                            continue
                        changes.append(
                            TrackChange(
                                type="upsert",
                                revision=r["revision"],
                                uuid_id=r["uuid_id"],
                                track=track,
                            )
                        )
                    else:
                        changes.append(
                            TrackChange(
                                type="delete",
                                revision=r["revision"],
                                uuid_id=r["uuid_id"],
                            )
                        )

                # Normally, a cursor is needed only when the raw stream hit
                # the page limit. If hydration dropped raw upsert rows, return
                # a cursor even on a short final page so clients can advance
                # past the consumed revision instead of requesting it forever.
                last_consumed_revision = stream[-1]["revision"] if stream else None
                last_returned_revision = (
                    changes[-1].revision if changes else after_revision
                )
                should_advance_past_dropped_rows = (
                    last_consumed_revision is not None
                    and last_consumed_revision > last_returned_revision
                )
                next_cursor = (
                    last_consumed_revision
                    if len(stream) == limit or should_advance_past_dropped_rows
                    else None
                )
                return changes, latest, next_cursor
        except Exception as e:
            # Re-raise so the endpoint surfaces a 5xx. Swallowing here would
            # return an empty page, which the client reads as "caught up" and
            # silently stops syncing — masking a transient DB failure.
            print(f"Failed to get changes after revision {after_revision}: {e}")
            raise

    def get_tracks_count(
        self,
        search_parameters: List[SearchParameter] | None = None,
        order_parameters: List[OrderParameter] | None = None,
        row_filter_parameters: List[RowFilterParameter] | None = None,
        artist_id: Optional[int] = None,
        album_id: Optional[int] = None,
        timeout: float = 5,
        *,
        owner_id: Owner,
    ) -> int | None:
        if search_parameters is None:
            search_parameters = []
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        if album_id is not None and artist_id is None:
            raise ValueError("Cannot filter by album without artist")

        search_query = (
            "SELECT COUNT(*) FROM tracks as t "
            "JOIN trackmetadata AS tm ON "
            " t.uuid_id = tm.uuid_id"
        )

        search_clauses = []
        search_values: list = []

        for param in search_parameters:
            column = param.column
            value = param.value
            operator = param.operator
            alias = alias_map(column)
            if value is None:
                search_clauses.append(f'{alias}."{column}" IS NULL')
            else:
                search_clauses.append(f'{alias}."{column}" {operator} ?')
                search_values.append(value)

        owner_clause, owner_values = _owner_predicate("t.owner_id", owner_id)
        if owner_clause:
            search_clauses.append(owner_clause)
            search_values.extend(owner_values)

        if artist_id is not None:
            search_clauses.append('tm."artist_id" = ?')
            search_values.append(artist_id)
        if album_id is not None:
            search_clauses.append('tm."album_id" = ?')
            search_values.append(album_id)

        if row_filter_parameters and order_parameters:
            cursor_clause, cursor_values = filter_for_cursor(
                row_filter_parameters, order_parameters
            )
            if cursor_clause:
                search_clauses.append("(" + cursor_clause + ")")
                search_values.extend(cursor_values)

        if search_clauses:
            search_query += " WHERE " + " AND ".join(search_clauses)

        try:
            with self._connection(timeout=timeout) as conn:
                count = int(
                    conn.cursor()
                    .execute(search_query, tuple(search_values))
                    .fetchone()[0]
                )
            return count
        except Exception as e:
            print(f"Failed to get count from database while executing query: {e}")
            return None

    def get_artists(
        self,
        order_parameters: List[ArtistOrderParameter] | None = None,
        row_filter_parameters: List[ArtistRowFilterParameter] | None = None,
        limit: int = 100,
        offset: int = 0,
        timeout: float = 5,
        *,
        owner_id: Owner,
    ) -> List[Artist] | None:
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        if limit <= 0 or limit > 1000 or offset < 0:
            print(
                f"Limit {limit} or Offset {offset} was set incorrectly for database.get_artists"
            )
            raise ValueError
        parameters: list = []

        query = "SELECT id, name FROM artists "

        owner_clause, owner_values = _owner_predicate("owner_id", owner_id)
        where_clauses: list[str] = [owner_clause] if owner_clause else []
        parameters.extend(owner_values)

        # Cursor filter
        cursor_clause, cursor_values = filter_for_artist_cursor(
            row_filter_parameters, order_parameters
        )
        if cursor_clause:
            where_clauses.append(f"({cursor_clause})")
            parameters.extend(cursor_values)
        if where_clauses:
            query += "WHERE " + " AND ".join(where_clauses) + " "

        # ORDER BY
        order_parts: list[str] = []
        for param in order_parameters:
            col = param.column
            direction = "ASC" if param.isAscending else "DESC"
            collate = " COLLATE NOCASE" if col in ARTIST_TEXT_COLUMNS else ""
            order_parts.append(f'"{col}"{collate} {direction}')

        if order_parts:
            query += "ORDER BY " + ", ".join(order_parts) + " "
        else:
            query += "ORDER BY name COLLATE NOCASE ASC "

        query += "LIMIT ? OFFSET ?"
        parameters.extend([limit, offset])

        try:
            with self._connection(timeout=timeout) as conn:
                rows = conn.cursor().execute(query, tuple(parameters)).fetchall()
            return [Artist(id=row["id"], name=row["name"]) for row in rows]
        except Exception as e:
            print(f"Error executing artist query: {e}")
            return None

    def get_artists_count(
        self,
        order_parameters: List[ArtistOrderParameter] | None = None,
        row_filter_parameters: List[ArtistRowFilterParameter] | None = None,
        timeout: float = 5,
        *,
        owner_id: Owner,
    ) -> int | None:
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        parameters: list = []

        query = "SELECT COUNT(*) FROM artists "

        owner_clause, owner_values = _owner_predicate("owner_id", owner_id)
        where_clauses: list[str] = [owner_clause] if owner_clause else []
        parameters.extend(owner_values)

        cursor_clause, cursor_values = filter_for_artist_cursor(
            row_filter_parameters, order_parameters
        )
        if cursor_clause:
            where_clauses.append(f"({cursor_clause})")
            parameters.extend(cursor_values)
        if where_clauses:
            query += "WHERE " + " AND ".join(where_clauses) + " "

        try:
            with self._connection(timeout=timeout) as conn:
                artist_count = int(
                    conn.cursor().execute(query, tuple(parameters)).fetchone()[0]
                )
            return artist_count
        except Exception as e:
            print(f"Unable to fetch artist counts. {e}")
            return None

    def get_albums(
        self,
        artist_id: Optional[int] = None,
        order_parameters: List[AlbumOrderParameter] | None = None,
        row_filter_parameters: List[AlbumRowFilterParameter] | None = None,
        limit: int = 100,
        offset: int = 0,
        timeout: float = 5,
        *,
        owner_id: Owner,
    ) -> List[Album] | None:
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []
        if limit <= 0 or limit > 1000 or offset < 0:
            print(
                f"Limit {limit} or Offset {offset} was set incorrectly for database.get_albums"
            )
            raise ValueError

        parameters: list = []

        query = (
            "SELECT a.id, a.name, ar.name AS artist, a.artist_id, "
            'a."year", a.is_single_grouping '
            "FROM albums a "
            "JOIN artists ar ON a.artist_id = ar.id"
        )

        owner_clause, owner_values = _owner_predicate("ar.owner_id", owner_id)
        where_clauses: list[str] = [owner_clause] if owner_clause else []
        parameters.extend(owner_values)

        if artist_id is not None:
            where_clauses.append("a.artist_id = ?")
            parameters.append(artist_id)

        # Cursor filter
        cursor_clause, cursor_values = filter_for_album_cursor(
            row_filter_parameters, order_parameters
        )
        if cursor_clause:
            where_clauses.append(f"({cursor_clause})")
            parameters.extend(cursor_values)

        if where_clauses:
            query += " WHERE " + " AND ".join(where_clauses)

        # ORDER BY
        order_parts: list[str] = []
        for param in order_parameters:
            col = param.column
            col_ref = _album_col_ref(col)
            direction = "ASC" if param.isAscending else "DESC"
            collate = " COLLATE NOCASE" if col in ALBUM_TEXT_COLUMNS else ""
            if param.nullsLast:
                order_parts.append(f'{col_ref} IS NULL ASC')
            order_parts.append(f'{col_ref}{collate} {direction}')

        if order_parts:
            query += " ORDER BY " + ", ".join(order_parts)

        query += " LIMIT ? OFFSET ?"
        parameters.extend([limit, offset])

        try:
            with self._connection(timeout=timeout) as conn:
                album_rows = (
                    conn.cursor().execute(query, tuple(parameters)).fetchall()
                )
        except Exception as e:
            print(f"Failed to retrieve albums: {e}")
            return None

        return [
            Album(
                id=row["id"],
                name=row["name"],
                artist=row["artist"],
                artist_id=row["artist_id"],
                year=row["year"] if row["year"] is not None else None,
                is_single_grouping=bool(row["is_single_grouping"]),
            )
            for row in album_rows
        ]

    def get_albums_count(
        self,
        artist_id: Optional[int] = None,
        order_parameters: List[AlbumOrderParameter] | None = None,
        row_filter_parameters: List[AlbumRowFilterParameter] | None = None,
        timeout: float = 5,
        *,
        owner_id: Owner,
    ) -> int | None:
        if order_parameters is None:
            order_parameters = []
        if row_filter_parameters is None:
            row_filter_parameters = []

        parameters: list = []

        query = (
            "SELECT COUNT(*) FROM albums a "
            "JOIN artists ar ON a.artist_id = ar.id"
        )

        owner_clause, owner_values = _owner_predicate("ar.owner_id", owner_id)
        where_clauses: list[str] = [owner_clause] if owner_clause else []
        parameters.extend(owner_values)

        if artist_id is not None:
            where_clauses.append("a.artist_id = ?")
            parameters.append(artist_id)

        cursor_clause, cursor_values = filter_for_album_cursor(
            row_filter_parameters, order_parameters
        )
        if cursor_clause:
            where_clauses.append(f"({cursor_clause})")
            parameters.extend(cursor_values)

        if where_clauses:
            query += " WHERE " + " AND ".join(where_clauses)

        try:
            with self._connection(timeout=timeout) as conn:
                album_count = int(
                    conn.cursor().execute(query, tuple(parameters)).fetchone()[0]
                )
            return album_count
        except Exception as e:
            print(f"Failed to retrieve album counts: {e}")
            return None

    def get_search_results(
        self,
        query: str,
        return_types: SearchEntityType = SearchEntityType.TRACKS | SearchEntityType.ARTISTS | SearchEntityType.ALBUMS,
        limit_per_type: int = 10,
        timeout: float = 5,
        *,
        owner_id: int,
    ) -> SearchResults:
        _require_owner(owner_id)
        fts_query = prepare_fts_query(query)
        if not fts_query:
            return SearchResults(tracks=[], artists=[], albums=[])

        result_tracks: List[Track] = []
        result_artists: List[Artist] = []
        result_albums: List[Album] = []

        try:
            with self._connection(timeout=timeout) as conn:
                if SearchEntityType.TRACKS in return_types:
                    track_rows = conn.execute(
                        "SELECT f.rowid FROM fts_tracks f "
                        "JOIN trackmetadata tm ON tm.track_id = f.rowid "
                        "JOIN tracks t ON t.uuid_id = tm.uuid_id "
                        "WHERE fts_tracks MATCH ? AND t.owner_id = ? "
                        "ORDER BY f.rank LIMIT ?",
                        (fts_query, owner_id, limit_per_type),
                    ).fetchall()
                    if track_rows:
                        track_ids = [r["rowid"] for r in track_rows]
                        placeholders = ", ".join("?" for _ in track_ids)
                        full_rows = conn.execute(
                            f"SELECT {_track_select_columns('tm.track_id')} "
                            "FROM trackmetadata AS tm "
                            "JOIN tracks AS t ON tm.uuid_id = t.uuid_id "
                            f"WHERE tm.track_id IN ({placeholders}) AND t.owner_id = ?",
                            (*track_ids, owner_id),
                        ).fetchall()
                        # Preserve FTS rank order
                        id_order = {tid: i for i, tid in enumerate(track_ids)}
                        full_rows_sorted = sorted(
                            full_rows,
                            key=lambda r: id_order.get(r["track_id"], 999),
                        )
                        for row in full_rows_sorted:
                            result_tracks.append(_row_to_track(row))

                if SearchEntityType.ARTISTS in return_types:
                    artist_rows = conn.execute(
                        "SELECT f.rowid FROM fts_artists f "
                        "JOIN artists a ON a.id = f.rowid "
                        "WHERE fts_artists MATCH ? AND a.owner_id = ? "
                        "ORDER BY f.rank LIMIT ?",
                        (fts_query, owner_id, limit_per_type),
                    ).fetchall()
                    if artist_rows:
                        artist_ids = [r["rowid"] for r in artist_rows]
                        placeholders = ", ".join("?" for _ in artist_ids)
                        full_rows = conn.execute(
                            f"SELECT id, name FROM artists WHERE id IN ({placeholders}) "
                            "AND owner_id = ?",
                            (*artist_ids, owner_id),
                        ).fetchall()
                        id_order = {aid: i for i, aid in enumerate(artist_ids)}
                        full_rows_sorted = sorted(
                            full_rows, key=lambda r: id_order.get(r["id"], 999)
                        )
                        result_artists = [
                            Artist(id=r["id"], name=r["name"])
                            for r in full_rows_sorted
                        ]

                if SearchEntityType.ALBUMS in return_types:
                    album_rows = conn.execute(
                        "SELECT f.rowid FROM fts_albums f "
                        "JOIN albums al ON al.id = f.rowid "
                        "JOIN artists ar ON ar.id = al.artist_id "
                        "WHERE fts_albums MATCH ? AND ar.owner_id = ? "
                        "ORDER BY f.rank LIMIT ?",
                        (fts_query, owner_id, limit_per_type),
                    ).fetchall()
                    if album_rows:
                        album_ids = [r["rowid"] for r in album_rows]
                        placeholders = ", ".join("?" for _ in album_ids)
                        full_rows = conn.execute(
                            "SELECT a.id, a.name, ar.name AS artist, a.artist_id, "
                            'a."year", a.is_single_grouping '
                            "FROM albums a "
                            "JOIN artists ar ON a.artist_id = ar.id "
                            f"WHERE a.id IN ({placeholders}) AND ar.owner_id = ?",
                            (*album_ids, owner_id),
                        ).fetchall()
                        id_order = {aid: i for i, aid in enumerate(album_ids)}
                        full_rows_sorted = sorted(
                            full_rows, key=lambda r: id_order.get(r["id"], 999)
                        )
                        result_albums = [
                            Album(
                                id=r["id"],
                                name=r["name"],
                                artist=r["artist"],
                                artist_id=r["artist_id"],
                                year=r["year"],
                                is_single_grouping=bool(r["is_single_grouping"]),
                            )
                            for r in full_rows_sorted
                        ]

        except Exception as e:
            print(f"Search failed: {e}")

        return SearchResults(
            tracks=result_tracks, artists=result_artists, albums=result_albums
        )

    # ── App settings ──────────────────────────────────────────────────────

    @staticmethod
    def _ensure_server_instance_id(conn: sqlite3.Connection) -> None:
        # Partial legacy databases may not yet have the settings table.
        conn.execute(
            "CREATE TABLE IF NOT EXISTS app_settings ("
            "key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL)"
        )
        conn.execute(
            "INSERT OR IGNORE INTO app_settings (key, value) VALUES (?, ?)",
            ("server_instance_id", str(uuid.uuid4())),
        )

    def get_server_instance_id(self) -> str:
        instance_id = self.get_setting("server_instance_id")
        if instance_id is None:
            raise RuntimeError("Server instance identity has not been initialized")
        return instance_id

    def read_setting(self, key: str) -> str | None:
        """The stored value, or None when there is no row. Raises on any error."""
        with self._connection() as conn:
            row = conn.execute(
                "SELECT value FROM app_settings WHERE key = ?", (key,)
            ).fetchone()
            return row[0] if row else None

    def get_setting(self, key: str) -> str | None:
        try:
            return self.read_setting(key)
        except Exception as e:
            print(f"Error reading setting {key!r}: {e}")
            return None

    def set_setting(self, key: str, value: str) -> None:
        # Raises on failure so callers can keep in-memory state consistent
        # with what is actually persisted.
        with self._connection(commit=True) as conn:
            conn.execute(
                "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
                (key, value),
            )

    def get_track_tombstones(self, *, owner_id: Owner) -> list[str]:
        """Return uuids of all hard-deleted tracks. Incremental sync streams
        tombstones by revision via ``get_changes``; this remains as a simple
        helper for ops and tests."""
        suffix, params = _and_owner("owner_id", owner_id)
        try:
            with self._connection() as conn:
                rows = conn.execute(
                    "SELECT uuid_id FROM track_tombstones WHERE 1 = 1" + suffix,
                    params,
                ).fetchall()
                return [row[0] for row in rows]
        except Exception as e:
            print(f"Error fetching track tombstones: {e}")
            return []

    def filter_owned_track_uuids(
        self, uuid_ids: list[str], *, owner_id: int
    ) -> list[str]:
        """The given uuids that are the owner's tracks, in input order
        (duplicates kept); unknown and foreign uuids are dropped."""
        _require_owner(owner_id)
        if not uuid_ids:
            return []
        placeholders = ",".join("?" * len(uuid_ids))
        with self._connection() as conn:
            rows = conn.execute(
                f"SELECT uuid_id FROM tracks WHERE owner_id = ? "
                f"AND uuid_id IN ({placeholders})",
                [owner_id, *uuid_ids],
            ).fetchall()
        owned = {row[0] for row in rows}
        return [u for u in uuid_ids if u in owned]

    def get_deleting_user_ids(self) -> set[int]:
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT id FROM users WHERE deleting_at IS NOT NULL"
            ).fetchall()
        return {row[0] for row in rows}

    def list_user_track_uuids_for_delete(self, user_id: int) -> set[str]:
        """The user's track and tombstone uuids. Unlike the swallowing reads
        above, a failure raises: a delete must not skip cleanup on a locked db."""
        with self._connection() as conn:
            tracks = conn.execute(
                "SELECT uuid_id FROM tracks WHERE owner_id = ?", (user_id,)
            ).fetchall()
            tombstones = conn.execute(
                "SELECT uuid_id FROM track_tombstones WHERE owner_id = ?", (user_id,)
            ).fetchall()
        return {row[0] for row in tracks} | {row[0] for row in tombstones}

    def get_all_track_uuids(self, *, owner_id: Owner) -> list[str]:
        suffix, params = _and_owner("owner_id", owner_id)
        try:
            with self._connection() as conn:
                rows = conn.execute(
                    "SELECT uuid_id FROM tracks WHERE 1 = 1" + suffix, params
                ).fetchall()
                return [row[0] for row in rows]
        except Exception as e:
            print(f"Error fetching all track UUIDs: {e}")
            return []


def prepare_fts_query(raw_query: str) -> str:
    terms = raw_query.strip().split()
    if not terms:
        return ""
    escaped = ['"' + t.replace('"', '""') + '"*' for t in terms]
    return " ".join(escaped)


def alias_map(column: str) -> str:
    if column in ALLOWED_METADATA_COLUMNS:
        return "tm"
    else:
        return "t"


# Sort-key cursor pagination logic.
# This cursor logic is linked to the frontend's getTrackPage() / getAlbumTrackPage()
# in frontend/lib/database/database.dart — keep them in sync.
def filter_for_cursor(
    row_filter_list: List[RowFilterParameter],
    order_parameters: List[OrderParameter],
) -> tuple[str, List[str]]:
    columns = [param.column for param in row_filter_list]
    allowed_columns = set(ALLOWED_TRACK_COLUMNS + ALLOWED_METADATA_COLUMNS)
    input_columns = set(columns)
    invalid_search_columns = input_columns - allowed_columns

    if invalid_search_columns:
        raise ValueError("Invalid columns input to filter for cursor")

    if len(set(columns)) != len(columns):
        raise ValueError("Filtering by row requires all unique columns")

    order_columns = [op.column for op in order_parameters]
    if columns != order_columns:
        raise ValueError(
            "row_filter_parameters columns must match order_parameters columns"
        )

    constraints: List[str] = []
    values: List[str] = []

    for depth in range(len(row_filter_list)):
        equality_parts: List[str] = []
        equality_values: List[str] = []

        for i in range(depth):
            alias = alias_map(row_filter_list[i].column)
            col = row_filter_list[i].column
            value = row_filter_list[i].value
            if value is None:
                equality_parts.append(f'{alias}."{col}" IS NULL')
            else:
                equality_parts.append(f'{alias}."{col}" = ?')
                equality_values.append(value)

        alias = alias_map(row_filter_list[depth].column)
        col = row_filter_list[depth].column
        cursor_value = row_filter_list[depth].value

        if cursor_value is None:
            # NULL: for ASC, any non-null value comes after NULL; for DESC, nothing is less than NULL
            if order_parameters[depth].isAscending:
                final_part = f'{alias}."{col}" IS NOT NULL'
            else:
                # Skip this depth entirely — no rows can be "less than" NULL
                continue
            all_parts = equality_parts + [final_part]
            all_values = equality_values
        else:
            op = ">" if order_parameters[depth].isAscending else "<"
            final_part = f'{alias}."{col}" {op} ?'
            all_parts = equality_parts + [final_part]
            all_values = equality_values + [cursor_value]

        if len(all_parts) == 1:
            constraints.append(all_parts[0])
        else:
            constraints.append("(" + " AND ".join(all_parts) + ")")
        values.extend(all_values)

    if not constraints:
        return ("", values)

    return (" OR ".join(constraints), values)


def _album_col_ref(col: str) -> str:
    """Return a table-qualified column reference for album queries.

    The get_albums query joins ``albums a`` with ``artists ar`` and aliases
    ``ar.name AS artist``.  Using a bare ``"name"`` would be ambiguous, so
    columns that live on the albums table are prefixed with ``a.``.
    """
    # "artist" maps to ar."name" — the actual column on the joined artists
    # table.  A SELECT alias cannot be used in WHERE clauses.
    if col == "artist":
        return 'ar."name"'
    # Everything else lives on the albums table.
    return f'a."{col}"'


def filter_for_album_cursor(
    row_filter_list: List[AlbumRowFilterParameter],
    order_parameters: List[AlbumOrderParameter],
) -> tuple[str, List[str]]:
    if not row_filter_list:
        return ("", [])

    columns = [param.column for param in row_filter_list]
    input_columns = set(columns)
    invalid_columns = input_columns - set(ALLOWED_ALBUM_COLUMNS)

    if invalid_columns:
        raise ValueError("Invalid columns input to filter for album cursor")

    if len(set(columns)) != len(columns):
        raise ValueError("Filtering by row requires all unique columns")

    order_columns = [op.column for op in order_parameters]
    if columns != order_columns:
        raise ValueError(
            "row_filter_parameters columns must match order_parameters columns"
        )

    constraints: List[str] = []
    values: List[str] = []

    for depth in range(len(row_filter_list)):
        equality_parts: List[str] = []
        equality_values: List[str] = []

        for i in range(depth):
            col = row_filter_list[i].column
            value = row_filter_list[i].value
            col_ref = _album_col_ref(col)
            collate = " COLLATE NOCASE" if col in ALBUM_TEXT_COLUMNS else ""
            param = "CAST(? AS INTEGER)" if col in ALBUM_INTEGER_COLUMNS else "?"
            if value is None:
                equality_parts.append(f'{col_ref} IS NULL')
            else:
                equality_parts.append(f'{col_ref}{collate} = {param}')
                equality_values.append(value)

        col = row_filter_list[depth].column
        col_ref = _album_col_ref(col)
        cursor_value = row_filter_list[depth].value
        nulls_last = order_parameters[depth].nullsLast
        collate = " COLLATE NOCASE" if col in ALBUM_TEXT_COLUMNS else ""
        param = "CAST(? AS INTEGER)" if col in ALBUM_INTEGER_COLUMNS else "?"

        if cursor_value is None:
            if nulls_last:
                # NULLs sort last: nothing comes after NULL
                continue
            elif order_parameters[depth].isAscending:
                # NULLs sort first (default): any non-null comes after NULL
                final_part = f'{col_ref} IS NOT NULL'
            else:
                # DESC with NULLs first: nothing is "less than" NULL
                continue
            all_parts = equality_parts + [final_part]
            all_values = equality_values
        else:
            op = ">" if order_parameters[depth].isAscending else "<"
            if nulls_last:
                # Non-NULL cursor with nullsLast: greater values OR NULLs come after
                final_part = f'({col_ref}{collate} {op} {param} OR {col_ref} IS NULL)'
                all_parts = equality_parts + [final_part]
                all_values = equality_values + [cursor_value]
            else:
                final_part = f'{col_ref}{collate} {op} {param}'
                all_parts = equality_parts + [final_part]
                all_values = equality_values + [cursor_value]

        if len(all_parts) == 1:
            constraints.append(all_parts[0])
        else:
            constraints.append("(" + " AND ".join(all_parts) + ")")
        values.extend(all_values)

    if not constraints:
        return ("", values)

    return (" OR ".join(constraints), values)


def filter_for_artist_cursor(
    row_filter_list: List[ArtistRowFilterParameter],
    order_parameters: List[ArtistOrderParameter],
) -> tuple[str, List[str]]:
    if not row_filter_list:
        return ("", [])

    columns = [param.column for param in row_filter_list]
    input_columns = set(columns)
    invalid_columns = input_columns - set(ALLOWED_ARTIST_COLUMNS)

    if invalid_columns:
        raise ValueError("Invalid columns input to filter for artist cursor")

    if len(set(columns)) != len(columns):
        raise ValueError("Filtering by row requires all unique columns")

    order_columns = [op.column for op in order_parameters]
    if columns != order_columns:
        raise ValueError(
            "row_filter_parameters columns must match order_parameters columns"
        )

    constraints: List[str] = []
    values: List[str] = []

    for depth in range(len(row_filter_list)):
        equality_parts: List[str] = []
        equality_values: List[str] = []

        for i in range(depth):
            col = row_filter_list[i].column
            value = row_filter_list[i].value
            collate = " COLLATE NOCASE" if col in ARTIST_TEXT_COLUMNS else ""
            if value is None:
                equality_parts.append(f'"{col}" IS NULL')
            else:
                equality_parts.append(f'"{col}"{collate} = ?')
                equality_values.append(value)

        col = row_filter_list[depth].column
        cursor_value = row_filter_list[depth].value
        collate = " COLLATE NOCASE" if col in ARTIST_TEXT_COLUMNS else ""

        if cursor_value is None:
            if order_parameters[depth].isAscending:
                final_part = f'"{col}" IS NOT NULL'
            else:
                continue
            all_parts = equality_parts + [final_part]
            all_values = equality_values
        else:
            op = ">" if order_parameters[depth].isAscending else "<"
            final_part = f'"{col}"{collate} {op} ?'
            all_parts = equality_parts + [final_part]
            all_values = equality_values + [cursor_value]

        if len(all_parts) == 1:
            constraints.append(all_parts[0])
        else:
            constraints.append("(" + " AND ".join(all_parts) + ")")
        values.extend(all_values)

    if not constraints:
        return ("", values)

    return (" OR ".join(constraints), values)


def server_database(app_data_dir: Path) -> Database:
    """The server's database under ``app_data_dir`` (creates nothing)."""
    return Database(
        DatabaseContext(
            database_path=Path(app_data_dir) / "database" / "database.db",
            init_sql_path=Path(__file__).parent / "init.sql",
        )
    )
