"""A two-user data dir for the ``users delete`` tests (M.2b, M-U17).

Sam is deleted; Alex must be untouched. They overlap on purpose: both own
"Lucky" by Radiohead on "OK Computer" (same FTS tokens) and share one cover
art. Every per-user table holds rows for both of them.

Everything lives under the test's ``tmp_path`` (see ``cli_fixtures``).
"""

import sqlite3
import uuid as uuidlib
from dataclasses import dataclass, field
from pathlib import Path

from app.library import Library
from app.models.history import HistoryEvent
from tests.auth_helpers import create_session
from tests.cli_fixtures import ADMIN, add_track, add_user, open_server_database, sql

# Per-user rows, written independently of the production delete code.
USER_ROWS = {
    "users": "id = :uid",
    "user_settings": "user_id = :uid",
    "auth_sessions": "user_id = :uid",
    "user_delete_art_capture": "user_id = :uid",
    "artists": "owner_id = :uid",
    "tracks": "owner_id = :uid",
    "track_tombstones": "owner_id = :uid",
    "history_events": "owner_id = :uid",
    "conversion_jobs": "owner_id = :uid",
    "edit_journal": "owner_id = :uid",
    "trackmetadata": "track_id IN (SELECT id FROM tracks WHERE owner_id = :uid)",
    "albums": "artist_id IN (SELECT id FROM artists WHERE owner_id = :uid)",
    "history_hook_failures": (
        "event_uuid IN (SELECT event_uuid FROM history_events WHERE owner_id = :uid)"
    ),
    # Phase 6.5 (plan D15): uuid-keyed children of tracks.
    "track_audio_identity": "uuid_id IN (SELECT uuid_id FROM tracks WHERE owner_id = :uid)",
    "track_audio_fingerprint": "uuid_id IN (SELECT uuid_id FROM tracks WHERE owner_id = :uid)",
    "track_duplicate_candidates": "owner_id = :uid",
    # Phase 7A.1c (decision O2): both users hold rows under the same client uuids.
    "upload_batches": "owner_id = :uid",
    "upload_items": "owner_id = :uid",
    "upload_item_audio_identity": "owner_id = :uid",
    "operation_receipts": "owner_id = :uid",
    "storage_reservations": "owner_id = :uid",
    "upload_item_acknowledgements": "owner_id = :uid",
    "upload_commit_journal": "owner_id = :uid",
    # Phase 8A.2a: keyed (owner_id, operation_uuid) like their receipt (DEV-7-01).
    "deletion_jobs": "owner_id = :uid",
    "deletion_job_items": "owner_id = :uid",
    "deletion_journal": "owner_id = :uid",
    # Phase 9D.1b: one Last.fm connection per user.
    "lastfm_connections": "owner_id = :uid",
    "scrobble_outbox": "owner_id = :uid",
}
SERVER_WIDE_TABLES = {"app_settings", "revision_counter", "cover_arts"}
FTS_TABLES = {"fts_tracks", "fts_artists", "fts_albums"}

# Tokens of everything Sam ever had in the FTS tables (current and edited-away).
SAM_TOKENS = [
    "lucky", "radiohead", "ok", "computer", "renamedtitle", "zebrafish",
    "uniquesam", "band", "samonly", "album", "gonetrack", "samvarious",
]


@dataclass
class World:
    settings: object
    db: object
    admin: int
    sam: int
    alex: int
    sam_uuids: list = field(default_factory=list)
    alex_uuids: list = field(default_factory=list)
    art: dict = field(default_factory=dict)  # name -> (id, Path)
    files: dict = field(default_factory=dict)  # name -> Path


def _art(world, settings, name):
    directory = settings.app_data_dir / "cover_art"
    directory.mkdir(parents=True, exist_ok=True)
    sha = (name * 64)[:64]
    path = directory / f"{sha}.jpg"
    path.write_bytes(b"jpeg " + name.encode())
    art_id = world.db.insert_cover_art(sha256=sha, phash="0" * 16, phash_prefix="00", file_path=str(path))
    world.art[name] = (art_id, path)
    return art_id


def _per_user_rows(world, uid, track_uuid, name):
    db = world.db
    lib = Library(db, uid)
    lib.set_user_setting("default_streaming_quality", "high")
    create_session(db, uid)
    event = str(uuidlib.uuid4())
    lib.insert_history_events([
        HistoryEvent(
            event_uuid=event, kind="play", entity_type="track", entity_ref=track_uuid,
            occurred_at=1_700_000_000_000, seconds_played=1.0, track_length=2.0,
        )
    ])
    sql(db, "INSERT INTO history_hook_failures (subscriber, event_uuid, error, created_at) "
            "VALUES ('test', ?, 'boom', 0)", (event,))
    lib.insert_conversion_job(track_uuid, "aac", "m4a", 256)
    lib.insert_journal_entry("relocate", track_uuid, old_path=f"/nowhere/{name}-old")
    # add_track (6.5A.2b) already wrote the identity row; OR IGNORE keeps it.
    sql(db, "INSERT OR IGNORE INTO track_audio_identity (uuid_id, exact_state, fp_state) "
            "VALUES (?, 'current', 'unavailable')", (track_uuid,))
    sql(db, "INSERT OR IGNORE INTO track_audio_fingerprint "
            "(uuid_id, backend, algorithm, duration_s, item_count, data) "
            "VALUES (?, 'fpcalc', 'chromaprint-2', 30.0, 1, X'01000000')", (track_uuid,))


def _candidate_pair(world, uid, uuids):
    uuid_a, uuid_b = sorted(uuids)
    sql(world.db, "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, "
                  "band_rank, sort_score, matcher_version, detected_at) "
                  "VALUES (?, ?, ?, 'exact', 0, 1.0, 'm1', 0)", (uid, uuid_a, uuid_b))


# Client-generated uuids both users send (decision O2: unique per owner only).
SHARED_BATCH = "00000000-0000-4000-8000-0000000000b1"
SHARED_ZIP = "00000000-0000-4000-8000-0000000000a1"
SHARED_ITEM = "00000000-0000-4000-8000-0000000000a2"
SHARED_OPERATION = "00000000-0000-4000-8000-0000000000c1"
SHARED_DELETION = "00000000-0000-4000-8000-0000000000d1"


def _deletion_rows(world, uid, track_uuid):
    """A deletion job for ``track_uuid`` (written while the track is still
    live; the caller deletes the track afterwards)."""
    sql(world.db, "INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash, "
                  "created_at, result_ref) VALUES (?, ?, 'track_deletion', ?, 0, ?)",
        (uid, SHARED_DELETION, "d" * 64, SHARED_DELETION))
    sql(world.db, "INSERT INTO deletion_jobs (owner_id, operation_uuid, created_at, status) "
                  "VALUES (?, ?, 0, 'accepted')", (uid, SHARED_DELETION))
    sql(world.db, "INSERT INTO deletion_job_items (owner_id, operation_uuid, uuid_id, position, "
                  "base_revision, status, tombstone_revision) VALUES (?, ?, ?, 0, 1, 'deleted', 99)",
        (uid, SHARED_DELETION, track_uuid))
    # Committed with storage cleanup pending: the journal outlives the track row.
    sql(world.db, "INSERT INTO deletion_journal (owner_id, operation_uuid, uuid_id, original_path, "
                  "quarantine_path, base_revision, src_dev, src_ino, src_size, master_missing, "
                  "stage, created_at, updated_at) VALUES (?, ?, ?, '/m/o', '/m/q', 1, 1, 2, 3, 0, "
                  "'committed', 0, 0)", (uid, SHARED_DELETION, track_uuid))


def _lastfm_rows(world, uid, name):
    """A bound Last.fm connection (made-up ciphertext) with a pending token."""
    sql(world.db, "INSERT INTO lastfm_connections (owner_id, connection_id, account_name, "
                  "session_key_enc, opted_in, needs_reconnect, pending_token_enc, "
                  "pending_token_expires_at, created_at, updated_at) "
                  "VALUES (?, ?, ?, ?, 1, 0, ?, 600000, 0, 0)",
        (uid, f"conn-{name}", f"{name}-on-lastfm", f"enc-session-{name}", f"enc-token-{name}"))
    for event, status, code, done in ((f"{name}-sent", "sent", None, 5), (f"{name}-wait", "pending", None, None),
                                      (f"{name}-lost", "dropped", "too_old", 6)):
        sql(world.db, "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s, "
                      "status, result_code, created_at, done_at) VALUES (?, ?, ?, 100, ?, ?, 1, ?)",
            (event, uid, '{"artist": "Radiohead", "track": "Lucky", "timestamp": 100}', status, code, done))


def _upload_rows(world, uid):
    sql(world.db, "INSERT INTO upload_batches (owner_id, batch_uuid, label, created_at, "
                  "updated_at) VALUES (?, ?, 'upload', 0, 0)", (uid, SHARED_BATCH))
    sql(world.db, "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, kind, filename, "
                  "selection_index, expected_bytes, expected_sha256, state, created_at, "
                  "updated_at, progress_at) VALUES (?, ?, ?, 'zip', 'a.zip', 0, 1, ?, "
                  "'expanded', 0, 0, 0)", (uid, SHARED_ZIP, SHARED_BATCH, "0" * 64))
    sql(world.db, "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, parent_item_uuid, "
                  "filename, selection_index, member_order_key, state, created_at, updated_at, "
                  "progress_at) VALUES (?, ?, ?, ?, 'a.flac', 0, 'a.flac', 'review_ready', "
                  "0, 0, 0)", (uid, SHARED_ITEM, SHARED_BATCH, SHARED_ZIP))
    sql(world.db, "INSERT INTO upload_item_audio_identity (owner_id, item_uuid, exact_state, "
                  "exact_kind, exact_digest, computed_at, fp_state) "
                  "VALUES (?, ?, 'current', 'pcm_sha256', ?, 0, 'unavailable')",
        (uid, SHARED_ITEM, "ab" * 32))
    sql(world.db, "INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash, "
                  "created_at, result_ref) VALUES (?, ?, 'upload_commit', ?, 0, ?)",
        (uid, SHARED_OPERATION, "f" * 64, SHARED_ITEM))
    sql(world.db, "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, "
                  "created_at) VALUES (?, 'upload_receive', ?, 5, 0)", (uid, SHARED_ITEM))
    sql(world.db, "INSERT INTO upload_item_acknowledgements (owner_id, item_uuid, subject_kind, "
                  "subject_ref) VALUES (?, ?, 'staged_item', ?)", (uid, SHARED_ITEM, SHARED_ZIP))
    sql(world.db, "INSERT INTO upload_commit_journal (owner_id, operation_uuid, item_uuid, state, "
                  "base_review_version, reserved_track_uuid, edits, write_tags, "
                  "acknowledged_duplicates, source_path, created_at, updated_at) "
                  "VALUES (?, ?, ?, 'committing', 0, ?, '{}', 0, '{}', '/s', 0, 0)",
        (uid, SHARED_OPERATION, SHARED_ITEM, f"track-of-{uid}"))


def build_world(settings) -> World:
    db = open_server_database(settings)
    world = World(settings=settings, db=db, admin=add_user(db, ADMIN, master=True),
                  sam=add_user(db, "Sam"), alex=add_user(db, "Alex"))
    shared = _art(world, settings, "a")
    sam_only = _art(world, settings, "b")
    alex_only = _art(world, settings, "c")
    _art(world, settings, "d")  # unreferenced by anyone; its row is never captured

    # Sam.
    lucky = add_track(db, settings, world.sam, cover_art_id=shared)
    zebra = add_track(db, settings, world.sam, title="Zebrafish", artist="Uniquesam Band",
                      album="Samonly Album", track_number=2, cover_art_id=sam_only,
                      # Review r1 m-R1-04: the FTS delete must use the album
                      # artist (stripped), as the insert did.
                      album_artist=" Samvarious ")
    gone = add_track(db, settings, world.sam, title="Gonetrack", track_number=3)
    lib = Library(db, world.sam)
    revision = lib.get_track_by_uuid(zebra.uuid_id).revision
    lib.apply_track_metadata_edit(zebra.uuid_id, {"title": "Renamedtitle"}, revision)
    _deletion_rows(world, world.sam, gone.uuid_id)
    assert lib.delete_track(gone.uuid_id)  # leaves a tombstone
    world.sam_uuids = [lucky.uuid_id, zebra.uuid_id]
    _candidate_pair(world, world.sam, world.sam_uuids)
    _per_user_rows(world, world.sam, lucky.uuid_id, "sam")
    _upload_rows(world, world.sam)
    _lastfm_rows(world, world.sam, "sam")

    # Alex: the same "Lucky", plus one of their own.
    a_lucky = add_track(db, settings, world.alex, cover_art_id=shared)
    a_kid = add_track(db, settings, world.alex, title="Idioteque", album="Kid A",
                      track_number=8, cover_art_id=alex_only)
    a_gone = add_track(db, settings, world.alex, title="Alexgone", album="Amnesiac",
                       track_number=9)
    _deletion_rows(world, world.alex, a_gone.uuid_id)
    assert Library(db, world.alex).delete_track(a_gone.uuid_id)
    a_gone.file_path.unlink()  # delete_track removes rows only
    world.alex_uuids = [a_lucky.uuid_id, a_kid.uuid_id]
    _candidate_pair(world, world.alex, world.alex_uuids)
    _per_user_rows(world, world.alex, a_lucky.uuid_id, "alex")
    _upload_rows(world, world.alex)
    _lastfm_rows(world, world.alex, "alex")

    # Files beside the rows.
    music, data = settings.music_library_dir, settings.app_data_dir
    staging = music / ".staging"
    staging.mkdir(parents=True, exist_ok=True)
    f = world.files
    f["sam_import"] = settings.user_import_dir / "Sam" / "dropped.flac"
    f["alex_import"] = settings.user_import_dir / "Alex" / "dropped.flac"
    f["sam_workspace"] = data / "workspace" / f"u{world.sam}" / "partial.zip"
    f["alex_workspace"] = data / "workspace" / f"u{world.alex}" / "partial.zip"
    f["sam_edit_temp"] = staging / f"{lucky.uuid_id}.flac"
    f["sam_convert_temp"] = staging / f"{zebra.uuid_id}.7.convert.m4a"
    f["sam_tagged_temp"] = staging / f"{zebra.uuid_id}.7.tagged.m4a"
    f["alex_edit_temp"] = staging / f"{a_lucky.uuid_id}.flac"
    f["sam_bare_temp"] = staging / lucky.uuid_id
    f["sam_gone_cache"] = data / "encoded_cache" / f"{gone.uuid_id}__q128.m4a"
    f["sam_cache"] = data / "encoded_cache" / f"{lucky.uuid_id}__q128.m4a"
    f["sam_default_cache"] = data / "default_cache" / f"{zebra.uuid_id}__qhigh.m4a"
    f["alex_cache"] = data / "encoded_cache" / f"{a_lucky.uuid_id}__q128.m4a"
    f["alex_default_cache"] = data / "default_cache" / f"{a_kid.uuid_id}__qhigh.m4a"
    f["orphan_art"] = data / "cover_art" / ("e" * 64 + ".jpg")
    f["not_art_photo"] = data / "cover_art" / "holiday.png"
    f["not_art_notes"] = data / "cover_art" / "README.txt"
    for path in f.values():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x")
    f["sam_music"] = music / "Sam"
    f["alex_music"] = music / "Alex"
    f["alex_master"] = a_lucky.file_path
    # A symlink inside Sam's folder to Alex's: the delete must not follow it.
    (music / "Sam" / "link-to-alex").symlink_to(music / "Alex", target_is_directory=True)
    (music / "Sam" / "link-to-alex-file").symlink_to(a_lucky.file_path)
    return world


def table_names(db) -> set[str]:
    rows = sql(db, "SELECT name FROM sqlite_master WHERE type = 'table'")
    return {
        r[0] for r in rows
        if not r[0].startswith("sqlite_")
        and not any(r[0].startswith(t + "_") for t in FTS_TABLES)
    }


def dump(db) -> dict[str, set]:
    """Every row of every ordinary table."""
    return {t: set(sql(db, f'SELECT * FROM "{t}"')) for t in table_names(db) - FTS_TABLES}


def user_rows(db, uid) -> dict[str, set]:
    conn = sqlite3.connect(db.context.database_path)
    try:
        return {
            t: set(conn.execute(f'SELECT * FROM "{t}" WHERE {where}', {"uid": uid}).fetchall())
            for t, where in USER_ROWS.items()
        }
    finally:
        conn.close()


def fts_matches(db, table: str, token: str) -> set[int]:
    return {r[0] for r in sql(db, f"SELECT rowid FROM {table} WHERE {table} MATCH ?", (token,))}


def fts_snapshot(db) -> dict:
    return {(t, tok): fts_matches(db, t, tok) for t in sorted(FTS_TABLES) for tok in SAM_TOKENS}


def owned_ids(db, uid) -> dict[str, set[int]]:
    return {
        "fts_tracks": {r[0] for r in sql(db, "SELECT id FROM tracks WHERE owner_id = ?", (uid,))},
        "fts_artists": {r[0] for r in sql(db, "SELECT id FROM artists WHERE owner_id = ?", (uid,))},
        "fts_albums": {
            r[0] for r in sql(
                db, "SELECT al.id FROM albums al JOIN artists ar ON ar.id = al.artist_id "
                    "WHERE ar.owner_id = ?", (uid,))
        },
    }


def exists(path: Path) -> bool:
    return path.exists() or path.is_symlink()
