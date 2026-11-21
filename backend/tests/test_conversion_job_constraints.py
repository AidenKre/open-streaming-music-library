"""What the schema itself refuses in ``conversion_jobs``, whatever the code does.

``insert_conversion_job`` already refuses a second queued or running job for a
track inside its own transaction, and the code writes only the five statuses of
``ConversionJobStatus``. The table says both too, so a row written any other way
(a later writer, a repair by hand) cannot break them. Rows are written here
with plain SQL on a database the product's own initialisation made.
"""

import re
import sqlite3

import pytest

from app.services.conversion import ConversionJobStatus

INSERT = (
    "INSERT INTO conversion_jobs (uuid_id, target_codec, target_container, status, owner_id) "
    "VALUES (?, 'aac', 'm4a', ?, ?)"
)


@pytest.fixture
def conn(db):
    connection = sqlite3.connect(db.context.database_path)
    connection.execute("PRAGMA foreign_keys=ON")
    yield connection
    connection.close()


def _insert(conn, db, uuid_id, status):
    conn.execute(INSERT, (uuid_id, status, db.owner_id))


@pytest.mark.parametrize("status", [s.value for s in ConversionJobStatus])
def test_each_status_the_code_writes_is_accepted(conn, db, status):
    _insert(conn, db, "u1", status)

    assert conn.execute("SELECT status FROM conversion_jobs").fetchall() == [(status,)]


@pytest.mark.parametrize("status", ["", "paused", "Queued", "done "])
def test_any_other_status_is_refused(conn, db, status):
    with pytest.raises(sqlite3.IntegrityError):
        _insert(conn, db, "u1", status)


def test_a_status_cannot_be_changed_to_an_unknown_one(conn, db):
    _insert(conn, db, "u1", "queued")

    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("UPDATE conversion_jobs SET status = 'stuck'")


def test_the_statuses_of_the_code_are_the_statuses_of_the_table(conn):
    """Both ways: a status added on one side only fails here."""
    [(table_sql,)] = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'conversion_jobs'"
    ).fetchall()
    [listed] = re.findall(r'CHECK\s*\(\s*"?status"?\s+IN\s*\(([^)]*)\)\s*\)', table_sql)

    assert sorted(re.findall(r"'([^']*)'", listed)) == sorted(s.value for s in ConversionJobStatus)


@pytest.mark.parametrize("first", ["queued", "running"])
@pytest.mark.parametrize("second", ["queued", "running"])
def test_a_track_has_at_most_one_queued_or_running_job(conn, db, first, second):
    _insert(conn, db, "u1", first)

    with pytest.raises(sqlite3.IntegrityError):
        _insert(conn, db, "u1", second)


def test_a_finished_job_cannot_become_active_beside_an_active_one(conn, db):
    _insert(conn, db, "u1", "failed")
    _insert(conn, db, "u1", "queued")

    with pytest.raises(sqlite3.IntegrityError):
        conn.execute("UPDATE conversion_jobs SET status = 'running' WHERE status = 'failed'")


def test_finished_jobs_and_other_tracks_jobs_do_not_count(conn, db):
    for status in ("done", "failed", "cancelled", "done", "queued"):
        _insert(conn, db, "u1", status)
    _insert(conn, db, "u2", "running")

    assert conn.execute("SELECT COUNT(*) FROM conversion_jobs").fetchone() == (6,)
