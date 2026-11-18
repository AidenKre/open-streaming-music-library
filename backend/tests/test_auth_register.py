"""Phase M.1a (M-U11, spec §5.2, §5.4): ``POST /auth/register``.

``{username, password}`` → 201 ``{token, media_token, server_instance_id,
user: {id, username, is_admin, is_master_admin}}``. The body is read through
``bounded_body(16 KiB)`` and validated with ``model_validate_json``. Errors use
the SC-22 envelope and never echo the password.
"""

import sqlite3

import anyio
import pytest
from argon2 import PasswordHasher

from app.auth.sessions import lookup_session
from tests.auth_helpers import sha256_hex
from tests.sqlite_helpers import sql_dicts

PASSWORD = "a long enough password"


def _users(client):
    return sql_dicts(client, "SELECT * FROM users ORDER BY id")


def _register(client, username="Sam", password=PASSWORD, **kwargs):
    return client.post("/auth/register", json={"username": username, "password": password}, **kwargs)


@pytest.fixture
def client(open_app_client):
    with open_app_client() as c:
        yield c


# ── success ─────────────────────────────────────────────────────────────────

def test_register_creates_the_user_and_logs_in(client):
    response = _register(client)

    assert response.status_code == 201, response.text
    body = response.json()
    assert set(body) == {"token", "media_token", "server_instance_id", "user"}
    new_user = _users(client)[-1]
    assert body["user"] == {
        "id": new_user["id"],
        "username": "Sam",
        "is_admin": False,
        "is_master_admin": False,
    }
    assert body["server_instance_id"] == client.get("/app/info").json()["server"]["instance_id"]


def test_the_new_user_row_holds_an_argon2id_hash_of_the_password(client):
    _register(client)

    user = _users(client)[-1]
    assert (user["username"], user["username_key"]) == ("Sam", "sam")
    assert (user["is_admin"], user["is_master_admin"]) == (0, 0)
    assert user["disabled_at"] is None and user["deleting_at"] is None
    assert user["created_at"] > 0
    assert user["password_hash"].startswith("$argon2id$")
    assert PasswordHasher().verify(user["password_hash"], PASSWORD)


def test_the_returned_tokens_are_a_live_session_stored_only_as_hashes(client):
    body = _register(client).json()

    # The fixture's own admin login (M.1b) is the only other session row.
    sessions = sql_dicts(
        client,
        "SELECT token_hash, media_hash, user_id, revoked_at FROM auth_sessions WHERE user_id != ?",
        (client.app.state.admin_user_id,),
    )
    assert sessions == [{
        "token_hash": sha256_hex(body["token"]),
        "media_hash": sha256_hex(body["media_token"]),
        "user_id": body["user"]["id"],
        "revoked_at": None,
    }]
    live = anyio.run(lookup_session, client.app.state.database, body["token"])
    assert live.user_id == body["user"]["id"]
    path = client.app.state.database.context.database_path
    conn = sqlite3.connect(path)
    try:
        dump = "\n".join(conn.iterdump())
    finally:
        conn.close()
    assert body["token"] not in dump and body["media_token"] not in dump
    assert PASSWORD not in dump


def test_the_library_folder_comes_from_the_username_key(client):
    _register(client, "Sam")
    assert _users(client)[-1]["library_folder"] == "sam"


def test_the_library_folder_skips_a_stray_music_folder(open_app_client, tmp_path):
    with open_app_client() as client:
        (tmp_path / "music" / "SAM").mkdir(parents=True)
        _register(client, "Sam")
        assert _users(client)[-1]["library_folder"] == "sam-2"


def test_the_route_reads_no_pydantic_body_parameter(client):
    # SC-16b: a Pydantic body parameter would buffer the whole body first.
    [route] = [r for r in client.app.routes if getattr(r, "path", None) == "/auth/register"]
    assert route.dependant.body_params == []


# ── bodies ──────────────────────────────────────────────────────────────────

def test_a_body_over_16_kib_is_refused_before_parsing(client):
    body = b'{"username": "Sam", "password": "' + b"p" * (16 * 1024) + b'"}'
    response = client.post("/auth/register", content=body,
                           headers={"Content-Type": "application/json"})

    assert response.status_code == 413
    assert response.json()["detail"]["error"] == "request_too_large"
    assert "ppppppppp" not in response.text
    assert len(_users(client)) == 1


def test_a_body_of_exactly_16_kib_is_read(client):
    prefix, suffix = b'{"username": "Sam", "password": "', b'"}'
    filler = b"p" * (16 * 1024 - len(prefix) - len(suffix))
    response = client.post("/auth/register", content=prefix + filler + suffix,
                           headers={"Content-Type": "application/json"})
    # Read and parsed; the password is then too long for the 1024 rule.
    assert response.status_code == 422
    assert response.json()["detail"]["error"] == "weak_password"


@pytest.mark.parametrize("body", [
    b"not json",
    b'{"username": "Sam"}',
    b'{"password": "a long enough password"}',
    b'{"username": 5, "password": "a long enough password"}',
    b'{"username": "Sam", "password": ["a long enough password"]}',
    b"[]",
])
def test_a_malformed_body_is_422_without_echoing_input(client, body):
    response = client.post("/auth/register", content=body,
                           headers={"Content-Type": "application/json"})

    assert response.status_code == 422
    detail = response.json()["detail"]
    assert isinstance(detail, list)
    assert all("input" not in item for item in detail)
    assert "a long enough password" not in response.text
    assert len(_users(client)) == 1


# ── refusals ────────────────────────────────────────────────────────────────

def _assert_refused(client, response, status, code):
    assert response.status_code == status, response.text
    detail = response.json()["detail"]
    assert detail["error"] == code
    assert detail["retryable"] is False
    assert isinstance(detail["message"], str) and detail["message"]
    assert len(_users(client)) == 1  # only the admin
    # Only the fixture's own admin login (M.1b) holds a session.
    assert [row["user_id"] for row in sql_dicts(client, "SELECT * FROM auth_sessions")] == [
        client.app.state.admin_user_id
    ]


@pytest.mark.parametrize("username", ["ab", "-sam", "s m", "säm", "a" * 33, "", "sam/x"])
def test_an_invalid_username_is_refused(client, username):
    _assert_refused(client, _register(client, username), 422, "invalid_username")


@pytest.mark.parametrize("username", ["root", "System", "CON", "nul", "com1", "LPT9"])
def test_a_reserved_username_is_refused_for_signup(client, username):
    _assert_refused(client, _register(client, username), 422, "invalid_username")


@pytest.mark.parametrize("password", ["p" * 7, "p" * 1025, "é" * 4, ""])
def test_a_weak_password_is_refused_without_echoing_it(client, password):
    response = _register(client, "Sam", password)
    _assert_refused(client, response, 422, "weak_password")
    if password:
        assert password not in response.text


@pytest.mark.parametrize("length", [8, 1024])
def test_passwords_of_8_and_1024_characters_are_accepted(client, length):
    assert _register(client, "Sam", "p" * length).status_code == 201


@pytest.mark.parametrize("username", ["admin", "ADMIN", "Admin"])
def test_a_taken_username_is_refused_whatever_its_case(client, username):
    _assert_refused(client, _register(client, username), 409, "username_taken")


def test_a_second_signup_with_the_same_key_is_refused(client):
    assert _register(client, "Sam").status_code == 201
    response = _register(client, "sAM", "another long password")
    assert response.status_code == 409
    assert response.json()["detail"]["error"] == "username_taken"
    assert len(_users(client)) == 2


def test_closed_signup_is_refused(open_app_client):
    with open_app_client(env={"OSML_SIGNUP_ENABLED": "false"}) as client:
        _assert_refused(client, _register(client), 403, "signup_disabled")


def test_a_full_server_is_refused(open_app_client):
    # The admin alone fills a one-user server.
    with open_app_client(env={"OSML_MAX_USERS": "1"}) as client:
        _assert_refused(client, _register(client), 403, "user_limit_reached")


def test_the_last_slot_can_be_taken_once(open_app_client):
    with open_app_client(env={"OSML_MAX_USERS": "2"}) as client:
        assert _register(client, "Sam").status_code == 201
        response = _register(client, "Alex")
        assert response.status_code == 403
        assert response.json()["detail"]["error"] == "user_limit_reached"


def test_closed_signup_hides_whether_a_name_is_taken(open_app_client):
    with open_app_client(env={"OSML_SIGNUP_ENABLED": "false"}) as client:
        _assert_refused(client, _register(client, "admin"), 403, "signup_disabled")


def test_the_password_never_appears_in_any_register_response_or_log(client, caplog):
    secret = "unmistakable-secret-éé"
    with caplog.at_level("DEBUG"):
        responses = [
            _register(client, "Sam", secret),
            _register(client, "Sam", secret),  # taken
            _register(client, "root", secret),  # reserved
            _register(client, "Sam", secret[:7]),  # weak
        ]
    assert [r.status_code for r in responses] == [201, 409, 422, 422]
    for response in responses:
        assert secret[:7] not in response.text
    assert secret[:7] not in caplog.text
