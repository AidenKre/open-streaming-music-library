"""Phase M.1b (M-U12, SC-18, spec §5.4 "Route enumeration"): every route in
``app.routes`` is either on the exact public allow-list or answers 401 without
a valid token — every method, the FastAPI docs routes included, and an
oversized body is refused before the body is read.

The routes are derived from ``app.routes`` (never a hand list), so a route a
later phase adds is covered automatically.
"""

import asyncio
import re

import pytest

from app.auth.middleware import PUBLIC_PATHS

SAMPLE_ID = "00000000-0000-4000-8000-000000000000"


def _concrete(route) -> str:
    """The route's path with every parameter filled by a well-formed sample;
    the middleware answers before any parameter is validated."""
    return re.sub(r"\{[^}]+\}", SAMPLE_ID, route.path)


def _probes(app):
    probes = []
    for route in app.routes:
        methods = getattr(route, "methods", None)
        assert methods, f"route without methods: {route!r}"  # no Mounts/WebSockets yet
        for method in sorted(methods):
            probes.append((method, route.path, _concrete(route)))
    return probes


def test_the_enumeration_sees_every_route(app_client):
    paths = {template for _, template, _ in _probes(app_client.app)}

    assert {"/tracks", "/tracks/{uuid_id:uuid}/stream", "/history", "/auth/logout", "/docs"} <= paths
    assert len(paths) >= 20
    # 9D.1d: the Last.fm routes are enumerated like every other route.
    assert {"/settings/integrations/lastfm", "/settings/integrations/lastfm/connect",
            "/settings/integrations/lastfm/complete"} <= paths
    # 9D.2a: the opt-in route too.
    assert "/settings/integrations/lastfm/enable" in paths
    # 9D.2c: Now Playing.
    assert "/settings/integrations/lastfm/now-playing" in paths


def test_every_route_is_public_or_refused_without_a_token(app_client):
    app_client.headers.pop("Authorization")
    wrong = {}
    for method, template, path in _probes(app_client.app):
        response = app_client.request(method, path)
        if template in PUBLIC_PATHS:
            if response.status_code == 401:
                wrong[(method, template)] = "public route refused"
        elif _refusal(response, method) != _expected(method, "auth_required"):
            wrong[(method, template)] = response.status_code

    assert wrong == {}


def test_every_non_public_route_refuses_a_bad_token(app_client):
    wrong = {}
    for method, template, path in _probes(app_client.app):
        if template in PUBLIC_PATHS:
            continue
        response = app_client.request(method, path, headers={"Authorization": "Bearer nope"})
        if _refusal(response, method) != _expected(method, "invalid_token"):
            wrong[(method, template)] = response.status_code

    assert wrong == {}


def test_only_the_four_spec_paths_are_public(app_client):
    app_client.headers.pop("Authorization")
    public = {
        template for method, template, path in _probes(app_client.app)
        if app_client.request(method, path).status_code != 401
    }

    assert public == {"/", "/app/info", "/auth/login", "/auth/register"}


@pytest.mark.parametrize(
    "path",
    [
        "/app/info/",
        "/auth/login/x",
        "/APP/info",
        "/App/Info",
        "/auth/register/",
        "/auth/LOGIN",
        "/app/info/..",
        "/app",
        "/auth",
        "/no/such/route",
    ],
)
@pytest.mark.parametrize("method", ["GET", "POST"])
def test_look_alikes_of_public_paths_are_not_public(app_client, path, method):
    app_client.headers.pop("Authorization")

    response = app_client.request(method, path)

    assert (response.status_code, _code(response)) == (401, "auth_required")


def _refusal(response, method):
    # A HEAD response has no body; its code is covered by the GET probe.
    return response.status_code, (None if method == "HEAD" else _code(response))


def _expected(method, code):
    return 401, (None if method == "HEAD" else code)


def _code(response):
    try:
        return response.json()["detail"]["error"]
    except Exception:
        return None


# ── an oversized body is refused before it is read ──────────────────────────

def _call(app, method, path, headers):
    receives, sent = [], []
    body = b"x" * (8 << 20)  # far beyond every bounded_body cap

    async def receive():
        receives.append(1)
        return {"type": "http.request", "body": body, "more_body": False}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
        "method": method, "scheme": "http", "path": path, "raw_path": path.encode(),
        "root_path": "", "query_string": b"",
        "headers": [(b"content-length", str(len(body)).encode()), *headers],
        "client": ("127.0.0.1", 5000), "server": ("testserver", 80), "state": {},
    }
    asyncio.run(app(scope, receive, send))
    return receives, sent


@pytest.mark.parametrize("headers", [[], [(b"authorization", b"Bearer nope")]], ids=["none", "bad"])
def test_an_oversized_body_on_any_route_is_refused_before_it_is_read(app_client, headers):
    read = {}
    for method, template, path in _probes(app_client.app):
        if template in PUBLIC_PATHS:
            continue
        receives, sent = _call(app_client.app, method, path, headers)
        if receives or sent[0]["status"] != 401:
            read[(method, template)] = (len(receives), sent[0]["status"])

    assert read == {}
