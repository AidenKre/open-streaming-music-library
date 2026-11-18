"""Phase M.0a (M-U04): the v13 account tables.

``users`` (one master admin at most, unique ``username_key`` and
``library_folder``), ``user_settings`` keyed by ``(user_id, key)`` and
``auth_sessions`` (both token hashes unique, used from M.1). Each references
``users`` with foreign keys enforced.
"""

import sqlite3

import pytest

from app.database.database import Database
from tests.schema_fixtures import open_database


@pytest.fixture
def conn(tmp_path):
    path = tmp_path / "database.db"
    open_database(path)
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA foreign_keys=ON")
    yield conn
    conn.close()


def _user(conn, username="Sam", *, key=None, folder=None, admin=0, master=0):
    return conn.execute(
        "INSERT INTO users (username, username_key, password_hash, is_admin, "
        "is_master_admin, library_folder, created_at) VALUES (?, ?, 'h', ?, ?, ?, 1)",
        (username, key or username.lower(), admin, master, folder or username.lower()),
    ).lastrowid


def test_schema_version_is_17():
    assert Database.LATEST_SCHEMA_VERSION == 17


def test_a_user_row_round_trips_with_unknown_timestamps_null(conn):
    uid = _user(conn, "Sam")
    row = conn.execute(
        "SELECT username, username_key, is_admin, is_master_admin, library_folder, "
        "disabled_at, deleting_at FROM users WHERE id = ?",
        (uid,),
    ).fetchone()
    assert row == ("Sam", "sam", 0, 0, "sam", None, None)


def test_only_one_master_admin(conn):
    _user(conn, "Admin", admin=1, master=1)
    _user(conn, "Other", admin=1, master=0)  # a plain admin is fine
    with pytest.raises(sqlite3.IntegrityError):
        _user(conn, "Second", admin=1, master=1)


def test_username_key_and_library_folder_are_unique(conn):
    _user(conn, "Sam", key="sam", folder="sam")
    with pytest.raises(sqlite3.IntegrityError):
        _user(conn, "SAM", key="sam", folder="sam-2")
    with pytest.raises(sqlite3.IntegrityError):
        _user(conn, "Alex", key="alex", folder="sam")


@pytest.mark.parametrize("column", ["is_admin", "is_master_admin"])
def test_flags_are_booleans(conn, column):
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            f"INSERT INTO users (username, username_key, password_hash, {column}, "
            "library_folder, created_at) VALUES ('a', 'a', 'h', 2, 'a', 1)"
        )


def test_user_settings_are_keyed_per_user_and_need_a_user(conn):
    sam, alex = _user(conn, "Sam"), _user(conn, "Alex")
    insert = "INSERT INTO user_settings (user_id, key, value) VALUES (?, ?, ?)"
    conn.execute(insert, (sam, "default_streaming_quality", "320"))
    conn.execute(insert, (alex, "default_streaming_quality", "original"))
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(insert, (sam, "default_streaming_quality", "128"))
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(insert, (999, "k", "v"))


def test_auth_sessions_hashes_are_unique_and_need_a_user(conn):
    sam = _user(conn, "Sam")
    insert = (
        "INSERT INTO auth_sessions (token_hash, media_hash, user_id, created_at) "
        "VALUES (?, ?, ?, 1)"
    )
    conn.execute(insert, ("t1", "m1", sam))
    assert conn.execute(
        "SELECT revoked_at FROM auth_sessions WHERE token_hash = 't1'"
    ).fetchone() == (None,)
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(insert, ("t1", "m2", sam))
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(insert, ("t2", "m1", sam))
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(insert, ("t3", "m3", 999))
