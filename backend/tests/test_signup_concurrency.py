"""Phase M.1a (M-U11, spec §5.2): the register transaction.

The argon2 hash is computed **before** the ``BEGIN IMMEDIATE`` register
transaction, and ``signup_policy.check(conn)`` runs inside it, so two
concurrent signups for the last slot (two connections) let exactly one win.
"""

import sqlite3
import threading

import pytest
from argon2 import PasswordHasher

from app.auth import accounts, signup_policy
from app.auth.signup_policy import UserLimitReached
from app.config import Settings
from app.database.database import Database, DatabaseContext
from tests.owned_database import add_test_user
from tests.schema_fixtures import INIT_SQL

PASSWORD = "a long enough password"


@pytest.fixture
def db(tmp_path):
    database = Database(
        DatabaseContext(database_path=tmp_path / "database.db", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    add_test_user(database, "admin")
    return database


def _settings(tmp_path, **overrides) -> Settings:
    values = dict(
        osml_insecure_fast_password_hashing=True,
        music_library_dir=tmp_path / "music",
        user_import_dir=tmp_path / "import-users",
    )
    values.update(overrides)
    return Settings(_env_file=None, **values)


def _user_keys(db):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return [r[0] for r in conn.execute("SELECT username_key FROM users ORDER BY id")]
    finally:
        conn.close()


def test_the_hash_is_computed_before_the_write_lock_is_taken(db, tmp_path, monkeypatch):
    settings = _settings(tmp_path)
    lock_free_while_hashing = []
    real_hash = PasswordHasher.hash

    def probing_hash(hasher, *args, **kwargs):
        # Another connection can take the write lock at once: register holds
        # no transaction while it hashes.
        probe = sqlite3.connect(db.context.database_path, timeout=0)
        try:
            probe.execute("BEGIN IMMEDIATE")
            probe.rollback()
            lock_free_while_hashing.append(True)
        except sqlite3.OperationalError:
            lock_free_while_hashing.append(False)
        finally:
            probe.close()
        return real_hash(hasher, *args, **kwargs)

    monkeypatch.setattr(PasswordHasher, "hash", probing_hash)

    accounts.register(db, settings, "Sam", PASSWORD)

    assert lock_free_while_hashing == [True]
    assert _user_keys(db) == ["admin", "sam"]


def test_two_concurrent_signups_for_the_last_slot_let_exactly_one_win(db, tmp_path, monkeypatch):
    settings = _settings(tmp_path, osml_max_users=2)  # the admin + one slot
    first_checked = threading.Event()
    release_first = threading.Event()
    real_check = signup_policy.check
    callers = []

    def gated_check(conn, settings_):
        real_check(conn, settings_)
        callers.append(threading.current_thread().name)
        if threading.current_thread().name == "first":
            # Hold the first signup inside its transaction, past the check
            # and before its insert.
            first_checked.set()
            assert release_first.wait(5), "never released"

    monkeypatch.setattr(signup_policy, "check", gated_check)

    # The second signup's connection reports when it asks for the write lock.
    second_locking = threading.Event()
    real_connect = sqlite3.connect

    def tracing_connect(*args, **kwargs):
        conn = real_connect(*args, **kwargs)
        if threading.current_thread().name == "second":
            def trace(statement):
                if statement.lstrip().upper().startswith("BEGIN IMMEDIATE"):
                    second_locking.set()
            conn.set_trace_callback(trace)
        return conn

    monkeypatch.setattr(sqlite3, "connect", tracing_connect)
    outcomes = {}

    def signup(name, username):
        try:
            accounts.register(db, settings, username, PASSWORD)
            outcomes[name] = "won"
        except UserLimitReached:
            outcomes[name] = "limit"

    first = threading.Thread(target=signup, args=("first", "Sam"), name="first")
    second = threading.Thread(target=signup, args=("second", "Alex"), name="second")
    first.start()
    assert first_checked.wait(5)
    second.start()
    # The second signup, on its own connection, asks for the write lock while
    # the first still holds it past its check; only then is the first let go.
    # (Without BEGIN IMMEDIATE the second never asks and this wait fails.)
    second_reached_lock = second_locking.wait(5)
    release_first.set()
    first.join(5)
    second.join(5)

    assert second_reached_lock
    assert outcomes == {"first": "won", "second": "limit"}
    assert _user_keys(db) == ["admin", "sam"]
    assert callers == ["first"]  # the second was refused by the check itself


def test_the_policy_check_runs_inside_the_write_transaction(db, tmp_path, monkeypatch):
    settings = _settings(tmp_path)
    in_transaction = []
    real_check = signup_policy.check

    def recording_check(conn, settings_):
        in_transaction.append(conn.in_transaction)
        probe = sqlite3.connect(db.context.database_path, timeout=0)
        try:
            with pytest.raises(sqlite3.OperationalError):
                probe.execute("BEGIN IMMEDIATE")
        finally:
            probe.close()
        real_check(conn, settings_)

    monkeypatch.setattr(signup_policy, "check", recording_check)

    accounts.register(db, settings, "Sam", PASSWORD)

    assert in_transaction == [True]
