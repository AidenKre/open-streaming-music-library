"""SC-16b: one shared ``bounded_body(max_bytes)`` dependency that enforces
the byte cap WHILE streaming (independent of Content-Length: absent, or
false/too small), refuses with 413 without echoing input, and the one 422
helper that maps a Pydantic ``ValidationError`` without ``input`` values."""

import asyncio
import json
import logging

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient
from pydantic import BaseModel, ConfigDict, ValidationError

from app.auth.principal import auth_error
from app.core.bounded_body import bounded_body, validation_error_422
from app.library import current_library

CAP = 16
SECRET = b"SECRET-PAYLOAD-SHOULD-NOT-ECHO"


def _app():
    app = FastAPI()

    @app.post("/echo-len")
    async def echo_len(raw: bytes = Depends(bounded_body(CAP))):
        return {"length": len(raw)}

    return app


def _asgi_post(app, chunks, headers):
    """Drive the ASGI app directly so the test controls Content-Length and
    the chunking exactly (httpx would correct a false Content-Length)."""
    sent = []
    messages = [
        {"type": "http.request", "body": c, "more_body": i < len(chunks) - 1}
        for i, c in enumerate(chunks)
    ] or [{"type": "http.request", "body": b"", "more_body": False}]
    received = []

    async def receive():
        if messages:
            msg = messages.pop(0)
            received.append(len(msg["body"]))
            return msg
        return {"type": "http.disconnect"}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": "/echo-len",
        "raw_path": b"/echo-len",
        "query_string": b"",
        "root_path": "",
        "headers": [(k.lower().encode(), v.encode()) for k, v in headers],
        "client": ("127.0.0.1", 1),
        "server": ("testserver", 80),
    }
    asyncio.run(app(scope, receive, send))
    status = next(m["status"] for m in sent if m["type"] == "http.response.start")
    body = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
    return status, body, received


def test_body_within_the_cap_is_returned():
    client = TestClient(_app())
    res = client.post("/echo-len", content=b"x" * CAP)
    assert res.status_code == 200
    assert res.json() == {"length": CAP}


def test_over_the_cap_is_413_without_echo():
    client = TestClient(_app())
    res = client.post("/echo-len", content=SECRET)
    assert res.status_code == 413
    assert SECRET not in res.content
    detail = res.json()["detail"]
    assert detail["error"] == "request_too_large"
    assert detail["retryable"] is False


def test_absent_content_length_is_still_capped():
    status, body, _ = _asgi_post(_app(), [b"x" * 10, b"x" * 10], headers=[])
    assert status == 413
    assert b"xxxxxxxx" not in body


def test_false_small_content_length_is_still_capped():
    status, _, _ = _asgi_post(
        _app(), [b"x" * 10, b"x" * 10], headers=[("Content-Length", "4")]
    )
    assert status == 413


def test_reading_stops_once_over_the_cap():
    """The cap is enforced while streaming: chunks after the cap is passed are
    never pulled from the client."""
    chunks = [b"x" * 10, b"x" * 10, b"y" * 1000, b"z" * 1000]
    status, _, received = _asgi_post(_app(), chunks, headers=[])
    assert status == 413
    assert sum(received) <= 20


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str
    count: int


def test_validation_error_maps_to_422_without_input():
    with pytest.raises(ValidationError) as caught:
        _Strict.model_validate_json(json.dumps({"name": SECRET.decode(), "count": "x", "extra": SECRET.decode()}))
    exc = validation_error_422(caught.value)
    assert exc.status_code == 422
    assert isinstance(exc.detail, list) and exc.detail
    for item in exc.detail:
        assert "input" not in item
        assert {"type", "loc", "msg"} <= set(item)
    assert SECRET.decode() not in json.dumps(exc.detail)


# ── Phase 7 live gate 7-L-01: a client that goes away while the body is read ──

def _disconnecting_post(app, first_chunks):
    """Drive the ASGI app; after ``first_chunks`` the client disconnects."""
    messages = [{"type": "http.request", "body": c, "more_body": True} for c in first_chunks]
    sent = []

    async def receive():
        if messages:
            return messages.pop(0)
        return {"type": "http.disconnect"}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "POST",
        "scheme": "http", "path": "/write", "raw_path": b"/write", "query_string": b"",
        "root_path": "", "headers": [], "client": ("127.0.0.1", 1), "server": ("testserver", 80),
    }
    asyncio.run(app(scope, receive, send))  # an unhandled exception would raise here
    return sent


@pytest.mark.parametrize("first_chunks", [[], [b"x" * 4]], ids=["before-any-byte", "mid-body"])
def test_a_client_disconnect_while_the_body_is_read_ends_the_request_quietly(first_chunks, caplog):
    writes = []
    app = FastAPI()

    @app.post("/write")
    async def write(raw: bytes = Depends(bounded_body(CAP))):
        writes.append(raw)  # the route's effect: never reached
        return {"ok": True}

    with caplog.at_level(logging.DEBUG):
        sent = _disconnecting_post(app, first_chunks)

    assert writes == []
    # 499 "client closed request": never seen by anyone (the server drops sends
    # after a disconnect); it only ends the request without an error.
    starts = [m for m in sent if m["type"] == "http.response.start"]
    assert [m["status"] for m in starts] == [499]
    assert not [r for r in caplog.records if r.levelno >= logging.WARNING]
    assert not [r for r in caplog.records if r.exc_info]
    # Live gate 7-L-02: one INFO line an operator sees at the default level.
    operator = [r for r in caplog.records if r.name == "uvicorn.error"]
    assert [r.levelno for r in operator] == [logging.INFO]
    assert "client went away" in operator[0].getMessage()
    assert "/" not in operator[0].getMessage()


# ── the four routes that moved out of main.py and take their body through json_body ──

SAMPLE_ID = "00000000-0000-4000-8000-000000000000"
JSON_BODY_ROUTES = [
    ("POST", "/tracks/warm"),
    ("PUT", "/settings/quality"),
    ("PATCH", f"/tracks/{SAMPLE_ID}"),
    ("POST", "/jobs"),
]
ROUTE_IDS = ["warm", "quality", "patch-track", "jobs"]


def _refuse_sign_in():
    raise auth_error("auth_required")


@pytest.mark.parametrize("body", [b"{", b"x" * (64 * 1024 + 1)], ids=["malformed", "oversized"])
@pytest.mark.parametrize("method, path", JSON_BODY_ROUTES, ids=ROUTE_IDS)
def test_a_refused_sign_in_answers_before_the_body_is_read(app_client, method, path, body):
    # The token passes the middleware; the route's sign-in dependency then refuses
    # (as for a user removed since). It answers first: 401, not 422 or 413.
    app_client.app.dependency_overrides[current_library] = _refuse_sign_in
    try:
        response = app_client.request(
            method, path, content=body, headers={"content-type": "application/json"}
        )
    finally:
        app_client.app.dependency_overrides.clear()

    assert response.status_code == 401
    assert response.json()["detail"]["error"] == "auth_required"


def _disconnecting_request(app, method, path, headers, first_chunks):
    """Drive the ASGI app; after ``first_chunks`` the client disconnects."""
    messages = [{"type": "http.request", "body": c, "more_body": True} for c in first_chunks]
    sent = []

    async def receive():
        if messages:
            return messages.pop(0)
        return {"type": "http.disconnect"}

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": method,
        "scheme": "http", "path": path, "raw_path": path.encode(), "query_string": b"",
        "root_path": "", "headers": [(b"content-type", b"application/json"), *headers],
        "client": ("127.0.0.1", 1), "server": ("testserver", 80), "state": {},
    }
    asyncio.run(app(scope, receive, send))  # an unhandled exception would raise here
    return sent


@pytest.mark.parametrize("first_chunks", [[], [b'{"quality": ']], ids=["before-any-byte", "mid-body"])
@pytest.mark.parametrize("method, path", JSON_BODY_ROUTES, ids=ROUTE_IDS)
def test_a_client_that_goes_away_while_a_json_body_is_read_ends_quietly(
    app_client, method, path, first_chunks, caplog
):
    auth = [(b"authorization", app_client.headers["Authorization"].encode())]

    with caplog.at_level(logging.DEBUG):
        sent = _disconnecting_request(app_client.app, method, path, auth, first_chunks)

    starts = [m for m in sent if m["type"] == "http.response.start"]
    assert [m["status"] for m in starts] == [499]
    assert not [r for r in caplog.records if r.levelno >= logging.WARNING]
    assert not [r for r in caplog.records if r.exc_info]
    operator = [r for r in caplog.records if r.name == "uvicorn.error"]
    assert [r.getMessage() for r in operator] == ["client went away before its request body was read"]
