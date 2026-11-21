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
        path = _concrete(route)
        # The probe reaches the route it was made for, so its 401 comes from
        # the token rule and not from a path no route serves.
        assert route.path_regex.match(path), (route.path, path)
        for method in sorted(methods):
            probes.append((method, route.path, path))
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


# ── A signed-in caller's oversized body is refused while it is read ───

_CHUNK = b"x" * (64 << 10)
_CHUNKS = 128  # 8 MiB in all, far beyond every body cap
_READ_AT_MOST = 1 << 20  # every cap is 256 KiB or less


def _chunked_call(app, method, path, headers):
    """Drive the ASGI app with the body in 64 KiB chunks and count the chunks
    the server pulls."""
    receives, sent = [], []

    async def receive():
        receives.append(1)
        if len(receives) > _CHUNKS:
            return {"type": "http.disconnect"}
        return {"type": "http.request", "body": _CHUNK, "more_body": len(receives) < _CHUNKS}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
        "method": method, "scheme": "http", "path": path, "raw_path": path.encode(),
        "root_path": "", "query_string": b"",
        "headers": [
            (b"content-length", str(len(_CHUNK) * _CHUNKS).encode()),
            (b"content-type", b"application/json"),
            *headers,
        ],
        "client": ("127.0.0.1", 5000), "server": ("testserver", 80), "state": {},
    }
    asyncio.run(app(scope, receive, send))
    return len(receives) * len(_CHUNK), sent[0]["status"]


def test_an_oversized_body_from_a_signed_in_caller_is_refused_while_it_is_read(open_app_client):
    # The deletion switch is on, so the deletion routes reach their body too.
    with open_app_client(env={"LIBRARY_DELETE_ENABLED": "true"}) as client:
        auth = [(b"authorization", client.headers["Authorization"].encode())]
        probes = sorted(
            (p for p in _probes(client.app) if p[1] not in PUBLIC_PATHS),
            key=lambda p: p[1] == "/auth/logout",  # logout ends the session: last
        )
        refused, wrong = set(), {}
        for method, template, path in probes:
            read, status = _chunked_call(client.app, method, path, auth)
            assert status != 401, (method, template)  # the probe stayed signed in
            if read == 0:
                continue  # the route never reads a body
            if status == 413 and read <= _READ_AT_MOST:
                refused.add((method, template))
            else:
                wrong[(method, template)] = (read, status)

    assert wrong == {}
    # Every route that takes a JSON body was reached and refused, not skipped.
    assert _json_body_routes(client.app) <= refused
    assert {
        ("POST", "/tracks/warm"),
        ("PUT", "/settings/quality"),
        ("PATCH", "/tracks/{uuid_id:uuid}"),
        ("POST", "/jobs"),
    } <= refused


def _json_body_routes(app):
    """(method, path) of every route whose dependencies include ``json_body``."""

    def takes_json_body(dependant):
        return any(
            getattr(d.call, "__qualname__", "").startswith("json_body.")
            or takes_json_body(d)
            for d in dependant.dependencies
        )

    routes = {
        (method, route.path)
        for route in app.routes
        if hasattr(route, "dependant") and takes_json_body(route.dependant)
        for method in route.methods
    }
    assert len(routes) >= 19  # the four routes that moved out of main.py and the fifteen others
    return routes - {(m, p) for m, p in routes if p in PUBLIC_PATHS}


_SECRET = "SECRET-INPUT-NOT-ECHOED"


@pytest.mark.parametrize(
    "method, path, body",
    [
        ("POST", "/tracks/warm", {"current_index": _SECRET, "quality": "high", "track_uuids": []}),
        ("PUT", "/settings/quality", {"quality": {_SECRET: 1}}),
        ("PATCH", f"/tracks/{SAMPLE_ID}", {"base_revision": _SECRET}),
        (
            "POST",
            "/jobs",
            {"type": "conversion", "uuid_id": SAMPLE_ID,
             "params": {"target_codec": {_SECRET: 1}}, "base_revision": _SECRET},
        ),
    ],
    ids=["warm", "quality", "patch-track", "jobs"],
)
def test_a_body_of_the_wrong_type_is_a_422_that_does_not_repeat_the_input(
    app_client, method, path, body
):
    response = app_client.request(method, path, json=body)

    assert response.status_code == 422
    items = response.json()["detail"]
    assert isinstance(items, list) and items
    for item in items:
        assert "input" not in item
        assert item["loc"][0] == "body"
    assert _SECRET not in response.text
