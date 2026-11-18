"""Real previous-version backend databases.

``fixtures/schema_v<N>.sql`` is the frozen ``init.sql`` of schema version N:
v9 (``main`` @ 3ee4c9e, the last pre-Phase-5 schema), v11 (PR 5A.0,
``phase-5a0`` @ 747fa35, before the history tables), v12 (``main`` @
a516b17, the last pre-multi-user schema), v13 (``roadmap-integration`` @
92adfe0, Phase M's fresh schema, the last before Phase 6.5) and v14
(``roadmap-integration`` @ 2e4e4a4, Phase 6.5's audio identity, the last
before Phase 7). The server refuses v9-v12 and upgrades v13 and v14; the
tests build them with plain SQL and open them through the production
``Database.initialize()``.
"""

import sqlite3
from pathlib import Path

from app.database.database import DatabaseContext
from tests.owned_database import OwnedTestDatabase

FIXTURES = Path(__file__).parent / "fixtures"
LEGACY_VERSIONS = (9, 11, 12, 13, 14)
INIT_SQL = Path(__file__).parent.parent / "app" / "database" / "init.sql"


def make_legacy_database(path: Path, version: int) -> None:
    """An empty database at a frozen schema ``version`` (9, 11, 12, 13 or 14).
    From v11 on it carries a server instance id, as those versions shipped."""
    if version not in LEGACY_VERSIONS:
        raise ValueError(f"no frozen schema for version {version}")
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        conn.executescript((FIXTURES / f"schema_v{version}.sql").read_text())
        conn.execute(f"PRAGMA user_version = {version}")
        if version >= 11:
            conn.execute(
                "INSERT INTO app_settings (key, value) "
                "VALUES ('server_instance_id', ?)",
                (f"inst-v{version}",),
            )
        conn.commit()
    finally:
        conn.close()


def seed_two_user_library(conn: sqlite3.Connection) -> None:
    """A Phase M library as a running server leaves it, in plain SQL valid on
    v13 and later: two users with tracks, metadata, FTS rows, an edited-away
    FTS entry, a tombstone, a journal row, conversion jobs (one deleted, so
    ``sqlite_sequence`` runs ahead of the highest id), history and settings.
    The caller commits."""
    conn.execute("PRAGMA foreign_keys=ON")
    for uid, name in ((1, "sam"), (2, "alex")):
        conn.execute(
            "INSERT INTO users (id, username, username_key, password_hash, "
            "library_folder, created_at) VALUES (?, ?, ?, 'h', ?, 1)",
            (uid, name.title(), name, name),
        )
        conn.execute("INSERT INTO user_settings VALUES (?, 'k', 'v')", (uid,))
        conn.execute(
            "INSERT INTO artists (id, name, owner_id) VALUES (?, 'Radiohead', ?)", (uid, uid)
        )
        conn.execute(
            "INSERT INTO albums (id, name, artist_id) VALUES (?, 'OK Computer', ?)", (uid, uid)
        )
        conn.execute(
            "INSERT INTO fts_artists (rowid, name) VALUES (?, 'Radiohead')", (uid,)
        )
        conn.execute(
            "INSERT INTO fts_albums (rowid, name, artist_name) "
            "VALUES (?, 'OK Computer', 'Radiohead')",
            (uid,),
        )
    tracks = [
        (11, "u-sam-1", 1, "Lucky", 5),
        (12, "u-sam-2", 1, "Airbag", 6),
        (21, "u-alex-1", 2, "Lucky", 7),
        (22, "u-alex-2", 2, "Idioteque", 8),
        (23, "u-alex-3", 2, "Gone", 9),
    ]
    for track_id, uuid, owner, title, revision in tracks:
        conn.execute(
            "INSERT INTO tracks (id, uuid_id, file_path, created_at, last_updated, "
            "revision, owner_id) VALUES (?, ?, ?, 100, 200, ?, ?)",
            (track_id, uuid, f"/music/{owner}/{uuid}.flac", revision, owner),
        )
        conn.execute(
            "INSERT INTO trackmetadata (track_id, uuid_id, title, artist, album, "
            "artist_id, album_id, codec, duration, has_album_art) "
            "VALUES (?, ?, ?, 'Radiohead', 'OK Computer', ?, ?, 'flac', NULL, 0)",
            (track_id, uuid, title, owner, owner),
        )
        conn.execute(
            "INSERT INTO fts_tracks (rowid, title, artist_name, album_name) "
            "VALUES (?, ?, 'Radiohead', 'OK Computer')",
            (track_id, title),
        )
    # Alex deletes "Gone": rows go, a tombstone stays, sqlite_sequence keeps 23.
    conn.execute(
        "INSERT INTO fts_tracks (fts_tracks, rowid, title, artist_name, album_name) "
        "VALUES ('delete', 23, 'Gone', 'Radiohead', 'OK Computer')"
    )
    conn.execute("DELETE FROM trackmetadata WHERE track_id = 23")
    conn.execute("DELETE FROM tracks WHERE id = 23")
    conn.execute("INSERT INTO track_tombstones VALUES ('u-alex-3', 300, 10, 2)")
    conn.execute("UPDATE revision_counter SET value = 10")
    conn.execute(
        "INSERT INTO edit_journal (intent, uuid_id, old_path, created_at, owner_id) "
        "VALUES ('relocate', 'u-sam-1', '/music/1/old.flac', 400, 1)"
    )
    for uuid, owner in (("u-sam-2", 1), ("u-alex-1", 2), ("u-alex-2", 2)):
        conn.execute(
            "INSERT INTO conversion_jobs (uuid_id, target_codec, target_container, "
            "status, owner_id) VALUES (?, 'aac', 'm4a', 'done', ?)",
            (uuid, owner),
        )
    conn.execute("DELETE FROM conversion_jobs WHERE id = 3")
    conn.execute(
        "INSERT INTO history_events VALUES ('e1', 1, 'play', 'track', 'u-sam-1', 0, "
        "1.0, 2.0, 0, 1)"
    )


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


def open_database(path: Path) -> OwnedTestDatabase:
    """Run production initialization and seed the adapter's test owner."""
    path.parent.mkdir(parents=True, exist_ok=True)  # as startup_event does
    db = OwnedTestDatabase(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))
    assert db.initialize() is True
    return db


def user_version(path: Path) -> int:
    conn = sqlite3.connect(path)
    try:
        return conn.execute("PRAGMA user_version").fetchone()[0]
    finally:
        conn.close()
