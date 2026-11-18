"""Phase M.1b (M-U12, spec §5.3): the auth boundary middleware, on a toy app.

``AuthMiddleware`` is a pure ASGI middleware: ``lifespan`` passes through; an
HTTP request to an exact public path passes; any other request needs
``Authorization: Bearer <api token>`` and otherwise gets a 401 in the SC-22
envelope (``auth_required`` without credentials, ``invalid_token`` with bad
ones) before the request body is read. A valid token puts an immutable
``Principal`` in ``scope["state"]``.

The real app's wiring (outermost, every route) is tested in
``test_route_enumeration.py``; this file pins the middleware's own behavior.
"""

import asyncio
import contextlib
import hashlib
import sqlite3

import pytest
from fastapi import Depends, FastAPI, Request
from fastapi.testclient import TestClient

from app.auth.middleware import PUBLIC_PATHS, AuthMiddleware
from app.auth.principal import Principal, current_principal
from app.auth.sessions import hash_token, revoke_session_hash
from app.database.database import Database, DatabaseContext
from tests.auth_helpers import create_session
from tests.owned_database import add_test_user
from tests.schema_fixtures import INIT_SQL


@pytest.fixture
def db(tmp_path):
    database = Database(
        DatabaseContext(database_path=tmp_path / "database.db", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    return database


def _sql(db, statement, params=()):
    conn = sqlite3.connect(db.context.database_path)
    try:
        conn.execute(statement, params)
        conn.commit()
    finally:
        conn.close()


class _Toy:
    """A FastAPI app behind the middleware that records what reached it."""

    def __init__(self, db):
        self.reached = []
        self.lifespan_events = []

        @contextlib.asynccontextmanager
        async def lifespan(_app):
            self.lifespan_events.append("startup")
            yield
            self.lifespan_events.append("shutdown")

        app = FastAPI(lifespan=lifespan)
        app.state.database = db

        def public(request: Request):
            self.reached.append(request.url.path)
            return {"public": True}

        for path in ("/", "/app/info", "/auth/login", "/auth/register"):
            app.add_api_route(path, public, methods=["GET", "POST"])
        # Look-alikes of public paths, so a 401 proves the middleware refused
        # them (without these routes a 404 would be ambiguous).
        for path in ("/app/info/", "/APP/info", "/auth/login/x", "/app", "/auth", "/appinfo"):
            app.add_api_route(path, public, methods=["GET", "POST"])

        @app.api_route("/private", methods=["GET", "POST"])
        def private(request: Request, principal: Principal = Depends(current_principal)):
            self.reached.append(request.url.path)
            return {
                "user_id": principal.user_id,
                "is_admin": principal.is_admin,
                "is_master_admin": principal.is_master_admin,
                "session_hash": principal.session_hash,
            }

        app.add_middleware(AuthMiddleware)
        self.app = app


@pytest.fixture
def toy(db):
    return _Toy(db)


@pytest.fixture
def client(toy):
    with TestClient(toy.app) as c:
        yield c


def _assert_401(response, code):
    assert response.status_code == 401
    assert response.json() == {
        "detail": {"error": code, "message": response.json()["detail"]["message"], "retryable": False}
    }
    assert response.json()["detail"]["message"]
    assert response.headers["www-authenticate"] == "Bearer"


# ── public paths ────────────────────────────────────────────────────────────

def test_the_public_allow_list_is_exactly_the_four_spec_paths():
    assert PUBLIC_PATHS == frozenset({"/", "/app/info", "/auth/login", "/auth/register"})


@pytest.mark.parametrize("path", ["/", "/app/info", "/auth/login", "/auth/register"])
@pytest.mark.parametrize("method", ["GET", "POST"])
def test_public_paths_pass_without_a_token(client, toy, path, method):
    response = client.request(method, path)

    assert response.status_code == 200
    assert toy.reached == [path]


def test_a_public_path_passes_even_with_a_bad_token(client, toy):
    response = client.get("/app/info", headers={"Authorization": "Bearer nope"})

    assert response.status_code == 200


@pytest.mark.parametrize(
    "path", ["/app/info/", "/APP/info", "/auth/login/x", "/app", "/auth", "/appinfo"]
)
def test_look_alikes_of_public_paths_are_not_public(client, toy, path):
    _assert_401(client.get(path), "auth_required")
    assert toy.reached == []


# ── credentials ─────────────────────────────────────────────────────────────

def test_no_credentials_is_auth_required_and_never_reaches_the_app(client, toy):
    _assert_401(client.get("/private"), "auth_required")
    _assert_401(client.post("/private", content=b"{}"), "auth_required")
    assert toy.reached == []


@pytest.mark.parametrize(
    "header",
    [
        "Bearer unknown-token",
        "Bearer ",
        "Bearer",
        "Basic dXNlcjpwYXNz",
        "Token abc",
        "unknown-token",
    ],
)
def test_a_bad_authorization_header_is_invalid_token(client, toy, header):
    _assert_401(client.get("/private", headers={"Authorization": header}), "invalid_token")
    assert toy.reached == []


def test_a_valid_api_token_reaches_the_handler_with_its_principal(client, toy, db):
    user_id = add_test_user(db, "sam")
    _sql(db, "UPDATE users SET is_admin = 1 WHERE id = ?", (user_id,))
    tokens = create_session(db, user_id)

    response = client.get("/private", headers={"Authorization": f"Bearer {tokens.token}"})

    assert response.status_code == 200
    assert response.json() == {
        "user_id": user_id,
        "is_admin": True,
        "is_master_admin": False,
        "session_hash": hashlib.sha256(tokens.token.encode()).hexdigest(),
    }
    assert toy.reached == ["/private"]


def test_the_media_token_is_not_accepted_as_a_bearer_token(client, toy, db):
    tokens = create_session(db, add_test_user(db, "sam"))

    response = client.get("/private", headers={"Authorization": f"Bearer {tokens.media_token}"})

    _assert_401(response, "invalid_token")


def test_a_revoked_token_is_invalid_on_the_next_request(client, db):
    tokens = create_session(db, add_test_user(db, "sam"))
    headers = {"Authorization": f"Bearer {tokens.token}"}
    assert client.get("/private", headers=headers).status_code == 200

    revoke_session_hash(db, hash_token(tokens.token))

    _assert_401(client.get("/private", headers=headers), "invalid_token")


def test_each_request_gets_its_own_principal(client, db):
    sam, alex = add_test_user(db, "sam"), add_test_user(db, "alex")
    sams, alexs = create_session(db, sam), create_session(db, alex)

    first = client.get("/private", headers={"Authorization": f"Bearer {sams.token}"})
    second = client.get("/private", headers={"Authorization": f"Bearer {alexs.token}"})

    assert (first.json()["user_id"], second.json()["user_id"]) == (sam, alex)


# ── the body is never read before the decision ──────────────────────────────

def _call(app, scope_overrides, body=b"x" * (1 << 20)):
    """Drive the ASGI app directly and record every ``receive`` call."""
    receives = []
    sent = []

    async def receive():
        receives.append(1)
        return {"type": "http.request", "body": body, "more_body": False}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": "/private",
        "raw_path": b"/private",
        "root_path": "",
        "query_string": b"",
        "headers": [(b"content-length", str(len(body)).encode())],
        "client": ("127.0.0.1", 5000),
        "server": ("testserver", 80),
        "state": {},
    }
    scope.update(scope_overrides)
    asyncio.run(app(scope, receive, send))
    return receives, sent


def test_an_oversized_body_without_a_token_is_refused_before_it_is_read(toy):
    receives, sent = _call(toy.app, {})

    assert receives == []
    assert sent[0]["type"] == "http.response.start"
    assert sent[0]["status"] == 401
    assert toy.reached == []


def test_an_oversized_body_with_a_bad_token_is_refused_before_it_is_read(toy):
    receives, sent = _call(
        toy.app,
        {"headers": [(b"authorization", b"Bearer nope"), (b"content-length", b"1048576")]},
    )

    assert receives == []
    assert sent[0]["status"] == 401


# ── lifespan ────────────────────────────────────────────────────────────────

def test_lifespan_passes_through_untouched(toy):
    with TestClient(toy.app):
        assert toy.lifespan_events == ["startup"]
    assert toy.lifespan_events == ["startup", "shutdown"]


# ── WebSocket scopes take the same path (spec §5.3 "Other scopes") ──────────

def _ws_app(db, reached):
    from fastapi import WebSocket

    app = FastAPI()
    app.state.database = db

    @app.websocket("/ws")
    async def ws(websocket: WebSocket):
        reached.append("/ws")
        await websocket.accept()
        principal = websocket.scope["state"]["principal"]
        await websocket.send_json({"user_id": principal.user_id})
        await websocket.close()

    @app.websocket("/app/info")
    async def ws_public(websocket: WebSocket):
        reached.append("/app/info")
        await websocket.accept()
        await websocket.send_json({"public": True})
        await websocket.close()

    app.add_middleware(AuthMiddleware)
    return app


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer nope"}])
def test_a_websocket_without_a_valid_token_is_closed_before_accept(db, headers):
    from starlette.websockets import WebSocketDisconnect

    reached = []
    with TestClient(_ws_app(db, reached)) as client:
        with pytest.raises(WebSocketDisconnect) as caught:
            with client.websocket_connect("/ws", headers=headers):
                pass

    assert caught.value.code == 1008
    assert reached == []


def test_a_websocket_with_a_valid_token_gets_its_principal(db):
    user_id = add_test_user(db, "sam")
    tokens = create_session(db, user_id)
    reached = []
    with TestClient(_ws_app(db, reached)) as client:
        with client.websocket_connect(
            "/ws", headers={"Authorization": f"Bearer {tokens.token}"}
        ) as ws:
            assert ws.receive_json() == {"user_id": user_id}

    assert reached == ["/ws"]


def test_a_websocket_on_a_public_path_passes(db):
    reached = []
    with TestClient(_ws_app(db, reached)) as client:
        with client.websocket_connect("/app/info") as ws:
            assert ws.receive_json() == {"public": True}


def test_a_websocket_never_accepts_the_media_token(db):
    from starlette.websockets import WebSocketDisconnect

    tokens = create_session(db, add_test_user(db, "sam"))
    reached = []
    with TestClient(_ws_app(db, reached)) as client:
        with pytest.raises(WebSocketDisconnect):
            with client.websocket_connect(f"/ws?access_token={tokens.media_token}"):
                pass
    assert reached == []


# ── review r1 ───────────────────────────────────────────────────────────────

@pytest.mark.parametrize("path", ["/api/app/info", "/api/", "/api/auth/login"])
def test_public_paths_are_matched_under_a_root_path(toy, path):
    # uvicorn --root-path /api puts the prefix in scope["path"]; the router
    # strips it, so the allow-list must compare the route path too (review #2).
    receives, sent = _call(
        toy.app, {"method": "GET", "root_path": "/api", "path": path, "raw_path": path.encode()},
        body=b"",
    )

    assert sent[0]["status"] == 200


@pytest.mark.parametrize("path", ["/api/private", "/api/app/info/", "/app/info/x"])
def test_a_root_path_does_not_widen_the_allow_list(toy, path):
    receives, sent = _call(
        toy.app, {"method": "GET", "root_path": "/api", "path": path, "raw_path": path.encode()},
        body=b"",
    )

    assert sent[0]["status"] == 401
    assert receives == []


def test_the_media_token_follows_the_route_the_router_would_serve(db):
    # Two routes match the same path; the router serves the first. The media
    # token must count only when that first match is a media route (review #6).
    tokens = create_session(db, add_test_user(db, "sam"))
    app = FastAPI()
    app.state.database = db

    @app.get("/tracks/{uuid_id}/stream", name="shadow")
    def shadow(uuid_id: str):
        return {"served": "shadow"}

    @app.get("/tracks/{uuid_id}/stream", name="stream_track")
    def stream_track(uuid_id: str):
        return {"served": "stream"}

    app.add_middleware(AuthMiddleware)
    with TestClient(app) as client:
        response = client.get("/tracks/x/stream", params={"access_token": tokens.media_token})

    assert response.status_code == 401
