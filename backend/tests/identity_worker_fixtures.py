"""Shared setup for the 6.5A.2d identity-worker tests.

Every test builds its own database under ``tmp_path`` (xdist-safe). Rows are
written and read with plain SQL so the expected state never comes from the
code under test.
"""

import sqlite3
import uuid as uuid_mod
from pathlib import Path
from typing import Any, Optional

from app.database import DatabaseContext
from tests.owned_database import OwnedTestDatabase
from tests.schema_fixtures import INIT_SQL

DIGEST_A = "aa" * 32
DIGEST_B = "bb" * 32


def make_db(tmp_path: Path) -> OwnedTestDatabase:
    database = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    return database


def sql(db, query: str, params: tuple = ()) -> list[dict]:
    conn = sqlite3.connect(db.context.database_path)
    conn.row_factory = sqlite3.Row
    try:
        rows = [dict(r) for r in conn.execute(query, params)]
        conn.commit()
        return rows
    finally:
        conn.close()


def add_track(
    db,
    file_path: Path | str,
    *,
    codec: Optional[str] = "flac",
    owner_id: Optional[int] = None,
    identity: Optional[dict[str, Any]] = None,
) -> str:
    """A track (tracks + trackmetadata) with an identity row. ``identity``
    overrides the default pending row's columns; ``identity={"_none": True}``
    leaves the track without a row."""
    uuid_id = str(uuid_mod.uuid4())
    owner = owner_id if owner_id is not None else db.owner_id
    conn = sqlite3.connect(db.context.database_path)
    try:
        track_id = conn.execute(
            "INSERT INTO tracks (uuid_id, file_path, owner_id) VALUES (?, ?, ?)",
            (uuid_id, str(file_path), owner),
        ).lastrowid
        conn.execute(
            "INSERT INTO trackmetadata (track_id, uuid_id, codec, has_album_art) VALUES (?, ?, ?, 0)",
            (track_id, uuid_id, codec),
        )
        # The FTS row a real insert writes, so delete_track can remove it.
        conn.execute(
            "INSERT INTO fts_tracks (rowid, title, artist_name, album_name) VALUES (?, '', '', '')",
            (track_id,),
        )
        values = {
            "generation": 1, "exact_state": "pending", "fp_state": "unavailable",
            "match_state": "pending", "priority": 1,
        }
        values.update(identity or {})
        if not values.pop("_none", False):
            names = ["uuid_id", *values]
            conn.execute(
                f"INSERT INTO track_audio_identity ({', '.join(names)}) "
                f"VALUES ({', '.join('?' * len(names))})",
                (uuid_id, *values.values()),
            )
        conn.commit()
    finally:
        conn.close()
    return uuid_id


def identity(db, uuid_id: str) -> Optional[dict]:
    rows = sql(db, "SELECT * FROM track_audio_identity WHERE uuid_id = ?", (uuid_id,))
    return rows[0] if rows else None


def set_identity(db, uuid_id: str, **values) -> None:
    sets = ", ".join(f"{k} = ?" for k in values)
    sql(db, f"UPDATE track_audio_identity SET {sets} WHERE uuid_id = ?", (*values.values(), uuid_id))


def add_journal(db, uuid_id: str, intent: str = "inplace", owner_id: Optional[int] = None) -> int:
    conn = sqlite3.connect(db.context.database_path)
    try:
        jid = conn.execute(
            "INSERT INTO edit_journal (intent, uuid_id, created_at, owner_id) VALUES (?, ?, 0, ?)",
            (intent, uuid_id, owner_id if owner_id is not None else db.owner_id),
        ).lastrowid
        conn.commit()
        return jid
    finally:
        conn.close()


def delete_journal(db, journal_id: int) -> None:
    sql(db, "DELETE FROM edit_journal WHERE id = ?", (journal_id,))
