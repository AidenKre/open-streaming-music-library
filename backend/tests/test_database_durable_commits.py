"""Every connection the server opens commits durably.

The owner's decision of 2026-11-20, after measuring what a flush costs:
"hold one idle connection open and flush every commit". Before it, a commit only wrote to the
write-ahead log and asked the disk for nothing (``synchronous`` at SQLite's
default for WAL mode); the write reached the disk at a later checkpoint.

What these tests show: the two settings SQLite needs for a commit that is on
disk when it returns are in force on every connection the product opens, at
the moment a real product write commits, and on the durable point's own
connection:

- ``synchronous=FULL`` (2): the log is synced before the commit returns;
- ``fullfsync=ON`` (1): on macOS that sync is ``F_FULLFSYNC``, which flushes
  the drive's own cache (a plain ``fsync`` does not there). Linux has no such
  call: the flag is stored and changes nothing, and the sync is ``fsync``.

What they cannot show: that the drive kept the bytes through a power cut. No
test cuts the power, and SQLite's own sync calls are made in C, out of a
test's reach.

They carry ``real_sqlite_durability``: an ordinary test runs with
``synchronous=OFF`` (``tests/conftest.py``; pinned in
``tests/test_sqlite_test_durability.py``).
"""

import sqlite3

import pytest

from tests.database_fixtures import plain_database

FULL = 2
DURABLE = {"journal_mode": "wal", "synchronous": FULL, "fullfsync": 1}

# Every way the product asks for a connection (``DatabaseCore._connection``).
FORMS = {
    "a read": {},
    "a write": {"commit": True},
    "a write that takes the lock first": {"commit": True, "immediate": True},
    "the durable point's (no wait)": {"timeout": 0},
}


def _settings(execute) -> dict:
    return {name: execute(f"PRAGMA {name}").fetchone()[0] for name in DURABLE}


@pytest.mark.real_sqlite_durability
@pytest.mark.parametrize("form", list(FORMS))
def test_every_product_connection_flushes_its_commits_to_the_disk(tmp_path, form):
    db = plain_database(tmp_path)

    with db._connection(**FORMS[form]) as conn:
        assert _settings(conn.execute) == DURABLE


class _CommitRecorder(sqlite3.Connection):
    """Records the connection's own settings at the moment it commits."""

    seen: list = []

    def commit(self):
        _CommitRecorder.seen.append(_settings(super().execute))
        return super().commit()


@pytest.mark.real_sqlite_durability
def test_a_product_write_commits_with_those_settings(tmp_path, monkeypatch):
    """Through a public method, at the commit itself: nothing between the
    connection's set-up and its commit switched the settings back."""
    db = plain_database(tmp_path)
    real_connect = sqlite3.connect
    _CommitRecorder.seen = []

    def connect(*args, **kwargs):
        kwargs.setdefault("factory", _CommitRecorder)
        return real_connect(*args, **kwargs)

    monkeypatch.setattr(sqlite3, "connect", connect)
    db.set_setting("durable-commit-probe", "1")

    assert _CommitRecorder.seen == [DURABLE]
    assert db.read_setting("durable-commit-probe") == "1"


def test_an_ordinary_test_runs_the_same_code_without_syncing(tmp_path):
    """The other side: the test process's opt-out still wins over the product's
    own setting, so the suite does not sync to disk."""
    db = plain_database(tmp_path)

    with db._connection(commit=True, immediate=True) as conn:
        assert conn.execute("PRAGMA synchronous").fetchone()[0] == 0


# ── the two connections opened outside ``DatabaseCore._connection`` ─────────


class _CloseRecorder(sqlite3.Connection):
    """Records the connection's own settings when it is closed (the purge and
    the table rebuild open and close their connections inside one call)."""

    seen: list = []

    def close(self):
        try:
            _CloseRecorder.seen.append(_settings(super().execute))
        except sqlite3.ProgrammingError:
            pass  # already closed
        return super().close()


def _record_closes(monkeypatch) -> list:
    real_connect = sqlite3.connect
    _CloseRecorder.seen = []

    def connect(*args, **kwargs):
        kwargs.setdefault("factory", _CloseRecorder)
        return real_connect(*args, **kwargs)

    monkeypatch.setattr(sqlite3, "connect", connect)
    return _CloseRecorder.seen


@pytest.mark.real_sqlite_durability
def test_the_lastfm_purge_deletes_and_compacts_on_durable_connections(tmp_path, monkeypatch):
    """The purge deletes on one connection and compacts the files (``VACUUM``,
    then the log truncated) on a second one of its own."""
    db = plain_database(tmp_path)
    seen = _record_closes(monkeypatch)

    assert db.purge_lastfm_data() == (0, 0)

    assert seen == [DURABLE, DURABLE]


@pytest.mark.real_sqlite_durability
def test_a_table_rebuild_and_its_backup_copy_are_written_on_durable_connections(
    tmp_path, monkeypatch
):
    from app.database.table_rebuild import rebuild_tables

    path = tmp_path / "rebuild.sqlite"
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE kept (id INTEGER PRIMARY KEY)")
    conn.execute("PRAGMA user_version = 1")
    conn.commit()
    conn.close()
    seen = _record_closes(monkeypatch)

    migrated = rebuild_tables(
        path,
        target_version=2,
        rebuild=lambda conn: conn.execute("CREATE TABLE added (id INTEGER PRIMARY KEY)"),
        backup_path=tmp_path / "backup.sqlite",
    )

    assert migrated is True
    # The backup copy's connection, then the rebuild's. The backup is a file of
    # its own, written on a plain connection with the same flush settings (so
    # no log and no side files are made for it; ``test_table_rebuild.py``). Its
    # journal mode is not asked here: once the copy is complete the file is a
    # copy of a WAL database and reports that.
    backup, rebuild = seen
    assert rebuild == DURABLE
    assert (backup["synchronous"], backup["fullfsync"]) == (FULL, 1)


# ── the log is cut back after a checkpoint ──────────────────────────────────


def _log_limit_and_checkpoint_size(execute) -> tuple[int, int]:
    """The connection's ``journal_size_limit`` and the size of the log at which
    SQLite's automatic checkpoint runs (``wal_autocheckpoint`` pages)."""
    limit = execute("PRAGMA journal_size_limit").fetchone()[0]
    pages = execute("PRAGMA wal_autocheckpoint").fetchone()[0]
    page_size = execute("PRAGMA page_size").fetchone()[0]
    return limit, pages * page_size


@pytest.mark.parametrize("form", list(FORMS))
def test_every_product_connection_cuts_the_log_back_well_above_the_automatic_checkpoint(
    tmp_path, form
):
    """While the server holds a connection open the log is never deleted, so
    without a limit it keeps its largest size until the server stops. The limit
    is set (not -1, "keep it") and lies comfortably above the size at which the
    automatic checkpoint runs, so an ordinary log is never cut and grown again."""
    db = plain_database(tmp_path)

    with db._connection(**FORMS[form]) as conn:
        limit, checkpoint_size = _log_limit_and_checkpoint_size(conn.execute)

    assert limit >= 2 * checkpoint_size > 0
