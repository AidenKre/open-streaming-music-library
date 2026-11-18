"""Phase M.1a (M-U10, spec §5.1, SC-22): with both hashing slots taken,
register and login answer 503 ``auth_busy`` with ``retryable: true``.

The test holds the two slots with a gate inside argon2 (no sleeps).
"""

import threading

import pytest
from argon2 import PasswordHasher

from app.auth.passwords import hash_password
from tests.sqlite_helpers import table_count

PASSWORD = "a long enough password"


@pytest.fixture
def client(open_app_client):
    with open_app_client() as c:
        assert c.post("/auth/register", json={"username": "Sam", "password": PASSWORD}).status_code == 201
        yield c


@pytest.fixture
def both_slots_held(client, monkeypatch):
    release = threading.Event()
    entered = threading.Semaphore(0)
    real_hash = PasswordHasher.hash

    def blocking_hash(hasher, *args, **kwargs):
        entered.release()
        assert release.wait(5), "gate never released"
        return real_hash(hasher, *args, **kwargs)

    monkeypatch.setattr(PasswordHasher, "hash", blocking_hash)
    settings = client.app.state.settings
    holders = [threading.Thread(target=hash_password, args=(settings, "x" * 8)) for _ in range(2)]
    for holder in holders:
        holder.start()
    for _ in holders:
        assert entered.acquire(timeout=5)
    yield
    release.set()
    for holder in holders:
        holder.join(5)


def _assert_busy(response):
    assert response.status_code == 503, response.text
    detail = response.json()["detail"]
    assert detail["error"] == "auth_busy"
    assert detail["retryable"] is True
    assert PASSWORD not in response.text


def test_register_answers_auth_busy_and_creates_nothing(client, both_slots_held):
    users, sessions = table_count(client, "users"), table_count(client, "auth_sessions")

    _assert_busy(client.post("/auth/register", json={"username": "Alex", "password": PASSWORD}))

    assert (table_count(client, "users"), table_count(client, "auth_sessions")) == (users, sessions)


def test_login_answers_auth_busy_and_creates_no_session(client, both_slots_held):
    sessions = table_count(client, "auth_sessions")

    _assert_busy(client.post("/auth/login", json={"username": "Sam", "password": PASSWORD}))

    assert table_count(client, "auth_sessions") == sessions


def test_login_works_again_once_a_slot_is_free(client):
    assert client.post("/auth/login", json={"username": "Sam", "password": PASSWORD}).status_code == 200
