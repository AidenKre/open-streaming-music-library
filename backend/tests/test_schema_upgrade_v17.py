"""Phase 9D.1b (spec §7.3, plan decision O2, review 9-U08c): the 16 -> 17 upgrade.

v17 is one additive ladder step holding the two Last.fm tables. The server
accepts v13 to v16 and upgrades each to v17 in one open; every other version
is refused by the read-only check before any write. The admin CLI never
migrates, so it requires v17.

The v13 to v16 files are real: the frozen ``fixtures/schema_v1{3,4,5,6}.sql``
plus plain SQL (two users with tracks, FTS, history, an edit journal,
identity rows, candidate pairs, upload rows, receipts and deletion rows),
opened through the production ``Database.initialize()``.
"""

import logging
import os
import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.database import table_registry as registry
from app.database.database import Database, SchemaVersionRefused
from tests.schema_fixtures import make_legacy_database, seed_two_user_library, user_version
from tests.test_schema_upgrade_v16 import (
    _connect,
    _database,
    _deny,
    _fts,
    _normalized_schema,
    _open,
    _rows,
    _schema,
    _seed_identity_rows,
    _seed_upload_rows,
    _set_user_version,
)

_PAST_NS = 1_000_000_000_000_000_000
OPERATOR = "uvicorn.error"  # app.core.operator_log.operator_logger
UPGRADABLE = (13, 14, 15, 16)
NEW_TABLES = ("lastfm_connections", "scrobble_outbox")
DELETION_OP = "00000000-0000-4000-8000-0000000000d1"


# --- realistic files at each upgradable version ------------------------------------------------


def _seed_second_history_event(conn: sqlite3.Connection) -> None:
    """``seed_two_user_library`` holds one event of Sam's; Alex gets one too."""
    conn.execute(
        "INSERT INTO history_events VALUES ('e2', 2, 'play', 'track', 'u-alex-1', 5, "
        "3.0, 4.0, 6, 2)"
    )


def _seed_deletion_rows(conn: sqlite3.Connection) -> None:
    """Phase 8 rows for both users under the same operation uuid: a receipt,
    a job, a running item and its intent-stage journal (track still live)."""
    for owner, track in ((1, "u-sam-2"), (2, "u-alex-2")):
        conn.execute(
            "INSERT INTO operation_receipts VALUES (?, ?, 'track_deletion', ?, 900, ?)",
            (owner, DELETION_OP, "d" * 64, DELETION_OP),
        )
        conn.execute(
            "INSERT INTO deletion_jobs VALUES (?, ?, 900, 'accepted')", (owner, DELETION_OP)
        )
        conn.execute(
            "INSERT INTO deletion_job_items (owner_id, operation_uuid, uuid_id, position, "
            "base_revision, status, lease_boot_id) VALUES (?, ?, ?, 0, 6, 'running', 'boot')",
            (owner, DELETION_OP, track),
        )
        conn.execute(
            "INSERT INTO deletion_journal (owner_id, operation_uuid, uuid_id, original_path, "
            "quarantine_path, base_revision, src_dev, src_ino, src_size, src_mtime_ns, "
            "master_missing, stage, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, 6, 1, 2, 3, 4, 0, 'intent', 901, 902)",
            (owner, DELETION_OP, track, f"/music/{owner}/{track}.flac", f"/q/{track}"),
        )


def _rich(path: Path, version: int) -> None:
    """A real v13, v14, v15 or v16 file holding two users' libraries."""
    make_legacy_database(path, version)
    conn = sqlite3.connect(path)
    try:
        seed_two_user_library(conn)
        _seed_second_history_event(conn)
        if version >= 14:
            _seed_identity_rows(conn)
        if version >= 15:
            _seed_upload_rows(conn)
        if version >= 16:
            _seed_deletion_rows(conn)
        conn.commit()
    finally:
        conn.close()


# --- the version window -----------------------------------------------------------------------


def test_the_latest_schema_is_17_and_the_window_starts_at_13():
    assert Database.LATEST_SCHEMA_VERSION == 17
    assert Database.MINIMUM_SCHEMA_VERSION == 13


def test_a_fresh_database_lands_on_17(tmp_path):
    path = tmp_path / "database.db"
    _open(path)
    assert user_version(path) == 17


@pytest.mark.parametrize("version", UPGRADABLE)
def test_an_upgradable_database_reaches_17_in_one_open_and_keeps_its_instance_id(tmp_path, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, version)

    db = _database(path)
    assert db.initialize() is True

    assert user_version(path) == 17
    assert db.get_server_instance_id() == f"inst-v{version}"


@pytest.mark.parametrize("version", [12, 18])
def test_versions_outside_13_to_17_are_refused_untouched(tmp_path, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, 16)
    _set_user_version(path, version)
    os.utime(path, ns=(_PAST_NS, _PAST_NS))
    data, mtime, listing = path.read_bytes(), path.stat().st_mtime_ns, sorted(os.listdir(tmp_path))

    with pytest.raises(SchemaVersionRefused) as refused:
        _database(path).initialize()

    assert f"schema {version}" in str(refused.value)
    assert path.read_bytes() == data
    assert path.stat().st_mtime_ns == mtime
    assert sorted(os.listdir(tmp_path)) == listing


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
    assert "upgrade it to schema 17" in message
    assert path.read_bytes() == data and path.stat().st_mtime_ns == mtime


def test_the_cli_check_accepts_17(tmp_path):
    path = tmp_path / "database.db"
    _rich(path, 16)
    _open(path)

    _database(path).require_current_schema()


# --- the upgrade keeps every existing row ----------------------------------------------------


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_upgrade_keeps_every_existing_row_byte_for_byte(tmp_path, version):
    """Ids, uuids, revisions, history, identity rows, candidate pairs, upload
    rows, receipts, deletion rows, FTS (shadow tables) and ``sqlite_sequence``
    are unchanged. (From v13 the 13 -> 14 step adds its backfilled identity
    rows, which test_schema_upgrade_v14 pins.)"""
    path = tmp_path / "database.db"
    _rich(path, version)
    before = _rows(path)

    _open(path)

    assert _rows(path, tables=list(before)) == before
    assert _fts(path, "fts_tracks", "lucky") == [11, 21]
    assert _fts(path, "fts_artists", "radiohead") == [1, 2]
    assert [r[0] for r in before["history_events"]] == ["e1", "e2"]
    sequence = dict(before["sqlite_sequence"])
    assert sequence["conversion_jobs"] == 3 and sequence["tracks"] == 23
    if version >= 15:
        assert sequence["storage_reservations"] == 2
        assert len(before["upload_items"]) == 2
    if version >= 16:
        assert len(before["deletion_journal"]) == 2
        assert len(before["operation_receipts"]) == 4
    assert user_version(path) == 17


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_upgrade_adds_the_lastfm_tables_empty(tmp_path, version):
    path = tmp_path / "database.db"
    _rich(path, version)

    _open(path)

    assert _rows(path, tables=list(NEW_TABLES)) == {t: [] for t in NEW_TABLES}


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


def test_a_fresh_v17_file_verifies(tmp_path):
    path = tmp_path / "database.db"
    _open(path)

    conn = sqlite3.connect(path)
    try:
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
    assert user_version(path) == 17


@pytest.mark.parametrize("stale", UPGRADABLE)
def test_a_stale_outer_read_is_a_no_op_on_a_v17_file(tmp_path, monkeypatch, stale):
    path = tmp_path / "database.db"
    _rich(path, 16)
    _open(path)
    rows, schema = _rows(path), _schema(path)

    monkeypatch.setattr(Database, "_existing_schema_version", lambda self: stale)
    assert _database(path).initialize() is True

    assert _rows(path) == rows
    assert _schema(path) == schema
    assert user_version(path) == 17


@pytest.mark.parametrize("version", UPGRADABLE)
def test_a_fresh_v17_schema_equals_a_migrated_one(tmp_path, version):
    fresh = tmp_path / "fresh" / "database.db"
    migrated = tmp_path / "migrated" / "database.db"
    _open(fresh)
    migrated.parent.mkdir()
    _rich(migrated, version)
    _open(migrated)

    assert _normalized_schema(fresh) == _normalized_schema(migrated)


@pytest.mark.parametrize("version", UPGRADABLE)
def test_the_upgrade_is_logged_once_from_the_files_version_to_17(tmp_path, caplog, version):
    path = tmp_path / "database.db"
    make_legacy_database(path, version)

    with caplog.at_level(logging.INFO, logger=OPERATOR):
        _database(path).initialize()

    lines = [r.getMessage() for r in caplog.records if r.name == OPERATOR and "schema" in r.getMessage()]
    assert lines == [f"database schema upgraded from {version} to 17"]


@pytest.mark.parametrize("version", UPGRADABLE)
def test_server_startup_upgrades_an_old_data_dir(tmp_path, configure_app, version):
    """The upgrade runs inside the real startup, under the instance lock."""
    path = tmp_path / "data" / "database" / "database.db"
    _rich(path, version)
    main = configure_app()

    with TestClient(main.app):
        assert user_version(path) == 17

    conn = sqlite3.connect(path)
    try:
        assert registry.verify(conn) == []
    finally:
        conn.close()


# --- a failure inside the step ----------------------------------------------------------------

# Every v17 object; later steps of this piece extend the list.
FAILURE_POINTS = [
    (sqlite3.SQLITE_CREATE_TABLE, "lastfm_connections"),
    (sqlite3.SQLITE_CREATE_TABLE, "scrobble_outbox"),
    (sqlite3.SQLITE_CREATE_INDEX, "idx_scrobble_outbox_owner"),
    (sqlite3.SQLITE_CREATE_INDEX, "idx_scrobble_outbox_due"),
]


@pytest.mark.parametrize("action,name", FAILURE_POINTS)
@pytest.mark.parametrize("version", UPGRADABLE)
def test_a_failure_mid_step_rolls_back_to_the_files_version(tmp_path, monkeypatch, version, action, name):
    """Every step shares one transaction: a v13 file stays at 13 (not 16)."""
    path = tmp_path / "database.db"
    _rich(path, version)
    rows, schema = _rows(path), _schema(path)

    with monkeypatch.context() as patch:
        patch.setattr(sqlite3, "connect", _deny(action, name))
        with pytest.raises(sqlite3.DatabaseError):
            _database(path).initialize()

    assert user_version(path) == version
    assert _schema(path) == schema  # no partial table or index
    assert _rows(path) == rows

    _open(path)  # the next start upgrades it
    assert user_version(path) == 17


@pytest.mark.parametrize("version", UPGRADABLE)
def test_a_failure_after_the_last_v17_statement_rolls_back(tmp_path, monkeypatch, version):
    from app.database import database as database_module

    path = tmp_path / "database.db"
    _rich(path, version)
    rows, schema = _rows(path), _schema(path)

    with monkeypatch.context() as patch:
        patch.setattr(database_module, "SCHEMA_V17_DDL",
                      (*database_module.SCHEMA_V17_DDL, "SELECT * FROM no_such_table"))
        with pytest.raises(sqlite3.OperationalError):
            _database(path).initialize()

    assert user_version(path) == version
    assert _schema(path) == schema
    assert _rows(path) == rows


# --- lastfm_connections -----------------------------------------------------------------------


@pytest.fixture
def v17(tmp_path):
    """A v17 file migrated from a rich v16 file (users 1 and 2)."""
    path = tmp_path / "database.db"
    _rich(path, 16)
    _open(path)
    return path


def _connection(conn, owner, **values):
    row = {
        "owner_id": owner, "connection_id": None, "account_name": None,
        "session_key_enc": None, "opted_in": 0, "needs_reconnect": 0,
        "pending_token_enc": None, "pending_token_expires_at": None,
        "created_at": 1000, "updated_at": 1000,
    }
    row.update(values)
    conn.execute(
        "INSERT INTO lastfm_connections (owner_id, connection_id, account_name, session_key_enc, "
        "opted_in, needs_reconnect, pending_token_enc, pending_token_expires_at, created_at, "
        "updated_at) VALUES (:owner_id, :connection_id, :account_name, :session_key_enc, "
        ":opted_in, :needs_reconnect, :pending_token_enc, :pending_token_expires_at, "
        ":created_at, :updated_at)",
        row,
    )


BOUND = {"connection_id": "c-1", "account_name": "rj", "session_key_enc": "enc-key"}


def test_the_connection_table_has_the_spec_columns(v17):
    conn = sqlite3.connect(v17)
    try:
        columns = [r[1] for r in conn.execute("PRAGMA table_info('lastfm_connections')")]
    finally:
        conn.close()
    assert sorted(columns) == sorted([
        "owner_id", "connection_id", "account_name", "session_key_enc", "opted_in",
        "needs_reconnect", "pending_token_enc", "pending_token_expires_at",
        "created_at", "updated_at",
    ])


def test_each_user_holds_at_most_one_connection(v17):
    conn = _connect(v17)
    try:
        _connection(conn, 1, **BOUND)
        _connection(conn, 2, **BOUND)  # two users may connect the same account
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, 1, pending_token_enc="t", pending_token_expires_at=5)
    finally:
        conn.close()


@pytest.mark.parametrize("owner", [None, 99])
def test_a_connection_needs_a_real_owner(v17, owner):
    conn = _connect(v17)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, owner, **BOUND)
    finally:
        conn.close()


def test_the_owner_column_has_no_default(v17):
    conn = sqlite3.connect(v17)
    try:
        info = {r[1]: r for r in conn.execute("PRAGMA table_info('lastfm_connections')")}
    finally:
        conn.close()
    assert info["owner_id"][3] == 1  # NOT NULL
    assert info["owner_id"][4] is None  # no default


def test_a_new_row_is_neither_opted_in_nor_awaiting_repair(v17):
    conn = _connect(v17)
    try:
        conn.execute(
            "INSERT INTO lastfm_connections (owner_id, pending_token_enc, "
            "pending_token_expires_at, created_at, updated_at) VALUES (1, 't', 5, 1, 1)"
        )
        assert conn.execute(
            "SELECT opted_in, needs_reconnect FROM lastfm_connections WHERE owner_id = 1"
        ).fetchone() == (0, 0)
    finally:
        conn.close()


@pytest.mark.parametrize(
    "values",
    [
        {"connection_id": "c-1"},
        {"account_name": "rj"},
        {"session_key_enc": "enc-key"},
        {"connection_id": "c-1", "account_name": "rj"},
        {"connection_id": "c-1", "session_key_enc": "enc-key"},
        {"account_name": "rj", "session_key_enc": "enc-key"},
    ],
)
def test_a_bound_account_has_its_id_name_and_key_together(v17, values):
    conn = _connect(v17)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, 1, **values)
        _connection(conn, 1, **BOUND)
    finally:
        conn.close()


@pytest.mark.parametrize("values", [{"pending_token_enc": "t"}, {"pending_token_expires_at": 5}])
def test_a_pending_token_has_its_expiry_and_vice_versa(v17, values):
    conn = _connect(v17)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, 1, **values)
        _connection(conn, 1, pending_token_enc="t", pending_token_expires_at=5)
    finally:
        conn.close()


def test_opting_in_needs_a_session_key(v17):
    conn = _connect(v17)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, 1, opted_in=1, pending_token_enc="t", pending_token_expires_at=5)
        _connection(conn, 1, opted_in=1, **BOUND)
    finally:
        conn.close()


def test_opt_in_and_needs_reconnect_are_independent_facts(v17):
    """Spec §7.3: nothing that changes one changes the other."""
    conn = _connect(v17)
    try:
        _connection(conn, 1, opted_in=1, needs_reconnect=1, **BOUND)
        _connection(conn, 2, opted_in=0, needs_reconnect=1, **BOUND)
        conn.execute("UPDATE lastfm_connections SET needs_reconnect = 0 WHERE owner_id = 1")
        conn.execute("UPDATE lastfm_connections SET opted_in = 1 WHERE owner_id = 2")
        assert conn.execute(
            "SELECT owner_id, opted_in, needs_reconnect FROM lastfm_connections ORDER BY owner_id"
        ).fetchall() == [(1, 1, 0), (2, 1, 1)]
    finally:
        conn.close()


@pytest.mark.parametrize("column", ["opted_in", "needs_reconnect"])
@pytest.mark.parametrize("value", [2, -1, None])
def test_the_flags_are_zero_or_one(v17, column, value):
    conn = _connect(v17)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, 1, **{column: value}, **BOUND)
    finally:
        conn.close()


@pytest.mark.parametrize("column", ["created_at", "updated_at"])
def test_a_connection_records_its_times(v17, column):
    conn = _connect(v17)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, 1, **{column: None}, **BOUND)
    finally:
        conn.close()


# --- scrobble_outbox --------------------------------------------------------------------------

PAYLOAD = '{"artist": "Radiohead", "track": "Lucky", "timestamp": 1700000000}'


def _outbox(conn, owner, event="e1", **values):
    row = {
        "event_uuid": event, "owner_id": owner, "payload": PAYLOAD,
        "listened_at_s": 1_700_000_000, "status": "pending", "result_code": None,
        "attempts": 0, "alone": 0, "created_at": 1000, "done_at": None,
    }
    row.update(values)
    conn.execute(
        "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s, status, "
        "result_code, attempts, alone, created_at, done_at) VALUES (:event_uuid, :owner_id, "
        ":payload, :listened_at_s, :status, :result_code, :attempts, :alone, :created_at, "
        ":done_at)",
        row,
    )


def test_the_outbox_table_has_the_spec_columns(v17):
    conn = sqlite3.connect(v17)
    try:
        columns = [r[1] for r in conn.execute("PRAGMA table_info('scrobble_outbox')")]
    finally:
        conn.close()
    assert sorted(columns) == sorted([
        "event_uuid", "owner_id", "payload", "listened_at_s", "status", "result_code",
        "attempts", "alone", "created_at", "done_at",
    ])


def test_an_event_is_queued_at_most_once(v17):
    """Spec §7.3: ``event_uuid`` is the primary key, for every owner."""
    conn = _connect(v17)
    try:
        _outbox(conn, 1, "e1")
        with pytest.raises(sqlite3.IntegrityError):
            _outbox(conn, 1, "e1")
        with pytest.raises(sqlite3.IntegrityError):
            _outbox(conn, 2, "e1")
    finally:
        conn.close()


@pytest.mark.parametrize("owner", [None, 99])
def test_an_outbox_row_needs_a_real_owner(v17, owner):
    conn = _connect(v17)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _outbox(conn, owner)
    finally:
        conn.close()


def test_the_outbox_owner_column_has_no_default(v17):
    conn = sqlite3.connect(v17)
    try:
        info = {r[1]: r for r in conn.execute("PRAGMA table_info('scrobble_outbox')")}
    finally:
        conn.close()
    assert info["owner_id"][3] == 1 and info["owner_id"][4] is None


def test_a_new_row_is_pending_untried_and_batchable(v17):
    conn = _connect(v17)
    try:
        conn.execute(
            "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s, "
            "created_at) VALUES ('e1', 1, ?, 5, 6)",
            (PAYLOAD,),
        )
        assert conn.execute(
            "SELECT status, result_code, attempts, alone, done_at FROM scrobble_outbox"
        ).fetchone() == ("pending", None, 0, 0, None)
    finally:
        conn.close()


@pytest.mark.parametrize("payload", [None, "", "not json", '{"artist": ', "[1]", '"text"', "3"])
def test_the_payload_is_a_stored_json_object(v17, payload):
    conn = _connect(v17)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _outbox(conn, 1, payload=payload)
    finally:
        conn.close()


def test_the_frozen_payload_is_kept_exactly(v17):
    """The sender sends what was stored: no column links a row to the track
    it came from, so a later rename cannot change it (spec §7.7)."""
    payload = '{"track":"Café ’&+%=[]","artist":"レディオヘッド \U0001f3b5","timestamp":1}'
    conn = _connect(v17)
    try:
        _outbox(conn, 1, payload=payload)
        conn.commit()
        assert conn.execute("SELECT payload FROM scrobble_outbox").fetchone()[0] == payload
        columns = {r[1] for r in conn.execute("PRAGMA table_info('scrobble_outbox')")}
        fks = conn.execute("PRAGMA foreign_key_list('scrobble_outbox')").fetchall()
    finally:
        conn.close()
    assert not columns & {"uuid_id", "track_uuid", "track_id", "entity_ref"}
    assert [(fk[2], fk[3]) for fk in fks] == [("users", "owner_id")]


@pytest.mark.parametrize(
    "status,result_code,done_at,ok",
    [
        ("pending", None, None, True),
        ("sent", None, 2000, True),
        ("ignored", "1", 2000, True),
        ("failed", "13", 2000, True),
        ("dropped", "too_many_tries", 2000, True),
        ("dropped", "too_old", 2000, True),
        ("dropped", "no_answer", 2000, True),
        # an unknown status
        ("queued", None, None, False),
        ("", None, None, False),
        # pending is not done, and has no outcome yet
        ("pending", None, 2000, False),
        ("pending", "8", None, False),
        # every terminal row records when it ended
        ("sent", None, None, False),
        ("failed", "13", None, False),
        # sent has no code; ignored, failed and dropped need one
        ("sent", "0", 2000, False),
        ("ignored", None, 2000, False),
        ("failed", None, 2000, False),
        ("dropped", None, 2000, False),
        # OSML's reasons for giving up are exactly three
        ("dropped", "13", 2000, False),
        ("dropped", "gave_up", 2000, False),
    ],
)
def test_the_status_result_code_and_done_time_fit_together(v17, status, result_code, done_at, ok):
    conn = _connect(v17)
    try:
        if ok:
            _outbox(conn, 1, status=status, result_code=result_code, done_at=done_at)
        else:
            with pytest.raises(sqlite3.IntegrityError):
                _outbox(conn, 1, status=status, result_code=result_code, done_at=done_at)
    finally:
        conn.close()


@pytest.mark.parametrize(
    "column,value",
    [("attempts", -1), ("attempts", None), ("alone", 2), ("alone", None),
     ("listened_at_s", None), ("created_at", None)],
)
def test_counters_flags_and_times_are_well_formed(v17, column, value):
    conn = _connect(v17)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _outbox(conn, 1, **{column: value})
    finally:
        conn.close()


def _plan(path, sql, params=()):
    conn = sqlite3.connect(path)
    try:
        return " ".join(r[3] for r in conn.execute("EXPLAIN QUERY PLAN " + sql, params))
    finally:
        conn.close()


def _index_columns(path, name):
    conn = sqlite3.connect(path)
    try:
        return [r[2] for r in conn.execute(f"PRAGMA index_info('{name}')")]
    finally:
        conn.close()


def test_the_owner_index_leads_with_the_owner_and_serves_the_status_counts(v17):
    assert _index_columns(v17, "idx_scrobble_outbox_owner") == ["owner_id", "status", "listened_at_s"]
    plan = _plan(
        v17,
        "SELECT status, count(*) FROM scrobble_outbox WHERE owner_id = ? GROUP BY status",
        (1,),
    )
    assert "idx_scrobble_outbox_owner" in plan and "TEMP B-TREE" not in plan


def test_a_users_oldest_pending_rows_are_read_in_listen_order_from_the_owner_index(v17):
    plan = _plan(
        v17,
        "SELECT event_uuid FROM scrobble_outbox WHERE owner_id = ? AND status = 'pending' "
        "ORDER BY listened_at_s LIMIT 50",
        (1,),
    )
    assert "idx_scrobble_outbox_owner" in plan and "TEMP B-TREE" not in plan


def test_the_due_scan_reads_only_the_pending_index(v17):
    """The sender's due scan (spec §7.8): per user, the earliest-queued
    pending row whose listen time has arrived. The partial index covers it."""
    assert _index_columns(v17, "idx_scrobble_outbox_due") == ["owner_id", "created_at", "listened_at_s"]
    conn = sqlite3.connect(v17)
    try:
        partial = conn.execute(
            "SELECT sql FROM sqlite_master WHERE name = 'idx_scrobble_outbox_due'"
        ).fetchone()[0]
    finally:
        conn.close()
    assert "WHERE status = 'pending'" in " ".join(partial.split())
    plan = _plan(
        v17,
        "SELECT owner_id, MIN(created_at) FROM scrobble_outbox "
        "WHERE status = 'pending' AND listened_at_s <= ? GROUP BY owner_id",
        (1_700_000_000,),
    )
    assert "COVERING INDEX idx_scrobble_outbox_due" in plan
    assert "TEMP B-TREE" not in plan


def test_the_due_scan_finds_the_earliest_queued_row_per_user(v17):
    conn = _connect(v17)
    try:
        _outbox(conn, 1, "a", created_at=300, listened_at_s=10)
        _outbox(conn, 1, "b", created_at=100, listened_at_s=20)
        _outbox(conn, 1, "c", created_at=50, listened_at_s=99)  # listen time not yet arrived
        _outbox(conn, 1, "d", created_at=10, listened_at_s=5, status="sent", done_at=11)
        _outbox(conn, 2, "e", created_at=400, listened_at_s=30)
        rows = conn.execute(
            "SELECT owner_id, MIN(created_at) FROM scrobble_outbox "
            "WHERE status = 'pending' AND listened_at_s <= ? GROUP BY owner_id ORDER BY owner_id",
            (40,),
        ).fetchall()
    finally:
        conn.close()
    assert rows == [(1, 100), (2, 400)]
