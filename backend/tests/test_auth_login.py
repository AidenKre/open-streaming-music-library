"""Phase M.1a (M-U10, M-U11, spec §5.2): ``POST /auth/login``.

Same body as register → 200 with the same shape. An unknown, disabled or
deleting user and a wrong password all answer 401 ``invalid_credentials``,
and every path performs exactly one argon2 verify (a dummy hash for an
unknown user; the real hash before rejecting a disabled or deleting user),
so timing doesn't tell them apart. A hash made with other parameters is
rehashed on a successful login.
"""

import pytest
from argon2 import PasswordHasher, extract_parameters

from tests.auth_helpers import sha256_hex
from tests.sqlite_helpers import sql_dicts

PASSWORD = "a long enough password"


def _login(client, username="Sam", password=PASSWORD):
    return client.post("/auth/login", json={"username": username, "password": password})


@pytest.fixture
def client(open_app_client):
    with open_app_client() as c:
        assert c.post("/auth/register", json={"username": "Sam", "password": PASSWORD}).status_code == 201
        yield c


@pytest.fixture
def verifies(monkeypatch):
    """Counts real argon2 verifies."""
    calls = []
    real_verify = PasswordHasher.verify

    def counting_verify(hasher, *args, **kwargs):
        calls.append(args)
        return real_verify(hasher, *args, **kwargs)

    monkeypatch.setattr(PasswordHasher, "verify", counting_verify)
    return calls


def _sam(client):
    return sql_dicts(client, "SELECT * FROM users WHERE username_key = 'sam'")[0]


# ── success ─────────────────────────────────────────────────────────────────

def test_login_returns_a_new_session_and_the_user(client):
    sam = _sam(client)
    response = _login(client)

    assert response.status_code == 200, response.text
    body = response.json()
    assert set(body) == {"token", "media_token", "server_instance_id", "user"}
    assert body["user"] == {"id": sam["id"], "username": "Sam", "is_admin": False, "is_master_admin": False}
    assert body["server_instance_id"] == client.get("/app/info").json()["server"]["instance_id"]
    sessions = sql_dicts(client, "SELECT token_hash, media_hash FROM auth_sessions WHERE user_id = ?", (sam["id"],))
    assert {"token_hash": sha256_hex(body["token"]), "media_hash": sha256_hex(body["media_token"])} in sessions
    assert len(sessions) == 2  # register's session is kept


def test_the_username_is_matched_by_its_key(client):
    assert _login(client, "sAM").json()["user"]["username"] == "Sam"


def test_the_admin_logs_in_with_the_env_password(client):
    from tests.conftest import TEST_ADMIN_PASSWORD, TEST_ADMIN_USERNAME

    body = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD).json()
    assert body["user"]["is_admin"] is True and body["user"]["is_master_admin"] is True


def test_a_decomposed_spelling_logs_in(open_app_client):
    with open_app_client() as client:
        composed = "café-au-lait"
        client.post("/auth/register", json={"username": "Sam", "password": composed})
        assert _login(client, "Sam", "café-au-lait").status_code == 200


def test_a_hash_with_other_parameters_is_rehashed_on_login(client):
    old = PasswordHasher(time_cost=1, memory_cost=16, parallelism=1).hash(PASSWORD)
    sql_dicts(client, "UPDATE users SET password_hash = ? WHERE username_key = 'sam'", (old,))

    assert _login(client).status_code == 200

    stored = _sam(client)["password_hash"]
    assert stored != old
    assert extract_parameters(stored).memory_cost != 16
    assert PasswordHasher().verify(stored, PASSWORD)
    assert _login(client).status_code == 200


def test_a_current_hash_is_left_alone(client):
    before = _sam(client)["password_hash"]
    _login(client)
    assert _sam(client)["password_hash"] == before


# ── refusals: one code, one verify ──────────────────────────────────────────

def _refusal(response):
    assert response.status_code == 401, response.text
    detail = response.json()["detail"]
    assert detail["error"] == "invalid_credentials"
    assert detail["retryable"] is False
    return response.json()


def _setup_path(client, path):
    if path == "disabled":
        sql_dicts(client, "UPDATE users SET disabled_at = 5 WHERE username_key = 'sam'")
    elif path == "deleting":
        sql_dicts(client, "UPDATE users SET deleting_at = 5 WHERE username_key = 'sam'")


_PATHS = {
    "unknown user": ("nobody", PASSWORD),
    "wrong password": ("Sam", PASSWORD + "!"),
    "disabled": ("Sam", PASSWORD),
    "deleting": ("Sam", PASSWORD),
    "malformed username": ("Kate", PASSWORD),  # Kelvin sign; lower() is "kate"
    "too long a password": ("Sam", "p" * 1025),
    "empty": ("", ""),
}


@pytest.mark.parametrize("path", list(_PATHS))
def test_every_refused_login_is_the_same_401(client, path):
    _setup_path(client, path)
    sessions_before = sql_dicts(client, "SELECT * FROM auth_sessions")

    body = _refusal(_login(client, *_PATHS[path]))

    reference = _refusal(_login(client, "nobody", PASSWORD))
    assert body == reference
    assert sql_dicts(client, "SELECT * FROM auth_sessions") == sessions_before


@pytest.mark.parametrize("path", [*_PATHS, "success"])
def test_every_login_path_performs_exactly_one_verify(client, verifies, path):
    _setup_path(client, path)
    username, password = _PATHS.get(path, ("Sam", PASSWORD))
    verifies.clear()

    _login(client, username, password)

    assert len(verifies) == 1


@pytest.mark.parametrize("path", ["disabled", "deleting"])
def test_a_disabled_or_deleting_user_is_verified_against_the_real_hash(client, verifies, path):
    _setup_path(client, path)
    stored = _sam(client)["password_hash"]
    verifies.clear()

    _login(client)

    [(verified_hash, _password)] = verifies
    assert verified_hash == stored


def test_an_unknown_user_is_verified_against_a_dummy_with_current_parameters(client, verifies):
    sam_params = extract_parameters(_sam(client)["password_hash"])
    verifies.clear()

    _login(client, "nobody")

    [(dummy, _password)] = verifies
    assert extract_parameters(dummy) == sam_params


def test_a_wrong_password_never_appears_in_the_response_or_log(client, caplog):
    secret = "unmistakable-wrong-secret"
    with caplog.at_level("DEBUG"):
        response = _login(client, "Sam", secret)
    assert response.status_code == 401
    assert secret not in response.text and secret not in caplog.text


# ── bodies ──────────────────────────────────────────────────────────────────

def test_the_route_reads_no_pydantic_body_parameter(client):
    [route] = [r for r in client.app.routes if getattr(r, "path", None) == "/auth/login"]
    assert route.dependant.body_params == []


def test_a_body_over_16_kib_is_refused(client, verifies):
    body = b'{"username": "Sam", "password": "' + b"p" * (16 * 1024) + b'"}'
    verifies.clear()
    response = client.post("/auth/login", content=body, headers={"Content-Type": "application/json"})
    assert response.status_code == 413
    assert response.json()["detail"]["error"] == "request_too_large"
    assert verifies == []


def test_a_malformed_body_is_422_without_echoing_input(client):
    response = client.post("/auth/login", content=b'{"username": "Sam", "password": 12345678}',
                           headers={"Content-Type": "application/json"})
    assert response.status_code == 422
    assert all("input" not in item for item in response.json()["detail"])


# ── review r1 #2: an admin change racing a login ────────────────────────────

def _change_during_verify(client, monkeypatch, statement, params=()):
    """Run ``statement`` from another connection while login verifies, like an
    admin CLI command landing between the verify and the session insert."""
    real_verify = PasswordHasher.verify

    def racing_verify(hasher, *args, **kwargs):
        result = real_verify(hasher, *args, **kwargs)
        sql_dicts(client, statement, params)
        return result

    monkeypatch.setattr(PasswordHasher, "verify", racing_verify)


def test_a_password_reset_during_login_refuses_the_login(client, monkeypatch):
    reset = PasswordHasher(time_cost=1, memory_cost=8, parallelism=1).hash("the new password")
    sessions_before = sql_dicts(client, "SELECT * FROM auth_sessions")
    _change_during_verify(
        client, monkeypatch, "UPDATE users SET password_hash = ? WHERE username_key = 'sam'", (reset,)
    )

    _refusal(_login(client))

    assert _sam(client)["password_hash"] == reset
    assert sql_dicts(client, "SELECT * FROM auth_sessions") == sessions_before


def test_a_password_reset_during_a_rehashing_login_is_not_undone(client, monkeypatch):
    old = PasswordHasher(time_cost=1, memory_cost=16, parallelism=1).hash(PASSWORD)
    sql_dicts(client, "UPDATE users SET password_hash = ? WHERE username_key = 'sam'", (old,))
    reset = PasswordHasher(time_cost=1, memory_cost=8, parallelism=1).hash("the new password")
    sessions_before = sql_dicts(client, "SELECT * FROM auth_sessions")
    _change_during_verify(
        client, monkeypatch, "UPDATE users SET password_hash = ? WHERE username_key = 'sam'", (reset,)
    )

    _refusal(_login(client))

    assert _sam(client)["password_hash"] == reset
    assert sql_dicts(client, "SELECT * FROM auth_sessions") == sessions_before


def test_two_rehashing_logins_with_the_right_password_both_succeed(client, monkeypatch):
    """Pre-merge A1-01: two sign-ins on a hash with old parameters both verify
    against it and both rehash; the one that stores second finds the first's
    new hash. That is not a password reset: it signs in too."""
    from app.auth import accounts

    old = PasswordHasher(time_cost=1, memory_cost=16, parallelism=1).hash(PASSWORD)
    sql_dicts(client, "UPDATE users SET password_hash = ? WHERE username_key = 'sam'", (old,))
    sessions_before = len(sql_dicts(client, "SELECT * FROM auth_sessions"))
    real_verify = PasswordHasher.verify
    other = []

    def other_login_during_verify(hasher, *args, **kwargs):
        result = real_verify(hasher, *args, **kwargs)
        if not other:  # once: the other device's whole sign-in lands here
            other.append(None)
            state = client.app.state
            other[0] = accounts.login(state.database, state.settings, "Sam", PASSWORD)
        return result

    monkeypatch.setattr(PasswordHasher, "verify", other_login_during_verify)

    response = _login(client)

    assert other[0] is not None
    assert response.status_code == 200, response.text
    assert len(sql_dicts(client, "SELECT * FROM auth_sessions")) == sessions_before + 2
    stored = _sam(client)["password_hash"]
    assert stored != old and real_verify(PasswordHasher(), stored, PASSWORD)


def test_a_login_whose_own_rehash_was_busy_still_signs_in_after_another_rehash(client, monkeypatch):
    """Pre-merge A1-01 review: the login that loses the race may have had no
    hashing slot for its own rehash; it signs in all the same."""
    from app.auth import accounts
    from app.auth.passwords import AuthBusy

    old = PasswordHasher(time_cost=1, memory_cost=16, parallelism=1).hash(PASSWORD)
    sql_dicts(client, "UPDATE users SET password_hash = ? WHERE username_key = 'sam'", (old,))
    real_verify, real_hash = PasswordHasher.verify, accounts.hash_password
    other, hashes = [], []

    def other_login_during_verify(hasher, *args, **kwargs):
        result = real_verify(hasher, *args, **kwargs)
        if not other:
            other.append(None)
            state = client.app.state
            other[0] = accounts.login(state.database, state.settings, "Sam", PASSWORD)
        return result

    def busy_after_the_first(settings, password):
        hashes.append(None)
        if len(hashes) > 1:  # the other sign-in rehashed; ours finds no slot
            raise AuthBusy("password hashing is busy")
        return real_hash(settings, password)

    monkeypatch.setattr(PasswordHasher, "verify", other_login_during_verify)
    monkeypatch.setattr(accounts, "hash_password", busy_after_the_first)

    response = _login(client)

    assert other[0] is not None and len(hashes) == 2
    assert response.status_code == 200, response.text


@pytest.mark.parametrize("column", ["disabled_at", "deleting_at"])
def test_a_disable_during_login_refuses_the_login(client, monkeypatch, column):
    sessions_before = sql_dicts(client, "SELECT * FROM auth_sessions")
    _change_during_verify(client, monkeypatch, f"UPDATE users SET {column} = 5 WHERE username_key = 'sam'")

    _refusal(_login(client))

    assert sql_dicts(client, "SELECT * FROM auth_sessions") == sessions_before
