"""One idle connection held open on a ``Database``.

Each database call opens its own connection and closes it. When the closed
connection was the only one open, SQLite checkpoints the write-ahead log and
deletes it, and the next write starts a new one: 3 to 5 ms per write
(measured on 2026-11-20). ``Database.hold_open()`` keeps one idle
connection open so that no call's close is the last one; ``Database.close()``
closes it, and that close, now the last, checkpoints.

The rules pinned here:

- held: a call's close leaves the log in place, and a commit is in the files
  at once (the main file with its log), without any later close or checkpoint;
- the held connection commits nothing itself, keeps no snapshot (the durable
  point still works) and has the durable settings, so the checkpoint its close
  runs is a full flush;
- it is one connection, opened once, and it cannot leak: ``close()`` and
  dropping the object both close it, and a ``Database`` that never held one
  (every ordinary test's) leaves no open file behind.

What "in the files" shows and what it cannot: a copy of the main file and its
log, taken right after the commit returns, holds the row. That is what the
operating system has been handed; whether the drive kept it through a power
cut rests on the settings pinned in ``test_database_durable_commits.py``.
"""

import gc
import sqlite3
import subprocess
import sys
import threading

import pytest

from tests.database_file_probes import (
    file_identities,
    log_bytes,
    open_in_this_process,
    setting_in_a_copy_of_the_files,
    setting_in_the_main_file_alone,
)
from tests.database_fixtures import plain_database

DURABLE = {"journal_mode": "wal", "synchronous": 2, "fullfsync": 1}

READ_ONLY_IN_ANOTHER_PROCESS = (
    "import sqlite3, sys\n"
    "conn = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)\n"
    "row = conn.execute(\"SELECT value FROM app_settings WHERE key = 'probe'\").fetchone()\n"
    "print(row[0] if row else 'no row')\n"
    "conn.close()\n"
)


@pytest.fixture
def db(tmp_path):
    database = plain_database(tmp_path)
    yield database
    database.close()


@pytest.fixture
def connections(monkeypatch):
    """Every connection opened from here on, in order."""
    opened = []
    real_connect = sqlite3.connect

    def connect(*args, **kwargs):
        conn = real_connect(*args, **kwargs)
        opened.append(conn)
        return conn

    monkeypatch.setattr(sqlite3, "connect", connect)
    return opened


# ── without it, and with it ─────────────────────────────────────────────────


def test_without_a_held_connection_every_write_ends_with_a_checkpoint(db, tmp_path):
    """The premise: the close of the only connection copies the log into the
    database file and empties or deletes the log."""
    db.set_setting("probe", "written")

    assert log_bytes(db.context.database_path) == 0
    assert setting_in_the_main_file_alone(db.context.database_path, tmp_path) == "written"


def test_a_held_connection_keeps_the_log_across_calls(db, tmp_path):
    db.hold_open()

    db.set_setting("probe", "written")

    assert log_bytes(db.context.database_path) > 0
    assert setting_in_the_main_file_alone(db.context.database_path, tmp_path) is None  # no checkpoint ran
    assert db.read_setting("probe") == "written"


def test_a_commit_is_in_the_files_at_once_without_a_close_or_a_checkpoint(db, tmp_path):
    db.hold_open()

    db.set_setting("probe", "written")

    assert setting_in_the_main_file_alone(db.context.database_path, tmp_path) is None
    assert setting_in_a_copy_of_the_files(db.context.database_path, tmp_path) == "written"


@pytest.mark.integration
def test_another_process_reading_the_file_read_only_sees_the_commit(db, tmp_path):
    db.hold_open()

    db.set_setting("probe", "written")
    seen = subprocess.run(
        [sys.executable, "-c", READ_ONLY_IN_ANOTHER_PROCESS, str(db.context.database_path)],
        capture_output=True, text=True, timeout=30, cwd=tmp_path,
    )

    assert seen.stdout.strip() == "written", seen.stderr
    assert setting_in_the_main_file_alone(db.context.database_path, tmp_path) is None  # still no checkpoint


# ── what the held connection is ─────────────────────────────────────────────


def test_holding_opens_one_connection_and_a_second_hold_opens_none(db, connections):
    db.hold_open()
    db.hold_open()

    assert len(connections) == 1


@pytest.mark.real_sqlite_durability
def test_the_held_connection_has_the_durable_settings(db, connections):
    """Its close is the last one and runs the checkpoint: that checkpoint
    syncs the way the connection is set up."""
    db.hold_open()

    (held,) = connections
    assert {name: held.execute(f"PRAGMA {name}").fetchone()[0] for name in DURABLE} == DURABLE


def test_the_held_connection_has_the_log_size_limit(db, connections):
    db.hold_open()

    (held,) = connections
    limit = held.execute("PRAGMA journal_size_limit").fetchone()[0]
    with db._connection() as conn:
        assert limit == conn.execute("PRAGMA journal_size_limit").fetchone()[0] > 0


def test_while_held_a_large_log_is_cut_back_after_a_checkpoint(db):
    """The held connection keeps the log from being deleted. After a large
    transaction and a checkpoint, the next commit cuts the log back to the
    limit instead of keeping its largest size until the server stops."""
    db.hold_open()
    with db._connection() as conn:
        limit = conn.execute("PRAGMA journal_size_limit").fetchone()[0]
    assert limit > 0
    with db._connection(commit=True) as conn:
        conn.execute("CREATE TABLE large_probe (data BLOB)")
        conn.execute("INSERT INTO large_probe VALUES (zeroblob(?))", (limit + 1024 * 1024,))
    assert log_bytes(db.context.database_path) > limit  # the premise: a log above the limit

    assert db.make_durable() is True  # a checkpoint that copied the whole log
    db.set_setting("probe", "written")

    assert 0 < log_bytes(db.context.database_path) <= limit
    assert db.read_setting("probe") == "written"


def test_the_held_connection_keeps_no_snapshot_so_the_durable_point_still_works(db, tmp_path):
    db.hold_open()
    db.set_setting("probe", "written")

    assert db.make_durable() is True

    assert setting_in_the_main_file_alone(db.context.database_path, tmp_path) == "written"


# ── it cannot leak ──────────────────────────────────────────────────────────


def test_close_checkpoints_the_log_and_leaves_no_open_file(db, tmp_path):
    db.hold_open()
    db.set_setting("probe", "written")
    files = file_identities(db.context.database_path)
    assert set(open_in_this_process(files)) == {"db.sqlite", "db.sqlite-shm", "db.sqlite-wal"}

    db.close()

    assert open_in_this_process(files) == []
    assert log_bytes(db.context.database_path) == 0
    assert setting_in_the_main_file_alone(db.context.database_path, tmp_path) == "written"


@pytest.mark.real_sqlite_durability
def test_with_the_servers_own_settings_the_last_close_empties_the_log(db, tmp_path):
    """What the README tells the operator: after a clean stop the ``-wal`` file
    is gone or empty and ``database.db`` is complete. The same rule as in an
    ordinary test, here with the settings the server runs with."""
    db.hold_open()
    db.set_setting("probe", "written")
    assert log_bytes(db.context.database_path) > 0

    db.close()

    assert log_bytes(db.context.database_path) == 0
    assert setting_in_the_main_file_alone(db.context.database_path, tmp_path) == "written"


def test_the_calls_made_while_it_is_held_do_not_pile_up_open_files(db):
    """While another connection of this process holds the file, SQLite keeps a
    closed connection's descriptor on the main file and hands it to the next
    connection (closing it would drop the holder's locks). Calls made one
    after another therefore reuse one spare descriptor. (Calls made at the
    same time each need their own, so the spares number at most the
    connections that were ever open at once: bounded by the threads, not by
    the number of calls.) The close of the held connection releases them."""
    db.hold_open()
    files = file_identities(db.context.database_path)

    for n in range(50):
        db.set_setting("probe", str(n))
        db.read_setting("probe")

    held = open_in_this_process(files)
    assert set(held) == {"db.sqlite", "db.sqlite-shm", "db.sqlite-wal"}
    assert len(held) <= 4  # the held connection's three and one spare
    db.close()
    assert open_in_this_process(files) == []


def test_a_dropped_database_object_closes_its_held_connection(tmp_path):
    database = plain_database(tmp_path)
    database.hold_open()
    database.set_setting("probe", "written")
    files = file_identities(database.context.database_path)
    path = database.context.database_path
    assert open_in_this_process(files) != []

    del database
    gc.collect()

    assert open_in_this_process(files) == []
    assert log_bytes(path) == 0


def test_a_database_object_that_never_held_one_leaves_no_open_file(tmp_path):
    """Every ordinary test's database: created, used, dropped, never closed."""
    database = plain_database(tmp_path)
    database.set_setting("probe", "written")

    assert open_in_this_process(file_identities(database.context.database_path)) == []


def test_close_is_harmless_when_nothing_is_held_and_when_called_twice(db):
    db.close()
    db.hold_open()
    files = file_identities(db.context.database_path)

    db.close()
    db.close()

    assert open_in_this_process(files) == []
    assert db.read_setting("server_instance_id") is not None


def test_it_can_be_held_again_after_a_close(db, tmp_path):
    db.hold_open()
    db.close()

    db.hold_open()
    db.set_setting("probe", "written")

    assert log_bytes(db.context.database_path) > 0
    db.close()
    assert log_bytes(db.context.database_path) == 0
    assert setting_in_the_main_file_alone(db.context.database_path, tmp_path) == "written"


def test_it_can_be_closed_from_another_thread(db):
    """The server's shutdown need not run on the thread that started it."""
    db.hold_open()
    files = file_identities(db.context.database_path)
    errors = []

    def close():
        try:
            db.close()
        except Exception as e:  # reported by the assertion below
            errors.append(e)

    thread = threading.Thread(target=close)
    thread.start()
    thread.join()

    assert errors == []
    assert open_in_this_process(files) == []
