"""Phase 7A.1c (7-U01, plan D1 and decision O1): the 14 -> 15 upgrade.

v15 is one additive ladder step holding every Phase 7 table. The server
accepts v13 and v14 and upgrades both to v15 in one open (13 -> 14 -> 15);
every other version is refused by the read-only check before any write. The
admin CLI never migrates, so it requires v15.

The v13 and v14 files are real: the frozen ``fixtures/schema_v1{3,4}.sql``
plus plain SQL, opened through the production ``Database.initialize()``.
"""

import logging
import os
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.database import table_registry as registry
from app.database.database import Database, DatabaseContext, SchemaVersionRefused
from tests.schema_fixtures import (
    INIT_SQL,
    make_legacy_database,
    seed_two_user_library,
    user_version,
)

_PAST_NS = 1_000_000_000_000_000_000
OPERATOR = "uvicorn.error"  # app.core.operator_log.operator_logger
UPGRADABLE = (13, 14)


def _database(path: Path) -> Database:
    return Database(DatabaseContext(database_path=path, init_sql_path=INIT_SQL))


def _open(path: Path) -> None:
    """Production initialization alone (no test owner is seeded)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    assert _database(path).initialize() is True


def _set_user_version(path: Path, version: int) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.execute(f"PRAGMA user_version = {version}")
        conn.commit()
    finally:
        conn.close()


def _schema(path: Path) -> list:
    conn = sqlite3.connect(path)
    try:
        return conn.execute(
            "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
        ).fetchall()
    finally:
        conn.close()


def _normalized_schema(path: Path) -> set:
    return {
        (kind, name, table, " ".join(sql.split()) if sql else None)
        for kind, name, table, sql in _schema(path)
    }


def _rows(path: Path, tables=None) -> dict:
    """Every row of every table (shadow tables and sqlite_sequence included)."""
    conn = sqlite3.connect(path)
    try:
        if tables is None:
            tables = [
                r[0] for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table' "
                    "AND sql NOT LIKE 'CREATE VIRTUAL TABLE%'"
                )
            ]
        return {t: sorted(conn.execute(f'SELECT * FROM "{t}"').fetchall()) for t in tables}
    finally:
        conn.close()


def _fts(path: Path, table: str, token: str) -> list:
    conn = sqlite3.connect(path)
    try:
        return sorted(
            r[0] for r in conn.execute(f"SELECT rowid FROM {table} WHERE {table} MATCH ?", (token,))
        )
    finally:
        conn.close()


def _seed_identity_rows(conn: sqlite3.Connection) -> None:
    """Phase 6.5 rows as its worker leaves them: identities for every live
    track, one fingerprint, one open duplicate pair."""
    for uuid in ("u-sam-1", "u-sam-2", "u-alex-1", "u-alex-2"):
        conn.execute(
            "INSERT INTO track_audio_identity (uuid_id, generation, exact_state, exact_kind, "
            "exact_digest, sample_rate_hz, channels, bits_per_sample, fp_state, match_state, "
            "priority, stat_size, stat_mtime_ns, stat_inode, computed_at, tool_versions) "
            "VALUES (?, 2, 'current', 'pcm_sha256', ?, 44100, 2, 16, 'current', 'current', "
            "1, 1000, 5000, 77, 600, 'ffmpeg 8.1; fpcalc 1.6.2')",
            (uuid, "ab" * 32 if uuid.endswith("-1") else "cd" * 32),
        )
    conn.execute(
        "INSERT INTO track_audio_fingerprint VALUES "
        "('u-alex-1', 'fpcalc', 'chromaprint-2', 180.5, 3, X'0102030405')"
    )
    conn.execute(
        "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
        "sort_score, matcher_version, detected_at) "
        "VALUES (2, 'u-alex-1', 'u-alex-2', 'fingerprint', 1, 0.93, 'm1', 700)"
    )


def _rich(path: Path, version: int) -> None:
    """A real v13 or v14 file holding two users' libraries."""
    make_legacy_database(path, version)
    conn = sqlite3.connect(path)
    try:
        seed_two_user_library(conn)
        if version >= 14:
            _seed_identity_rows(conn)
        conn.commit()
    finally:
        conn.close()


# --- the version window -----------------------------------------------------------------------


def test_the_latest_schema_is_15():
    assert Database.LATEST_SCHEMA_VERSION == 15
    assert Database.MINIMUM_SCHEMA_VERSION == 13


def test_a_fresh_database_lands_on_15(tmp_path):
    path = tmp_path / "database.db"
    _open(path)
    assert user_version(path) == 15


@pytest.mark.parametrize("version", UPGRADABLE)
def test_an_upgradable_database_reaches_15_in_one_open_and_keeps_its_instance_id(tmp_path, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, version)

    db = _database(path)
    assert db.initialize() is True

    assert user_version(path) == 15
    assert db.get_server_instance_id() == f"inst-v{version}"


@pytest.mark.parametrize("version", [12, 16])
def test_versions_outside_13_to_15_are_refused_untouched(tmp_path, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, 13)
    _set_user_version(path, version)
    os.utime(path, ns=(_PAST_NS, _PAST_NS))
    data, mtime, listing = path.read_bytes(), path.stat().st_mtime_ns, sorted(os.listdir(tmp_path))

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert f"schema {version}" in str(refused.value)
    assert path.read_bytes() == data
    assert path.stat().st_mtime_ns == mtime
    assert sorted(os.listdir(tmp_path)) == listing


@pytest.mark.parametrize("version", [12, 16])
def test_a_refused_wal_file_keeps_its_sidecars_untouched(tmp_path, version):
    """The refusal comes before any write, ``-wal`` and ``-shm`` included."""
    source = tmp_path / "source.db"
    make_legacy_database(source, 13)
    _set_user_version(source, version)
    holder = sqlite3.connect(source)
    holder.execute("PRAGMA journal_mode=WAL")
    holder.execute("INSERT INTO app_settings (key, value) VALUES ('pending', 'frame')")
    holder.commit()
    path = tmp_path / "copy" / "database.db"
    path.parent.mkdir()
    for suffix in ("", "-wal", "-shm"):
        Path(f"{source}{suffix}").exists() and Path(f"{path}{suffix}").write_bytes(
            Path(f"{source}{suffix}").read_bytes()
        )
    holder.close()
    files = sorted(p for p in path.parent.iterdir())
    assert {p.name for p in files} == {"database.db", "database.db-wal", "database.db-shm"}
    for p in files:
        os.utime(p, ns=(_PAST_NS, _PAST_NS))
    before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in files}

    with pytest.raises(SchemaVersionRefused):
        _database(path).initialize()

    after = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in path.parent.iterdir()}
    assert after == before


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_cli_check_refuses_an_upgradable_file_untouched(tmp_path, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, version)
    os.utime(path, ns=(_PAST_NS, _PAST_NS))
    data, mtime = path.read_bytes(), path.stat().st_mtime_ns

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).require_current_schema()

    message = str(refused.value)
    assert f"schema {version}" in message
    assert "upgrade it to schema 15" in message
    assert path.read_bytes() == data and path.stat().st_mtime_ns == mtime


def test_the_cli_check_accepts_15(tmp_path):
    path = tmp_path / "database.db"
    _rich(path, 14)
    _open(path)

    _database(path).require_current_schema()


# --- the upgrade keeps every existing row ----------------------------------------------------


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_upgrade_keeps_every_existing_row_byte_for_byte(tmp_path, version):
    """Ids, uuids, revisions, timestamps, identity rows, FTS (shadow tables)
    and ``sqlite_sequence`` are unchanged; nothing is bumped."""
    path = tmp_path / "database.db"
    _rich(path, version)
    before = _rows(path)

    _open(path)

    assert _rows(path, tables=list(before)) == before
    assert _fts(path, "fts_tracks", "lucky") == [11, 21]
    assert _fts(path, "fts_tracks", "gone") == []
    sequence = dict(before["sqlite_sequence"])
    assert sequence["conversion_jobs"] == 3 and sequence["tracks"] == 23
    assert user_version(path) == 15


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_upgraded_file_is_consistent_and_verifies(tmp_path, version):
    path = tmp_path / "database.db"
    _rich(path, version)

    _open(path)

    conn = sqlite3.connect(path)
    try:
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []
        assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert registry.verify(conn) == []
    finally:
        conn.close()


@pytest.mark.parametrize("version", UPGRADABLE)
def test_a_second_open_changes_no_row_and_no_schema(tmp_path, version):
    path = tmp_path / "database.db"
    _rich(path, version)
    _open(path)
    rows, schema = _rows(path), _schema(path)

    _open(path)

    assert _rows(path) == rows
    assert _schema(path) == schema
    assert user_version(path) == 15


@pytest.mark.parametrize("stale", UPGRADABLE)
def test_a_stale_outer_read_is_a_no_op_on_a_v15_file(tmp_path, monkeypatch, stale):
    path = tmp_path / "database.db"
    _rich(path, 14)
    _open(path)
    rows, schema = _rows(path), _schema(path)

    monkeypatch.setattr(Database, "_existing_schema_version", lambda self: stale)
    assert _database(path).initialize() is True

    assert _rows(path) == rows
    assert _schema(path) == schema
    assert user_version(path) == 15


@pytest.mark.parametrize("version", UPGRADABLE)
def test_a_fresh_v15_schema_equals_a_migrated_one(tmp_path, version):
    fresh = tmp_path / "fresh" / "database.db"
    migrated = tmp_path / "migrated" / "database.db"
    _open(fresh)
    migrated.parent.mkdir()
    _rich(migrated, version)
    _open(migrated)

    assert _normalized_schema(fresh) == _normalized_schema(migrated)


# --- the operator log -------------------------------------------------------------------------


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_upgrade_is_logged_once_from_the_files_version_to_15(tmp_path, caplog, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, version)

    with caplog.at_level(logging.INFO, logger=OPERATOR):
        _database(path).initialize()

    lines = [r.getMessage() for r in caplog.records if r.name == OPERATOR and "schema" in r.getMessage()]
    assert lines == [f"database schema upgraded from {version} to 15"]


# --- the real startup -------------------------------------------------------------------------


@pytest.mark.parametrize("version", UPGRADABLE)
def test_server_startup_upgrades_an_old_data_dir(tmp_path, configure_app, version):
    """The upgrade runs inside the real startup, under the instance lock."""
    path = tmp_path / "data" / "database" / "database.db"
    _rich(path, version)
    main = configure_app()

    with TestClient(main.app):
        assert user_version(path) == 15

    conn = sqlite3.connect(path)
    try:
        assert registry.verify(conn) == []
    finally:
        conn.close()


# --- a failure inside the step ----------------------------------------------------------------


def _deny_creating(index: str):
    """A connection factory whose authorizer refuses creating ``index``: the
    step fails after its earlier DDL already ran."""
    real_connect = sqlite3.connect

    def connect(*args, **kwargs):
        conn = real_connect(*args, **kwargs)

        def authorizer(action, arg1, *_):
            if action == sqlite3.SQLITE_CREATE_INDEX and arg1 == index:
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK

        conn.set_authorizer(authorizer)
        return conn

    return connect


@pytest.mark.parametrize("index", ["idx_upload_batches_list", "idx_upload_journal_item"])
@pytest.mark.parametrize("version", UPGRADABLE)
def test_a_failure_mid_step_rolls_back_to_the_files_version(tmp_path, monkeypatch, version, index):
    """Both steps share one transaction: a v13 file stays at 13 (not 14).
    The step fails at its first and at its last v15 object."""
    path = tmp_path / "database.db"
    _rich(path, version)
    rows, schema = _rows(path), _schema(path)

    with monkeypatch.context() as patch:
        patch.setattr(sqlite3, "connect", _deny_creating(index))
        with pytest.raises(sqlite3.DatabaseError):
            _database(path).initialize()

    assert user_version(path) == version
    assert _schema(path) == schema  # no partial table or index
    assert _rows(path) == rows

    _open(path)  # the next start upgrades it
    assert user_version(path) == 15
