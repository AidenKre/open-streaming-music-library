"""An in-process fake of Last.fm for unit tests: an httpx MockTransport with
scripted replies, the captured requests, reply builders and a fake clock.

Nothing here opens a socket. Every value is made up.
"""

from collections.abc import Callable, Iterable, Iterator
from urllib.parse import parse_qsl

import httpx
from pydantic import SecretStr

from app.services.lastfm_config import LastfmConfig
from tests import lastfm_secrets as planted

Reply = httpx.Response | BaseException | Callable[[httpx.Request], httpx.Response]


def make_config(**overrides) -> LastfmConfig:
    values = dict(
        api_key=SecretStr(planted.API_KEY),
        api_secret=SecretStr(planted.API_SECRET),
        credential_key=SecretStr(planted.CREDENTIAL_KEY),
        settle_delay_s=60,
        min_request_gap_s=5,
    )
    values.update(overrides)
    return LastfmConfig(**values)


class FakeLastfm:
    """Replies in order from ``replies``; records every request it receives."""

    def __init__(self, *replies: Reply):
        self.replies: list[Reply] = list(replies)
        self.requests: list[httpx.Request] = []
        self.transport = httpx.MockTransport(self._handle)

    def queue(self, *replies: Reply) -> None:
        self.replies.extend(replies)

    def _handle(self, request: httpx.Request) -> httpx.Response:
        request.read()
        self.requests.append(request)
        if not self.replies:
            raise AssertionError("FakeLastfm got a request it has no reply for")
        reply = self.replies.pop(0)
        if isinstance(reply, BaseException):
            raise reply
        if callable(reply) and not isinstance(reply, httpx.Response):
            return reply(request)
        return reply

    def form(self, index: int = -1) -> list[tuple[str, str]]:
        """The decoded form body of a captured request, in body order."""
        body = self.requests[index].content.decode("utf-8")
        return parse_qsl(body, keep_blank_values=True, strict_parsing=True)


def xml_reply(body: str | bytes, status: int = 200, headers: dict | None = None) -> httpx.Response:
    content = body.encode("utf-8") if isinstance(body, str) else body
    return httpx.Response(
        status, content=content, headers={"Content-Type": "text/xml; charset=utf-8", **(headers or {})}
    )


def ok_token(token: str) -> httpx.Response:
    return xml_reply(f'<?xml version="1.0" encoding="utf-8"?>\n<lfm status="ok"><token>{token}</token></lfm>')


def ok_session(name: str, key: str) -> httpx.Response:
    return xml_reply(
        '<?xml version="1.0" encoding="utf-8"?>\n<lfm status="ok"><session>'
        f"<name>{name}</name><key>{key}</key><subscriber>0</subscriber></session></lfm>"
    )


def ok_now_playing() -> httpx.Response:
    return xml_reply(
        '<lfm status="ok"><nowplaying><track corrected="0">T</track>'
        '<artist corrected="0">A</artist><album corrected="0"></album>'
        '<albumArtist corrected="0"></albumArtist>'
        '<ignoredMessage code="0"></ignoredMessage></nowplaying></lfm>'
    )


def scrobble_result(timestamp: int, ignored_code: int | str = 0, track: str = "T") -> str:
    return (
        f'<scrobble><track corrected="0">{track}</track><artist corrected="0">A</artist>'
        '<album corrected="0"></album><albumArtist corrected="0"></albumArtist>'
        f'<timestamp>{timestamp}</timestamp><ignoredMessage code="{ignored_code}"></ignoredMessage></scrobble>'
    )


def ok_scrobbles(accepted: int, ignored: int, results: Iterable[str]) -> httpx.Response:
    return xml_reply(
        f'<lfm status="ok"><scrobbles accepted="{accepted}" ignored="{ignored}">'
        + "".join(results)
        + "</scrobbles></lfm>"
    )


def failed(code: int, status: int = 200, message: str = "Something failed") -> httpx.Response:
    return xml_reply(
        f'<?xml version="1.0" encoding="utf-8"?>\n<lfm status="failed"><error code="{code}">{message}</error></lfm>',
        status=status,
    )


class ChunkStream(httpx.SyncByteStream):
    """A reply body handed out chunk by chunk; ``on_chunk`` runs before each one
    (to move a fake clock) and ``pulled`` counts the chunks actually read."""

    def __init__(self, chunks: Iterable[bytes], on_chunk: Callable[[int], None] | None = None):
        self._chunks = chunks
        self._on_chunk = on_chunk
        self.pulled = 0
        self.closed = False

    def __iter__(self) -> Iterator[bytes]:
        for chunk in self._chunks:
            if self._on_chunk:
                self._on_chunk(self.pulled)
            self.pulled += 1
            yield chunk

    def close(self) -> None:
        self.closed = True


class FakeClock:
    """A monotonic clock that moves only when told to, or when a gate waits on it.

    ``wait(condition, timeout)`` is the gate's waiting seam: with a timeout it
    moves time forward by that much (and runs ``on_wait`` hooks first); with
    ``None`` it blocks on the real condition, for tests that use threads.
    """

    def __init__(self, start: float = 1000.0):
        self.now = start
        self.waits: list[float | None] = []
        self.on_wait: list[Callable[[float | None], None]] = []

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds

    def wait(self, condition, timeout: float | None) -> None:
        self.waits.append(timeout)
        for hook in list(self.on_wait):
            hook(timeout)
        if timeout is None:
            condition.wait()
        else:
            self.now += timeout
