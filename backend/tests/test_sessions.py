"""Phase M.1a (M-U10, spec §5.1): session tokens in ``app/auth/sessions.py``.

A login creates one ``auth_sessions`` row holding the SHA-256 hashes of two
256-bit random tokens (the API token and the media token); the plaintext is
returned once and never stored. Lookup is one primary-key read joined to
``users``, run off the event loop, with no cache: a revoked session, a
disabled user or a deleting user is rejected on the very next lookup.
"""

import sqlite3
import threading

import anyio
import pytest

from app.auth.sessions import (
    LiveSession,
    new_session_tokens,
    lookup_media_session,
    hash_token,
    lookup_session,
    revoke_session_hash,
)
from app.database.database import Database, DatabaseContext
from tests.auth_helpers import create_session, sha256_hex
from tests.owned_database import add_test_user
from tests.schema_fixtures import INIT_SQL
from tests.sqlite_helpers import sql_rows


@pytest.fixture
def db(tmp_path):
    database = Database(
        DatabaseContext(database_path=tmp_path / "database.db", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    return database


def _dump(db) -> str:
    conn = sqlite3.connect(db.context.database_path)
    try:
        return "\n".join(conn.iterdump())
    finally:
        conn.close()


def _lookup(db, token):
    return anyio.run(lookup_session, db, token)


def _lookup_media(db, media_token):
    return anyio.run(lookup_media_session, db, media_token)


# ── creation ────────────────────────────────────────────────────────────────

def test_a_session_has_two_distinct_256_bit_url_safe_tokens():
    tokens = new_session_tokens()

    assert tokens.token != tokens.media_token
    for token in (tokens.token, tokens.media_token):
        # token_urlsafe(32): 32 random bytes, 43 base64url characters.
        assert len(token) == 43
        assert set(token) <= set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )


def test_every_session_gets_fresh_tokens():
    first, second = new_session_tokens(), new_session_tokens()
    assert {first.token, first.media_token}.isdisjoint({second.token, second.media_token})


def test_the_stored_hashes_are_the_sha256_of_the_tokens():
    tokens = new_session_tokens()
    assert (tokens.token_hash, tokens.media_hash) == (
        sha256_hex(tokens.token), sha256_hex(tokens.media_token)
    )


# ── lookup ──────────────────────────────────────────────────────────────────

def test_a_live_api_token_resolves_to_its_user(db):
    user_id = add_test_user(db, "sam")
    sql_rows(db, "UPDATE users SET is_admin = 1 WHERE id = ?", (user_id,))
    tokens = create_session(db, user_id)

    assert _lookup(db, tokens.token) == LiveSession(
        session_hash=sha256_hex(tokens.token),
        user_id=user_id,
        is_admin=True,
        is_master_admin=False,
    )


@pytest.mark.parametrize("token", ["", "unknown-token", "x" * 43])
def test_an_unknown_token_resolves_to_nothing(db, token):
    create_session(db, add_test_user(db, "sam"))
    assert _lookup(db, token) is None


def test_the_media_token_is_not_an_api_token(db):
    tokens = create_session(db, add_test_user(db, "sam"))
    assert _lookup(db, tokens.media_token) is None


def test_the_stored_hash_is_not_accepted_as_a_token(db):
    tokens = create_session(db, add_test_user(db, "sam"))
    assert _lookup(db, sha256_hex(tokens.token)) is None


@pytest.mark.parametrize("column", ["disabled_at", "deleting_at"])
def test_a_disabled_or_deleting_user_is_rejected_on_the_next_lookup(db, column):
    user_id = add_test_user(db, "sam")
    tokens = create_session(db, user_id)
    assert _lookup(db, tokens.token) is not None

    # A CLI-style write from another connection, with no cache to invalidate.
    sql_rows(db, f"UPDATE users SET {column} = 5 WHERE id = ?", (user_id,))

    assert _lookup(db, tokens.token) is None


def test_one_users_flag_leaves_another_users_session_alone(db):
    sam, alex = add_test_user(db, "sam"), add_test_user(db, "alex")
    sams, alexs = create_session(db, sam), create_session(db, alex)
    sql_rows(db, "UPDATE users SET disabled_at = 5 WHERE id = ?", (sam,))

    assert _lookup(db, sams.token) is None
    assert _lookup(db, alexs.token).user_id == alex


def test_the_lookup_runs_off_the_event_loop_thread(db, monkeypatch):
    tokens = create_session(db, add_test_user(db, "sam"))
    threads = []
    real_connect = sqlite3.connect

    def recording_connect(*args, **kwargs):
        threads.append(threading.get_ident())
        return real_connect(*args, **kwargs)

    monkeypatch.setattr(sqlite3, "connect", recording_connect)

    async def lookup_and_report_loop_thread():
        return await lookup_session(db, tokens.token), threading.get_ident()

    found, loop_thread = anyio.run(lookup_and_report_loop_thread)

    assert found is not None
    assert threads and loop_thread not in threads


# ── revocation ──────────────────────────────────────────────────────────────

def test_revoking_rejects_the_session_and_keeps_the_row(db):
    user_id = add_test_user(db, "sam")
    tokens = create_session(db, user_id)

    revoke_session_hash(db, hash_token(tokens.token))

    assert _lookup(db, tokens.token) is None
    [(revoked_at,)] = sql_rows(db, "SELECT revoked_at FROM auth_sessions")
    assert revoked_at is not None


def test_revoking_is_idempotent_and_keeps_the_first_time(db):
    tokens = create_session(db, add_test_user(db, "sam"))
    revoke_session_hash(db, hash_token(tokens.token))
    [(first,)] = sql_rows(db, "SELECT revoked_at FROM auth_sessions")
    sql_rows(db, "UPDATE auth_sessions SET revoked_at = 1")

    revoke_session_hash(db, hash_token(tokens.token))
    revoke_session_hash(db, hash_token("unknown-token"))

    assert first is not None
    assert sql_rows(db, "SELECT revoked_at FROM auth_sessions") == [(1,)]


def test_revoking_one_session_leaves_the_users_other_sessions(db):
    user_id = add_test_user(db, "sam")
    first, second = create_session(db, user_id), create_session(db, user_id)

    revoke_session_hash(db, hash_token(first.token))

    assert _lookup(db, first.token) is None
    assert _lookup(db, second.token).user_id == user_id


# ── media-token lookup (M.1b, spec §5.3: ``?access_token=`` on media GETs) ───

def test_a_live_media_token_resolves_to_its_session_and_user(db):
    user_id = add_test_user(db, "sam")
    sql_rows(db, "UPDATE users SET is_admin = 1 WHERE id = ?", (user_id,))
    tokens = create_session(db, user_id)

    # The principal names the session by its API-token hash in both cases, so
    # a logout through either token revokes the same row.
    assert _lookup_media(db, tokens.media_token) == LiveSession(
        session_hash=sha256_hex(tokens.token),
        user_id=user_id,
        is_admin=True,
        is_master_admin=False,
    )


@pytest.mark.parametrize("token", ["", "unknown-token", "x" * 43])
def test_an_unknown_media_token_resolves_to_nothing(db, token):
    create_session(db, add_test_user(db, "sam"))
    assert _lookup_media(db, token) is None


def test_the_api_token_is_not_a_media_token(db):
    tokens = create_session(db, add_test_user(db, "sam"))
    assert _lookup_media(db, tokens.token) is None


def test_the_stored_media_hash_is_not_accepted_as_a_media_token(db):
    tokens = create_session(db, add_test_user(db, "sam"))
    assert _lookup_media(db, sha256_hex(tokens.media_token)) is None


def test_revoking_the_session_rejects_its_media_token_too(db):
    user_id = add_test_user(db, "sam")
    first, second = create_session(db, user_id), create_session(db, user_id)

    revoke_session_hash(db, hash_token(first.token))

    assert _lookup_media(db, first.media_token) is None
    assert _lookup_media(db, second.media_token).user_id == user_id


@pytest.mark.parametrize("column", ["disabled_at", "deleting_at"])
def test_a_disabled_or_deleting_users_media_token_is_rejected_next_lookup(db, column):
    user_id = add_test_user(db, "sam")
    tokens = create_session(db, user_id)
    assert _lookup_media(db, tokens.media_token) is not None

    sql_rows(db, f"UPDATE users SET {column} = 5 WHERE id = ?", (user_id,))

    assert _lookup_media(db, tokens.media_token) is None


def test_the_media_lookup_runs_off_the_event_loop_thread(db, monkeypatch):
    tokens = create_session(db, add_test_user(db, "sam"))
    threads = []
    real_connect = sqlite3.connect

    def recording_connect(*args, **kwargs):
        threads.append(threading.get_ident())
        return real_connect(*args, **kwargs)

    monkeypatch.setattr(sqlite3, "connect", recording_connect)

    async def lookup_and_report_loop_thread():
        return await lookup_media_session(db, tokens.media_token), threading.get_ident()

    found, loop_thread = anyio.run(lookup_and_report_loop_thread)

    assert found is not None
    assert threads and loop_thread not in threads
