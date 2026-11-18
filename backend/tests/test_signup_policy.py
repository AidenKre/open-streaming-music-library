"""Phase M.1a (M-U11, spec §5.2): the signup valves are one function,
``signup_policy.check(conn, settings)``, run inside the register transaction.

``OSML_MAX_USERS`` counts every row in ``users``: the admin, disabled and
deleting users included.
"""

import sqlite3

import pytest

from app.auth import signup_policy
from app.auth.signup_policy import SignupDisabled, UserLimitReached
from app.config import Settings
from tests.schema_fixtures import INIT_SQL


@pytest.fixture
def conn():
    connection = sqlite3.connect(":memory:")
    connection.executescript(INIT_SQL.read_text())
    yield connection
    connection.close()


def _settings(**overrides) -> Settings:
    return Settings(_env_file=None, **overrides)


def _add_users(conn, count, **columns):
    start = conn.execute("SELECT count(*) FROM users").fetchone()[0]
    for i in range(start, start + count):
        conn.execute(
            "INSERT INTO users (username, username_key, password_hash, library_folder, "
            "created_at, is_admin, is_master_admin, disabled_at, deleting_at) "
            "VALUES (?, ?, 'h', ?, 0, ?, ?, ?, ?)",
            (
                f"user{i}", f"user{i}", f"user{i}",
                columns.get("is_admin", 0), columns.get("is_master_admin", 0),
                columns.get("disabled_at"), columns.get("deleting_at"),
            ),
        )


def test_open_signup_below_the_limit_passes(conn):
    _add_users(conn, 2)
    signup_policy.check(conn, _settings(osml_max_users=3))


def test_closed_signup_is_refused(conn):
    with pytest.raises(SignupDisabled):
        signup_policy.check(conn, _settings(osml_signup_enabled=False))


def test_closed_signup_wins_over_a_full_server(conn):
    _add_users(conn, 3)
    with pytest.raises(SignupDisabled):
        signup_policy.check(conn, _settings(osml_signup_enabled=False, osml_max_users=3))


def test_a_full_server_refuses_signup(conn):
    _add_users(conn, 3)
    with pytest.raises(UserLimitReached):
        signup_policy.check(conn, _settings(osml_max_users=3))


def test_the_count_includes_the_admin_and_disabled_and_deleting_users(conn):
    _add_users(conn, 1, is_admin=1, is_master_admin=1)
    _add_users(conn, 1, disabled_at=5)
    _add_users(conn, 1, deleting_at=5)
    with pytest.raises(UserLimitReached):
        signup_policy.check(conn, _settings(osml_max_users=3))
    signup_policy.check(conn, _settings(osml_max_users=4))


def test_a_limit_of_zero_refuses_every_signup(conn):
    with pytest.raises(UserLimitReached):
        signup_policy.check(conn, _settings(osml_max_users=0))
