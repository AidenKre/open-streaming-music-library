"""Phase M.1a (spec §5.4 "Injection payloads"): hostile usernames and
passwords on register and login are rejected or stored and looked up
literally, never interpolated into SQL.
"""

import pytest

from tests.conftest import TEST_ADMIN_PASSWORD
from tests.sqlite_helpers import sql_rows

PASSWORD = "a long enough password"

HOSTILE_USERNAMES = [
    "' OR '1'='1",
    "admin' --",
    "admin'/*",
    '"; DROP TABLE users; --',
    "sam\x00",
    "sam\x00admin",
    "sam\nadmin",
    "a" * 10_000,
    "ѕam",  # Cyrillic dze, looks like "sam"
    "Kate",  # Kelvin sign; str.lower() gives "kate"
    "ｓａｍ",  # fullwidth "sam"
    "admın",  # dotless i
    "ADMİN",  # dotted capital I; lower() gives "admi̇n"
]


def _users(client):
    return [r[0] for r in sql_rows(client, "SELECT username FROM users ORDER BY id")]


@pytest.fixture
def client(open_app_client):
    with open_app_client() as c:
        for name in ("Sam", "kate"):
            assert c.post("/auth/register", json={"username": name, "password": PASSWORD}).status_code == 201
        yield c


@pytest.mark.parametrize("username", HOSTILE_USERNAMES, ids=range(len(HOSTILE_USERNAMES)))
def test_a_hostile_username_is_refused_on_register(client, username):
    response = client.post("/auth/register", json={"username": username, "password": PASSWORD})

    assert response.status_code == 422
    assert response.json()["detail"]["error"] == "invalid_username"
    assert _users(client) == ["admin", "Sam", "kate"]


@pytest.mark.parametrize("username", HOSTILE_USERNAMES, ids=range(len(HOSTILE_USERNAMES)))
@pytest.mark.parametrize("password", [PASSWORD, TEST_ADMIN_PASSWORD, "' OR '1'='1"])
def test_a_hostile_username_never_logs_in(client, username, password):
    response = client.post("/auth/login", json={"username": username, "password": password})

    assert response.status_code == 401
    assert response.json()["detail"]["error"] == "invalid_credentials"
    assert _users(client) == ["admin", "Sam", "kate"]


@pytest.mark.parametrize("password", [
    "' OR '1'='1' --",
    '"; DROP TABLE users; --',
    "pass\x00word-with-nul",
    "pass\nword\r\nwith newlines",
    "  ﻿ zero-width",
])
def test_a_hostile_password_is_stored_and_checked_literally(client, password):
    register = client.post("/auth/register", json={"username": "alex", "password": password})
    assert register.status_code == 201, register.text

    ok = client.post("/auth/login", json={"username": "alex", "password": password})
    near = client.post("/auth/login", json={"username": "alex", "password": password[:-1]})

    assert ok.status_code == 200
    assert near.status_code == 401
    assert password not in register.text + ok.text + near.text
    assert _users(client) == ["admin", "Sam", "kate", "alex"]


@pytest.mark.parametrize("payload", ["' OR '1'='1", "admin' --", "x' OR username_key LIKE '%"])
def test_the_username_lookup_binds_its_value(tmp_path, payload):
    """Review r1 m-R1-29: the format gate blocks every payload before SQL,
    so the API tests above cannot see the lookup itself. Call it directly:
    a hostile key matches nobody (and never every user)."""
    from tests.cli_fixtures import add_user, cli_settings, open_server_database

    db = open_server_database(cli_settings(tmp_path))
    add_user(db, "admin", master=True)
    add_user(db, "sam")

    assert db.get_user_by_username_key(payload) is None
    assert db.get_user_by_username_key("sam")["username"] == "sam"
