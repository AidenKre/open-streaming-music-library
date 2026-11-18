"""Phase 9D.1b (spec §7.3, §7.4, review 9-U08c, SC-28 rule 3): the owned
``Database`` methods behind the Last.fm routes.

Every method takes a required keyword-only ``owner_id`` and is reached
through the caller's ``Library``. They store and return Fernet ciphertext as
given, never decrypt, and act on the caller's rows only: one user's
connection and outbox are invisible to another's calls.

Values here are made up (``tests/lastfm_secrets.py``); the ciphertext is real
Fernet output under a made-up key.
"""

import sqlite3

import pytest

from app.library import Library
from app.models.lastfm import BindOutcome, EnableOutcome
from app.services.lastfm_crypto import encrypt
from tests.lastfm_secrets import CREDENTIAL_KEY, SESSION_KEY, TOKEN, assert_secret_equal
from tests.owned_database import add_test_user
from tests.schema_fixtures import open_database

NOW = 1_700_000_000_000
LATER = NOW + 5_000
EXPIRES = NOW + 600_000


@pytest.fixture
def db(tmp_path):
    return open_database(tmp_path / "database.db")


@pytest.fixture
def sam(db):
    return Library(db, add_test_user(db, "Sam"))


@pytest.fixture
def alex(db):
    return Library(db, add_test_user(db, "Alex"))


def _enc(value):
    return encrypt(CREDENTIAL_KEY, value)


def _row(db, owner_id):
    conn = sqlite3.connect(db.context.database_path)
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute(
            "SELECT * FROM lastfm_connections WHERE owner_id = ?", (owner_id,)
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def _bound(lib, *, account="rj", token=None, connection_id="conn-1", key=None):
    """Connect + complete for ``lib``'s user; returns (token_enc, key_enc)."""
    token_enc = token or _enc(TOKEN)
    key_enc = key or _enc(SESSION_KEY)
    lib.store_lastfm_pending_token(token_enc, EXPIRES, NOW)
    result = lib.bind_lastfm_session(
        token_enc, account_name=account, session_key_enc=key_enc,
        new_connection_id=connection_id, now=NOW,
    )
    assert result.outcome is BindOutcome.BOUND
    return token_enc, key_enc


# --- reading ---------------------------------------------------------------------------------


def test_a_user_who_never_connected_has_no_connection(sam):
    assert sam.get_lastfm_connection() is None


def test_the_connection_reads_back_every_field_with_the_ciphertext_as_stored(db, sam):
    token_enc, key_enc = _bound(sam)
    new_token = _enc(TOKEN)
    sam.store_lastfm_pending_token(new_token, EXPIRES + 1, LATER)

    connection = sam.get_lastfm_connection()

    assert set(connection) == {
        "connection_id", "account_name", "session_key_enc", "opted_in", "needs_reconnect",
        "pending_token_enc", "pending_token_expires_at", "created_at", "updated_at",
    }
    assert connection["connection_id"] == "conn-1"
    assert connection["account_name"] == "rj"
    assert_secret_equal(connection["session_key_enc"], key_enc, "session key ciphertext")
    assert_secret_equal(connection["pending_token_enc"], new_token, "token ciphertext")
    assert connection["opted_in"] is False and connection["needs_reconnect"] is False
    assert connection["pending_token_expires_at"] == EXPIRES + 1
    assert (connection["created_at"], connection["updated_at"]) == (NOW, LATER)


def test_one_user_never_sees_another_users_connection(sam, alex):
    _bound(sam)
    assert alex.get_lastfm_connection() is None


# --- connect: the pending token ------------------------------------------------------------


def test_connect_creates_the_row_holding_only_the_token(db, sam):
    token_enc = _enc(TOKEN)

    sam.store_lastfm_pending_token(token_enc, EXPIRES, NOW)

    row = _row(db, sam.owner_id)
    assert_secret_equal(row["pending_token_enc"], token_enc, "token ciphertext")
    assert row["pending_token_expires_at"] == EXPIRES
    assert (row["connection_id"], row["account_name"], row["session_key_enc"]) == (None, None, None)
    assert (row["opted_in"], row["needs_reconnect"]) == (0, 0)
    assert (row["created_at"], row["updated_at"]) == (NOW, NOW)


def test_a_new_token_replaces_the_earlier_one_and_keeps_the_binding(db, sam):
    _, key_enc = _bound(sam)
    assert sam.enable_lastfm_scrobbling("conn-1", NOW) is EnableOutcome.ENABLED
    newer = _enc(TOKEN)

    sam.store_lastfm_pending_token(newer, EXPIRES + 9, LATER)

    row = _row(db, sam.owner_id)
    assert_secret_equal(row["pending_token_enc"], newer, "token ciphertext")
    assert row["pending_token_expires_at"] == EXPIRES + 9
    assert (row["connection_id"], row["account_name"], row["opted_in"]) == ("conn-1", "rj", 1)
    assert_secret_equal(row["session_key_enc"], key_enc, "session key ciphertext")
    assert (row["created_at"], row["updated_at"]) == (NOW, LATER)


def test_a_token_is_cleared_only_while_the_row_still_holds_it(db, sam):
    first, second = _enc(TOKEN), _enc(TOKEN)
    sam.store_lastfm_pending_token(first, EXPIRES, NOW)
    sam.store_lastfm_pending_token(second, EXPIRES, NOW)

    assert sam.clear_lastfm_pending_token(first, LATER) is False  # started over meanwhile
    assert _row(db, sam.owner_id)["pending_token_enc"] == second

    assert sam.clear_lastfm_pending_token(second, LATER) is True
    row = _row(db, sam.owner_id)
    assert (row["pending_token_enc"], row["pending_token_expires_at"]) == (None, None)
    assert row["updated_at"] == LATER


def test_clearing_a_token_after_disconnect_changes_nothing(db, sam):
    token_enc = _enc(TOKEN)
    assert sam.clear_lastfm_pending_token(token_enc, LATER) is False
    assert _row(db, sam.owner_id) is None


def test_a_users_token_calls_never_touch_another_users_row(db, sam, alex):
    sams = _enc(TOKEN)
    sam.store_lastfm_pending_token(sams, EXPIRES, NOW)
    before = _row(db, sam.owner_id)

    alex.store_lastfm_pending_token(_enc(TOKEN), EXPIRES, LATER)
    assert alex.clear_lastfm_pending_token(sams, LATER) is False  # Sam's token, Alex's call

    assert _row(db, sam.owner_id) == before


# --- complete: the conditional bind (spec §7.4 table) ---------------------------------------


def test_the_first_binding_stores_the_key_and_name_mints_the_id_and_clears_the_token(db, sam):
    token_enc, key_enc = _enc(TOKEN), _enc(SESSION_KEY)
    sam.store_lastfm_pending_token(token_enc, EXPIRES, NOW)

    result = sam.bind_lastfm_session(
        token_enc, account_name="rj", session_key_enc=key_enc,
        new_connection_id="conn-1", now=LATER,
    )

    assert result.outcome is BindOutcome.BOUND
    assert result.connection_id == "conn-1" and result.stored_account is None
    row = _row(db, sam.owner_id)
    assert (row["connection_id"], row["account_name"]) == ("conn-1", "rj")
    assert_secret_equal(row["session_key_enc"], key_enc, "session key ciphertext")
    assert (row["opted_in"], row["needs_reconnect"]) == (0, 0)
    assert (row["pending_token_enc"], row["pending_token_expires_at"]) == (None, None)
    assert row["updated_at"] == LATER


def test_the_same_account_replaces_the_key_clears_repair_and_keeps_id_and_opt_in(db, sam):
    _bound(sam)
    sam.enable_lastfm_scrobbling("conn-1", NOW)
    conn = sqlite3.connect(db.context.database_path)
    conn.execute("UPDATE lastfm_connections SET needs_reconnect = 1")
    conn.commit()
    conn.close()
    token_enc, fresh_key = _enc(TOKEN), _enc(SESSION_KEY)
    sam.store_lastfm_pending_token(token_enc, EXPIRES, NOW)

    result = sam.bind_lastfm_session(
        token_enc, account_name="rj", session_key_enc=fresh_key,
        new_connection_id="conn-2", now=LATER,
    )

    assert result.outcome is BindOutcome.REBOUND and result.connection_id == "conn-1"
    row = _row(db, sam.owner_id)
    assert (row["connection_id"], row["opted_in"], row["needs_reconnect"]) == ("conn-1", 1, 0)
    assert_secret_equal(row["session_key_enc"], fresh_key, "session key ciphertext")
    assert row["pending_token_enc"] is None


def test_a_different_account_binds_nothing_discards_the_key_and_clears_the_token(db, sam):
    _, old_key = _bound(sam)
    token_enc = _enc(TOKEN)
    sam.store_lastfm_pending_token(token_enc, EXPIRES, NOW)

    result = sam.bind_lastfm_session(
        token_enc, account_name="someone-else", session_key_enc=_enc(SESSION_KEY),
        new_connection_id="conn-2", now=LATER,
    )

    assert result.outcome is BindOutcome.ACCOUNT_MISMATCH
    assert result.stored_account == "rj" and result.connection_id is None
    row = _row(db, sam.owner_id)
    assert (row["connection_id"], row["account_name"]) == ("conn-1", "rj")
    assert_secret_equal(row["session_key_enc"], old_key, "session key ciphertext")
    assert (row["pending_token_enc"], row["pending_token_expires_at"]) == (None, None)


def test_account_names_are_compared_exactly(db, sam):
    _bound(sam, account="rj")
    token_enc = _enc(TOKEN)
    sam.store_lastfm_pending_token(token_enc, EXPIRES, NOW)

    result = sam.bind_lastfm_session(
        token_enc, account_name="RJ", session_key_enc=_enc(SESSION_KEY),
        new_connection_id="conn-2", now=LATER,
    )

    assert result.outcome is BindOutcome.ACCOUNT_MISMATCH


@pytest.mark.parametrize("situation", ["started_over", "disconnected", "never_connected"])
def test_a_bind_whose_token_is_no_longer_held_binds_nothing(db, sam, situation):
    """Spec §7.4: complete applies its result only if the row still holds the
    token it sent; otherwise it answers 410 and binds nothing."""
    sent = _enc(TOKEN)
    if situation != "never_connected":
        sam.store_lastfm_pending_token(sent, EXPIRES, NOW)
    if situation == "started_over":
        sam.store_lastfm_pending_token(_enc(TOKEN), EXPIRES, NOW)
    if situation == "disconnected":
        sam.disconnect_lastfm()
    before = _row(db, sam.owner_id)

    result = sam.bind_lastfm_session(
        sent, account_name="rj", session_key_enc=_enc(SESSION_KEY),
        new_connection_id="conn-1", now=LATER,
    )

    assert result.outcome is BindOutcome.TOKEN_CHANGED
    assert result.connection_id is None and result.stored_account is None
    assert _row(db, sam.owner_id) == before


def test_a_bind_with_another_users_token_binds_nothing_for_either(db, sam, alex):
    sams = _enc(TOKEN)
    sam.store_lastfm_pending_token(sams, EXPIRES, NOW)
    alex.store_lastfm_pending_token(_enc(TOKEN), EXPIRES, NOW)
    before = (_row(db, sam.owner_id), _row(db, alex.owner_id))

    result = alex.bind_lastfm_session(
        sams, account_name="rj", session_key_enc=_enc(SESSION_KEY),
        new_connection_id="conn-1", now=LATER,
    )

    assert result.outcome is BindOutcome.TOKEN_CHANGED
    assert (_row(db, sam.owner_id), _row(db, alex.owner_id)) == before


def test_two_users_may_bind_the_same_lastfm_account(db, sam, alex):
    _bound(sam, account="rj", connection_id="conn-s")
    _bound(alex, account="rj", connection_id="conn-a")

    assert _row(db, sam.owner_id)["connection_id"] == "conn-s"
    assert _row(db, alex.owner_id)["connection_id"] == "conn-a"


# --- enable: the opt-in (spec §7.4) --------------------------------------------------------


def test_enable_opts_in_the_current_connection_and_is_harmless_twice(db, sam):
    _bound(sam)

    assert sam.enable_lastfm_scrobbling("conn-1", LATER) is EnableOutcome.ENABLED
    assert sam.enable_lastfm_scrobbling("conn-1", LATER + 1) is EnableOutcome.ENABLED

    row = _row(db, sam.owner_id)
    assert (row["opted_in"], row["needs_reconnect"]) == (1, 0)


@pytest.mark.parametrize("situation", ["never_connected", "token_only"])
def test_enable_without_a_session_key_is_not_connected(db, sam, situation):
    if situation == "token_only":
        sam.store_lastfm_pending_token(_enc(TOKEN), EXPIRES, NOW)
    before = _row(db, sam.owner_id)

    assert sam.enable_lastfm_scrobbling("conn-1", LATER) is EnableOutcome.NOT_CONNECTED
    assert _row(db, sam.owner_id) == before


def test_a_stale_unknown_or_foreign_connection_id_answers_alike(db, sam, alex):
    """9-U08c: a connection_id that is not the caller's current one is
    refused the same way whether it is stale, unknown or another user's."""
    _bound(sam, connection_id="conn-old")
    sam.disconnect_lastfm()
    _bound(sam, connection_id="conn-new")
    _bound(alex, connection_id="conn-alex")
    before = (_row(db, sam.owner_id), _row(db, alex.owner_id))

    outcomes = {
        sam.enable_lastfm_scrobbling(cid, LATER) for cid in ("conn-old", "nope", "conn-alex")
    }

    assert outcomes == {EnableOutcome.CONNECTION_CHANGED}
    assert (_row(db, sam.owner_id), _row(db, alex.owner_id)) == before


def test_enable_while_the_connection_needs_repair_is_refused(db, sam):
    _bound(sam)
    conn = sqlite3.connect(db.context.database_path)
    conn.execute("UPDATE lastfm_connections SET needs_reconnect = 1")
    conn.commit()
    conn.close()

    assert sam.enable_lastfm_scrobbling("conn-1", LATER) is EnableOutcome.RECONNECT_REQUIRED
    assert _row(db, sam.owner_id)["opted_in"] == 0


# --- disconnect (spec §7.4) ----------------------------------------------------------------


def _queue(db, owner_id, event, status="pending", code=None, done_at=None, *,
           artist="Radiohead", track="Lucky", listened_at_s=1_700_000_000, created_at=NOW):
    payload = '{"artist": %s, "track": %s, "timestamp": %d}' % (
        _json(artist), _json(track), listened_at_s)
    conn = sqlite3.connect(db.context.database_path)
    try:
        conn.execute(
            "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s, status, "
            "result_code, created_at, done_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (event, owner_id, payload, listened_at_s, status, code, created_at, done_at),
        )
        conn.commit()
    finally:
        conn.close()


def _json(text):
    import json

    return json.dumps(text)


def _outbox(db, owner_id):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return sorted(r[0] for r in conn.execute(
            "SELECT event_uuid FROM scrobble_outbox WHERE owner_id = ?", (owner_id,)))
    finally:
        conn.close()


def test_disconnect_deletes_the_callers_row_and_all_their_outbox_rows(db, sam, alex):
    _bound(sam)
    _bound(alex)
    for event, status, code, done in (("s1", "pending", None, None), ("s2", "sent", None, NOW),
                                      ("s3", "failed", "13", NOW), ("s4", "dropped", "too_old", NOW)):
        _queue(db, sam.owner_id, event, status, code, done)
    _queue(db, alex.owner_id, "a1")
    alex_before = _row(db, alex.owner_id)

    sam.disconnect_lastfm()

    assert _row(db, sam.owner_id) is None and _outbox(db, sam.owner_id) == []
    assert _row(db, alex.owner_id) == alex_before and _outbox(db, alex.owner_id) == ["a1"]


def test_disconnect_is_idempotent_and_works_with_nothing_connected(db, sam, alex):
    _bound(alex)
    sam.disconnect_lastfm()
    sam.disconnect_lastfm()
    assert _row(db, sam.owner_id) is None and _row(db, alex.owner_id) is not None


def test_disconnect_removes_outbox_rows_even_without_a_connection_row(db, sam):
    _queue(db, sam.owner_id, "s1")
    sam.disconnect_lastfm()
    assert _outbox(db, sam.owner_id) == []


# --- the status body's outbox facts (spec §7.4 "Status body") ---------------------------

WINDOW = NOW - 30 * 86_400_000  # the route passes now minus 30 days


def test_a_user_with_no_rows_has_zero_counts_no_problems_and_no_success(sam):
    summary = sam.get_lastfm_outbox_summary(WINDOW)

    assert summary == {
        "counts": {"pending": 0, "sent": 0, "ignored": 0, "failed": 0, "dropped": 0},
        "recent_problems": [],
        "last_success_at": None,
    }


def test_counts_cover_pending_rows_and_terminal_rows_inside_the_window(db, sam):
    _queue(db, sam.owner_id, "p-old", created_at=WINDOW - 99)  # pending: always counted
    _queue(db, sam.owner_id, "p-new")
    _queue(db, sam.owner_id, "s1", "sent", None, NOW)
    _queue(db, sam.owner_id, "s2", "sent", None, WINDOW)  # the boundary is inside
    _queue(db, sam.owner_id, "s-old", "sent", None, WINDOW - 1)  # not yet pruned
    _queue(db, sam.owner_id, "i1", "ignored", "1", NOW)
    _queue(db, sam.owner_id, "f1", "failed", "13", NOW)
    _queue(db, sam.owner_id, "d1", "dropped", "too_old", NOW)
    _queue(db, sam.owner_id, "d2", "dropped", "no_answer", NOW)

    counts = sam.get_lastfm_outbox_summary(WINDOW)["counts"]

    assert counts == {"pending": 2, "sent": 2, "ignored": 1, "failed": 1, "dropped": 2}


def test_recent_problems_are_the_newest_ignored_failed_and_dropped_rows(db, sam):
    _queue(db, sam.owner_id, "sent", "sent", None, NOW + 50)
    _queue(db, sam.owner_id, "wait")
    _queue(db, sam.owner_id, "ign", "ignored", "2", NOW + 30,
           artist="Sigur Rós", track="Hoppípolla", listened_at_s=111)
    _queue(db, sam.owner_id, "fail", "failed", "13", NOW + 20, track="Café ’&", listened_at_s=222)
    _queue(db, sam.owner_id, "drop", "dropped", "too_many_tries", NOW + 10, listened_at_s=333)
    _queue(db, sam.owner_id, "ancient", "failed", "6", WINDOW - 1)

    problems = sam.get_lastfm_outbox_summary(WINDOW)["recent_problems"]

    assert problems == [
        {"artist": "Sigur Rós", "track": "Hoppípolla", "listened_at_s": 111,
         "status": "ignored", "code": "2"},
        {"artist": "Radiohead", "track": "Café ’&", "listened_at_s": 222,
         "status": "failed", "code": "13"},
        {"artist": "Radiohead", "track": "Lucky", "listened_at_s": 333,
         "status": "dropped", "code": "too_many_tries"},
    ]


def test_at_most_twenty_problems_newest_first(db, sam):
    for i in range(25):
        _queue(db, sam.owner_id, f"f{i:02d}", "failed", "13", NOW + i, listened_at_s=i)

    problems = sam.get_lastfm_outbox_summary(WINDOW)["recent_problems"]

    assert [p["listened_at_s"] for p in problems] == list(range(24, 4, -1))


def test_last_success_is_the_newest_sent_rows_done_time(db, sam):
    _queue(db, sam.owner_id, "s1", "sent", None, NOW + 1)
    _queue(db, sam.owner_id, "s2", "sent", None, NOW + 7)
    _queue(db, sam.owner_id, "f1", "failed", "13", NOW + 9)

    assert sam.get_lastfm_outbox_summary(WINDOW)["last_success_at"] == NOW + 7


def test_one_users_outbox_never_appears_in_anothers_summary(db, sam, alex):
    _queue(db, alex.owner_id, "a1")
    _queue(db, alex.owner_id, "a2", "sent", None, NOW)
    _queue(db, alex.owner_id, "a3", "failed", "13", NOW)

    assert sam.get_lastfm_outbox_summary(WINDOW) == {
        "counts": {"pending": 0, "sent": 0, "ignored": 0, "failed": 0, "dropped": 0},
        "recent_problems": [],
        "last_success_at": None,
    }


# --- review r1 --------------------------------------------------------------------------------


def test_review_r1_f1_a_bind_without_any_token_binds_nothing(db, sam):
    """Neither side holding a token is not a match (SQL ``= NULL`` never is)."""
    _bound(sam)
    before = _row(db, sam.owner_id)
    sams_rebind = sam.bind_lastfm_session(
        None, account_name="rj", session_key_enc=_enc(SESSION_KEY),
        new_connection_id="conn-2", now=LATER,
    )
    assert sams_rebind.outcome is BindOutcome.TOKEN_CHANGED
    assert _row(db, sam.owner_id) == before


def test_review_r1_f1_a_bind_on_a_tokenless_unbound_row_binds_nothing(db, sam):
    sam.store_lastfm_pending_token(_enc(TOKEN), EXPIRES, NOW)
    conn = sqlite3.connect(db.context.database_path)
    conn.execute("UPDATE lastfm_connections SET pending_token_enc = NULL, "
                 "pending_token_expires_at = NULL")
    conn.commit()
    conn.close()
    before = _row(db, sam.owner_id)

    result = sam.bind_lastfm_session(
        None, account_name="rj", session_key_enc=_enc(SESSION_KEY),
        new_connection_id="conn-1", now=LATER,
    )

    assert result.outcome is BindOutcome.TOKEN_CHANGED
    assert _row(db, sam.owner_id) == before


def test_review_r1_f2_the_summary_is_one_consistent_read(db, sam, monkeypatch):
    """A row the sender settles while the summary is being read appears in
    all of its parts or in none."""
    from app.database import database as database_module

    _queue(db, sam.owner_id, "f1", "failed", "13", NOW)
    _queue(db, sam.owner_id, "p1")
    real_loads = database_module.json.loads
    settled = []

    def loads_then_settle(text, *args, **kwargs):
        if not settled:
            settled.append(True)
            conn = sqlite3.connect(db.context.database_path)
            conn.execute("UPDATE scrobble_outbox SET status = 'sent', done_at = ? "
                         "WHERE event_uuid = 'p1'", (NOW + 99,))
            conn.commit()
            conn.close()
        return real_loads(text, *args, **kwargs)

    monkeypatch.setattr(database_module.json, "loads", loads_then_settle)

    summary = sam.get_lastfm_outbox_summary(WINDOW)

    assert settled
    assert summary["counts"]["pending"] == 1 and summary["counts"]["sent"] == 0
    assert summary["last_success_at"] is None
