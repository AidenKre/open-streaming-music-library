"""SC-16k: SQLite table rebuilds, called while holding the instance lock."""

import os
import re
import sqlite3
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Tuple

import app.database.core as database_core
from app.core.durable_fs import fsync_dir


class RebuildForeignKeyViolation(RuntimeError):
    """``PRAGMA foreign_key_check`` found violations after the rebuild."""


class RebuildVerificationError(RuntimeError):
    """A verified table changed its row count or id set during the rebuild."""


class RebuildBackupExists(FileExistsError):
    """A file is already at the backup's path. Nothing was changed.

    A backup is the copy of the database from before a rebuild, so it is never
    written over (and it is a WAL database: a plain connection would open it
    with a log and side files of its own). The caller names the backup after
    the rebuild (its target version). A rebuild that already succeeded is not
    asked again (the version check comes first), so a file found here was left
    by an attempt at this rebuild that did not finish: it failed, or the server
    was stopped after the copy. That file is what the operator needs to go
    back, so it stays until they move it; until then every attempt is refused
    with this error. Its text names the file relative to the database's folder,
    never by its full path; ``backup_path`` has the path itself."""

    def __init__(self, db_path, backup_path):
        self.backup_path = Path(backup_path)
        name = os.path.relpath(backup_path, Path(db_path).parent)
        super().__init__(
            f"A backup of an earlier attempt at this rebuild is still there: {name} (next to "
            "the database). It holds the database as it was before that attempt, which did not "
            "finish. Nothing was changed. Keep the file until the database is known to be good, "
            "then move it away and start again."
        )


def _table_snapshot(
    conn: sqlite3.Connection, table: str
) -> Optional[Tuple[int, List[int]]]:
    """Row count and exact (ordered) id set of ``table``; None when the table
    does not exist (older partial databases may lack it)."""
    exists = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()
    if exists is None:
        return None
    count = conn.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
    ids = [row[0] for row in conn.execute(f'SELECT id FROM "{table}" ORDER BY id')]
    return count, ids


_AUTOINCREMENT = re.compile(r"\bAUTOINCREMENT\b", re.IGNORECASE)


def _sequences(conn: sqlite3.Connection) -> Dict[str, int]:
    """``sqlite_sequence`` as it is: for each AUTOINCREMENT table that ever held
    a row, the highest id it has given out. Empty when the database has no
    AUTOINCREMENT table (SQLite makes ``sqlite_sequence`` with the first one)."""
    exists = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='sqlite_sequence'"
    ).fetchone()
    if exists is None:
        return {}
    return {name: seq or 0 for name, seq in conn.execute("SELECT name, seq FROM sqlite_sequence")}


def _keep_sequences(conn: sqlite3.Connection, before: Dict[str, int]) -> None:
    """No AUTOINCREMENT table gives out an id it gave out before the rebuild.

    A create-copy-drop-rename leaves the new table's sequence at the highest id
    that was copied (or with no sequence row at all when no row was copied), so
    an id that was given out and deleted before the rebuild would be given out
    again. For every table that had a sequence before and is still an
    AUTOINCREMENT table, the sequence becomes the highest of: what it was
    before, what it is now, and the table's highest id. A table the rebuild
    dropped, or one that is no longer AUTOINCREMENT, is left alone."""
    for table, old_seq in before.items():
        row = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table,)
        ).fetchone()
        if row is None or not _AUTOINCREMENT.search(row[0] or ""):
            continue
        highest = conn.execute(f'SELECT MAX(rowid) FROM "{table}"').fetchone()[0] or 0
        floor = max(old_seq, highest)
        updated = conn.execute(
            "UPDATE sqlite_sequence SET seq = MAX(COALESCE(seq, 0), ?) WHERE name = ?",
            (floor, table),
        ).rowcount
        if not updated:
            conn.execute("INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)", (table, floor))


def _connect(database_path, *, isolation_level=None) -> sqlite3.Connection:
    """The product's opener, looked up in its module at call time."""
    return database_core.open_connection(database_path, isolation_level=isolation_level)


def rebuild_tables(
    db_path: Path,
    *,
    target_version: int,
    rebuild: Callable[[sqlite3.Connection], None],
    backup_path: Path,
    connect: Callable[..., sqlite3.Connection] = _connect,
    verify_tables: Sequence[str] = (),
) -> bool:
    """Run ``rebuild`` (a create-copy-drop-rename of one or more tables) in one
    exclusive transaction and stamp ``target_version``; False when the database
    is already at that version. The steps and their order are SC-16k's: a copy
    of the database at ``backup_path`` first (a path nothing is at yet:
    ``RebuildBackupExists`` otherwise, before anything changes), foreign keys
    off, ``BEGIN IMMEDIATE``, the version read again, the rebuild, the
    foreign-key check, the row counts and ids of ``verify_tables``, the
    ``sqlite_sequence`` rows (``_keep_sequences``), the version, the commit. Any
    failure rolls everything back.

    The backup. The caller gives each rebuild a ``backup_path`` of its own (named
    after the target version). The copy is written under ``<backup_path>.partial``
    and gets its name only when it is whole, so a file at ``backup_path`` is
    always a complete copy of the database from before an attempt. It is never
    removed here: after a rebuild that succeeded the caller decides when the old
    tables may go; after one that failed it is the operator's way back, and the
    next attempt is refused until they move it (``RebuildBackupExists``)."""
    conn = connect(str(db_path), isolation_level=None)
    try:
        prior_foreign_keys = conn.execute("PRAGMA foreign_keys").fetchone()[0]
        try:
            if conn.execute("PRAGMA user_version").fetchone()[0] >= target_version:
                return False

            if os.path.lexists(backup_path):
                raise RebuildBackupExists(db_path, backup_path)
            # The backup is a file of its own, not the server's database: a plain
            # connection, so that making it leaves no side files beside it (the
            # opener would write it through a log of its own), with the opener's
            # flush settings, so the copy is on disk before the rebuild begins.
            # The copy keeps its source's journal mode in its header. It is
            # written under a name of its own (a copy an earlier attempt did not
            # finish goes first) and renamed when it is whole.
            partial = Path(f"{backup_path}.partial")
            try:
                partial.unlink(missing_ok=True)
                backup = sqlite3.connect(str(partial), isolation_level=None)
                try:
                    backup.execute("PRAGMA synchronous=FULL")
                    backup.execute("PRAGMA fullfsync=ON")
                    conn.backup(backup)
                finally:
                    backup.close()
                os.replace(partial, backup_path)
                fsync_dir(Path(backup_path).parent)
            except BaseException:
                partial.unlink(missing_ok=True)
                raise

            conn.execute("PRAGMA foreign_keys=OFF")
            conn.execute("BEGIN IMMEDIATE")
            if conn.execute("PRAGMA user_version").fetchone()[0] >= target_version:
                conn.execute("ROLLBACK")
                return False

            # Phase 5 §3a step 5: verify at runtime, not only by construction.
            before = {table: _table_snapshot(conn, table) for table in verify_tables}
            sequences = _sequences(conn)
            rebuild(conn)
            violations = [tuple(row) for row in conn.execute("PRAGMA foreign_key_check")]
            if violations:
                raise RebuildForeignKeyViolation(
                    f"Table rebuild caused foreign key violations: {violations!r}"
                )
            for table, snapshot in before.items():
                if _table_snapshot(conn, table) != snapshot:
                    raise RebuildVerificationError(
                        f"Table rebuild changed the row count or ids of {table!r}"
                    )
            _keep_sequences(conn, sequences)
            conn.execute(f"PRAGMA user_version = {target_version}")
            conn.execute("COMMIT")
            return True
        except BaseException:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
            raise
        finally:
            conn.execute(f"PRAGMA foreign_keys = {prior_foreign_keys}")
            if conn.execute("PRAGMA foreign_keys").fetchone()[0] != prior_foreign_keys:
                raise RuntimeError("Failed to restore prior PRAGMA foreign_keys value")
    finally:
        conn.close()
