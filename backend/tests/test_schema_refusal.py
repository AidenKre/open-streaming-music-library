"""Phase M.0a (M-U04): databases at any other schema version are refused.

Phase M ships a fresh schema and no migration code. A file at an older or
newer ``user_version`` is refused through a read-only version check that runs
before any pragma or write, so the refused file keeps its exact bytes and
mtime and gains no ``-wal``/``-shm`` sidecar. Startup raises instead of
serving.
"""

import os
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.database.database import (
    Database,
    DatabaseContext,
    DatabaseMissing,
    DatabaseUnreadable,
    SchemaVersionRefused,
)
from tests.schema_fixtures import (
    INIT_SQL,
    insert_v9_track,
    make_legacy_database,
    open_database,
    user_version,
)

# A fixed, clearly-past mtime: any write by the refusal path would move it.
_PAST_NS = 1_000_000_000_000_000_000


def _database(path: Path) -> Database:
    return Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))


def _snapshot(path: Path):
    os.utime(path, ns=(_PAST_NS, _PAST_NS))
    return path.read_bytes(), path.stat().st_mtime_ns, sorted(os.listdir(path.parent))


def _assert_untouched(path: Path, before) -> None:
    data, mtime, listing = before
    assert path.read_bytes() == data
    assert path.stat().st_mtime_ns == mtime
    assert sorted(os.listdir(path.parent)) == listing


def _legacy_with_a_track(path: Path, version: int) -> None:
    make_legacy_database(path, version)
    conn = sqlite3.connect(path)
    try:
        insert_v9_track(conn, track_id=1, uuid_id="u-legacy", artist_id=1, album_id=1)
        conn.commit()
    finally:
        conn.close()


def _set_user_version(path: Path, version: int) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.execute(f"PRAGMA user_version = {version}")
        conn.commit()
    finally:
        conn.close()


@pytest.mark.parametrize("version", [9, 11, 12])
def test_legacy_database_is_refused_untouched(tmp_path, version):
    path = tmp_path / "database.db"
    _legacy_with_a_track(path, version)
    before = _snapshot(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    message = str(refused.value)
    assert f"predates multi-user support (schema {version})" in message
    assert "fresh APP_DATA_DIR" in message
    _assert_untouched(path, before)


def test_newer_database_is_refused_untouched(tmp_path):
    path = tmp_path / "database.db"
    open_database(path)
    newer = Database.LATEST_SCHEMA_VERSION + 1
    _set_user_version(path, newer)
    before = _snapshot(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    message = str(refused.value)
    assert f"schema {newer}" in message
    assert "newer than this server" in message
    _assert_untouched(path, before)


def test_unversioned_database_with_tables_is_refused_untouched(tmp_path):
    path = tmp_path / "database.db"
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE not_ours (id INTEGER PRIMARY KEY)")
    conn.commit()
    conn.close()
    before = _snapshot(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert "(schema 0)" in str(refused.value)
    _assert_untouched(path, before)


def test_version_is_checked_before_any_write_connection(tmp_path, monkeypatch):
    """The WAL pragma in ``_connection()`` would rewrite a non-WAL header, so
    the refusal must never reach it."""
    path = tmp_path / "database.db"
    make_legacy_database(path, 11)

    def _no_write_connection(self, **kwargs):
        raise AssertionError("_connection() opened before the version check")

    monkeypatch.setattr(Database, "_connection", _no_write_connection)
    with pytest.raises(SchemaVersionRefused):
        _database(path).initialize()


def test_startup_raises_on_a_legacy_database(tmp_path, configure_app):
    path = tmp_path / "data" / "database" / "database.db"
    _legacy_with_a_track(path, 9)
    before = _snapshot(path)
    main = configure_app()

    with pytest.raises(SchemaVersionRefused):
        with TestClient(main.app):
            pass

    _assert_untouched(path, before)


def _without_wal_sidecars(path: Path) -> None:
    """Leave a WAL-mode file the way a clean shutdown does on Linux: fully
    checkpointed, with no ``-wal``/``-shm`` next to it."""
    conn = sqlite3.connect(path)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    finally:
        conn.close()
    for suffix in ("-wal", "-shm"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)


def test_wal_mode_legacy_database_without_sidecars_is_refused_untouched(tmp_path):
    path = tmp_path / "database.db"
    _legacy_with_a_track(path, 12)
    _without_wal_sidecars(path)
    before = _snapshot(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert "(schema 12)" in str(refused.value)
    _assert_untouched(path, before)


# Live gate m-L-01 (M-L01b): a pre-M server stopped uncleanly leaves -wal and
# -shm next to the file. The refusal leaves all of them untouched, the WAL
# index included.

_SIDECARS = ("-wal", "-shm")


def _copy_with_live_sidecars(source: Path, target: Path) -> None:
    """Copy a WAL-mode file and its sidecars while a writer still has
    uncheckpointed frames, the way an unclean shutdown leaves them. The
    ``user_version`` lives only in the WAL, so a reader that skips the WAL
    would see the wrong version."""
    conn = sqlite3.connect(source)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA wal_autocheckpoint=0")
        conn.execute("PRAGMA user_version = 11")
        conn.commit()
        for suffix in ("", *_SIDECARS):
            Path(f"{target}{suffix}").write_bytes(Path(f"{source}{suffix}").read_bytes())
    finally:
        conn.close()


def _snapshot_all(path: Path):
    files = {}
    for suffix in ("", *_SIDECARS):
        member = Path(f"{path}{suffix}")
        if member.exists():
            os.utime(member, ns=(_PAST_NS, _PAST_NS))
            files[member.name] = (member.read_bytes(), member.stat().st_mtime_ns)
    return files, sorted(os.listdir(path.parent))


def _assert_all_untouched(path: Path, before) -> None:
    files, listing = before
    assert sorted(os.listdir(path.parent)) == listing
    for name, (data, mtime) in files.items():
        member = path.parent / name
        assert member.read_bytes() == data, name
        assert member.stat().st_mtime_ns == mtime, name


def test_legacy_database_with_wal_and_shm_is_refused_untouched(tmp_path):
    source = tmp_path / "writer" / "database.db"
    source.parent.mkdir()
    _legacy_with_a_track(source, 12)
    path = tmp_path / "data" / "database.db"
    path.parent.mkdir()
    _copy_with_live_sidecars(source, path)
    before = _snapshot_all(path)
    assert len(before[0]) == 3

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert "(schema 11)" in str(refused.value)  # read through the WAL
    _assert_all_untouched(path, before)


def test_legacy_database_with_wal_but_no_shm_is_refused_untouched(tmp_path):
    source = tmp_path / "writer" / "database.db"
    source.parent.mkdir()
    _legacy_with_a_track(source, 12)
    path = tmp_path / "data" / "database.db"
    path.parent.mkdir()
    _copy_with_live_sidecars(source, path)
    Path(f"{path}-shm").unlink()
    before = _snapshot_all(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert "(schema 11)" in str(refused.value)
    _assert_all_untouched(path, before)  # no -shm created


# M.0a review #4 (shared with the M.2b admin CLI): one friendly, read-only
# version check for the server and the CLI.


def test_non_sqlite_file_is_refused_untouched_with_a_clear_message(tmp_path):
    path = tmp_path / "database.db"
    path.write_bytes(b"this is a text file, not a database\n" * 200)
    before = _snapshot(path)

    with pytest.raises(DatabaseUnreadable) as refused:
        _database(path).initialize()

    message = str(refused.value)
    assert str(path) in message
    assert "not a SQLite database" in message
    assert "fresh APP_DATA_DIR" in message
    _assert_untouched(path, before)


def test_require_current_schema_accepts_the_current_version_without_writing(tmp_path):
    path = tmp_path / "database.db"
    open_database(path)
    for suffix in ("-wal", "-shm"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)
    before = _snapshot(path)

    _database(path).require_current_schema()

    _assert_untouched(path, before)


@pytest.mark.parametrize("version", [12, Database.LATEST_SCHEMA_VERSION + 1])
def test_require_current_schema_refuses_other_versions_untouched(tmp_path, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, 12)
    _set_user_version(path, version)
    before = _snapshot(path)

    with pytest.raises(SchemaVersionRefused):
        _database(path).require_current_schema()

    _assert_untouched(path, before)


def test_require_current_schema_refuses_a_non_sqlite_file(tmp_path):
    path = tmp_path / "database.db"
    path.write_bytes(b"garbage" * 1000)

    with pytest.raises(DatabaseUnreadable):
        _database(path).require_current_schema()


def test_require_current_schema_never_creates_a_missing_database(tmp_path):
    path = tmp_path / "database.db"

    with pytest.raises(DatabaseMissing) as missing:
        _database(path).require_current_schema()

    assert str(path) in str(missing.value)
    assert os.listdir(tmp_path) == []


def test_a_directory_at_the_database_path_is_a_clear_error(tmp_path):
    path = tmp_path / "database.db"
    path.mkdir()

    with pytest.raises(DatabaseUnreadable) as refused:
        _database(path).require_current_schema()

    assert str(path) in str(refused.value)


# U03-B-03: a ladder that stops short of LATEST_SCHEMA_VERSION (a bumped
# version whose step was never added) must fail the upgrade inside its
# transaction, so the file keeps its old version and gains nothing.


def _table_names(path: Path) -> set:
    conn = sqlite3.connect(path)
    try:
        return {r[0] for r in conn.execute("SELECT name FROM sqlite_master")}
    finally:
        conn.close()


def test_a_bumped_version_with_no_step_leaves_the_file_at_its_version(
    tmp_path, monkeypatch
):
    path = tmp_path / "database.db"
    open_database(path)
    current = Database.LATEST_SCHEMA_VERSION
    tables = _table_names(path)
    monkeypatch.setattr(Database, "LATEST_SCHEMA_VERSION", current + 1)

    with pytest.raises(RuntimeError, match=f"stop at schema {current}"):
        _database(path).initialize()

    assert user_version(path) == current
    assert _table_names(path) == tables


def test_a_ladder_that_stops_short_rolls_back_the_steps_it_ran(
    tmp_path, monkeypatch
):
    path = tmp_path / "database.db"
    make_legacy_database(path, 14)
    tables = _table_names(path)
    monkeypatch.setattr(
        Database, "LATEST_SCHEMA_VERSION", Database.LATEST_SCHEMA_VERSION + 1
    )

    with pytest.raises(RuntimeError, match="stop at schema"):
        _database(path).initialize()

    assert user_version(path) == 14
    assert _table_names(path) == tables
