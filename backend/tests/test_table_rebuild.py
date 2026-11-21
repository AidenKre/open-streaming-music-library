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


def test_the_backup_is_one_file(tmp_path):
    """The backup is a file of its own, not the server's database: making it
    leaves no ``-wal`` / ``-shm`` beside it that would have to be kept with it
    (its connection is a plain one; a backup into a connection in WAL mode is
    also refused when the page sizes differ). The copy itself is faithful: it
    is a WAL database like its source, so it is read here without a log. The
    database is a WAL database, as the server's is, and the rebuild runs on
    the helper's own default connection."""
    db = tmp_path / "db.sqlite"
    backup = tmp_path / "backups" / "backup.sqlite"
    backup.parent.mkdir()
    _make_db(db)
    conn = sqlite3.connect(db)
    assert conn.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    conn.close()

    assert rebuild_tables(
        db, target_version=2, rebuild=_rebuild_parent_autoincrement, backup_path=backup
    ) is True

    assert sorted(p.name for p in backup.parent.iterdir()) == ["backup.sqlite"]
    conn = sqlite3.connect(f"file:{backup}?mode=ro&immutable=1", uri=True)
    try:
        assert conn.execute("SELECT id, name FROM parent ORDER BY id").fetchall() == [(3, "a"), (7, "b")]
        assert conn.execute("PRAGMA user_version").fetchone()[0] == 1  # the state before the rebuild
    finally:
        conn.close()
    assert sorted(p.name for p in backup.parent.iterdir()) == ["backup.sqlite"]


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


# SC-16k: a create-copy-drop-rename of an AUTOINCREMENT table resets its
# ``sqlite_sequence`` row to the highest id copied, so an id that was given out
# and then deleted would be given out again. The helper keeps every table's
# sequence at least where it was.
def _make_numbered_db(path, *, rows=5, delete=(5,)):
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE entry (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)")
    conn.executemany("INSERT INTO entry (name) VALUES (?)", [(f"n{i}",) for i in range(rows)])
    conn.executemany("DELETE FROM entry WHERE id = ?", [(i,) for i in delete])
    conn.execute("PRAGMA user_version = 1")
    conn.commit()
    conn.close()


def _rebuild_entry(conn):
    conn.execute(
        "CREATE TABLE entry_new (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, "
        "note TEXT)"
    )
    conn.execute("INSERT INTO entry_new (id, name) SELECT id, name FROM entry")
    conn.execute("DROP TABLE entry")
    conn.execute("ALTER TABLE entry_new RENAME TO entry")


def _next_id(path, table="entry"):
    conn = sqlite3.connect(path)
    try:
        return conn.execute(f"INSERT INTO {table} (name) VALUES ('next')").lastrowid
    finally:
        conn.close()


@pytest.mark.parametrize(
    "delete, next_id",
    [((5,), 6), ((1, 2, 3, 4, 5), 6), ((), 6), ((2,), 6)],
    ids=["the highest id was deleted", "every row was deleted", "control: nothing was deleted",
         "control: a lower id was deleted"],
)
def test_a_rebuilt_autoincrement_table_never_gives_out_an_id_again(tmp_path, delete, next_id):
    db = tmp_path / "db.sqlite"
    _make_numbered_db(db, delete=delete)

    assert rebuild_tables(
        db, target_version=2, rebuild=_rebuild_entry, backup_path=tmp_path / "backup.sqlite",
        verify_tables=("entry",),
    )

    assert _next_id(db) == next_id


def test_a_table_the_rebuild_drops_leaves_no_sequence_behind(tmp_path):
    db = tmp_path / "db.sqlite"
    _make_numbered_db(db)

    def rebuild(conn):
        conn.execute("DROP TABLE entry")
        conn.execute("CREATE TABLE other (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")

    assert rebuild_tables(
        db, target_version=2, rebuild=rebuild, backup_path=tmp_path / "backup.sqlite"
    )

    conn = sqlite3.connect(db)
    try:
        assert conn.execute("SELECT name FROM sqlite_sequence").fetchall() == []
    finally:
        conn.close()
    assert _next_id(db, "other") == 1


def test_a_table_that_stops_being_autoincrement_gets_no_sequence_row(tmp_path):
    db = tmp_path / "db.sqlite"
    _make_numbered_db(db)

    def rebuild(conn):
        conn.execute("CREATE TABLE entry_new (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        conn.execute("INSERT INTO entry_new (id, name) SELECT id, name FROM entry")
        conn.execute("DROP TABLE entry")
        conn.execute("ALTER TABLE entry_new RENAME TO entry")

    assert rebuild_tables(
        db, target_version=2, rebuild=rebuild, backup_path=tmp_path / "backup.sqlite"
    )

    conn = sqlite3.connect(db)
    try:
        assert conn.execute("SELECT name FROM sqlite_sequence").fetchall() == []
    finally:
        conn.close()


def test_a_failed_rebuild_leaves_the_sequence_as_it_was(tmp_path):
    db = tmp_path / "db.sqlite"
    _make_numbered_db(db)

    def failing(conn):
        _rebuild_entry(conn)
        raise RuntimeError("boom after the DDL")

    with pytest.raises(RuntimeError, match="boom"):
        rebuild_tables(db, target_version=2, rebuild=failing, backup_path=tmp_path / "backup.sqlite")

    assert _next_id(db) == 6


# A backup is the copy of the database from before a rebuild: it is never
# written over. A second rebuild given the same backup path is refused before
# anything changes (the old file is also a WAL database already: a plain
# connection would open it with a log and side files of its own).
def test_an_existing_backup_is_never_written_over(tmp_path):
    from app.database.table_rebuild import RebuildBackupExists

    db = tmp_path / "db.sqlite"
    backup = tmp_path / "backup.sqlite"
    _make_db(db)
    backup.write_bytes(b"the copy an earlier rebuild made")
    calls = []

    with pytest.raises(RebuildBackupExists):
        rebuild_tables(db, target_version=2, rebuild=calls.append, backup_path=backup)

    assert calls == []
    assert backup.read_bytes() == b"the copy an earlier rebuild made"
    assert [p.name for p in tmp_path.iterdir() if p.name.startswith("backup")] == ["backup.sqlite"]
    assert _user_version(db) == 1 and "AUTOINCREMENT" not in _table_sql(db, "parent")


def test_the_backup_of_an_earlier_rebuild_is_refused_too(tmp_path):
    """The real case: the first rebuild's own backup (a WAL database) is at the
    path the second rebuild is given."""
    from app.database.table_rebuild import RebuildBackupExists

    db = tmp_path / "db.sqlite"
    backup = tmp_path / "backups" / "backup.sqlite"
    backup.parent.mkdir()
    _make_db(db)
    conn = sqlite3.connect(db)
    assert conn.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    conn.close()
    assert rebuild_tables(
        db, target_version=2, rebuild=_rebuild_parent_autoincrement, backup_path=backup
    )
    first = backup.read_bytes()

    with pytest.raises(RebuildBackupExists):
        rebuild_tables(
            db, target_version=3, rebuild=lambda conn: conn.execute("CREATE TABLE more (id INTEGER)"),
            backup_path=backup,
        )

    assert backup.read_bytes() == first
    assert sorted(p.name for p in backup.parent.iterdir()) == ["backup.sqlite"]
    assert _user_version(db) == 2 and _table_sql(db, "more") is None


def test_two_rebuilds_with_backups_of_their_own_both_run(tmp_path):
    db = tmp_path / "db.sqlite"
    _make_db(db)

    assert rebuild_tables(
        db, target_version=2, rebuild=_rebuild_parent_autoincrement,
        backup_path=tmp_path / "before-2.sqlite",
    )
    assert rebuild_tables(
        db, target_version=3, rebuild=lambda conn: conn.execute("CREATE TABLE more (id INTEGER)"),
        backup_path=tmp_path / "before-3.sqlite",
    )

    assert _user_version(tmp_path / "before-2.sqlite") == 1
    assert _user_version(tmp_path / "before-3.sqlite") == 2


# What becomes of the backup. A rebuild that succeeds leaves it (the caller
# decides when the copy of the old tables may go). A rebuild that fails leaves
# it too: it is what the operator needs to go back. The next call with the same
# path is refused, and says which file that is and what it holds.
def test_after_a_failed_rebuild_the_next_call_is_refused_and_says_what_the_backup_is(tmp_path):
    from app.database.table_rebuild import RebuildBackupExists

    db = tmp_path / "data" / "database" / "db.sqlite"
    backup = db.parent / "backups" / "before-2.sqlite"
    backup.parent.mkdir(parents=True)
    _make_db(db)

    def failing(conn):
        _rebuild_parent_autoincrement(conn)
        raise RuntimeError("boom after the DDL")

    with pytest.raises(RuntimeError, match="boom"):
        rebuild_tables(db, target_version=2, rebuild=failing, backup_path=backup)
    kept = backup.read_bytes()
    assert _user_version(backup) == 1 and "AUTOINCREMENT" not in _table_sql(backup, "parent")

    with pytest.raises(RebuildBackupExists) as refused:
        rebuild_tables(
            db, target_version=2, rebuild=_rebuild_parent_autoincrement, backup_path=backup
        )

    text = str(refused.value)
    assert text == (
        "A backup of an earlier attempt at this rebuild is still there: backups/before-2.sqlite "
        "(next to the database). It holds the database as it was before that attempt, which did "
        "not finish. Nothing was changed. Keep the file until the database is known to be good, "
        "then move it away and start again."
    )
    assert str(tmp_path) not in text  # no full path
    assert refused.value.backup_path == backup
    assert backup.read_bytes() == kept
    assert _user_version(db) == 1 and "AUTOINCREMENT" not in _table_sql(db, "parent")


def test_a_rebuild_that_succeeded_leaves_its_backup_and_the_same_call_is_not_refused(tmp_path):
    db = tmp_path / "db.sqlite"
    backup = tmp_path / "before-2.sqlite"
    _make_db(db)
    assert rebuild_tables(
        db, target_version=2, rebuild=_rebuild_parent_autoincrement, backup_path=backup
    )
    kept = backup.read_bytes()
    calls = []

    # The next start asks again: already at the version, so the backup is not even looked at.
    assert rebuild_tables(db, target_version=2, rebuild=calls.append, backup_path=backup) is False

    assert calls == [] and backup.read_bytes() == kept
    assert _user_version(backup) == 1  # the tables as they were before the rebuild


class _BackupCutShort(sqlite3.Connection):
    """The copy into the backup stops after its first page (a kill, a full disk)."""

    def backup(self, target, **kwargs):
        def stop(status, remaining, total):
            raise OSError("the copy was cut short")

        super().backup(target, pages=1, progress=stop)


def test_a_backup_that_was_cut_short_is_never_taken_for_a_backup(tmp_path):
    """A file at the backup's path is a whole backup or nothing: a copy that
    stopped half-way leaves no file there, so the next call is not refused in
    the name of a "backup" that holds half a database."""
    db = tmp_path / "db.sqlite"
    backup = tmp_path / "before-2.sqlite"
    _make_db(db)
    calls = []

    with pytest.raises(OSError, match="cut short"):
        rebuild_tables(
            db, target_version=2, rebuild=calls.append, backup_path=backup,
            connect=functools.partial(sqlite3.connect, factory=_BackupCutShort),
        )

    assert calls == [] and not backup.exists()
    assert not (tmp_path / "before-2.sqlite.partial").exists()  # the half copy went too
    assert _user_version(db) == 1

    assert rebuild_tables(
        db, target_version=2, rebuild=_rebuild_parent_autoincrement, backup_path=backup
    )
    # One file, under the backup's own name (looked at before it is opened here).
    assert [p.name for p in tmp_path.iterdir() if p.name.startswith("before-2")] == ["before-2.sqlite"]
    assert _user_version(backup) == 1
