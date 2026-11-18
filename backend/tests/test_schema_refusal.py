"""A database at any other schema version is refused, untouched.

The server opens exactly the schema version ``init.sql`` creates. A file at
another ``user_version`` (a database from before the version reset, one
written by a later server, or tables with no version at all) is refused
through a read-only version check that runs before any pragma or write, so
the refused file keeps its exact bytes and mtime and gains no ``-wal``/``-shm``
sidecar. Startup raises instead of serving; the admin tool's check
(``require_current_schema``) refuses the same way.

The words of the refusal are pinned in one place, ``test_the_refusal_sentences``;
every other test here checks the exception and the version it found.
"""

import hashlib
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
    FIXTURES,
    INIT_SQL,
    PRE_RESET_VERSION,
    REFUSED_VERSIONS,
    make_database_at,
    make_pre_reset_database,
    open_database,
    user_version,
)

# A fixed, clearly-past mtime: any write by the refusal path would move it.
_PAST_NS = 1_000_000_000_000_000_000
LATEST = Database.LATEST_SCHEMA_VERSION


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


# --- the words ----------------------------------------------------------------------------------


@pytest.mark.parametrize(
    "found,latest,minimum,sentence",
    [
        # One or more steps behind a server that has steps: only the admin tool says this.
        (1, 2, 1,
         "This database is at schema 1; start the server once to upgrade it to schema 2, "
         "then run this command again."),
        # Every version no upgrade reaches gets one sentence (owner, 2026-11-17):
        # below the oldest version the server upgrades from,
        (0, 1, 1,
         "This database has schema 0; this server reads schema 1. Back it up and start "
         "with a fresh APP_DATA_DIR."),
        # above the latest version (today also a database from before the reset),
        (17, 1, 1,
         "This database has schema 17; this server reads schema 1. Back it up and start "
         "with a fresh APP_DATA_DIR."),
        # and the same on a server that has steps, below and above its window.
        (1, 3, 2,
         "This database has schema 1; this server reads schema 3. Back it up and start "
         "with a fresh APP_DATA_DIR."),
        (4, 3, 2,
         "This database has schema 4; this server reads schema 3. Back it up and start "
         "with a fresh APP_DATA_DIR."),
    ],
    ids=["behind-a-server-with-steps", "below-the-window", "above-the-window",
         "below-the-window-of-a-server-with-steps", "above-the-window-of-a-server-with-steps"],
)
def test_the_refusal_sentences(found, latest, minimum, sentence):
    refused = SchemaVersionRefused(found, latest, minimum)

    assert str(refused) == sentence
    assert refused.found_version == found


def test_a_refused_file_is_told_this_servers_own_version(tmp_path):
    """The supported number in the sentence is ``LATEST_SCHEMA_VERSION``, the
    number this server reads, whatever version the file has."""
    path = tmp_path / "database.db"
    make_pre_reset_database(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert str(refused.value) == (
        f"This database has schema {PRE_RESET_VERSION}; this server reads schema "
        f"{Database.LATEST_SCHEMA_VERSION}. Back it up and start with a fresh APP_DATA_DIR."
    )


# --- another version, at start-up ---------------------------------------------------------------


@pytest.mark.parametrize("version", REFUSED_VERSIONS)
def test_a_database_of_another_version_is_refused_untouched(tmp_path, version):
    path = tmp_path / "database.db"
    make_database_at(path, version)
    before = _snapshot(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert refused.value.found_version == version
    _assert_untouched(path, before)


def test_the_pre_reset_database_is_a_real_version_17_file(tmp_path):
    """What the refusal tests call "17" is a database built from the schema
    file of the last commit before the reset, holding two users' libraries."""
    path = tmp_path / "database.db"
    make_pre_reset_database(path)

    # init.sql at the last commit before the reset, byte for byte.
    frozen = (FIXTURES / "schema_v17.sql").read_bytes()
    assert hashlib.sha256(frozen).hexdigest() == (
        "dcc3623a2aae959a3f224c0b88ebebcbfe6e8baca00e02dfdd2112912b4e8472"
    )
    assert user_version(path) == PRE_RESET_VERSION == 17
    conn = sqlite3.connect(path)
    try:
        assert conn.execute("SELECT count(*) FROM users").fetchone()[0] == 2
        assert conn.execute("SELECT count(*) FROM tracks").fetchone()[0] == 4
        assert conn.execute("SELECT count(*) FROM sqlite_master").fetchone()[0] > 100
    finally:
        conn.close()


def test_unversioned_database_with_tables_is_refused_untouched(tmp_path):
    path = tmp_path / "database.db"
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE not_ours (id INTEGER PRIMARY KEY)")
    conn.commit()
    conn.close()
    before = _snapshot(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert refused.value.found_version == 0
    _assert_untouched(path, before)


def test_version_is_checked_before_any_write_connection(tmp_path, monkeypatch):
    """The WAL pragma in ``_connection()`` would rewrite a non-WAL header, so
    the refusal must never reach it."""
    path = tmp_path / "database.db"
    make_pre_reset_database(path)

    def _no_write_connection(self, **kwargs):
        raise AssertionError("_connection() opened before the version check")

    monkeypatch.setattr(Database, "_connection", _no_write_connection)
    with pytest.raises(SchemaVersionRefused):
        _database(path).initialize()


def test_startup_raises_on_a_pre_reset_database(tmp_path, configure_app):
    path = tmp_path / "data" / "database" / "database.db"
    make_pre_reset_database(path)
    before = _snapshot(path)
    main = configure_app()

    with pytest.raises(SchemaVersionRefused) as refused:
        with TestClient(main.app):
            pass

    assert refused.value.found_version == PRE_RESET_VERSION
    _assert_untouched(path, before)


# --- write-ahead-log files ------------------------------------------------------------------------


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


def test_wal_mode_database_of_another_version_without_sidecars_is_refused_untouched(tmp_path):
    path = tmp_path / "database.db"
    make_pre_reset_database(path)
    _without_wal_sidecars(path)
    before = _snapshot(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert refused.value.found_version == PRE_RESET_VERSION
    _assert_untouched(path, before)


# Live gate m-L-01 (M-L01b): a server stopped uncleanly leaves -wal and -shm
# next to the file. The refusal leaves all of them untouched, the WAL index
# included.

_SIDECARS = ("-wal", "-shm")
# Neither the main file's 17 nor a version the server opens, whatever the latest is.
_ONLY_IN_THE_WAL = max(LATEST, PRE_RESET_VERSION) + 4


def _copy_with_live_sidecars(source: Path, target: Path) -> None:
    """Copy a WAL-mode file and its sidecars while a writer still has
    uncheckpointed frames, the way an unclean shutdown leaves them. The
    ``user_version`` lives only in the WAL, so a reader that skips the WAL
    would see the wrong version."""
    conn = sqlite3.connect(source)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA wal_autocheckpoint=0")
        conn.execute(f"PRAGMA user_version = {_ONLY_IN_THE_WAL}")
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


def _file_whose_wal_holds_its_version(tmp_path) -> Path:
    source = tmp_path / "writer" / "database.db"
    make_pre_reset_database(source)  # the main file says 17
    path = tmp_path / "data" / "database.db"
    path.parent.mkdir()
    _copy_with_live_sidecars(source, path)
    return path


def test_database_with_wal_and_shm_is_refused_untouched(tmp_path):
    path = _file_whose_wal_holds_its_version(tmp_path)
    before = _snapshot_all(path)
    assert len(before[0]) == 3

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert refused.value.found_version == _ONLY_IN_THE_WAL  # read through the WAL
    _assert_all_untouched(path, before)


def test_database_with_wal_but_no_shm_is_refused_untouched(tmp_path):
    path = _file_whose_wal_holds_its_version(tmp_path)
    Path(f"{path}-shm").unlink()
    before = _snapshot_all(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert refused.value.found_version == _ONLY_IN_THE_WAL
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


@pytest.mark.parametrize("version", REFUSED_VERSIONS)
def test_require_current_schema_refuses_other_versions_untouched(tmp_path, version):
    path = tmp_path / "database.db"
    make_database_at(path, version)
    before = _snapshot(path)

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).require_current_schema()

    assert refused.value.found_version == version
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


# Other-issues row 37: a database file the server's user cannot read is a
# file-system problem, not a damaged database: the refusal says what to check
# instead of "Back it up and start with a fresh APP_DATA_DIR".


def _permissions_hint(path: Path, error: str) -> str:
    return (
        f"{path} cannot be read ({error}). Check the permissions and owner of this file, "
        "its -wal and -shm files and its folder: the user the server runs as must be able "
        "to read and write them."
    )


@pytest.mark.requires_chmod_denial
def test_an_unreadable_database_file_is_refused_with_what_to_check(tmp_path):
    path = tmp_path / "database.db"
    open_database(path)
    for suffix in ("-wal", "-shm"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)
    os.chmod(path, 0)
    try:
        with pytest.raises(DatabaseUnreadable) as refused:
            _database(path).initialize()
    finally:
        os.chmod(path, 0o600)

    assert str(refused.value) == _permissions_hint(path, "unable to open database file")


@pytest.mark.requires_chmod_denial
def test_an_unreadable_wal_file_is_refused_with_what_to_check(tmp_path):
    path = _file_whose_wal_holds_its_version(tmp_path)
    Path(f"{path}-shm").unlink()
    wal = Path(f"{path}-wal")
    os.chmod(wal, 0)
    try:
        with pytest.raises(DatabaseUnreadable) as refused:
            _database(path).require_current_schema()
    finally:
        os.chmod(wal, 0o600)

    assert str(refused.value) == _permissions_hint(
        path, f"[Errno 13] Permission denied: '{wal}'"
    )


def test_a_directory_at_the_database_path_keeps_the_back_it_up_sentence(tmp_path):
    path = tmp_path / "database.db"
    path.mkdir()

    with pytest.raises(DatabaseUnreadable) as refused:
        _database(path).require_current_schema()

    assert str(refused.value) == (
        f"{path} cannot be read as a SQLite database (unable to open database file). "
        "Back it up and start with a fresh APP_DATA_DIR."
    )


def test_a_disk_error_while_reading_the_wal_keeps_the_back_it_up_sentence(tmp_path, monkeypatch):
    """Review m1: only a permission problem gets the permissions advice; a full
    disk while copying the -wal (no -shm) is not one."""
    path = _file_whose_wal_holds_its_version(tmp_path)
    Path(f"{path}-shm").unlink()

    def full_disk(src, dst, *args, **kwargs):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr("app.database.database.shutil.copyfile", full_disk)

    with pytest.raises(DatabaseUnreadable) as refused:
        _database(path).require_current_schema()

    assert str(refused.value) == (
        f"{path} cannot be read as a SQLite database ([Errno 28] No space left on device). "
        "Back it up and start with a fresh APP_DATA_DIR."
    )
