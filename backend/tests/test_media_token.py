"""Phase M.1b (M-U12, spec §5.3, SC-27 Phase M): the media token.

``?access_token=<media token>`` authenticates **only** a GET of a media route
(``GET /tracks/{uuid}/stream`` and, from 7A.2c, ``GET
/tracks/uploads/items/{uuid}/preview``). It is refused on every other route and
with every other method, an API token is not accepted in its place, and it is
revoked with its session.
"""

import pytest
from fastapi.routing import APIRoute

from app.auth.sessions import hash_token, revoke_session_hash
from app.library import Library
from app.models import Track, TrackMetaData
from tests.conftest import log_in
from tests.owned_database import add_test_user

OTHER_METHODS = ["POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]


def _track(source, title):
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"not really flac")
    return Track(
        file_path=source,
        metadata=TrackMetaData(
            title=title, artist="Radiohead", album="OK Computer", codec="flac",
            duration=1.0, bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
            track_number=1, disc_number=1,
        ),
    )


@pytest.fixture
def media(app_client, tmp_path):
    """The admin's tokens and own track, on a client that sends no header."""
    tokens = log_in(app_client)
    app_client.headers.pop("Authorization")
    track = _track(tmp_path / "music" / "admin" / "Airbag.flac", "Airbag")
    assert app_client.app.state.admin_library.add_track(track)
    return app_client, tokens, track


def _stream(client, uuid_id, token, method="GET"):
    return client.request(
        method,
        f"/tracks/{uuid_id}/stream",
        params={"quality": "original", "access_token": token},
    )


def _concrete(path: str) -> str:
    return (
        path.replace("{uuid_id}", "00000000-0000-4000-8000-000000000000")
        .replace("{cover_art_id}", "1")
        .replace("{job_id}", "1")
    )


def test_the_media_token_streams_the_callers_track(media):
    client, tokens, track = media

    response = _stream(client, track.uuid_id, tokens["media_token"])

    assert response.status_code == 200
    assert response.content == b"not really flac"


def test_the_media_token_authenticates_as_its_user(media, tmp_path):
    client, tokens, _ = media
    db = client.app.state.database
    theirs = _track(tmp_path / "music" / "sam" / "Lucky.flac", "Lucky")
    assert Library(db, add_test_user(db, "sam")).add_track(theirs)

    # Authenticated (not 401), and as the admin: another user's track is absent.
    assert _stream(client, theirs.uuid_id, tokens["media_token"]).status_code == 404


PUBLIC = {"/", "/app/info", "/auth/login", "/auth/register"}
MEDIA_ROUTES = {"stream_track", "preview_upload_item"}


def test_the_media_routes_are_exactly_the_stream_and_the_upload_preview():
    from app.auth.middleware import MEDIA_ROUTE_NAMES

    assert MEDIA_ROUTE_NAMES == MEDIA_ROUTES


def test_every_other_route_and_method_refuses_the_media_token(media):
    client, tokens, track = media
    routes = [r for r in client.app.routes if getattr(r, "methods", None)]
    assert any(r.name == "stream_track" for r in routes)
    probes = []
    for route in routes:
        if route.path in PUBLIC:
            continue
        path = _concrete(route.path).replace(
            "00000000-0000-4000-8000-000000000000", track.uuid_id
        )
        # Media routes (7A.2c adds the upload preview): only their other methods.
        methods = OTHER_METHODS if route.name in MEDIA_ROUTES else sorted(route.methods)
        probes += [(method, path) for method in methods]
    assert len(probes) > 20

    accepted = {
        (method, path): status
        for method, path in probes
        if (status := client.request(
            method, path, params={"access_token": tokens["media_token"]}
        ).status_code) != 401
    }

    assert accepted == {}


def test_the_api_token_is_not_accepted_as_a_media_token(media):
    client, tokens, track = media

    response = _stream(client, track.uuid_id, tokens["token"])

    assert response.status_code == 401
    assert response.json()["detail"]["error"] == "invalid_token"


@pytest.mark.parametrize("token", ["", "nope", "x" * 43])
def test_an_unknown_media_token_is_invalid(media, token):
    client, _, track = media

    response = _stream(client, track.uuid_id, token)

    assert response.status_code == 401
    assert response.json()["detail"]["error"] == "invalid_token"


def test_the_media_token_is_revoked_with_its_session(media):
    client, tokens, track = media
    assert _stream(client, track.uuid_id, tokens["media_token"]).status_code == 200

    revoke_session_hash(client.app.state.database, hash_token(tokens["token"]))

    response = _stream(client, track.uuid_id, tokens["media_token"])
    assert response.status_code == 401
    assert response.json()["detail"]["error"] == "invalid_token"


def test_the_stream_without_any_token_is_auth_required(media):
    client, _, track = media

    response = client.get(f"/tracks/{track.uuid_id}/stream", params={"quality": "original"})

    assert response.status_code == 401
    assert response.json()["detail"]["error"] == "auth_required"


def test_the_media_route_is_found_by_route_not_by_a_path_prefix(media):
    client, tokens, track = media

    # A path that merely starts or ends like the stream route is not a media route.
    for path in (
        f"/tracks/{track.uuid_id}/stream/",
        f"/tracks/{track.uuid_id}/stream/x",
        f"/x/tracks/{track.uuid_id}/stream",
        f"/tracks/{track.uuid_id}/streamx",
    ):
        response = client.get(path, params={"access_token": tokens["media_token"]})
        assert response.status_code == 401, path
