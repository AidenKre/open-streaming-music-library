"""The place for future schema steps.

``init.sql`` is the whole schema and ``Database._schema_steps()`` returns no
step, so today nothing is ever upgraded. The code that will run the first
real step stays in ``Database._migrate``: one write transaction for the whole
run, the version re-read inside it, "a step must advance the version", "the
steps must reach the latest version", and the operator's log line.

These tests keep that code working. They raise ``LATEST_SCHEMA_VERSION`` and
replace ``_schema_steps`` with fake steps, counted from the version
``init.sql`` creates, so they hold whatever the real latest version is.

A real step, once one exists, also gets tests that upgrade a real file of the
version before it; these stay as they are.
"""

import logging
import os
import sqlite3
import uuid
from pathlib import Path

import pytest

from app.database.database import Database, DatabaseContext, SchemaVersionRefused
from tests.schema_fixtures import (
    INIT_SQL,
    PRE_RESET_VERSION,
    make_two_user_database,
    user_version,
)

OPERATOR = "uvicorn.error"  # app.core.operator_log.operator_logger
BASE = Database.LATEST_SCHEMA_VERSION  # the version init.sql creates
_PAST_NS = 1_000_000_000_000_000_000


class _StepFailed(Exception):
    pass


def _database(path: Path) -> Database:
    return Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))


def _use_steps(monkeypatch, latest: int, steps: dict) -> None:
    """Pretend the server is at schema ``latest`` with these steps."""
    monkeypatch.setattr(Database, "LATEST_SCHEMA_VERSION", latest)
    monkeypatch.setattr(Database, "_schema_steps", lambda self: steps)


def _adds_table(name: str, to_version: int, calls: list | None = None):
    """A step as a real one would be written: it creates a table, fills it,
    changes an existing row and stamps its version."""

    def step(conn):
        if calls is not None:
            calls.append(name)
        conn.execute(f"CREATE TABLE {name} (id INTEGER PRIMARY KEY)")
        conn.execute(f"INSERT INTO {name} (id) VALUES (1)")
        conn.execute("UPDATE revision_counter SET value = value + 100")
        conn.execute(f"PRAGMA user_version = {to_version}")

    return step


def _schema(path: Path) -> list:
    conn = sqlite3.connect(path)
    try:
        return conn.execute(
            "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
        ).fetchall()
    finally:
        conn.close()


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


def _set_user_version(path: Path, version: int) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.execute(f"PRAGMA user_version = {version}")
        conn.commit()
    finally:
        conn.close()


def _schema_lines(caplog) -> list:
    """The operator's schema lines logged since the test's last ``caplog.clear()``
    (each test clears at the start of the block it checks, so a line an earlier
    open logged never counts, at whatever level the logger was then)."""
    return [
        r.getMessage() for r in caplog.records
        if r.name == OPERATOR and "schema" in r.getMessage()
    ]


@pytest.fixture
def path(tmp_path):
    """A database at today's schema holding two users' libraries. Its folder
    name would be private in a log line."""
    path = tmp_path / "Private Library" / "database.db"
    make_two_user_database(path)
    return path


# --- a step upgrades a file ---------------------------------------------------------------------


def test_a_step_upgrades_a_file_in_one_open_and_keeps_what_it_held(path, monkeypatch, caplog):
    instance_id = _database(path).get_server_instance_id()
    before = _rows(path)
    del before["revision_counter"]  # the step changes it, see below
    _use_steps(monkeypatch, BASE + 1, {BASE: _adds_table("step_one", BASE + 1)})

    with caplog.at_level(logging.INFO, logger=OPERATOR):
        caplog.clear()  # only this block's lines, whatever was logged before it
        db = _database(path)
        assert db.initialize() is True

    assert user_version(path) == BASE + 1
    after = _rows(path)
    assert after["step_one"] == [(1,)]
    assert after["revision_counter"] == [(0, 110)]  # the seeded 10, plus the step's 100
    assert {t: after[t] for t in before} == before
    assert db.get_server_instance_id() == instance_id
    conn = sqlite3.connect(path)
    try:
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []
        assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    finally:
        conn.close()
    # Logged once, with both versions; the line is exactly this, so it has no path.
    assert _schema_lines(caplog) == [f"database schema upgraded from {BASE} to {BASE + 1}"]


def test_several_steps_run_in_one_open_and_are_logged_as_one_upgrade(path, monkeypatch, caplog):
    calls = []
    _use_steps(monkeypatch, BASE + 2, {
        BASE: _adds_table("step_one", BASE + 1, calls),
        BASE + 1: _adds_table("step_two", BASE + 2, calls),
    })

    with caplog.at_level(logging.INFO, logger=OPERATOR):
        caplog.clear()  # only this block's lines, whatever was logged before it
        assert _database(path).initialize() is True

    assert calls == ["step_one", "step_two"]
    assert user_version(path) == BASE + 2
    assert _rows(path, ["step_one", "step_two"]) == {"step_one": [(1,)], "step_two": [(1,)]}
    assert _schema_lines(caplog) == [f"database schema upgraded from {BASE} to {BASE + 2}"]


def test_a_second_open_after_a_step_changes_nothing(path, monkeypatch, caplog):
    calls = []
    _use_steps(monkeypatch, BASE + 1, {BASE: _adds_table("step_one", BASE + 1, calls)})
    assert _database(path).initialize() is True
    schema, rows = _schema(path), _rows(path)

    with caplog.at_level(logging.INFO, logger=OPERATOR):
        caplog.clear()  # only this block's lines, whatever was logged before it
        assert _database(path).initialize() is True

    assert calls == ["step_one"]  # not run again
    assert _schema(path) == schema
    assert _rows(path) == rows
    assert user_version(path) == BASE + 1
    assert _schema_lines(caplog) == []


def test_the_admin_tool_check_never_runs_a_step(path, monkeypatch):
    """``require_current_schema`` refuses a file one step behind and leaves
    its bytes, its modification time and its folder as they were."""
    calls = []
    for suffix in ("-wal", "-shm"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)
    os.utime(path, ns=(_PAST_NS, _PAST_NS))
    data, mtime, listing = path.read_bytes(), path.stat().st_mtime_ns, sorted(os.listdir(path.parent))
    _use_steps(monkeypatch, BASE + 1, {BASE: _adds_table("step_one", BASE + 1, calls)})

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).require_current_schema()

    assert refused.value.found_version == BASE
    # It says what a file one step behind is told, with this server's numbers
    # (the words themselves are pinned in test_schema_refusal.py).
    assert str(refused.value) == str(
        SchemaVersionRefused(BASE, BASE + 1, Database.MINIMUM_SCHEMA_VERSION)
    )
    assert calls == []
    assert path.read_bytes() == data
    assert path.stat().st_mtime_ns == mtime
    assert sorted(os.listdir(path.parent)) == listing


@pytest.mark.parametrize("stale_read", [False, True], ids=["outer-check", "re-read"])
def test_a_refusal_at_start_names_this_servers_latest_and_minimum_version(
    path, monkeypatch, stale_read
):
    """While the latest and the minimum version are the same number, mixing
    them up in a refusal changes nothing. On a server with a step they differ,
    so both refusals of ``initialize`` are checked here: the read-only check,
    and the re-read inside the write transaction."""
    _set_user_version(path, BASE + 2)
    _use_steps(monkeypatch, BASE + 1, {BASE: _adds_table("step_one", BASE + 1)})
    if stale_read:
        monkeypatch.setattr(Database, "_existing_schema_version", lambda self: BASE)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert str(refused.value) == str(
        SchemaVersionRefused(BASE + 2, BASE + 1, Database.MINIMUM_SCHEMA_VERSION)
    )
    assert user_version(path) == BASE + 2


def test_an_open_gives_a_file_without_an_instance_id_one_and_keeps_it(path):
    """The run that upgrades a file also makes sure it has an instance id."""
    conn = sqlite3.connect(path)
    try:
        conn.execute("DELETE FROM app_settings WHERE key = 'server_instance_id'")
        conn.commit()
    finally:
        conn.close()

    db = _database(path)
    assert db.initialize() is True
    instance_id = db.get_server_instance_id()

    assert uuid.UUID(instance_id).version == 4
    assert _database(path).initialize() is True
    assert _database(path).get_server_instance_id() == instance_id


# --- a step that fails ----------------------------------------------------------------------------


def test_a_step_that_fails_half_way_rolls_back_every_step_of_the_run(path, monkeypatch, caplog):
    """All steps of one open share one transaction: when the second step
    fails after its own first statements, the first step is undone too."""
    schema, rows = _schema(path), _rows(path)

    def fails_half_way(conn):
        conn.execute("CREATE TABLE step_two (id INTEGER PRIMARY KEY)")
        conn.execute("DROP VIEW live_tracks")
        conn.execute("CREATE VIEW live_tracks AS SELECT id FROM tracks")
        conn.execute("DELETE FROM trackmetadata")
        raise _StepFailed("half-way")

    _use_steps(monkeypatch, BASE + 2, {
        BASE: _adds_table("step_one", BASE + 1),
        BASE + 1: fails_half_way,
    })

    with caplog.at_level(logging.INFO, logger=OPERATOR):
        caplog.clear()  # only this block's lines, whatever was logged before it
        with pytest.raises(_StepFailed):
            _database(path).initialize()

    assert user_version(path) == BASE  # not BASE + 1
    assert _schema(path) == schema  # neither step's table, and the old view
    assert _rows(path) == rows
    assert _schema_lines(caplog) == []

    # The next start, with a working second step, upgrades the file.
    _use_steps(monkeypatch, BASE + 2, {
        BASE: _adds_table("step_one", BASE + 1),
        BASE + 1: _adds_table("step_two", BASE + 2),
    })
    assert _database(path).initialize() is True
    assert user_version(path) == BASE + 2


@pytest.mark.parametrize("stamps", [None, BASE, BASE - 1], ids=["nothing", "same", "lower"])
def test_a_step_that_does_not_advance_the_version_fails_instead_of_looping(
    path, monkeypatch, stamps
):
    """A step that forgets to stamp its version (or stamps one that is not
    higher) must not spin while holding the write lock."""
    schema, rows = _schema(path), _rows(path)
    calls = []

    def forgetful(conn):
        calls.append(1)
        if len(calls) > 1:
            raise AssertionError("the step ran again instead of failing")
        conn.execute("CREATE TABLE step_one (id INTEGER PRIMARY KEY)")
        if stamps is not None:
            conn.execute(f"PRAGMA user_version = {stamps}")

    _use_steps(monkeypatch, BASE + 1, {BASE: forgetful})

    with pytest.raises(RuntimeError, match="did not advance"):
        _database(path).initialize()

    assert calls == [1]
    assert user_version(path) == BASE
    assert _schema(path) == schema
    assert _rows(path) == rows


# --- steps that stop short of the latest version (U03-B-03) ---------------------------------------


def test_a_bumped_version_with_no_step_leaves_the_file_at_its_version(path, monkeypatch):
    """The version was raised and the step was never added: with the real
    step table, the upgrade fails inside its transaction."""
    schema = _schema(path)
    monkeypatch.setattr(Database, "LATEST_SCHEMA_VERSION", BASE + 1)

    with pytest.raises(RuntimeError, match=f"stop at schema {BASE}"):
        _database(path).initialize()

    assert user_version(path) == BASE
    assert _schema(path) == schema


def test_steps_that_stop_short_roll_back_the_steps_they_ran(path, monkeypatch):
    schema, rows = _schema(path), _rows(path)
    calls = []
    _use_steps(monkeypatch, BASE + 2, {BASE: _adds_table("step_one", BASE + 1, calls)})

    with pytest.raises(RuntimeError, match=f"stop at schema {BASE + 1}"):
        _database(path).initialize()

    assert calls == ["step_one"]  # it ran, and was undone
    assert user_version(path) == BASE
    assert _schema(path) == schema
    assert _rows(path) == rows


# --- the version read before the write lock may be stale ----------------------------------------


def test_a_stale_outer_read_is_a_no_op_on_a_file_that_was_upgraded_meanwhile(path, monkeypatch):
    """Another opener may upgrade the file between the read-only check and the
    write lock. The run trusts only the version it reads inside its own
    ``BEGIN IMMEDIATE``, so a stale "one step behind" runs no step."""
    calls = []
    _use_steps(monkeypatch, BASE + 1, {BASE: _adds_table("step_one", BASE + 1, calls)})
    assert _database(path).initialize() is True
    schema, rows = _schema(path), _rows(path)

    monkeypatch.setattr(Database, "_existing_schema_version", lambda self: BASE)
    assert _database(path).initialize() is True

    assert calls == ["step_one"]  # once, by the first open
    assert _schema(path) == schema
    assert _rows(path) == rows
    assert user_version(path) == BASE + 1


# Below the window, above it, and the last version before the reset.
OUTSIDE_THE_WINDOW = sorted({Database.MINIMUM_SCHEMA_VERSION - 1, BASE + 1, PRE_RESET_VERSION})


@pytest.mark.parametrize("version", OUTSIDE_THE_WINDOW)
def test_a_stale_outer_read_never_lets_a_file_of_another_version_through(
    path, monkeypatch, version
):
    """The re-read inside the transaction is the guard: it fails closed when
    the file turns out to be at a version this server does not open. No fake
    step here: this is the server as it is."""
    _set_user_version(path, version)
    schema, rows = _schema(path), _rows(path)

    monkeypatch.setattr(Database, "_existing_schema_version", lambda self: BASE)
    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert refused.value.found_version == version
    assert user_version(path) == version
    assert _schema(path) == schema
    assert _rows(path) == rows
