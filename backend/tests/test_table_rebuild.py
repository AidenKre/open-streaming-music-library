"""SC-16k: the one SQLite table-rebuild migration helper.

Contract (shared architecture SC-16 row k): a dedicated connection; backup
first; ``PRAGMA foreign_keys=OFF`` outside the transaction; explicit
``BEGIN IMMEDIATE``; re-read ``user_version`` inside the exclusive transaction
and skip if already migrated; create-copy-drop-rename (caller's callback);
``foreign_key_check``; commit; restore FK enforcement in ``finally``.
"""

import functools
import sqlite3

import pytest

from app.database.table_rebuild import (
    RebuildForeignKeyViolation,
    RebuildVerificationError,
    rebuild_tables,
)


class _RecordingConnection(sqlite3.Connection):
    """Records the connection's FK mode at close time (the helper's own,
    dedicated connection is otherwise invisible to the test)."""

    closed_fk_states: list = []

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Like the app's own connections (`Database._connection`), FK
        # enforcement starts ON, so "restore the prior mode" means ON.
        self.execute("PRAGMA foreign_keys=ON")

    def close(self):
        _RecordingConnection.closed_fk_states.append(
            self.execute("PRAGMA foreign_keys").fetchone()[0]
        )
        super().close()


@pytest.fixture
def recording_connect():
    _RecordingConnection.closed_fk_states = []
    return functools.partial(sqlite3.connect, factory=_RecordingConnection)


def _make_db(path, *, version=1):
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        PRAGMA foreign_keys=ON;
        CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE child (
            id INTEGER PRIMARY KEY,
            parent_id INTEGER NOT NULL REFERENCES parent(id)
        );
        CREATE INDEX idx_parent_name ON parent(name);
        INSERT INTO parent (id, name) VALUES (3, 'a'), (7, 'b');
        INSERT INTO child (id, parent_id) VALUES (1, 3), (2, 7);
        """
    )
    conn.execute(f"PRAGMA user_version = {version}")
    conn.commit()
    conn.close()


def _rebuild_parent_autoincrement(conn):
    conn.execute(
        "CREATE TABLE parent_new (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)"
    )
    conn.execute("INSERT INTO parent_new (id, name) SELECT id, name FROM parent")
    conn.execute("DROP TABLE parent")
    conn.execute("ALTER TABLE parent_new RENAME TO parent")
    conn.execute("CREATE INDEX idx_parent_name ON parent(name)")


def _table_sql(path, name):
    conn = sqlite3.connect(path)
    try:
        row = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (name,)
        ).fetchone()
        return row[0] if row else None
    finally:
        conn.close()


def _user_version(path):
    conn = sqlite3.connect(path)
    try:
        return conn.execute("PRAGMA user_version").fetchone()[0]
    finally:
        conn.close()


def test_success_rebuilds_preserves_rows_and_sets_version(tmp_path, recording_connect):
    db = tmp_path / "db.sqlite"
    _make_db(db)

    migrated = rebuild_tables(
        db,
        target_version=2,
        rebuild=_rebuild_parent_autoincrement,
        backup_path=tmp_path / "backup.sqlite",
        connect=recording_connect,
    )

    assert migrated is True
    assert _user_version(db) == 2
    assert "AUTOINCREMENT" in _table_sql(db, "parent")
    conn = sqlite3.connect(db)
    try:
        assert conn.execute("SELECT id, name FROM parent ORDER BY id").fetchall() == [
            (3, "a"),
            (7, "b"),
        ]
        assert conn.execute("SELECT id, parent_id FROM child ORDER BY id").fetchall() == [
            (1, 3),
            (2, 7),
        ]
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []
        # The child's FK still points at the (renamed) parent table.
        assert "REFERENCES parent" in _table_sql(db, "child")
    finally:
        conn.close()
    # FK enforcement was restored on the helper's dedicated connection.
    assert _RecordingConnection.closed_fk_states == [1]


def test_callback_runs_with_fks_off_inside_an_explicit_transaction(tmp_path, recording_connect):
    db = tmp_path / "db.sqlite"
    _make_db(db)
    seen = {}

    def rebuild(conn):
        seen["foreign_keys"] = conn.execute("PRAGMA foreign_keys").fetchone()[0]
        seen["in_transaction"] = conn.in_transaction
        _rebuild_parent_autoincrement(conn)

    rebuild_tables(
        db,
        target_version=2,
        rebuild=rebuild,
        backup_path=tmp_path / "backup.sqlite",
        connect=recording_connect,
    )
    assert seen == {"foreign_keys": 0, "in_transaction": True}


def test_backup_is_taken_before_the_rebuild(tmp_path, recording_connect):
    db = tmp_path / "db.sqlite"
    backup = tmp_path / "backup.sqlite"
    _make_db(db)

    rebuild_tables(
        db,
        target_version=2,
        rebuild=_rebuild_parent_autoincrement,
        backup_path=backup,
        connect=recording_connect,
    )

    assert backup.exists()
    # The backup is the PRE-rebuild database.
    assert _user_version(backup) == 1
    assert "AUTOINCREMENT" not in _table_sql(backup, "parent")
    conn = sqlite3.connect(backup)
    try:
        assert conn.execute("SELECT COUNT(*) FROM parent").fetchone()[0] == 2
    finally:
        conn.close()


def test_failure_rolls_back_ddl_keeps_version_and_restores_fks(tmp_path, recording_connect):
    db = tmp_path / "db.sqlite"
    _make_db(db)

    def failing_rebuild(conn):
        _rebuild_parent_autoincrement(conn)
        raise RuntimeError("boom after the DDL")

    with pytest.raises(RuntimeError, match="boom"):
        rebuild_tables(
            db,
            target_version=2,
            rebuild=failing_rebuild,
            backup_path=tmp_path / "backup.sqlite",
            connect=recording_connect,
        )

    assert _user_version(db) == 1
    # DDL undone: the original table definition and rows are back.
    assert "AUTOINCREMENT" not in _table_sql(db, "parent")
    assert _table_sql(db, "parent_new") is None
    conn = sqlite3.connect(db)
    try:
        assert conn.execute("SELECT COUNT(*) FROM parent").fetchone()[0] == 2
    finally:
        conn.close()
    assert _RecordingConnection.closed_fk_states == [1]


def test_foreign_key_violation_aborts_and_rolls_back(tmp_path, recording_connect):
    db = tmp_path / "db.sqlite"
    _make_db(db)

    def dangling_rebuild(conn):
        _rebuild_parent_autoincrement(conn)
        conn.execute("INSERT INTO child (id, parent_id) VALUES (9, 999)")

    with pytest.raises(RebuildForeignKeyViolation):
        rebuild_tables(
            db,
            target_version=2,
            rebuild=dangling_rebuild,
            backup_path=tmp_path / "backup.sqlite",
            connect=recording_connect,
        )

    assert _user_version(db) == 1
    conn = sqlite3.connect(db)
    try:
        assert conn.execute("SELECT COUNT(*) FROM child").fetchone()[0] == 2
    finally:
        conn.close()
    assert "AUTOINCREMENT" not in _table_sql(db, "parent")
    assert _RecordingConnection.closed_fk_states == [1]


def test_already_migrated_database_is_skipped(tmp_path, recording_connect):
    db = tmp_path / "db.sqlite"
    backup = tmp_path / "backup.sqlite"
    _make_db(db, version=2)
    calls = []

    migrated = rebuild_tables(
        db,
        target_version=2,
        rebuild=calls.append,
        backup_path=backup,
        connect=recording_connect,
    )

    assert migrated is False
    assert calls == []
    assert not backup.exists()
    assert _user_version(db) == 2


def test_prior_fk_mode_off_is_restored_as_off(tmp_path):
    """The helper restores the connection's PRIOR mode, it does not force ON."""
    db = tmp_path / "db.sqlite"
    _make_db(db)
    states = []

    class _OffByDefault(sqlite3.Connection):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.execute("PRAGMA foreign_keys=OFF")

        def close(self):
            states.append(self.execute("PRAGMA foreign_keys").fetchone()[0])
            super().close()

    rebuild_tables(
        db,
        target_version=2,
        rebuild=_rebuild_parent_autoincrement,
        backup_path=tmp_path / "backup.sqlite",
        connect=functools.partial(sqlite3.connect, factory=_OffByDefault),
    )
    assert states == [0]


# Phase 5 §3a step 5 (audit 5A.0(b) #4): the rebuild verifies its result at
# runtime, not only by construction: each verified table keeps its row count
# and exact id set, else the rebuild rolls back.
def _rebuild_losing_a_childless_parent(conn):
    conn.execute(
        "CREATE TABLE parent_new (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)"
    )
    conn.execute("INSERT INTO parent_new (id, name) SELECT id, name FROM parent WHERE id != 9")
    conn.execute("DROP TABLE parent")
    conn.execute("ALTER TABLE parent_new RENAME TO parent")
    conn.execute("CREATE INDEX idx_parent_name ON parent(name)")


def _add_childless_parent(path):
    conn = sqlite3.connect(path)
    conn.execute("INSERT INTO parent (id, name) VALUES (9, 'c')")
    conn.commit()
    conn.close()


def test_verified_table_losing_a_row_rolls_back(tmp_path, recording_connect):
    db = tmp_path / "db.sqlite"
    _make_db(db)
    _add_childless_parent(db)

    with pytest.raises(RebuildVerificationError):
        rebuild_tables(
            db,
            target_version=2,
            rebuild=_rebuild_losing_a_childless_parent,
            backup_path=tmp_path / "backup.sqlite",
            connect=recording_connect,
            verify_tables=("parent",),
        )

    assert _user_version(db) == 1
    assert "AUTOINCREMENT" not in _table_sql(db, "parent")
    conn = sqlite3.connect(db)
    try:
        assert conn.execute("SELECT id FROM parent ORDER BY id").fetchall() == [(3,), (7,), (9,)]
    finally:
        conn.close()
    assert _RecordingConnection.closed_fk_states == [1]


def test_verified_tables_pass_when_rows_and_ids_are_kept(tmp_path, recording_connect):
    db = tmp_path / "db.sqlite"
    _make_db(db)
    _add_childless_parent(db)

    assert rebuild_tables(
        db,
        target_version=2,
        rebuild=_rebuild_parent_autoincrement,
        backup_path=tmp_path / "backup.sqlite",
        connect=recording_connect,
        verify_tables=("parent",),
    )
    assert _user_version(db) == 2


def _rebuild_renumbering_a_childless_parent(conn):
    _rebuild_parent_autoincrement(conn)
    conn.execute("UPDATE parent SET id = 10 WHERE id = 9")


def test_verified_table_with_a_renumbered_id_rolls_back(tmp_path, recording_connect):
    """Audit 5A.0(c) #6: same row count, different id set -> rejected."""
    db = tmp_path / "db.sqlite"
    _make_db(db)
    _add_childless_parent(db)

    with pytest.raises(RebuildVerificationError):
        rebuild_tables(
            db,
            target_version=2,
            rebuild=_rebuild_renumbering_a_childless_parent,
            backup_path=tmp_path / "backup.sqlite",
            connect=recording_connect,
            verify_tables=("parent",),
        )
    assert _user_version(db) == 1
    conn = sqlite3.connect(db)
    try:
        assert conn.execute("SELECT id FROM parent ORDER BY id").fetchall() == [(3,), (7,), (9,)]
    finally:
        conn.close()


class _RacedConnection(sqlite3.Connection):
    """Another process migrates the database between the helper's first
    version check and its exclusive transaction."""

    target = 0
    path = None

    def execute(self, sql, *args):
        if sql == "BEGIN IMMEDIATE":
            other = sqlite3.connect(_RacedConnection.path, isolation_level=None)
            other.execute(f"PRAGMA user_version = {_RacedConnection.target}")
            other.close()
        return super().execute(sql, *args)


def test_version_is_rechecked_inside_the_exclusive_transaction(tmp_path):
    """Audit 5A.0(c) #10 (SC-16k): re-read user_version after BEGIN IMMEDIATE."""
    db = tmp_path / "db.sqlite"
    _make_db(db)
    _RacedConnection.path = str(db)
    _RacedConnection.target = 2
    called = []

    migrated = rebuild_tables(
        db,
        target_version=2,
        rebuild=lambda conn: called.append(True),
        backup_path=tmp_path / "backup.sqlite",
        connect=functools.partial(sqlite3.connect, factory=_RacedConnection),
    )

    assert migrated is False
    assert called == []
    assert "AUTOINCREMENT" not in _table_sql(db, "parent")
