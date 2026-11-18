"""Phase M.1b (M-U12, spec §5.3 "Access log"): no ``access_token`` value in
the uvicorn access log.

The media token rides in the stream URL (SC-27 Phase M), and uvicorn's access
log prints the path with its query string. A ``logging.Filter`` attached to
the real ``uvicorn.access`` logger at startup strips the value, so the plain
README ``uvicorn`` launch needs no ``--log-config``.

The end-to-end test drives uvicorn's real HTTP/1.1 protocol class in-process
(no socket, no port) so the record is exactly the one uvicorn emits.
"""

import asyncio
import logging
import threading

import pytest
import uvicorn
from uvicorn.logging import AccessFormatter
from uvicorn.protocols.http.h11_impl import H11Protocol
from uvicorn.server import ServerState

SECRET = "S3cr3t-media-token_value-0123456789abcdefghij"
# A well-formed track ID, so the path matches the media route (7A.1a: the
# track routes take only UUIDs).
MEDIA_PATH = "/tracks/00000000-0000-4000-8000-000000000000/stream"


class _Capture(logging.Handler):
    def __init__(self):
        super().__init__()
        self.records = []

    def emit(self, record):
        self.records.append(record)


@pytest.fixture
def access_records():
    logger = logging.getLogger("uvicorn.access")
    handler = _Capture()
    logger.addHandler(handler)
    old_level = logger.level
    logger.setLevel(logging.INFO)
    try:
        yield handler.records
    finally:
        logger.removeHandler(handler)
        logger.setLevel(old_level)


class _Transport(asyncio.Transport):
    def __init__(self):
        super().__init__()
        self.written = bytearray()
        self.closed = False
        self.closed_event = asyncio.Event()

    def get_extra_info(self, name, default=None):
        return {"peername": ("127.0.0.1", 50000), "sockname": ("127.0.0.1", 8000)}.get(
            name, default
        )

    def write(self, data):
        self.written.extend(data)

    def is_closing(self):
        return self.closed

    def close(self):
        self.closed = True
        self.closed_event.set()

    def set_protocol(self, protocol):
        pass

    def pause_reading(self):
        pass

    def resume_reading(self):
        pass


def _serve_one_request(app, target: str, on_loop=None) -> bytes:
    """Send one GET through uvicorn's h11 protocol and return the raw response.

    ``on_loop(loop)``, if given, runs on the event loop before the request is
    sent (tests use it to schedule deterministic loop-tick gates)."""

    async def run():
        if on_loop is not None:
            on_loop(asyncio.get_running_loop())
        config = uvicorn.Config(app=app, log_config=None, lifespan="off", proxy_headers=False)
        config.load()
        transport = _Transport()
        protocol = H11Protocol(config=config, server_state=ServerState(), app_state={})
        protocol.connection_made(transport)
        protocol.data_received(
            f"GET {target} HTTP/1.1\r\nHost: testserver\r\nConnection: close\r\n\r\n".encode()
        )
        # uvicorn closes the transport once the "Connection: close" response is
        # complete: wait for exactly that signal (F-pre-1: a fixed yield budget
        # gave up under load while the session lookup was still in its thread).
        # The timeout is a hang guard only; no correct run comes near it.
        await asyncio.wait_for(transport.closed_event.wait(), timeout=60)
        protocol.connection_lost(None)
        return bytes(transport.written)

    return asyncio.run(run())


def _formatted(record) -> str:
    return AccessFormatter(fmt='%(client_addr)s - "%(request_line)s" %(status_code)s').format(record)


def test_the_running_app_redacts_the_media_token_from_real_access_records(
    app_client, access_records
):
    raw = _serve_one_request(
        app_client.app,
        f"/tracks/00000000-0000-4000-8000-000000000000/stream?quality=original&access_token={SECRET}",
    )

    assert raw.startswith(b"HTTP/1.1 401")
    assert len(access_records) == 1
    [record] = access_records
    assert SECRET not in record.getMessage()
    assert SECRET not in repr(record.args)
    line = _formatted(record)
    assert SECRET not in line
    # The rest of the line survives: still useful for operators.
    assert "/tracks/00000000-0000-4000-8000-000000000000/stream?quality=original" in line
    assert "access_token=" in line
    assert '" 401' in line


@pytest.mark.parametrize(
    "query",
    [
        f"access_token={SECRET}",
        f"access_token={SECRET}&quality=original",
        f"quality=original&access_token={SECRET}",
        f"a=1&access_token={SECRET}&b=2",
        f"access_token={SECRET}&access_token={SECRET}x",
        f"ACCESS_TOKEN={SECRET}",
        f"access%5Ftoken={SECRET}",
        # review #4: junk around the value, a doubled "?", a fragment marker.
        f'access_token="{SECRET}',
        f"access_token=%22{SECRET}",
        f"?access_token={SECRET}",
        f"access_token=x#{SECRET}",
    ],
)
def test_every_spelling_of_the_parameter_is_redacted(app_client, access_records, query):
    _serve_one_request(app_client.app, f"{MEDIA_PATH}?{query}")

    [record] = access_records
    assert SECRET not in _formatted(record)
    assert SECRET not in record.getMessage()


def test_other_query_values_are_left_alone(app_client, access_records):
    _serve_one_request(app_client.app, "/tracks?limit=5&access=yes&token=abc")

    [record] = access_records
    assert "/tracks?limit=5&access=yes&token=abc" in _formatted(record)


def test_the_filter_is_attached_once_even_after_repeated_startups(configure_app):
    from fastapi.testclient import TestClient

    for _ in range(3):
        main = configure_app()
        with TestClient(main.app):
            pass

    logger = logging.getLogger("uvicorn.access")
    redacting = [f for f in logger.filters if type(f).__name__ == "AccessTokenRedactor"]
    assert len(redacting) == 1


# ── F-pre-1: a session lookup slower than the harness's patience ────────────

class _LoopTickGate:
    """Blocks the session lookup's worker thread until the event loop has run
    ``ticks`` iterations (a self-rescheduling ``call_soon`` chain), so a
    lookup that outlasts any fixed yield budget is reproduced exactly, with no
    wall clock and no CPU load."""

    def __init__(self, ticks):
        self.ticks = ticks
        self.count = 0
        self.released = threading.Event()

    def install(self, loop):
        def tick():
            self.count += 1
            if self.count >= self.ticks:
                self.released.set()
            else:
                loop.call_soon(tick)

        loop.call_soon(tick)

    def wrap(self, lookup):
        def gated(*args, **kwargs):
            self.released.wait()
            return lookup(*args, **kwargs)

        return gated


def test_a_slow_media_lookup_is_still_answered_and_redacted(
    app_client, access_records, monkeypatch
):
    db = app_client.app.state.database
    gate = _LoopTickGate(ticks=1000)  # well beyond the old 200-yield budget
    monkeypatch.setattr(
        db, "get_live_session_by_media_hash", gate.wrap(db.get_live_session_by_media_hash)
    )

    raw = _serve_one_request(
        app_client.app, f"{MEDIA_PATH}?access_token={SECRET}", on_loop=gate.install
    )

    assert gate.released.is_set()
    assert raw.startswith(b"HTTP/1.1 401")
    [record] = [r for r in access_records if r.name == "uvicorn.access"]
    assert SECRET not in _formatted(record)


def test_a_request_cancelled_mid_lookup_logs_no_token_anywhere(app_client, monkeypatch):
    """The product side of F-pre-1: a request whose task is cancelled while
    its media-token lookup is in the worker thread (a shutdown or a lost
    client) sends no response and leaves no record, on any logger, carrying
    the token. uvicorn's own "Exception in ASGI application" error on that
    path names no URL."""
    db = app_client.app.state.database
    entered, release = threading.Event(), threading.Event()
    real_lookup = db.get_live_session_by_media_hash

    def gated(*args, **kwargs):
        entered.set()
        release.wait()
        return real_lookup(*args, **kwargs)

    monkeypatch.setattr(db, "get_live_session_by_media_hash", gated)
    records = _Capture()
    root = logging.getLogger()
    old_level = root.level
    root.addHandler(records)
    root.setLevel(logging.DEBUG)

    async def run():
        config = uvicorn.Config(
            app=app_client.app, log_config=None, lifespan="off", proxy_headers=False
        )
        config.load()
        transport = _Transport()
        protocol = H11Protocol(config=config, server_state=ServerState(), app_state={})
        protocol.connection_made(transport)
        protocol.data_received(
            f"GET {MEDIA_PATH}?access_token={SECRET} HTTP/1.1\r\n"
            "Host: testserver\r\nConnection: close\r\n\r\n".encode()
        )
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, entered.wait)  # the lookup is in its thread
        protocol.connection_lost(None)
        tasks = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
        for task in tasks:
            task.cancel()
        release.set()
        await asyncio.gather(*tasks, return_exceptions=True)
        return bytes(transport.written)

    try:
        raw = asyncio.run(run())
    finally:
        release.set()
        root.removeHandler(records)
        root.setLevel(old_level)

    assert raw == b""  # cancelled before any response
    # This is the F-pre-1 path: uvicorn reports the cancelled ASGI task.
    assert any(r.name == "uvicorn.error" and r.exc_info for r in records.records)
    for record in records.records:
        text = record.getMessage() + repr(record.args)
        if record.exc_info:
            text += logging.Formatter().formatException(record.exc_info)
        assert SECRET not in text, record.name
    assert not [r for r in records.records if r.name == "uvicorn.access"]
