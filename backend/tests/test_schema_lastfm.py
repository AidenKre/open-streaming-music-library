"""The Last.fm tables: ``lastfm_connections`` (one connection per user) and
``scrobble_outbox`` (the frozen payloads waiting to be sent), with the two
indexes the sender and the status counts read.

The database is created fresh by production initialization and then holds two
users' libraries in plain SQL (users 1 and 2).
"""

import sqlite3
from pathlib import Path

import pytest

from tests.schema_fixtures import make_two_user_database


def _connect(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


@pytest.fixture
def fresh(tmp_path):
    """A fresh database holding two users' libraries (users 1 and 2)."""
    path = tmp_path / "database.db"
    make_two_user_database(path)
    return path


# --- lastfm_connections -----------------------------------------------------------------------


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


def test_the_connection_table_has_the_spec_columns(fresh):
    conn = sqlite3.connect(fresh)
    try:
        columns = [r[1] for r in conn.execute("PRAGMA table_info('lastfm_connections')")]
    finally:
        conn.close()
    assert sorted(columns) == sorted([
        "owner_id", "connection_id", "account_name", "session_key_enc", "opted_in",
        "needs_reconnect", "pending_token_enc", "pending_token_expires_at",
        "created_at", "updated_at",
    ])


def test_each_user_holds_at_most_one_connection(fresh):
    conn = _connect(fresh)
    try:
        _connection(conn, 1, **BOUND)
        _connection(conn, 2, **BOUND)  # two users may connect the same account
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, 1, pending_token_enc="t", pending_token_expires_at=5)
    finally:
        conn.close()


@pytest.mark.parametrize("owner", [None, 99])
def test_a_connection_needs_a_real_owner(fresh, owner):
    conn = _connect(fresh)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, owner, **BOUND)
    finally:
        conn.close()


def test_the_owner_column_has_no_default(fresh):
    conn = sqlite3.connect(fresh)
    try:
        info = {r[1]: r for r in conn.execute("PRAGMA table_info('lastfm_connections')")}
    finally:
        conn.close()
    assert info["owner_id"][3] == 1  # NOT NULL
    assert info["owner_id"][4] is None  # no default


def test_a_new_row_is_neither_opted_in_nor_awaiting_repair(fresh):
    conn = _connect(fresh)
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
def test_a_bound_account_has_its_id_name_and_key_together(fresh, values):
    conn = _connect(fresh)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, 1, **values)
        _connection(conn, 1, **BOUND)
    finally:
        conn.close()


@pytest.mark.parametrize("values", [{"pending_token_enc": "t"}, {"pending_token_expires_at": 5}])
def test_a_pending_token_has_its_expiry_and_vice_versa(fresh, values):
    conn = _connect(fresh)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, 1, **values)
        _connection(conn, 1, pending_token_enc="t", pending_token_expires_at=5)
    finally:
        conn.close()


def test_opting_in_needs_a_session_key(fresh):
    conn = _connect(fresh)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, 1, opted_in=1, pending_token_enc="t", pending_token_expires_at=5)
        _connection(conn, 1, opted_in=1, **BOUND)
    finally:
        conn.close()


def test_opt_in_and_needs_reconnect_are_independent_facts(fresh):
    """Spec §7.3: nothing that changes one changes the other."""
    conn = _connect(fresh)
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
def test_the_flags_are_zero_or_one(fresh, column, value):
    conn = _connect(fresh)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _connection(conn, 1, **{column: value}, **BOUND)
    finally:
        conn.close()


@pytest.mark.parametrize("column", ["created_at", "updated_at"])
def test_a_connection_records_its_times(fresh, column):
    conn = _connect(fresh)
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


def test_the_outbox_table_has_the_spec_columns(fresh):
    conn = sqlite3.connect(fresh)
    try:
        columns = [r[1] for r in conn.execute("PRAGMA table_info('scrobble_outbox')")]
    finally:
        conn.close()
    assert sorted(columns) == sorted([
        "event_uuid", "owner_id", "payload", "listened_at_s", "status", "result_code",
        "attempts", "alone", "created_at", "done_at",
    ])


def test_an_event_is_queued_at_most_once(fresh):
    """Spec §7.3: ``event_uuid`` is the primary key, for every owner."""
    conn = _connect(fresh)
    try:
        _outbox(conn, 1, "e1")
        with pytest.raises(sqlite3.IntegrityError):
            _outbox(conn, 1, "e1")
        with pytest.raises(sqlite3.IntegrityError):
            _outbox(conn, 2, "e1")
    finally:
        conn.close()


@pytest.mark.parametrize("owner", [None, 99])
def test_an_outbox_row_needs_a_real_owner(fresh, owner):
    conn = _connect(fresh)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _outbox(conn, owner)
    finally:
        conn.close()


def test_the_outbox_owner_column_has_no_default(fresh):
    conn = sqlite3.connect(fresh)
    try:
        info = {r[1]: r for r in conn.execute("PRAGMA table_info('scrobble_outbox')")}
    finally:
        conn.close()
    assert info["owner_id"][3] == 1 and info["owner_id"][4] is None


def test_a_new_row_is_pending_untried_and_batchable(fresh):
    conn = _connect(fresh)
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
def test_the_payload_is_a_stored_json_object(fresh, payload):
    conn = _connect(fresh)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            _outbox(conn, 1, payload=payload)
    finally:
        conn.close()


def test_the_frozen_payload_is_kept_exactly(fresh):
    """The sender sends what was stored: no column links a row to the track
    it came from, so a later rename cannot change it (spec §7.7)."""
    payload = '{"track":"Café ’&+%=[]","artist":"レディオヘッド \U0001f3b5","timestamp":1}'
    conn = _connect(fresh)
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
def test_the_status_result_code_and_done_time_fit_together(fresh, status, result_code, done_at, ok):
    conn = _connect(fresh)
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
def test_counters_flags_and_times_are_well_formed(fresh, column, value):
    conn = _connect(fresh)
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


def test_the_owner_index_leads_with_the_owner_and_serves_the_status_counts(fresh):
    assert _index_columns(fresh, "idx_scrobble_outbox_owner") == ["owner_id", "status", "listened_at_s"]
    plan = _plan(
        fresh,
        "SELECT status, count(*) FROM scrobble_outbox WHERE owner_id = ? GROUP BY status",
        (1,),
    )
    assert "idx_scrobble_outbox_owner" in plan and "TEMP B-TREE" not in plan


def test_a_users_oldest_pending_rows_are_read_in_listen_order_from_the_owner_index(fresh):
    plan = _plan(
        fresh,
        "SELECT event_uuid FROM scrobble_outbox WHERE owner_id = ? AND status = 'pending' "
        "ORDER BY listened_at_s LIMIT 50",
        (1,),
    )
    assert "idx_scrobble_outbox_owner" in plan and "TEMP B-TREE" not in plan


def test_the_due_scan_reads_only_the_pending_index(fresh):
    """The sender's due scan (spec §7.8): per user, the earliest-queued
    pending row whose listen time has arrived. The partial index covers it."""
    assert _index_columns(fresh, "idx_scrobble_outbox_due") == ["owner_id", "created_at", "listened_at_s"]
    conn = sqlite3.connect(fresh)
    try:
        partial = conn.execute(
            "SELECT sql FROM sqlite_master WHERE name = 'idx_scrobble_outbox_due'"
        ).fetchone()[0]
    finally:
        conn.close()
    assert "WHERE status = 'pending'" in " ".join(partial.split())
    plan = _plan(
        fresh,
        "SELECT owner_id, MIN(created_at) FROM scrobble_outbox "
        "WHERE status = 'pending' AND listened_at_s <= ? GROUP BY owner_id",
        (1_700_000_000,),
    )
    assert "COVERING INDEX idx_scrobble_outbox_due" in plan
    assert "TEMP B-TREE" not in plan


def test_the_due_scan_finds_the_earliest_queued_row_per_user(fresh):
    conn = _connect(fresh)
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
