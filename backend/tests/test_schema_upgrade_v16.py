"""Phase 8A.2a (8-U04 schema part, plan decision O1): the 15 -> 16 upgrade.

v16 is one additive ladder step holding Phase 8's deletion tables and the
pending-deletion marker on ``live_tracks``. The server accepts v13, v14 and
v15 and upgrades each to v16 in one open (13 -> 14 -> 15 -> 16); every other
version is refused by the read-only check before any write. The admin CLI
never migrates, so it requires v16.

The v13, v14 and v15 files are real: the frozen ``fixtures/schema_v1{3,4,5}.sql``
plus plain SQL (two users with tracks, FTS, an edit journal, identity rows,
candidate pairs, upload rows and receipts), opened through the production
``Database.initialize()``.
"""

import logging
import os
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.database import table_registry as registry
from app.database.database import Database, DatabaseContext, SchemaVersionRefused
from tests.schema_fixtures import (
    INIT_SQL,
    make_legacy_database,
    seed_two_user_library,
    user_version,
)

_PAST_NS = 1_000_000_000_000_000_000
OPERATOR = "uvicorn.error"  # app.core.operator_log.operator_logger
UPGRADABLE = (13, 14, 15)
NEW_TABLES = ("deletion_jobs", "deletion_job_items", "deletion_journal")
LATEST = Database.LATEST_SCHEMA_VERSION  # 17 since Phase 9D.1b


def _database(path: Path) -> Database:
    return Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))


def _open(path: Path) -> None:
    """Production initialization alone (no test owner is seeded)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    assert _database(path).initialize() is True


def _connect(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def _set_user_version(path: Path, version: int) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.execute(f"PRAGMA user_version = {version}")
        conn.commit()
    finally:
        conn.close()


def _schema(path: Path) -> list:
    conn = sqlite3.connect(path)
    try:
        return conn.execute(
            "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
        ).fetchall()
    finally:
        conn.close()


def _normalized_schema(path: Path) -> set:
    return {
        (kind, name, table, " ".join(sql.split()) if sql else None)
        for kind, name, table, sql in _schema(path)
    }


def _rows(path: Path, tables=None) -> dict:
    """Every row of every table (shadow tables and sqlite_sequence included)."""
    conn = sqlite3.connect(path)
    try:
        if tables is None:
            tables = [
                r[0] for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table' "
                    "AND sql NOT LIKE 'CREATE VIRTUAL TABLE%'"
                )
            ]
        return {t: sorted(conn.execute(f'SELECT * FROM "{t}"').fetchall()) for t in tables}
    finally:
        conn.close()


def _fts(path: Path, table: str, token: str) -> list:
    conn = sqlite3.connect(path)
    try:
        return sorted(
            r[0] for r in conn.execute(f"SELECT rowid FROM {table} WHERE {table} MATCH ?", (token,))
        )
    finally:
        conn.close()


# --- realistic files at each upgradable version ------------------------------------------------


def _seed_identity_rows(conn: sqlite3.Connection) -> None:
    """Phase 6.5 rows: identities for every live track, one fingerprint, one
    open and one dismissed pair (one per user)."""
    for uuid in ("u-sam-1", "u-sam-2", "u-alex-1", "u-alex-2"):
        conn.execute(
            "INSERT INTO track_audio_identity (uuid_id, generation, exact_state, exact_kind, "
            "exact_digest, sample_rate_hz, channels, bits_per_sample, fp_state, match_state, "
            "priority, stat_size, stat_mtime_ns, stat_inode, computed_at, tool_versions) "
            "VALUES (?, 3, 'current', 'pcm_sha256', ?, 48000, 2, 24, 'current', 'current', "
            "1, 2000, 6000, 88, 650, 'ffmpeg 8.1; fpcalc 1.6.2')",
            (uuid, "12" * 32),
        )
    conn.execute(
        "INSERT INTO track_audio_fingerprint VALUES "
        "('u-sam-2', 'fpcalc', 'chromaprint-2', 201.25, 4, X'0A0B0C0D')"
    )
    conn.execute(
        "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
        "sort_score, matcher_version, detected_at) "
        "VALUES (1, 'u-sam-1', 'u-sam-2', 'exact', 0, 1.0, 'm1', 710)"
    )
    conn.execute(
        "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
        "sort_score, matcher_version, detected_at, status, status_changed_at) "
        "VALUES (2, 'u-alex-1', 'u-alex-2', 'fingerprint', 2, 0.71, 'm1', 720, 'dismissed', 730)"
    )


SHARED_BATCH = "00000000-0000-4000-8000-0000000000b1"
SHARED_ITEM = "00000000-0000-4000-8000-0000000000a2"
SHARED_OPERATION = "00000000-0000-4000-8000-0000000000c1"


def _seed_upload_rows(conn: sqlite3.Connection) -> None:
    """Phase 7 rows for both users under the same client uuids (unique per
    owner only): a batch, an imported item, its identity, an acknowledgement,
    a receipt, a reservation and a finished commit journal."""
    for owner, track in ((1, "u-sam-2"), (2, "u-alex-2")):
        conn.execute(
            "INSERT INTO upload_batches VALUES (?, ?, 'upload', 800, 810)", (owner, SHARED_BATCH)
        )
        conn.execute(
            "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, kind, filename, "
            "selection_index, expected_bytes, expected_sha256, received_bytes, state, "
            "result_track_uuid, result_revision, created_at, updated_at, progress_at) "
            "VALUES (?, ?, ?, 'audio', 'a.flac', 0, 10, ?, 10, 'imported', ?, 6, 800, 820, 815)",
            (owner, SHARED_ITEM, SHARED_BATCH, "e" * 64, track),
        )
        conn.execute(
            "INSERT INTO upload_item_audio_identity (owner_id, item_uuid, exact_state, "
            "exact_kind, exact_digest, computed_at, fp_state) "
            "VALUES (?, ?, 'current', 'pcm_sha256', ?, 805, 'unavailable')",
            (owner, SHARED_ITEM, "12" * 32),
        )
        conn.execute(
            "INSERT INTO upload_item_acknowledgements VALUES (?, ?, 'library_track', ?)",
            (owner, SHARED_ITEM, "u-sam-1" if owner == 1 else "u-alex-1"),
        )
        conn.execute(
            "INSERT INTO operation_receipts VALUES (?, ?, 'upload_commit', ?, 806, ?)",
            (owner, SHARED_OPERATION, "f" * 64, SHARED_ITEM),
        )
        conn.execute(
            "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, created_at) "
            "VALUES (?, 'upload_receive', ?, 10, 801)",
            (owner, SHARED_ITEM),
        )
        conn.execute(
            "INSERT INTO upload_commit_journal (owner_id, operation_uuid, item_uuid, state, "
            "base_review_version, reserved_track_uuid, edits, write_tags, "
            "acknowledged_duplicates, source_path, created_at, updated_at) "
            "VALUES (?, ?, ?, 'imported', 0, ?, '{}', 0, '[]', '/s', 806, 820)",
            (owner, SHARED_OPERATION, SHARED_ITEM, track),
        )
    # One reservation released: storage_reservations' sequence runs ahead of its max id.
    conn.execute("DELETE FROM storage_reservations WHERE id = 2")


def _rich(path: Path, version: int) -> None:
    """A real v13, v14 or v15 file holding two users' libraries."""
    make_legacy_database(path, version)
    conn = sqlite3.connect(path)
    try:
        seed_two_user_library(conn)
        if version >= 14:
            _seed_identity_rows(conn)
        if version >= 15:
            _seed_upload_rows(conn)
        conn.commit()
    finally:
        conn.close()


# --- the version window -----------------------------------------------------------------------


def test_the_minimum_schema_is_13():
    assert Database.MINIMUM_SCHEMA_VERSION == 13


def test_a_fresh_database_lands_on_latest(tmp_path):
    path = tmp_path / "database.db"
    _open(path)
    assert user_version(path) == LATEST


@pytest.mark.parametrize("version", UPGRADABLE)
def test_an_upgradable_database_reaches_latest_in_one_open_and_keeps_its_instance_id(tmp_path, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, version)

    db = _database(path)
    assert db.initialize() is True

    assert user_version(path) == LATEST
    assert db.get_server_instance_id() == f"inst-v{version}"


@pytest.mark.parametrize("version", [12, LATEST + 1])
def test_versions_outside_13_to_latest_are_refused_untouched(tmp_path, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, 15)
    _set_user_version(path, version)
    os.utime(path, ns=(_PAST_NS, _PAST_NS))
    data, mtime, listing = path.read_bytes(), path.stat().st_mtime_ns, sorted(os.listdir(tmp_path))

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert f"schema {version}" in str(refused.value)
    assert path.read_bytes() == data
    assert path.stat().st_mtime_ns == mtime
    assert sorted(os.listdir(tmp_path)) == listing


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_cli_check_refuses_an_upgradable_file_untouched(tmp_path, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, version)
    os.utime(path, ns=(_PAST_NS, _PAST_NS))
    data, mtime = path.read_bytes(), path.stat().st_mtime_ns

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).require_current_schema()

    message = str(refused.value)
    assert f"schema {version}" in message
    assert f"upgrade it to schema {LATEST}" in message
    assert path.read_bytes() == data and path.stat().st_mtime_ns == mtime


def test_the_cli_check_accepts_latest(tmp_path):
    path = tmp_path / "database.db"
    _rich(path, 15)
    _open(path)

    _database(path).require_current_schema()


# --- the upgrade keeps every existing row ----------------------------------------------------


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_upgrade_keeps_every_existing_row_byte_for_byte(tmp_path, version):
    """Ids, uuids, revisions, timestamps, identity rows, candidate pairs,
    upload rows, receipts, FTS (shadow tables) and ``sqlite_sequence`` are
    unchanged; nothing is bumped. (From v13 the 13 -> 14 step adds its
    backfilled identity rows, which test_schema_upgrade_v14 pins.)"""
    path = tmp_path / "database.db"
    _rich(path, version)
    before = _rows(path)

    _open(path)

    assert _rows(path, tables=list(before)) == before
    assert _fts(path, "fts_tracks", "lucky") == [11, 21]
    assert _fts(path, "fts_tracks", "gone") == []
    assert _fts(path, "fts_artists", "radiohead") == [1, 2]
    sequence = dict(before["sqlite_sequence"])
    assert sequence["conversion_jobs"] == 3 and sequence["tracks"] == 23
    if version >= 14:
        assert len(before["track_duplicate_candidates"]) == 2
    if version >= 15:
        assert sequence["storage_reservations"] == 2
        assert len(before["operation_receipts"]) == 2
        assert len(before["upload_items"]) == 2
    assert user_version(path) == LATEST


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_upgrade_adds_the_deletion_tables_empty(tmp_path, version):
    path = tmp_path / "database.db"
    _rich(path, version)

    _open(path)

    assert _rows(path, tables=list(NEW_TABLES)) == {t: [] for t in NEW_TABLES}


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_upgraded_file_is_consistent_and_verifies(tmp_path, version):
    path = tmp_path / "database.db"
    _rich(path, version)

    _open(path)

    conn = sqlite3.connect(path)
    try:
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []
        assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert registry.verify(conn) == []
    finally:
        conn.close()


def test_a_fresh_v16_file_verifies(tmp_path):
    path = tmp_path / "database.db"
    _open(path)

    conn = sqlite3.connect(path)
    try:
        assert registry.verify(conn) == []
    finally:
        conn.close()


@pytest.mark.parametrize("version", UPGRADABLE)
def test_a_second_open_changes_no_row_and_no_schema(tmp_path, version):
    path = tmp_path / "database.db"
    _rich(path, version)
    _open(path)
    rows, schema = _rows(path), _schema(path)

    _open(path)

    assert _rows(path) == rows
    assert _schema(path) == schema
    assert user_version(path) == LATEST


@pytest.mark.parametrize("stale", UPGRADABLE)
def test_a_stale_outer_read_is_a_no_op_on_a_v16_file(tmp_path, monkeypatch, stale):
    path = tmp_path / "database.db"
    _rich(path, 15)
    _open(path)
    rows, schema = _rows(path), _schema(path)

    monkeypatch.setattr(Database, "_existing_schema_version", lambda self: stale)
    assert _database(path).initialize() is True

    assert _rows(path) == rows
    assert _schema(path) == schema
    assert user_version(path) == LATEST


@pytest.mark.parametrize("version", UPGRADABLE)
def test_a_fresh_v16_schema_equals_a_migrated_one(tmp_path, version):
    fresh = tmp_path / "fresh" / "database.db"
    migrated = tmp_path / "migrated" / "database.db"
    _open(fresh)
    migrated.parent.mkdir()
    _rich(migrated, version)
    _open(migrated)

    assert _normalized_schema(fresh) == _normalized_schema(migrated)


# --- the operator log -------------------------------------------------------------------------


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_upgrade_is_logged_once_from_the_files_version_to_latest(tmp_path, caplog, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, version)

    with caplog.at_level(logging.INFO, logger=OPERATOR):
        _database(path).initialize()

    lines = [r.getMessage() for r in caplog.records if r.name == OPERATOR and "schema" in r.getMessage()]
    assert lines == [f"database schema upgraded from {version} to {LATEST}"]


# --- the real startup -------------------------------------------------------------------------


@pytest.mark.parametrize("version", UPGRADABLE)
def test_server_startup_upgrades_an_old_data_dir(tmp_path, configure_app, version):
    """The upgrade runs inside the real startup, under the instance lock."""
    path = tmp_path / "data" / "database" / "database.db"
    _rich(path, version)
    main = configure_app()

    with TestClient(main.app):
        assert user_version(path) == LATEST

    conn = sqlite3.connect(path)
    try:
        assert registry.verify(conn) == []
    finally:
        conn.close()


# --- a failure inside the step ----------------------------------------------------------------


def _deny(action: int, name: str):
    """A connection factory whose authorizer refuses ``action`` on ``name``:
    the step fails at that object, after any earlier DDL already ran."""
    real_connect = sqlite3.connect

    def connect(*args, **kwargs):
        conn = real_connect(*args, **kwargs)

        def authorizer(act, arg1, *_):
            if act == action and arg1 == name:
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK

        conn.set_authorizer(authorizer)
        return conn

    return connect


# The step's first and last objects; later steps of this piece extend the list.
FAILURE_POINTS = [
    (sqlite3.SQLITE_CREATE_TABLE, "deletion_jobs"),
    (sqlite3.SQLITE_CREATE_INDEX, "idx_deletion_jobs_list"),
    (sqlite3.SQLITE_CREATE_TABLE, "deletion_job_items"),
    (sqlite3.SQLITE_CREATE_TABLE, "deletion_journal"),
    (sqlite3.SQLITE_CREATE_TRIGGER, "deletion_journal_names_own_track"),
    (sqlite3.SQLITE_CREATE_TRIGGER, "deletion_journal_keeps_its_track"),
]


@pytest.mark.parametrize("action,name", FAILURE_POINTS)
@pytest.mark.parametrize("version", UPGRADABLE)
def test_a_failure_mid_step_rolls_back_to_the_files_version(tmp_path, monkeypatch, version, action, name):
    """Every step shares one transaction: a v13 file stays at 13 (not 14 or 15)."""
    path = tmp_path / "database.db"
    _rich(path, version)
    rows, schema = _rows(path), _schema(path)

    with monkeypatch.context() as patch:
        patch.setattr(sqlite3, "connect", _deny(action, name))
        with pytest.raises(sqlite3.DatabaseError):
            _database(path).initialize()

    assert user_version(path) == version
    assert _schema(path) == schema  # no partial table, index or view
    assert _rows(path) == rows

    _open(path)  # the next start upgrades it
    assert user_version(path) == LATEST


@pytest.mark.parametrize("version", UPGRADABLE)
def test_a_failure_after_the_view_swap_keeps_the_old_view(tmp_path, monkeypatch, version):
    """Review r1 M2: the v14 step also creates ``live_tracks``, so an
    authorizer on the view would fail there for v13/v14 files. Instead the
    v16 step fails after its last statement (the view already dropped and
    re-created): the old view, the version and every row survive."""
    from app.database import database as database_module

    path = tmp_path / "database.db"
    _rich(path, version)
    rows, schema = _rows(path), _schema(path)

    with monkeypatch.context() as patch:
        patch.setattr(database_module, "SCHEMA_V16_DDL",
                      (*database_module.SCHEMA_V16_DDL, "SELECT * FROM no_such_table"))
        with pytest.raises(sqlite3.OperationalError):
            _database(path).initialize()

    assert user_version(path) == version
    assert _schema(path) == schema  # the old live_tracks text included
    assert _rows(path) == rows

    _open(path)
    assert user_version(path) == LATEST


# --- deletion_jobs ----------------------------------------------------------------------------


@pytest.fixture
def v16(tmp_path):
    """A v16 file migrated from a rich v15 file (users 1 and 2)."""
    path = tmp_path / "database.db"
    _rich(path, 15)
    _open(path)
    return path


DELETION_OP = "00000000-0000-4000-8000-0000000000d1"


def _receipt(conn, owner, operation=DELETION_OP):
    conn.execute(
        "INSERT INTO operation_receipts VALUES (?, ?, 'track_deletion', ?, 900, ?)",
        (owner, operation, "a" * 64, operation),
    )


def _job(conn, owner, operation=DELETION_OP, created_at=900, status="accepted"):
    conn.execute(
        "INSERT INTO deletion_jobs (owner_id, operation_uuid, created_at, status) "
        "VALUES (?, ?, ?, ?)",
        (owner, operation, created_at, status),
    )


def test_two_users_may_hold_a_job_under_the_same_operation_uuid(v16):
    """Keyed (owner_id, operation_uuid) like its receipt (DEV-7-01)."""
    conn = _connect(v16)
    try:
        for owner in (1, 2):
            _receipt(conn, owner)
            _job(conn, owner)
        conn.commit()
        assert conn.execute(
            "SELECT owner_id FROM deletion_jobs WHERE operation_uuid = ? ORDER BY owner_id",
            (DELETION_OP,),
        ).fetchall() == [(1,), (2,)]
        with pytest.raises(sqlite3.IntegrityError):
            _job(conn, 1)
    finally:
        conn.close()


def test_a_job_needs_its_own_owners_receipt(v16):
    conn = _connect(v16)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _job(conn, 1)  # no receipt at all
        _receipt(conn, 2)
        with pytest.raises(sqlite3.IntegrityError):
            _job(conn, 1)  # the receipt is another user's
    finally:
        conn.close()


@pytest.mark.parametrize("column,value", [("owner_id", None), ("created_at", None), ("status", None)])
def test_a_job_requires_its_owner_time_and_status(v16, column, value):
    conn = _connect(v16)
    try:
        _receipt(conn, 1)
        row = {"owner_id": 1, "operation_uuid": DELETION_OP, "created_at": 900, "status": "accepted"}
        row[column] = value
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(
                "INSERT INTO deletion_jobs (owner_id, operation_uuid, created_at, status) "
                "VALUES (:owner_id, :operation_uuid, :created_at, :status)",
                row,
            )
    finally:
        conn.close()


@pytest.mark.parametrize("status,ok", [("accepted", True), ("completed", True), ("running", False), ("", False)])
def test_a_job_status_is_accepted_or_completed(v16, status, ok):
    conn = _connect(v16)
    try:
        _receipt(conn, 1)
        if ok:
            _job(conn, 1, status=status)
        else:
            with pytest.raises(sqlite3.IntegrityError):
                _job(conn, 1, status=status)
    finally:
        conn.close()


def test_the_receipts_page_seeks_through_the_keyset_index(v16):
    """``GET /tracks/deletions`` pages by (created_at, operation_uuid) per owner."""
    conn = sqlite3.connect(v16)
    try:
        columns = [r[2] for r in conn.execute("PRAGMA index_info('idx_deletion_jobs_list')")]
        plan = " ".join(
            r[3] for r in conn.execute(
                "EXPLAIN QUERY PLAN SELECT operation_uuid FROM deletion_jobs "
                "WHERE owner_id = ? AND (created_at, operation_uuid) > (?, ?) "
                "ORDER BY created_at, operation_uuid LIMIT 25",
                (1, 0, ""),
            )
        )
    finally:
        conn.close()
    assert columns == ["owner_id", "created_at", "operation_uuid"]
    assert "idx_deletion_jobs_list" in plan
    assert "TEMP B-TREE" not in plan


# --- deletion_job_items -----------------------------------------------------------------------

TRACK = "u-sam-1"  # a live track of user 1 in the rich fixture


def _item(conn, owner, uuid_id=TRACK, *, position=0, status="pending", operation=DELETION_OP,
          error_code=None, tombstone_revision=None, base_revision=5):
    conn.execute(
        "INSERT INTO deletion_job_items (owner_id, operation_uuid, uuid_id, position, "
        "base_revision, status, error_code, tombstone_revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (owner, operation, uuid_id, position, base_revision, status, error_code,
         tombstone_revision),
    )


@pytest.fixture
def job(v16):
    """User 1's accepted job (receipt + job row); yields an open connection."""
    conn = _connect(v16)
    _receipt(conn, 1)
    _job(conn, 1)
    yield conn
    conn.close()


def test_a_new_item_is_pending_not_cancelled_and_unleased(job):
    job.execute(
        "INSERT INTO deletion_job_items (owner_id, operation_uuid, uuid_id, position, base_revision) "
        "VALUES (1, ?, ?, 0, 5)", (DELETION_OP, TRACK),
    )
    row = job.execute(
        "SELECT status, cancel_requested, lease_boot_id, error_code, tombstone_revision, detail_json "
        "FROM deletion_job_items"
    ).fetchone()
    assert row == ("pending", 0, None, None, None, None)


@pytest.mark.parametrize(
    "status", ["pending", "running", "conflict", "busy"],
)
def test_the_non_terminal_and_refusal_outcomes_need_no_extra_field(job, status):
    _item(job, 1, status=status)


@pytest.mark.parametrize("status", ["deleted", "already_deleted"])
def test_a_deleted_outcome_records_its_tombstone_revision(job, status):
    with pytest.raises(sqlite3.IntegrityError):
        _item(job, 1, status=status)
    _item(job, 1, status=status, tombstone_revision=11)


def test_a_failed_outcome_records_its_error_code(job):
    with pytest.raises(sqlite3.IntegrityError):
        _item(job, 1, status="failed")
    _item(job, 1, status="failed", error_code="not_found")


@pytest.mark.parametrize("status", ["done", "cancelled", ""])
def test_an_unknown_item_status_is_refused(job, status):
    with pytest.raises(sqlite3.IntegrityError):
        _item(job, 1, status=status)


def test_an_item_belongs_to_its_owners_job(job):
    """The composite key makes an item of another user's job impossible."""
    with pytest.raises(sqlite3.IntegrityError):
        _item(job, 2)  # user 2 has no job under this operation uuid
    with pytest.raises(sqlite3.IntegrityError):
        _item(job, 1, operation="00000000-0000-4000-8000-0000000000ff")


def test_a_target_appears_once_per_job_and_positions_are_distinct(job):
    _item(job, 1, TRACK, position=0)
    with pytest.raises(sqlite3.IntegrityError):
        _item(job, 1, TRACK, position=1)  # the same target twice
    with pytest.raises(sqlite3.IntegrityError):
        _item(job, 1, "u-sam-2", position=0)  # the same position twice
    with pytest.raises(sqlite3.IntegrityError):
        _item(job, 1, "u-sam-2", position=-1)
    _item(job, 1, "u-sam-2", position=1)


def test_an_unknown_target_uuid_can_be_recorded(job):
    """A target the server does not know is a valid item (``failed:not_found``)."""
    _item(job, 1, "no-such-track", status="failed", error_code="not_found")


def test_a_job_with_items_cannot_be_deleted_under_them(job):
    _item(job, 1)
    with pytest.raises(sqlite3.IntegrityError):
        job.execute("DELETE FROM deletion_jobs")


# --- deletion_journal -------------------------------------------------------------------------


def _journal(conn, owner, uuid_id=TRACK, *, operation=DELETION_OP, stage="intent",
             master_missing=0, quarantine="/m/.deleting/1/op/u-sam-1.flac", dev=1, ino=2, size=3):
    conn.execute(
        "INSERT INTO deletion_journal (owner_id, operation_uuid, uuid_id, original_path, "
        "quarantine_path, base_revision, src_dev, src_ino, src_size, src_mtime_ns, "
        "master_missing, stage, created_at, updated_at) "
        "VALUES (?, ?, ?, '/m/sam/a.flac', ?, 5, ?, ?, ?, 4, ?, ?, 900, 900)",
        (owner, operation, uuid_id, quarantine, dev, ino, size, master_missing, stage),
    )


def test_a_journal_row_round_trips_with_unknown_identity_fields_null(job):
    _item(job, 1, status="running")
    _journal(job, 1)
    row = job.execute(
        "SELECT original_path, quarantine_path, base_revision, src_dev, src_ino, src_size, "
        "src_mtime_ns, exact_digest, cover_art_id, master_missing, stage "
        "FROM deletion_journal"
    ).fetchone()
    assert row == ("/m/sam/a.flac", "/m/.deleting/1/op/u-sam-1.flac", 5, 1, 2, 3, 4, None, None,
                   0, "intent")


def test_a_journal_row_needs_its_owners_job_item(job):
    with pytest.raises(sqlite3.IntegrityError):
        _journal(job, 1)  # no item yet
    _item(job, 1, status="running")
    with pytest.raises(sqlite3.IntegrityError):
        _journal(job, 2)  # same operation uuid and track, another owner


def test_a_track_has_at_most_one_journal_row(job):
    _item(job, 1, status="running")
    _journal(job, 1)
    other = "00000000-0000-4000-8000-0000000000d2"
    _receipt(job, 1, other)
    _job(job, 1, other)
    _item(job, 1, operation=other, status="running")
    with pytest.raises(sqlite3.IntegrityError):
        _journal(job, 1, operation=other)


@pytest.mark.parametrize("stage", ["intent", "moved", "committed"])
def test_the_journal_stages(job, stage):
    _item(job, 1, status="running")
    _journal(job, 1, stage=stage)


@pytest.mark.parametrize("stage", ["", "done", "recovery_required"])
def test_an_unknown_journal_stage_is_refused(job, stage):
    _item(job, 1, status="running")
    with pytest.raises(sqlite3.IntegrityError):
        _journal(job, 1, stage=stage)


@pytest.mark.parametrize("field", ["quarantine", "dev", "ino", "size"])
def test_a_present_master_records_its_quarantine_path_and_identity(job, field):
    _item(job, 1, status="running")
    with pytest.raises(sqlite3.IntegrityError):
        _journal(job, 1, **{field: None})


def test_a_missing_master_has_no_quarantine_path(job):
    _item(job, 1, status="running")
    with pytest.raises(sqlite3.IntegrityError):
        _journal(job, 1, master_missing=1)
    _journal(job, 1, master_missing=1, quarantine=None, dev=None, ino=None, size=None)


@pytest.mark.parametrize("value", [2, -1])
def test_master_missing_is_a_flag(job, value):
    _item(job, 1, status="running")
    with pytest.raises(sqlite3.IntegrityError):
        _journal(job, 1, master_missing=value, quarantine=None)


def test_an_item_cannot_be_deleted_under_its_journal(job):
    _item(job, 1, status="running")
    _journal(job, 1)
    with pytest.raises(sqlite3.IntegrityError):
        job.execute("DELETE FROM deletion_job_items")


# --- a journal row names one of its own owner's tracks (SC-28, "impossible by construction") --


def _journal_count(conn):
    return conn.execute("SELECT count(*) FROM deletion_journal").fetchone()[0]


def test_a_journal_row_for_another_users_track_is_refused(job):
    """User 1's job may name Alex's uuid (it answers ``failed:not_found``),
    but it can never mark Alex's track pending deletion."""
    _item(job, 1, "u-alex-1", status="running")
    with pytest.raises(sqlite3.IntegrityError):
        _journal(job, 1, "u-alex-1")
    assert _journal_count(job) == 0


def test_a_journal_row_for_an_unknown_uuid_is_refused(job):
    _item(job, 1, "no-such-track", status="running")
    with pytest.raises(sqlite3.IntegrityError):
        _journal(job, 1, "no-such-track")
    assert _journal_count(job) == 0


def test_a_journal_row_for_an_already_deleted_track_is_refused(v16):
    """The journal is written before the catalog delete; a tombstone alone
    (Alex's "Gone", u-alex-3) never gets one."""
    conn = _connect(v16)
    try:
        _receipt(conn, 2)
        _job(conn, 2)
        _item(conn, 2, "u-alex-3", status="running")
        with pytest.raises(sqlite3.IntegrityError):
            _journal(conn, 2, "u-alex-3")
        assert _journal_count(conn) == 0
    finally:
        conn.close()


def test_a_journal_row_for_the_owners_own_track_is_accepted_and_outlives_it(job):
    _item(job, 1, status="running")
    _journal(job, 1)
    # The catalog delete (step 4) runs while the journal row stays.
    job.execute("DELETE FROM track_duplicate_candidates WHERE uuid_a = ? OR uuid_b = ?",
                (TRACK, TRACK))
    job.execute("DELETE FROM trackmetadata WHERE uuid_id = ?", (TRACK,))
    job.execute("DELETE FROM tracks WHERE uuid_id = ?", (TRACK,))
    assert _journal_count(job) == 1


def test_a_journal_row_cannot_be_moved_to_another_track(job):
    _item(job, 1, status="running")
    _item(job, 1, "u-sam-2", position=1, status="running")
    _journal(job, 1)

    with pytest.raises(sqlite3.IntegrityError):
        job.execute("UPDATE deletion_journal SET uuid_id = 'u-sam-2'")
    job.execute("UPDATE deletion_journal SET stage = 'moved', updated_at = 901")
    assert job.execute("SELECT uuid_id, stage FROM deletion_journal").fetchall() == [
        (TRACK, "moved")
    ]


# --- live_tracks after the upgrade (D2) ---------------------------------------------------------


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_upgraded_view_keeps_its_columns_and_rows(tmp_path, version):
    """The view is re-created with the same column list; with no journal row
    every track is live, as before the upgrade."""
    path = tmp_path / "database.db"
    _rich(path, version)

    _open(path)

    conn = sqlite3.connect(path)
    try:
        columns = [row[1] for row in conn.execute("PRAGMA table_info(live_tracks)")]
        rows = sorted(conn.execute("SELECT * FROM live_tracks").fetchall())
    finally:
        conn.close()
    assert columns == ["id", "uuid_id", "owner_id", "file_path"]
    assert rows == [
        (11, "u-sam-1", 1, "/music/1/u-sam-1.flac"),
        (12, "u-sam-2", 1, "/music/1/u-sam-2.flac"),
        (21, "u-alex-1", 2, "/music/2/u-alex-1.flac"),
        (22, "u-alex-2", 2, "/music/2/u-alex-2.flac"),
    ]


def test_an_upgraded_view_hides_a_track_with_a_journal_row(v16):
    conn = _connect(v16)
    try:
        _receipt(conn, 1)
        _job(conn, 1)
        _item(conn, 1, status="running")
        _journal(conn, 1)
        conn.commit()
        live = [r[0] for r in conn.execute("SELECT uuid_id FROM live_tracks ORDER BY uuid_id")]
    finally:
        conn.close()
    assert live == ["u-alex-1", "u-alex-2", "u-sam-2"]
