"""Shared database helpers for the schema tests.

``fixtures/schema_v17.sql`` is the one frozen schema: ``init.sql`` as it was
at the last commit before the schema version was reset to 1
(``PRAGMA user_version = 17``), byte for byte. ``make_pre_reset_database``
builds a real database from it, so the tests can show that the server refuses
a file from before the reset. It is history: never edit it or freeze it again.
"""

import sqlite3
from pathlib import Path

from app.database.database import Database, DatabaseContext
from tests.owned_database import OwnedTestDatabase
from tests.track_paths import PATH_COLUMNS, PATH_MARKS, path_values

FIXTURES = Path(__file__).parent / "fixtures"
INIT_SQL = Path(__file__).parent.parent / "app" / "database" / "init.sql"
PRE_RESET_VERSION = 17
# Versions the server and the admin tool must refuse: 0 (tables, but no
# version stamp), the version after the latest, and the last one before the reset.
REFUSED_VERSIONS = (0, Database.LATEST_SCHEMA_VERSION + 1, PRE_RESET_VERSION)


def make_pre_reset_database(path: Path) -> None:
    """A real version-17 database as a server from before the reset left it:
    the frozen schema, an instance id and two users' libraries."""
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        conn.executescript((FIXTURES / "schema_v17.sql").read_text())
        conn.execute(
            "INSERT INTO app_settings (key, value) VALUES ('server_instance_id', 'inst-v17')"
        )
        seed_two_user_library(conn)
        conn.commit()
    finally:
        conn.close()


def make_database_at(path: Path, version: int) -> None:
    """A database stamped ``version``. Version 17 is the real thing
    (``make_pre_reset_database``). Any other version is today's tables under
    that stamp, written by plain ``sqlite3``: a rollback-journal file with no
    ``-wal`` or ``-shm`` next to it."""
    if version == PRE_RESET_VERSION:
        make_pre_reset_database(path)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        conn.executescript(INIT_SQL.read_text())
        conn.execute(f"PRAGMA user_version = {version}")
        conn.commit()
    finally:
        conn.close()


def seed_two_user_library(conn: sqlite3.Connection) -> None:
    """A library as a running server leaves it, in plain SQL (valid on today's
    schema and on the frozen version 17): two users with tracks, metadata,
    FTS rows, an edited-away FTS entry, a tombstone, a journal row, conversion
    jobs (one deleted, so ``sqlite_sequence`` runs ahead of the highest id),
    history and settings. The caller commits."""
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
    # The frozen version 17 stores the path alone, today's schema its folded form with it.
    folded = "file_path_fold" in {row[1] for row in conn.execute("PRAGMA table_info(tracks)")}
    path_columns, path_marks = (PATH_COLUMNS, PATH_MARKS) if folded else ("file_path", "?")
    for track_id, uuid, owner, title, revision in tracks:
        path = f"/music/{owner}/{uuid}.flac"
        conn.execute(
            f"INSERT INTO tracks (id, uuid_id, {path_columns}, created_at, last_updated, "
            f"revision, owner_id) VALUES (?, ?, {path_marks}, 100, 200, ?, ?)",
            (track_id, uuid, *(path_values(path) if folded else (path,)), revision, owner),
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


def make_two_user_database(path: Path) -> None:
    """A database created fresh by production initialization, with no test
    owner, holding ``seed_two_user_library`` (users 1 and 2)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    db = Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))
    assert db.initialize() is True
    conn = sqlite3.connect(path)
    try:
        seed_two_user_library(conn)
        conn.commit()
    finally:
        conn.close()


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
