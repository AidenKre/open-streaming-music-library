"""Test driver for the upload content PUT (Phase 7A.2b).

It calls the started app's ASGI callable directly, so a test controls every
message of the request body: its chunking, the Content-Length header (absent,
true or false), a gate that holds the next chunk back (a stalled client), and
a mid-body ``http.disconnect``. httpx and the TestClient would correct or
buffer these. The app must already be started (a ``TestClient`` context), so
``app.state`` holds the server's runtime.
"""

import json
from dataclasses import dataclass, field

import anyio


class Gate:
    """A body step that blocks the client until the test opens it."""

    # anyio events need a running loop, so they are made on first use (a test
    # builds its gates before it starts the loop).
    def __init__(self):
        self._event = None
        self._reached = None

    @property
    def event(self):
        if self._event is None:
            self._event = anyio.Event()
        return self._event

    @property
    def reached(self):
        if self._reached is None:
            self._reached = anyio.Event()
        return self._reached

    def open(self):
        self.event.set()


DISCONNECT = object()


@dataclass
class Sent:
    status: int | None = None
    headers: dict = field(default_factory=dict)
    body: bytes = b""
    # How many body messages the app pulled (0 = it never read the body).
    reads: int = 0

    def json(self):
        return json.loads(self.body)

    @property
    def error(self):
        return self.json()["detail"]["error"]


def _headers(client, content_length, extra):
    headers = [(b"host", b"testserver")]
    auth = client.headers.get("authorization")
    if auth:
        headers.append((b"authorization", auth.encode()))
    if content_length is not None:
        headers.append((b"content-length", str(content_length).encode()))
    for name, value in (extra or {}).items():
        headers.append((name.lower().encode(), value.encode()))
    return headers


async def request(client, method, path, steps=(), *, content_length=None, headers=None):
    """Drive one request. ``steps`` is a sequence of: ``bytes`` (one body
    message), a :class:`Gate` (wait until opened), or :data:`DISCONNECT`.
    The body ends after the last step unless the last step is DISCONNECT."""
    steps = list(steps)
    sent = Sent()
    done = anyio.Event()

    async def receive():
        while steps:
            step = steps.pop(0)
            if isinstance(step, Gate):
                step.reached.set()
                await step.event.wait()
                continue
            if step is DISCONNECT:
                steps.clear()
                return {"type": "http.disconnect"}
            sent.reads += 1
            return {"type": "http.request", "body": step, "more_body": bool(steps)}
        if sent.reads == 0:
            sent.reads += 1
            return {"type": "http.request", "body": b"", "more_body": False}
        await done.wait()
        return {"type": "http.disconnect"}

    async def send(message):
        if message["type"] == "http.response.start":
            sent.status = message["status"]
            sent.headers = {k.decode().lower(): v.decode() for k, v in message.get("headers", [])}
        elif message["type"] == "http.response.body":
            sent.body += message.get("body", b"")
            if not message.get("more_body"):
                done.set()

    raw_path = path.encode()
    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": method,
        "scheme": "http",
        "path": path,
        "raw_path": raw_path,
        "query_string": b"",
        "root_path": "",
        "headers": _headers(client, content_length, headers),
        "client": ("testclient", 50000),
        "server": ("testserver", 80),
        "state": {},
    }
    await client.app(scope, receive, send)
    return sent


def content_path(item_uuid):
    return f"/tracks/uploads/items/{item_uuid}/content"


def put(client, item_uuid, steps, *, content_length="auto", headers=None):
    """Synchronous PUT of ``steps`` (Content-Length = the byte total unless
    given; ``None`` sends none)."""
    if content_length == "auto":
        content_length = sum(len(s) for s in steps if isinstance(s, bytes))

    async def run():
        return await request(
            client, "PUT", content_path(item_uuid), steps,
            content_length=content_length, headers=headers,
        )

    return anyio.run(run)
