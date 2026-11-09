"""SC-16k: SQLite table rebuilds, called while holding the instance lock."""

import sqlite3
from pathlib import Path
from typing import Callable, List, Optional, Sequence, Tuple


class RebuildForeignKeyViolation(RuntimeError):
    """``PRAGMA foreign_key_check`` found violations after the rebuild."""


class RebuildVerificationError(RuntimeError):
    """A verified table changed its row count or id set during the rebuild."""


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


def rebuild_tables(
    db_path: Path,
    *,
    target_version: int,
    rebuild: Callable[[sqlite3.Connection], None],
    backup_path: Path,
    connect: Callable[..., sqlite3.Connection] = sqlite3.connect,
    verify_tables: Sequence[str] = (),
) -> bool:
    conn = connect(str(db_path), isolation_level=None)
    try:
        prior_foreign_keys = conn.execute("PRAGMA foreign_keys").fetchone()[0]
        try:
            if conn.execute("PRAGMA user_version").fetchone()[0] >= target_version:
                return False

            backup = sqlite3.connect(str(backup_path), isolation_level=None)
            try:
                conn.backup(backup)
            finally:
                backup.close()

            conn.execute("PRAGMA foreign_keys=OFF")
            conn.execute("BEGIN IMMEDIATE")
            if conn.execute("PRAGMA user_version").fetchone()[0] >= target_version:
                conn.execute("ROLLBACK")
                return False

            # Phase 5 §3a step 5: verify at runtime, not only by construction.
            before = {table: _table_snapshot(conn, table) for table in verify_tables}
            rebuild(conn)
            violations = conn.execute("PRAGMA foreign_key_check").fetchall()
            if violations:
                raise RebuildForeignKeyViolation(
                    f"Table rebuild caused foreign key violations: {violations!r}"
                )
            for table, snapshot in before.items():
                if _table_snapshot(conn, table) != snapshot:
                    raise RebuildVerificationError(
                        f"Table rebuild changed the row count or ids of {table!r}"
                    )
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
