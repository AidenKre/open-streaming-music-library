"""The deletion tables: ``deletion_jobs``, ``deletion_job_items`` and
``deletion_journal``, and the pending-deletion marker on ``live_tracks``.

Jobs are keyed (owner_id, operation_uuid) like their receipt; an item belongs
to its owner's job; a journal row names one of its own owner's tracks and
hides that track from ``live_tracks``.

The database is created fresh by production initialization and then holds two
users' libraries in plain SQL (tracks, FTS, an edit journal, identity rows,
candidate pairs, upload rows and receipts).
"""

import sqlite3
from pathlib import Path

import pytest

from tests.schema_fixtures import make_two_user_database


def _connect(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


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


@pytest.fixture
def fresh(tmp_path):
    """A fresh database holding two users' libraries (users 1 and 2)."""
    path = tmp_path / "database.db"
    make_two_user_database(path)
    conn = _connect(path)
    try:
        _seed_identity_rows(conn)
        _seed_upload_rows(conn)
        conn.commit()
    finally:
        conn.close()
    return path


# --- deletion_jobs ----------------------------------------------------------------------------

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


def test_two_users_may_hold_a_job_under_the_same_operation_uuid(fresh):
    """Keyed (owner_id, operation_uuid) like its receipt (DEV-7-01)."""
    conn = _connect(fresh)
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


def test_a_job_needs_its_own_owners_receipt(fresh):
    conn = _connect(fresh)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _job(conn, 1)  # no receipt at all
        _receipt(conn, 2)
        with pytest.raises(sqlite3.IntegrityError):
            _job(conn, 1)  # the receipt is another user's
    finally:
        conn.close()


@pytest.mark.parametrize("column,value", [("owner_id", None), ("created_at", None), ("status", None)])
def test_a_job_requires_its_owner_time_and_status(fresh, column, value):
    conn = _connect(fresh)
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
def test_a_job_status_is_accepted_or_completed(fresh, status, ok):
    conn = _connect(fresh)
    try:
        _receipt(conn, 1)
        if ok:
            _job(conn, 1, status=status)
        else:
            with pytest.raises(sqlite3.IntegrityError):
                _job(conn, 1, status=status)
    finally:
        conn.close()


def test_the_receipts_page_seeks_through_the_keyset_index(fresh):
    """``GET /tracks/deletions`` pages by (created_at, operation_uuid) per owner."""
    conn = sqlite3.connect(fresh)
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
def job(fresh):
    """User 1's accepted job (receipt + job row); yields an open connection."""
    conn = _connect(fresh)
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
        "quarantine_path, base_revision, src_dev, src_ino, src_size, "
        "master_missing, stage, created_at, updated_at) "
        "VALUES (?, ?, ?, '/m/sam/a.flac', ?, 5, ?, ?, ?, ?, ?, 900, 900)",
        (owner, operation, uuid_id, quarantine, dev, ino, size, master_missing, stage),
    )


def test_a_journal_row_round_trips_with_unknown_identity_fields_null(job):
    _item(job, 1, status="running")
    _journal(job, 1)
    row = job.execute(
        "SELECT original_path, quarantine_path, base_revision, src_dev, src_ino, src_size, "
        "cover_art_id, master_missing, stage "
        "FROM deletion_journal"
    ).fetchone()
    assert row == ("/m/sam/a.flac", "/m/.deleting/1/op/u-sam-1.flac", 5, 1, 2, 3, None,
                   0, "intent")


def test_the_journal_keeps_no_content_hash(job):
    # Pre-merge B1-03: the deletion proves the file by device, inode and size
    # (DEV-8-15); nothing ever wrote or read a digest.
    columns = {row[1] for row in job.execute("PRAGMA table_info(deletion_journal)")}
    assert "exact_digest" not in columns


def test_the_journal_keeps_no_modification_time(job):
    # Pre-merge B1-03, second half: the proof is device, inode and size
    # (DEV-8-15); the modification time was written and never read.
    columns = {row[1] for row in job.execute("PRAGMA table_info(deletion_journal)")}
    assert "src_mtime_ns" not in columns
    assert {"src_dev", "src_ino", "src_size"} <= columns


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


def test_a_journal_row_for_an_already_deleted_track_is_refused(fresh):
    """The journal is written before the catalog delete; a tombstone alone
    (Alex's "Gone", u-alex-3) never gets one."""
    conn = _connect(fresh)
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


# --- live_tracks ------------------------------------------------------------------------------


def test_the_view_hides_a_track_with_a_journal_row(fresh):
    conn = _connect(fresh)
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
