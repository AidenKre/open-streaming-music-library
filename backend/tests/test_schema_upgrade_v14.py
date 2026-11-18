"""Phase 6.5A.1 (6.5-U01 as shrunk by plan D1/D2, DEV-6.5-01): the v13 -> v14
upgrade.

v14 is the first step of the schema ladder after Phase M's reset. Since
Phase 7A.1c (v15, see test_schema_upgrade_v15.py) a v13 file runs this step
and then 14 -> 15 in the same open, so these tests check the 13 -> 14 step's
own effects and expect the file to end at ``LATEST``. Every version outside
the window is refused by the read-only check before any write; the admin CLI
never migrates and tells the operator to start the server once.

The v13 files are real: the frozen ``fixtures/schema_v13.sql`` plus plain SQL,
opened through the production ``Database.initialize()``.
"""

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
    open_database,
    seed_two_user_library,
    user_version,
)

_PAST_NS = 1_000_000_000_000_000_000


def _database(path: Path) -> Database:
    return Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))


def _set_user_version(path: Path, version: int) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.execute(f"PRAGMA user_version = {version}")
        conn.commit()
    finally:
        conn.close()


def _snapshot(path: Path):
    os.utime(path, ns=(_PAST_NS, _PAST_NS))
    return path.read_bytes(), path.stat().st_mtime_ns, sorted(os.listdir(path.parent))


def _assert_untouched(path: Path, before) -> None:
    data, mtime, listing = before
    assert path.read_bytes() == data
    assert path.stat().st_mtime_ns == mtime
    assert sorted(os.listdir(path.parent)) == listing


def _schema(path: Path) -> list:
    conn = sqlite3.connect(path)
    try:
        return conn.execute(
            "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
        ).fetchall()
    finally:
        conn.close()


LATEST = Database.LATEST_SCHEMA_VERSION  # 15 since Phase 7A.1c


def test_a_fresh_database_lands_on_the_latest_version(tmp_path):
    path = tmp_path / "database.db"
    open_database(path)
    assert user_version(path) == LATEST


def test_a_v13_database_is_upgraded_and_keeps_its_instance_id(tmp_path):
    path = tmp_path / "database.db"
    make_legacy_database(path, 13)

    db = open_database(path)

    assert user_version(path) == LATEST
    assert db.get_server_instance_id() == "inst-v13"


def test_a_second_open_of_an_upgraded_database_changes_nothing(tmp_path):
    path = tmp_path / "database.db"
    make_legacy_database(path, 13)
    open_database(path)
    schema = _schema(path)

    open_database(path)

    assert _schema(path) == schema
    assert user_version(path) == LATEST


def test_the_step_rereads_the_version_inside_its_transaction(tmp_path, monkeypatch):
    """A version read before the write lock can be stale (another opener may
    have upgraded the file in between). The step trusts only the version it
    reads inside its own ``BEGIN IMMEDIATE``, so a stale 13 is a no-op."""
    path = tmp_path / "database.db"
    make_legacy_database(path, 13)
    open_database(path)
    schema = _schema(path)

    monkeypatch.setattr(Database, "_existing_schema_version", lambda self: 13)
    assert _database(path).initialize() is True

    assert _schema(path) == schema
    assert user_version(path) == LATEST


@pytest.mark.parametrize("version", [12, LATEST + 1])
def test_a_stale_read_never_lets_an_unsupported_file_through(tmp_path, monkeypatch, version):
    """Review 6.5A.1 #1: the re-read inside the transaction is the guard, so
    it fails closed when the file is outside the window after all."""
    path = tmp_path / "database.db"
    make_legacy_database(path, 13)
    _set_user_version(path, version)
    schema = _schema(path)

    monkeypatch.setattr(Database, "_existing_schema_version", lambda self: 13)
    with pytest.raises(SchemaVersionRefused):
        _database(path).initialize()

    assert user_version(path) == version
    assert _schema(path) == schema


def test_a_step_that_does_not_advance_the_version_fails_instead_of_looping(
    tmp_path, monkeypatch
):
    """Review 6.5A.1 #2: a ladder step that forgets to stamp its version must
    not spin while holding the write lock."""
    path = tmp_path / "database.db"
    make_legacy_database(path, 13)
    calls = []

    def forgetful_step(self, conn):
        calls.append(1)
        if len(calls) > 1:
            raise AssertionError("the step ran again instead of failing")

    monkeypatch.setattr(Database, "_migrate_13_to_14", forgetful_step)
    with pytest.raises(RuntimeError):
        _database(path).initialize()

    assert calls == [1]
    assert user_version(path) == 13


@pytest.mark.parametrize("version", [12, LATEST + 1])
def test_versions_outside_the_window_are_refused_untouched(tmp_path, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, 13)
    _set_user_version(path, version)
    before = _snapshot(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert f"schema {version}" in str(refused.value)
    _assert_untouched(path, before)


def test_the_cli_check_refuses_v13_untouched_and_says_to_start_the_server(tmp_path):
    path = tmp_path / "database.db"
    make_legacy_database(path, 13)
    before = _snapshot(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).require_current_schema()

    message = str(refused.value)
    assert "schema 13" in message
    assert "start the server once" in message.lower()
    assert "predates multi-user" not in message
    _assert_untouched(path, before)


def test_the_cli_check_accepts_the_latest_version_untouched(tmp_path):
    path = tmp_path / "database.db"
    make_legacy_database(path, 13)
    open_database(path)
    for suffix in ("-wal", "-shm"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)
    before = _snapshot(path)

    _database(path).require_current_schema()

    _assert_untouched(path, before)


# --- the 13 -> 14 step on a realistic two-user v13 file ---------------------------


def _open(path: Path) -> None:
    """Production initialization alone (``open_database`` also seeds a test
    owner, which would show up as a changed row)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    assert _database(path).initialize() is True


def _rich_v13(path: Path) -> None:
    """A v13 file as a Phase M server leaves it (``seed_two_user_library``)."""
    make_legacy_database(path, 13)
    conn = sqlite3.connect(path)
    try:
        seed_two_user_library(conn)
        conn.commit()
    finally:
        conn.close()


LIVE_UUIDS = {"u-sam-1", "u-sam-2", "u-alex-1", "u-alex-2"}


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
            r[0] for r in conn.execute(
                f"SELECT rowid FROM {table} WHERE {table} MATCH ?", (token,)
            )
        )
    finally:
        conn.close()


def test_the_upgrade_keeps_every_existing_row_byte_for_byte(tmp_path):
    """Ids, uuids, revisions, timestamps, FTS (shadow tables) and
    ``sqlite_sequence`` are unchanged; nothing is bumped."""
    path = tmp_path / "database.db"
    _rich_v13(path)
    before = _rows(path)

    _open(path)

    after = _rows(path, tables=list(before))
    assert after == before
    assert _fts(path, "fts_tracks", "lucky") == [11, 21]
    assert _fts(path, "fts_tracks", "gone") == []
    assert dict(before["sqlite_sequence"])["conversion_jobs"] == 3
    assert dict(before["sqlite_sequence"])["tracks"] == 23


def test_the_upgrade_seeds_one_pending_backfill_row_per_track(tmp_path):
    path = tmp_path / "database.db"
    _rich_v13(path)

    _open(path)

    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    try:
        rows = [dict(r) for r in conn.execute("SELECT * FROM track_audio_identity")]
    finally:
        conn.close()
    assert {r["uuid_id"] for r in rows} == LIVE_UUIDS
    for row in rows:
        assert row == {
            "uuid_id": row["uuid_id"],
            "generation": 0,
            "exact_state": "pending",
            "exact_kind": None,
            "exact_digest": None,
            "sample_rate_hz": None,
            "channels": None,
            "bits_per_sample": None,
            "fp_state": "pending",
            "fp_algorithm": None,
            "match_state": "pending",
            "matcher_version": None,
            "failure_reason": None,
            "attempts": 0,
            "next_attempt_at": None,
            "priority": 1,
            "stat_size": None,
            "stat_mtime_ns": None,
            "stat_inode": None,
            "computed_at": None,
            "tool_versions": None,
        }


def test_the_upgraded_file_is_consistent_and_verifies(tmp_path):
    path = tmp_path / "database.db"
    _rich_v13(path)

    _open(path)

    conn = sqlite3.connect(path)
    try:
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []
        assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert registry.verify(conn) == []
    finally:
        conn.close()


def test_a_second_open_of_a_rich_upgraded_file_changes_no_row(tmp_path):
    path = tmp_path / "database.db"
    _rich_v13(path)
    _open(path)
    rows, schema = _rows(path), _schema(path)

    _open(path)

    assert _rows(path) == rows
    assert _schema(path) == schema


def _normalized_schema(path: Path) -> set:
    conn = sqlite3.connect(path)
    try:
        return {
            (kind, name, table, " ".join(sql.split()) if sql else None)
            for kind, name, table, sql in conn.execute(
                "SELECT type, name, tbl_name, sql FROM sqlite_master"
            )
        }
    finally:
        conn.close()


def test_a_fresh_schema_equals_one_migrated_from_v13(tmp_path):
    fresh = tmp_path / "fresh" / "database.db"
    migrated = tmp_path / "migrated" / "database.db"
    _open(fresh)
    _rich_v13(migrated)
    _open(migrated)

    assert _normalized_schema(fresh) == _normalized_schema(migrated)


def _deny_inserts_into(table: str):
    """A connection factory whose authorizer refuses INSERTs into ``table``:
    the step's seeding fails after its DDL already ran."""
    real_connect = sqlite3.connect

    def connect(*args, **kwargs):
        conn = real_connect(*args, **kwargs)

        def authorizer(action, arg1, *_):
            if action == sqlite3.SQLITE_INSERT and arg1 == table:
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK

        conn.set_authorizer(authorizer)
        return conn

    return connect


def test_a_failure_mid_step_rolls_everything_back(tmp_path, monkeypatch):
    path = tmp_path / "database.db"
    _rich_v13(path)
    rows, schema = _rows(path), _schema(path)

    with monkeypatch.context() as patch:
        patch.setattr(sqlite3, "connect", _deny_inserts_into("track_audio_identity"))
        with pytest.raises(sqlite3.DatabaseError):
            _database(path).initialize()

    assert user_version(path) == 13
    assert _schema(path) == schema  # no partial table, index or view
    assert _rows(path) == rows

    _open(path)  # the next start upgrades it
    assert user_version(path) == LATEST


def test_live_tracks_exposes_every_track_with_its_owner_after_the_upgrade(tmp_path):
    """6.5 spec §5 "Liveness" (6.5-U11): one view defines which tracks can be
    matched or listed; today that is every ``tracks`` row, with its owner."""
    path = tmp_path / "database.db"
    _rich_v13(path)

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


def test_server_startup_upgrades_a_v13_data_dir(tmp_path, configure_app):
    """The upgrade runs inside the real startup, under the instance lock."""
    path = tmp_path / "data" / "database" / "database.db"
    make_legacy_database(path, 13)
    main = configure_app()

    with TestClient(main.app):
        assert user_version(path) == LATEST

    conn = sqlite3.connect(path)
    try:
        assert registry.verify(conn) == []
    finally:
        conn.close()
