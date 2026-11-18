"""Phase M.0a (M-U04): fresh initialization is one transaction.

``init.sql`` and its ``PRAGMA user_version`` run inside one ``BEGIN … COMMIT``
in the script, so a process killed half-way through first init leaves a file
with no schema at all. The next start treats it as fresh (it is never refused
as a "version 0" database), and a second open of a complete database changes
nothing.
"""

import sqlite3
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from app.database.database import Database
from tests.schema_fixtures import INIT_SQL, open_database, user_version

BACKEND = Path(__file__).parent.parent

# Runs production initialization in a child process and kills it (os._exit:
# no rollback, no cleanup) the moment SQLite starts the statement that
# creates `cover_arts`, i.e. after several tables were already created inside
# the init transaction.
_CRASH_SCRIPT = textwrap.dedent(
    """
    import os, sqlite3, sys
    from pathlib import Path

    _real_connect = sqlite3.connect

    def _connect(*args, **kwargs):
        conn = _real_connect(*args, **kwargs)

        def _trace(statement):
            if "CREATE TABLE IF NOT EXISTS cover_arts" in statement:
                os._exit(17)

        conn.set_trace_callback(_trace)
        return conn

    sqlite3.connect = _connect

    from app.database.database import Database, DatabaseContext

    Database(DatabaseContext(
        database_path=Path(sys.argv[1]), init_sql_path=Path(sys.argv[2]),
    )).initialize()
    os._exit(0)
    """
)


def _schema_objects(path: Path) -> list:
    conn = sqlite3.connect(path)
    try:
        return conn.execute(
            "SELECT type, name, sql FROM sqlite_master ORDER BY type, name"
        ).fetchall()
    finally:
        conn.close()


@pytest.mark.integration
def test_crash_during_first_init_leaves_a_file_that_initializes_later(tmp_path):
    path = tmp_path / "database.db"
    crashed = subprocess.run(
        [sys.executable, "-c", _CRASH_SCRIPT, str(path), str(INIT_SQL)],
        cwd=BACKEND,
        capture_output=True,
        text=True,
    )
    assert crashed.returncode == 17, crashed.stderr  # killed mid-script

    # Nothing of the interrupted transaction survived.
    assert path.exists()
    assert user_version(path) == 0
    assert _schema_objects(path) == []

    # The next start initializes it as a fresh database instead of refusing it.
    db = open_database(path)
    assert user_version(path) == Database.LATEST_SCHEMA_VERSION
    names = {name for _, name, _ in _schema_objects(path)}
    assert {"tracks", "cover_arts", "app_settings"} <= names
    assert db.get_server_instance_id()


def test_second_open_changes_nothing(tmp_path):
    path = tmp_path / "database.db"
    first = open_database(path)
    instance_id = first.get_server_instance_id()
    schema = _schema_objects(path)

    second = open_database(path)

    assert _schema_objects(path) == schema
    assert user_version(path) == Database.LATEST_SCHEMA_VERSION
    assert second.get_server_instance_id() == instance_id


def test_reopen_after_a_clean_shutdown_without_wal_sidecars(tmp_path):
    """On Linux the last connection's close checkpoints and deletes -wal and
    -shm; the next start must still read the version and open normally."""
    path = tmp_path / "database.db"
    instance_id = open_database(path).get_server_instance_id()
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    for suffix in ("-wal", "-shm"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)

    reopened = open_database(path)

    assert user_version(path) == Database.LATEST_SCHEMA_VERSION
    assert reopened.get_server_instance_id() == instance_id

