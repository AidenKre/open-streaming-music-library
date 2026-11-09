"""SC-04 / Phase 5 §3a: stable artist/album identity (5-U10, 5-T17/5-T18 unit form).

artists/albums move from ``INTEGER PRIMARY KEY`` to ``INTEGER PRIMARY KEY
AUTOINCREMENT`` through the SC-16k rebuild helper, preserving every live ID,
the generated ``name_lower``, all indexes, the trackmetadata FKs and the
contentless FTS row ids. Afterwards a deleted highest parent ID is never
reused, even across a restart.
"""

import re
import sqlite3
import uuid
from pathlib import Path

import pytest

from app.database.database import Database, DatabaseContext
from app.models import Track, TrackMetaData

from tests.schema_fixtures import (
    INIT_SQL,
    insert_v9_track,
    make_v9_database,
    open_database,
    user_version,
)

ARTISTS = [(1, "Alpha"), (5, "Beta"), (9, "Gamma")]
# (id, name, artist_id, year, is_single_grouping)
ALBUMS = [(2, "One", 1, 2001, 0), (8, None, 5, None, 1), (12, "Two", 9, 1999, 0)]
TRACKS = {"t1": (1, 2), "t2": (5, 8), "t3": (9, 12)}  # uuid -> (artist_id, album_id)
UUIDS = {name: str(uuid.UUID(int=i + 1)) for i, name in enumerate(TRACKS)}


def _populate_v9(path: Path, *, dangling_album: bool = False) -> None:
    make_v9_database(path)
    conn = sqlite3.connect(path)
    try:
        conn.execute("PRAGMA foreign_keys=OFF")
        conn.executemany("INSERT INTO artists (id, name) VALUES (?, ?)", ARTISTS)
        conn.executemany(
            "INSERT INTO albums (id, name, artist_id, year, is_single_grouping) "
            "VALUES (?, ?, ?, ?, ?)",
            ALBUMS,
        )
        for artist_id, name in ARTISTS:
            conn.execute("INSERT INTO fts_artists(rowid, name) VALUES (?, ?)", (artist_id, name))
        names = dict(ARTISTS)
        for album_id, name, artist_id, _, _ in ALBUMS:
            conn.execute(
                "INSERT INTO fts_albums(rowid, name, artist_name) VALUES (?, ?, ?)",
                (album_id, name or "", names[artist_id]),
            )
        for i, (name, (artist_id, album_id)) in enumerate(TRACKS.items(), start=1):
            insert_v9_track(
                conn,
                track_id=i,
                uuid_id=UUIDS[name],
                artist_id=artist_id,
                album_id=album_id,
                title=name,
                revision=i,
            )
            conn.execute(
                "INSERT INTO fts_tracks(rowid, title, artist_name, album_name) VALUES (?, ?, ?, ?)",
                (i, name, "Artist", "Album"),
            )
        if dangling_album:
            # Fault injection: a reference the rebuild's foreign_key_check rejects.
            conn.execute("UPDATE trackmetadata SET album_id = 999 WHERE track_id = 1")
        conn.execute("UPDATE revision_counter SET value = ?", (len(TRACKS),))
        conn.commit()
    finally:
        conn.close()


def _q(path: Path, sql: str, params=()):
    conn = sqlite3.connect(path)
    try:
        return conn.execute(sql, params).fetchall()
    finally:
        conn.close()


def _table_sql(path: Path, name: str) -> str:
    return _q(path, "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (name,))[0][0]


@pytest.fixture
def migrated(tmp_path) -> Path:
    path = tmp_path / "database.db"
    _populate_v9(path)
    open_database(path)
    return path


def test_upgrade_reaches_latest_version(migrated):
    assert user_version(migrated) == Database.LATEST_SCHEMA_VERSION
    assert Database.LATEST_SCHEMA_VERSION >= 11


def test_upgrade_preserves_parent_rows(migrated):
    assert _q(migrated, "SELECT id, name, name_lower FROM artists ORDER BY id") == [
        (1, "Alpha", "alpha"),
        (5, "Beta", "beta"),
        (9, "Gamma", "gamma"),
    ]
    assert _q(
        migrated,
        "SELECT id, name, name_lower, artist_id, year, is_single_grouping FROM albums ORDER BY id",
    ) == [
        (2, "One", "one", 1, 2001, 0),
        (8, None, None, 5, None, 1),
        (12, "Two", "two", 9, 1999, 0),
    ]
    # Tracks still point at the same parents.
    assert dict(
        _q(migrated, "SELECT uuid_id, album_id FROM trackmetadata")
    ) == {UUIDS[n]: album for n, (_, album) in TRACKS.items()}


def test_upgrade_makes_parents_autoincrement_with_sequence_floor(migrated):
    assert "AUTOINCREMENT" in _table_sql(migrated, "artists").upper()
    assert "AUTOINCREMENT" in _table_sql(migrated, "albums").upper()
    seq = dict(_q(migrated, "SELECT name, seq FROM sqlite_sequence"))
    assert seq["artists"] >= 9
    assert seq["albums"] >= 12


def test_upgrade_keeps_indexes_and_uniqueness(migrated):
    index_names = {r[0] for r in _q(migrated, "SELECT name FROM sqlite_master WHERE type='index'")}
    assert {
        "idx_artists_name_lower",
        "idx_albums_regular",
        "idx_albums_singles",
        "idx_albums_name_lower",
        "idx_albums_artist_id",
    } <= index_names
    conn = sqlite3.connect(migrated)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute("INSERT INTO artists (name) VALUES ('ALPHA')")
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(
                "INSERT INTO albums (name, artist_id, year, is_single_grouping) VALUES ('one', 1, 1990, 0)"
            )
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(
                "INSERT INTO albums (name, artist_id, year, is_single_grouping) VALUES (NULL, 5, NULL, 1)"
            )
    finally:
        conn.close()


def test_upgrade_keeps_foreign_keys_and_fts_ids(migrated):
    assert _q(migrated, "PRAGMA foreign_key_check") == []
    fk_targets = {r[2] for r in _q(migrated, "PRAGMA foreign_key_list(trackmetadata)")}
    assert {"artists", "albums", "tracks"} <= fk_targets
    assert {r[2] for r in _q(migrated, "PRAGMA foreign_key_list(albums)")} == {"artists"}
    assert _q(migrated, "SELECT rowid FROM fts_artists WHERE fts_artists MATCH 'gamma'") == [(9,)]
    assert _q(migrated, "SELECT rowid FROM fts_albums WHERE fts_albums MATCH 'two'") == [(12,)]


def _add(db: Database, tmp_path: Path, artist: str, album: str) -> str:
    uid = str(uuid.uuid4())
    assert db.add_track(
        Track(
            uuid_id=uid,
            file_path=tmp_path / f"{uid}.flac",
            metadata=TrackMetaData(title="new", artist=artist, album=album, codec="flac"),
        )
    )
    return uid


def _parents_of(db: Database, uid: str) -> tuple[int, int]:
    meta = db.get_track_by_uuid(uid).metadata
    return meta.artist_id, meta.album_id


def test_deleted_highest_parents_are_not_reused_after_restart(migrated, tmp_path):
    db = open_database(migrated)
    assert db.delete_track(UUIDS["t3"])  # orphans artist 9 and album 12
    assert _q(migrated, "SELECT id FROM artists WHERE id = 9") == []
    assert _q(migrated, "SELECT id FROM albums WHERE id = 12") == []

    restarted = open_database(migrated)
    artist_id, album_id = _parents_of(restarted, _add(restarted, tmp_path, "Delta", "Three"))
    assert artist_id > 9
    assert album_id > 12


def test_deleting_every_parent_then_restart_never_reuses_ids(migrated, tmp_path):
    db = open_database(migrated)
    for uid in UUIDS.values():
        assert db.delete_track(uid)
    assert _q(migrated, "SELECT COUNT(*) FROM artists") == [(0,)]
    assert _q(migrated, "SELECT COUNT(*) FROM albums") == [(0,)]

    restarted = open_database(migrated)
    artist_id, album_id = _parents_of(restarted, _add(restarted, tmp_path, "Epsilon", "Four"))
    assert artist_id > 9
    assert album_id > 12


def test_second_open_is_idempotent(migrated):
    before = (
        _q(migrated, "SELECT * FROM artists ORDER BY id"),
        _q(migrated, "SELECT * FROM albums ORDER BY id"),
        _q(migrated, "SELECT name, seq FROM sqlite_sequence ORDER BY name"),
    )
    open_database(migrated)
    after = (
        _q(migrated, "SELECT * FROM artists ORDER BY id"),
        _q(migrated, "SELECT * FROM albums ORDER BY id"),
        _q(migrated, "SELECT name, seq FROM sqlite_sequence ORDER BY name"),
    )
    assert after == before
    assert user_version(migrated) == Database.LATEST_SCHEMA_VERSION


def test_upgrade_from_v8_runs_the_whole_ladder(tmp_path):
    path = tmp_path / "database.db"
    _populate_v9(path)
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA user_version = 8")
    conn.commit()
    conn.close()

    open_database(path)

    assert user_version(path) == Database.LATEST_SCHEMA_VERSION
    assert "AUTOINCREMENT" in _table_sql(path, "artists").upper()
    assert _q(path, "SELECT id FROM artists ORDER BY id") == [(1,), (5,), (9,)]


def _normalize_sql(sql: str | None) -> str | None:
    if sql is None:
        return None
    return re.sub(r"\s+", "", sql.replace('"', "")).lower()


def _schema_shape(path: Path) -> dict:
    shape = {}
    tables = [r[0] for r in _q(path, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
    for table in tables:
        shape[("table", table)] = (
            _q(path, f'PRAGMA table_xinfo("{table}")'),
            sorted(_q(path, f'PRAGMA foreign_key_list("{table}")')),
            "AUTOINCREMENT" in (_table_sql(path, table) or "").upper(),
        )
    for name, tbl, sql in _q(
        path, "SELECT name, tbl_name, sql FROM sqlite_master WHERE type='index' ORDER BY name"
    ):
        shape[("index", name)] = (tbl, _normalize_sql(sql))
    return shape


def test_fresh_and_migrated_schemas_are_equivalent(migrated, tmp_path):
    fresh = tmp_path / "fresh" / "database.db"
    fresh.parent.mkdir()
    open_database(fresh)

    assert user_version(fresh) == user_version(migrated)
    assert "AUTOINCREMENT" in _table_sql(fresh, "artists").upper()
    assert "AUTOINCREMENT" in _table_sql(fresh, "albums").upper()
    assert _schema_shape(fresh) == _schema_shape(migrated)


def test_failed_rebuild_rolls_back_and_refuses_startup(tmp_path):
    path = tmp_path / "database.db"
    _populate_v9(path, dangling_album=True)
    db = Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))

    with pytest.raises(Exception):
        db.initialize()

    assert user_version(path) < Database.LATEST_SCHEMA_VERSION
    assert "AUTOINCREMENT" not in _table_sql(path, "artists").upper()
    assert _q(path, "SELECT id FROM artists ORDER BY id") == [(1,), (5,), (9,)]
    # A backup of the pre-rebuild database was taken for operator recovery.
    others = {p.name for p in path.parent.iterdir()} - {
        "database.db",
        "database.db-wal",
        "database.db-shm",
    }
    assert others, "expected a pre-rebuild backup file next to the database"
    # Startup keeps refusing rather than half-migrating.
    with pytest.raises(Exception):
        db.initialize()


def test_v11_rebuild_verifies_the_parent_tables(tmp_path, monkeypatch):
    """Audit 5A.0(b) #4: the parent rebuild asks the helper to verify the
    artists and albums tables (row counts and id sets) at runtime."""
    import app.database.database as database_module

    seen = {}
    real = database_module.rebuild_tables

    def spy(*args, **kwargs):
        seen.update(kwargs)
        return real(*args, **kwargs)

    monkeypatch.setattr(database_module, "rebuild_tables", spy)
    path = tmp_path / "database.db"
    _populate_v9(path)
    Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL)).initialize()
    assert set(seen.get("verify_tables", ())) == {"artists", "albums"}


def test_backup_is_kept_after_a_successful_rebuild(migrated):
    """D6: the pre-v11 copy stays next to the database for operator recovery."""
    backup = migrated.with_name(migrated.name + ".pre-v11.bak")
    assert backup.exists()
    assert user_version(backup) == 10
