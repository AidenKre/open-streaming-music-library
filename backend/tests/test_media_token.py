"""Phase M.1b (M-U12, spec §5.3, SC-27 Phase M): the media token.

``?access_token=<media token>`` authenticates **only** a GET of a media route
(``GET /tracks/{uuid}/stream`` and, from 7A.2c, ``GET
/tracks/uploads/items/{uuid}/preview``). It is refused on every other route and
with every other method, an API token is not accepted in its place, and it is
revoked with its session.
"""

import re

import pytest

from app.auth.sessions import hash_token, revoke_session_hash
from app.library import Library
from tests.auth_helpers import flac_track
from tests.conftest import log_in
from tests.owned_database import add_test_user

OTHER_METHODS = ["POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]


@pytest.fixture
def media(app_client, tmp_path):
    """The admin's tokens and own track, on a client that sends no header."""
    tokens = log_in(app_client)
    app_client.headers.pop("Authorization")
    track = flac_track(tmp_path / "music" / "admin" / "Airbag.flac", "Airbag")
    assert app_client.app.state.admin_library.add_track(track)
    return app_client, tokens, track


def _stream(client, uuid_id, token, method="GET"):
    return client.request(
        method,
        f"/tracks/{uuid_id}/stream",
        params={"quality": "original", "access_token": token},
    )


ANY_UUID = "00000000-0000-4000-8000-000000000000"


def _concrete(path: str, uuid_value: str = ANY_UUID) -> str:
    """The route path with every ``{name}`` or ``{name:convertor}`` filled in:
    a uuid for a ``uuid`` convertor or a name ending in ``uuid``/``uuid_id``,
    otherwise ``1``."""

    def value(match):
        name, convertor = match.group(1), match.group(2)
        return uuid_value if convertor == "uuid" or name.endswith(("uuid", "uuid_id")) else "1"

    return re.sub(r"\{(\w+)(?::(\w+))?\}", value, path)


def test_the_media_token_streams_the_callers_track(media):
    client, tokens, track = media

    response = _stream(client, track.uuid_id, tokens["media_token"])

    assert response.status_code == 200
    assert response.content == b"not really flac"


def test_the_media_token_authenticates_as_its_user(media, tmp_path):
    client, tokens, _ = media
    db = client.app.state.database
    theirs = flac_track(tmp_path / "music" / "sam" / "Lucky.flac", "Lucky")
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
        path = _concrete(route.path, track.uuid_id)
        # U02-B-01: every probe reaches the route it was made for, so the
        # refusal it sees comes from the token rule, not from a missing route.
        assert route.path_regex.match(path), (route.path, path)
        # Media routes (7A.2c adds the upload preview): only their other methods.
        methods = OTHER_METHODS if route.name in MEDIA_ROUTES else sorted(route.methods)
        probes += [(method, path) for method in methods]
    assert len(probes) > 20
    assert {p for _, p in probes} >= {f"/tracks/{track.uuid_id}/stream",
                                       f"/tracks/uploads/items/{track.uuid_id}/preview"}

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
