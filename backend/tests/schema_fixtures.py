"""Real previous-version backend databases for migration tests.

``fixtures/schema_v9.sql`` is the frozen ``init.sql`` of schema version 9
(``main`` @ 3ee4c9e, the last pre-Phase-5 schema). Fixtures are built from it
with plain SQL and then opened through the production ``Database.initialize()``
so the real migration ladder runs.
"""

import sqlite3
from pathlib import Path

from app.database.database import Database, DatabaseContext

FIXTURES = Path(__file__).parent / "fixtures"
V9_SCHEMA = FIXTURES / "schema_v9.sql"
INIT_SQL = Path(__file__).parent.parent / "app" / "database" / "init.sql"


def make_v9_database(path: Path) -> None:
    """An empty schema-v9 database (user_version 9)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        conn.executescript(V9_SCHEMA.read_text())
        conn.execute("PRAGMA user_version = 9")
        conn.commit()
    finally:
        conn.close()


def insert_v9_track(
    conn: sqlite3.Connection,
    *,
    track_id: int,
    uuid_id: str,
    artist_id: int,
    album_id: int,
    title: str = "t",
    revision: int = 1,
    duration=180.0,
    sample_rate_hz=44100,
    channels=2,
    bitrate_kbps=320.0,
) -> None:
    conn.execute(
        "INSERT INTO tracks (id, uuid_id, file_path, revision) VALUES (?, ?, ?, ?)",
        (track_id, uuid_id, f"/music/{uuid_id}.flac", revision),
    )
    conn.execute(
        "INSERT INTO trackmetadata (track_id, uuid_id, title, artist, album, "
        "artist_id, album_id, codec, duration, bitrate_kbps, sample_rate_hz, "
        "channels, has_album_art) VALUES (?, ?, ?, 'Artist', 'Album', ?, ?, "
        "'flac', ?, ?, ?, ?, 0)",
        (
            track_id,
            uuid_id,
            title,
            artist_id,
            album_id,
            duration,
            bitrate_kbps,
            sample_rate_hz,
            channels,
        ),
    )


def open_database(path: Path) -> Database:
    """Run production initialization (fresh create or migration ladder)."""
    path.parent.mkdir(parents=True, exist_ok=True)  # as startup_event does
    db = Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))
    assert db.initialize() is True
    return db


def user_version(path: Path) -> int:
    conn = sqlite3.connect(path)
    try:
        return conn.execute("PRAGMA user_version").fetchone()[0]
    finally:
        conn.close()
