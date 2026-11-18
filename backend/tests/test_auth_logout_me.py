"""Phase M.1b (M-U11 logout/me, spec §5.2, §5.4 "Lifecycle"):
``POST /auth/logout`` and ``GET /auth/me``.

- Logout revokes the calling session: its API token and its media token stop
  working on the next request. It answers 204. Revoking is idempotent in the
  database; a repeated logout with the same (now revoked) token is refused by
  the boundary like any other dead token (401 ``invalid_token``).
- ``me`` answers ``{user: {id, username, is_admin, is_master_admin},
  server_instance_id}`` for the caller.
"""

import pytest

from app.library import Library
from tests.auth_helpers import flac_track
from tests.conftest import bearer, log_in
from tests.sqlite_helpers import sql_rows

PASSWORD = "correct horse battery"


def _register(client, username):
    response = client.post("/auth/register", json={"username": username, "password": PASSWORD})
    assert response.status_code == 201, response.text
    return response.json()


def _error(response):
    return response.status_code, response.json()["detail"]["error"]


# ── logout ──────────────────────────────────────────────────────────────────

def test_logout_answers_204_with_no_body(app_client):
    sam = _register(app_client, "Sam")

    response = app_client.post("/auth/logout", headers=bearer(sam["token"]))

    assert response.status_code == 204
    assert response.content == b""


def test_logout_revokes_the_api_token_on_the_next_request(app_client):
    sam = _register(app_client, "Sam")
    assert app_client.get("/tracks", headers=bearer(sam["token"])).status_code == 200

    app_client.post("/auth/logout", headers=bearer(sam["token"]))

    assert _error(app_client.get("/tracks", headers=bearer(sam["token"]))) == (401, "invalid_token")
    [(revoked_at,)] = sql_rows(
        app_client, "SELECT revoked_at FROM auth_sessions WHERE user_id = ?", (sam["user"]["id"],)
    )
    assert revoked_at is not None


def test_logout_revokes_the_media_token_too(app_client, tmp_path):
    db = app_client.app.state.database
    sam = _register(app_client, "Sam")
    folder = db.get_user(sam["user"]["id"])["library_folder"]
    track = flac_track(tmp_path / "music" / folder / "Lucky.flac", "Lucky")
    assert Library(db, sam["user"]["id"]).add_track(track)
    stream = f"/tracks/{track.uuid_id}/stream"
    params = {"quality": "original", "access_token": sam["media_token"]}
    app_client.headers.pop("Authorization")
    assert app_client.get(stream, params=params).status_code == 200

    app_client.post("/auth/logout", headers=bearer(sam["token"]))

    assert _error(app_client.get(stream, params=params)) == (401, "invalid_token")


def test_logout_leaves_the_users_other_sessions_and_other_users_alone(app_client):
    sam = _register(app_client, "Sam")
    second = log_in(app_client, "Sam", PASSWORD)
    alex = _register(app_client, "Alex")

    app_client.post("/auth/logout", headers=bearer(sam["token"]))

    assert app_client.get("/tracks", headers=bearer(second["token"])).status_code == 200
    assert app_client.get("/tracks", headers=bearer(alex["token"])).status_code == 200
    assert app_client.get("/tracks").status_code == 200  # the fixture's admin


def test_a_repeated_logout_is_refused_as_a_dead_token_and_changes_nothing(app_client):
    sam = _register(app_client, "Sam")
    app_client.post("/auth/logout", headers=bearer(sam["token"]))
    before = sql_rows(app_client, "SELECT * FROM auth_sessions ORDER BY token_hash")

    response = app_client.post("/auth/logout", headers=bearer(sam["token"]))

    assert _error(response) == (401, "invalid_token")
    assert sql_rows(app_client, "SELECT * FROM auth_sessions ORDER BY token_hash") == before


def test_logout_without_a_token_is_auth_required(app_client):
    app_client.headers.pop("Authorization")

    assert _error(app_client.post("/auth/logout")) == (401, "auth_required")


def test_logout_needs_the_api_token_not_the_media_token(app_client):
    sam = _register(app_client, "Sam")
    app_client.headers.pop("Authorization")

    response = app_client.post("/auth/logout", params={"access_token": sam["media_token"]})

    assert _error(response) == (401, "auth_required")
    assert app_client.get("/tracks", headers=bearer(sam["token"])).status_code == 200


def test_after_logout_the_user_can_log_in_again(app_client):
    sam = _register(app_client, "Sam")
    app_client.post("/auth/logout", headers=bearer(sam["token"]))

    again = log_in(app_client, "Sam", PASSWORD)

    assert app_client.get("/tracks", headers=bearer(again["token"])).status_code == 200


# ── me ──────────────────────────────────────────────────────────────────────

def test_me_describes_the_master_admin(app_client):
    info = app_client.get("/app/info").json()

    response = app_client.get("/auth/me")

    assert response.status_code == 200
    assert response.json() == {
        "user": {
            "id": app_client.app.state.admin_user_id,
            "username": "admin",
            "is_admin": True,
            "is_master_admin": True,
        },
        "server_instance_id": info["server"]["instance_id"],
    }


def test_me_describes_the_caller_not_the_admin(app_client):
    sam = _register(app_client, "Sam")

    response = app_client.get("/auth/me", headers=bearer(sam["token"]))

    assert response.status_code == 200
    assert response.json()["user"] == {
        "id": sam["user"]["id"],
        "username": "Sam",
        "is_admin": False,
        "is_master_admin": False,
    }
    assert response.json()["server_instance_id"] == sam["server_instance_id"]


def test_me_after_logout_is_refused(app_client):
    sam = _register(app_client, "Sam")
    app_client.post("/auth/logout", headers=bearer(sam["token"]))

    assert _error(app_client.get("/auth/me", headers=bearer(sam["token"]))) == (401, "invalid_token")


@pytest.mark.parametrize("method", ["POST", "PUT", "DELETE"])
def test_me_is_read_only(app_client, method):
    assert app_client.request(method, "/auth/me").status_code == 405


def test_logout_is_post_only(app_client):
    assert app_client.get("/auth/logout").status_code == 405
