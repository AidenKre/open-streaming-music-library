"""Phase 7A.1a (SC-01 rule 6 + its Phase M note, plan drift D5): the backend
stamps ``X-Server-Instance-Id`` on every HTTP response from the auth
middleware — public routes, 401s, 404s, router errors, streamed bodies,
redirects and unhandled 500s alike — so a client can compare it with its
bound instance before committing a page. The id is read once at startup and
cached on ``app.state``; it is identity fencing, not a secret."""

import uuid

import pytest
from fastapi.testclient import TestClient

from app.models import Track, TrackMetaData
from tests.conftest import TEST_ADMIN_PASSWORD, TEST_ADMIN_USERNAME, log_in

HEADER = "X-Server-Instance-Id"
UNKNOWN = "00000000-0000-4000-8000-000000000000"


def _instance_id(client) -> str:
    return client.get("/app/info").json()["server"]["instance_id"]


def _assert_stamped(response, instance_id):
    assert response.headers.get_list(HEADER) == [instance_id], (
        response.status_code, dict(response.headers),
    )


def _add_track(client):
    library = client.app.state.admin_library
    source = library.root / "Radiohead" / "Lucky.flac"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"not really flac")
    track = Track(
        file_path=source,
        metadata=TrackMetaData(
            title="Lucky", artist="Radiohead", album="OK Computer", codec="flac",
            duration=1.0, bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
        ),
    )
    assert library.add_track(track)
    return track.uuid_id


def test_the_stamp_is_the_persisted_instance_id(app_client):
    instance_id = _instance_id(app_client)

    assert str(uuid.UUID(instance_id)) == instance_id
    assert app_client.app.state.server_instance_id == instance_id
    assert app_client.app.state.database.get_server_instance_id() == instance_id


# ── public routes (the exact allow-list) ───────────────────────────────────

def test_public_responses_are_stamped(app_client):
    instance_id = _instance_id(app_client)
    app_client.headers.pop("Authorization")

    _assert_stamped(app_client.get("/"), instance_id)
    _assert_stamped(app_client.get("/app/info"), instance_id)
    ok = app_client.post(
        "/auth/login", json={"username": TEST_ADMIN_USERNAME, "password": TEST_ADMIN_PASSWORD}
    )
    assert ok.status_code == 200
    _assert_stamped(ok, instance_id)
    refused = app_client.post(
        "/auth/login", json={"username": TEST_ADMIN_USERNAME, "password": "wrong-password-x"}
    )
    assert refused.status_code == 401
    _assert_stamped(refused, instance_id)
    register = app_client.post("/auth/register", json={"username": "sam", "password": "x"})
    assert register.status_code >= 400  # signup off by default, or a weak password
    _assert_stamped(register, instance_id)


# ── refusals from the middleware itself ────────────────────────────────────

def test_auth_refusals_are_stamped(app_client):
    instance_id = _instance_id(app_client)
    app_client.headers.pop("Authorization")

    missing = app_client.get("/tracks")
    assert missing.status_code == 401
    _assert_stamped(missing, instance_id)

    bad = app_client.get("/tracks", headers={"Authorization": "Bearer not-a-real-token"})
    assert bad.status_code == 401
    _assert_stamped(bad, instance_id)

    malformed = app_client.get("/tracks", headers={"Authorization": "Basic abc"})
    assert malformed.status_code == 401
    _assert_stamped(malformed, instance_id)

    media = app_client.get(f"/tracks/{UNKNOWN}/stream", params={"access_token": "nope"})
    assert media.status_code == 401
    _assert_stamped(media, instance_id)


# ── authenticated answers of every kind ────────────────────────────────────

def test_authenticated_answers_are_stamped(app_client):
    instance_id = _instance_id(app_client)
    track = _add_track(app_client)

    cases = [
        (app_client.get("/tracks"), 200),
        (app_client.get(f"/tracks/{track}"), 200),
        (app_client.get(f"/tracks/{UNKNOWN}"), 404),           # handler 404
        (app_client.get("/tracks/nope"), 404),                  # router 404
        (app_client.get("/no-such-prefix"), 404),
        (app_client.get("/tracks/warm"), 405),                  # router 405
        (app_client.options("/tracks"), 405),
        (app_client.patch(f"/tracks/{track}", json={"bogus": 1}), 422),
        (app_client.get("/tracks/", follow_redirects=False), 307),  # slash redirect
    ]
    for response, status in cases:
        assert response.status_code == status, (status, response.text)
        _assert_stamped(response, instance_id)


def test_streamed_bodies_are_stamped(app_client):
    instance_id = _instance_id(app_client)
    track = _add_track(app_client)
    media_token = log_in(app_client)["media_token"]

    with_header = app_client.get(f"/tracks/{track}/stream", params={"quality": "original"})
    assert with_header.status_code == 200
    assert with_header.content == b"not really flac"
    _assert_stamped(with_header, instance_id)

    app_client.headers.pop("Authorization")
    with_media_token = app_client.get(
        f"/tracks/{track}/stream", params={"quality": "original", "access_token": media_token}
    )
    assert with_media_token.status_code == 200
    _assert_stamped(with_media_token, instance_id)

    ranged = app_client.get(
        f"/tracks/{track}/stream",
        params={"quality": "original", "access_token": media_token},
        headers={"Range": "bytes=0-3"},
    )
    assert ranged.status_code == 206
    _assert_stamped(ranged, instance_id)


# ── unhandled errors ───────────────────────────────────────────────────────

def _add_boom_route(app):
    @app.get("/boom")
    def boom():
        raise RuntimeError("kaboom")


def test_an_unhandled_error_500_is_stamped(app_client):
    instance_id = _instance_id(app_client)
    _add_boom_route(app_client.app)
    token = app_client.headers["Authorization"]

    # No ``with``: the app is already started, a second lifespan would refuse.
    client = TestClient(app_client.app, raise_server_exceptions=False)
    response = client.get("/boom", headers={"Authorization": token})

    assert response.status_code == 500
    assert response.text == "Internal Server Error"  # nothing about the error leaks
    _assert_stamped(response, instance_id)


def test_an_unhandled_error_still_reaches_the_server_error_path(app_client):
    # The stamp must not swallow the exception: the server still logs it.
    _add_boom_route(app_client.app)

    with pytest.raises(RuntimeError, match="kaboom"):
        app_client.get("/boom")


# ── the id is cached, never read per request ───────────────────────────────

def test_the_stamp_is_read_once_at_startup(app_client, monkeypatch):
    instance_id = _instance_id(app_client)

    def unavailable():
        raise AssertionError("the stamp must not read SQLite per request")

    monkeypatch.setattr(app_client.app.state.database, "get_server_instance_id", unavailable)

    response = app_client.get("/tracks")
    assert response.status_code == 200
    _assert_stamped(response, instance_id)
    app_client.headers.pop("Authorization")
    _assert_stamped(app_client.get("/"), instance_id)


def test_the_stamp_survives_a_restart_unchanged(open_app_client):
    with open_app_client() as client:
        first = client.get("/").headers[HEADER]

    # Same data dir (configure_app reuses tmp_path): the persisted id is kept.
    with open_app_client() as client:
        assert client.get("/").headers[HEADER] == first
