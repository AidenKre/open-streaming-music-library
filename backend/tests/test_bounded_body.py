"""SC-16b: one shared ``bounded_body(max_bytes)`` dependency that enforces
the byte cap WHILE streaming (independent of Content-Length: absent, or
false/too small), refuses with 413 without echoing input, and the one 422
helper that maps a Pydantic ``ValidationError`` without ``input`` values."""

import asyncio
import json

import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient
from pydantic import BaseModel, ConfigDict, ValidationError

from app.core.bounded_body import bounded_body, validation_error_422

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
