"""9D.1c: the client's limits (spec §7.8, 9-U09 client).

"Certificate verification is on, redirects are not followed, a request is
abandoned after 20 seconds in total, and reading stops at 1 MiB." The
deadline runs on an injected clock; the cap is enforced while streaming, not
after reading the whole reply.
"""

import gzip
import itertools

import httpx

from app.services.lastfm_client import AnswerKind, LastfmClient
from tests import lastfm_secrets as planted
from tests.lastfm_fake import ChunkStream, FakeClock, FakeLastfm, make_config

MIB = 1024 * 1024
TOKEN_XML = b'<lfm status="ok"><token>abc</token></lfm>'


def _chunks(body: bytes, size: int) -> list[bytes]:
    return [body[i : i + size] for i in range(0, len(body), size)]


def _get_token(reply, clock=None):
    fake = FakeLastfm(reply)
    kwargs = {"clock": clock} if clock is not None else {}
    client = LastfmClient(make_config(), transport=fake.transport, **kwargs)
    return client.get_token(), fake


# --- 20 seconds in total -----------------------------------------------------


def test_a_reply_trickling_past_twenty_seconds_in_total_is_abandoned():
    clock = FakeClock()
    stream = ChunkStream(_chunks(TOKEN_XML, 8), on_chunk=lambda _: clock.advance(6))

    result, _ = _get_token(httpx.Response(200, stream=stream), clock)

    # Chunks arrive at 6, 12, 18, 24 s: each wait is short, the total is not.
    assert result.answer.kind is AnswerKind.TRY_LATER
    assert result.token is None
    assert stream.pulled <= 4
    assert stream.pulled < len(_chunks(TOKEN_XML, 8))


def test_time_spent_before_the_reply_counts_towards_the_twenty_seconds():
    clock = FakeClock()

    def slow_start(request):
        clock.advance(19)  # connecting and sending took 19 s
        return httpx.Response(
            200, stream=ChunkStream(_chunks(TOKEN_XML, 16), on_chunk=lambda _: clock.advance(1))
        )

    result, _ = _get_token(slow_start, clock)

    assert result.answer.kind is AnswerKind.TRY_LATER


def test_a_reply_inside_twenty_seconds_is_read():
    clock = FakeClock()
    chunks = _chunks(TOKEN_XML, 16)
    stream = ChunkStream(chunks, on_chunk=lambda _: clock.advance(19 / len(chunks)))

    result, _ = _get_token(httpx.Response(200, stream=stream), clock)

    assert result.answer.kind is AnswerKind.OK
    assert result.token == "abc"


def test_the_deadline_is_measured_on_the_injected_clock_only():
    # The fake clock stands still: however the reply is chunked, nothing times out.
    clock = FakeClock()
    stream = ChunkStream(_chunks(TOKEN_XML, 1))

    result, _ = _get_token(httpx.Response(200, stream=stream), clock)

    assert result.answer.kind is AnswerKind.OK


# --- 1 MiB ---------------------------------------------------------------------


def test_an_endless_reply_is_cut_off_at_one_mebibyte_while_streaming():
    chunk = b" " * 65536
    # 64 MiB in all (finite, so a client without the cap fails instead of hanging).
    stream = ChunkStream(
        itertools.chain([b'<lfm status="ok"><token>abc</token>'], itertools.repeat(chunk, 1024))
    )

    result, _ = _get_token(httpx.Response(200, stream=stream))

    assert result.answer.kind is AnswerKind.TRY_LATER
    assert result.token is None
    # 1 MiB is 16 such chunks: reading stopped right after the cap, not at the end.
    assert stream.pulled <= 18


def test_a_reply_of_exactly_one_mebibyte_is_read():
    body = TOKEN_XML[:-6] + b" " * (MIB - len(TOKEN_XML)) + b"</lfm>"
    assert len(body) == MIB

    result, _ = _get_token(httpx.Response(200, stream=ChunkStream(_chunks(body, 65536))))

    assert result.answer.kind is AnswerKind.OK
    assert result.token == "abc"


def test_a_reply_one_byte_over_one_mebibyte_is_not_read():
    body = TOKEN_XML[:-6] + b" " * (MIB - len(TOKEN_XML) + 1) + b"</lfm>"
    assert len(body) == MIB + 1

    result, _ = _get_token(httpx.Response(200, stream=ChunkStream(_chunks(body, 65536))))

    assert result.answer.kind is AnswerKind.TRY_LATER


def test_a_declared_length_over_the_cap_is_refused_before_reading():
    stream = ChunkStream([TOKEN_XML])
    reply = httpx.Response(200, headers={"Content-Length": str(2 * MIB)}, stream=stream)

    result, _ = _get_token(reply)

    assert result.answer.kind is AnswerKind.TRY_LATER
    assert stream.pulled == 0


def test_a_compressed_reply_is_not_decompressed():
    # The client asks for identity; a compressed reply (a possible bomb) is unreadable.
    reply = httpx.Response(
        200, headers={"Content-Encoding": "gzip"}, stream=ChunkStream([gzip.compress(TOKEN_XML)])
    )

    result, fake = _get_token(reply)

    assert result.answer.kind is AnswerKind.TRY_LATER
    assert fake.requests[0].headers["accept-encoding"] == "identity"


def test_an_abandoned_reply_is_closed():
    stream = ChunkStream(itertools.repeat(b" " * 65536, 64))

    _get_token(httpx.Response(200, stream=stream))

    assert stream.closed


# --- transport defaults ----------------------------------------------------------


def test_the_default_transport_verifies_certificates_and_never_redirects_or_retries(monkeypatch):
    # 9-R1-18: observed through the arguments the client builds its transport
    # with (httpx's defaults: verify=True, retries=0), not httpx's private pool.
    built = []

    class RecordingTransport(httpx.BaseTransport):
        def __init__(self, *args, **kwargs):
            built.append((args, kwargs))

        def handle_request(self, request):
            raise AssertionError("this test sends nothing")

    monkeypatch.setattr(httpx, "HTTPTransport", RecordingTransport)
    client = LastfmClient(make_config())
    try:
        http = client._client
        [(args, kwargs)] = built
        assert args == ()
        assert kwargs.get("verify", True) is True  # the system trust store, hostnames checked
        assert kwargs.get("retries", 0) == 0
        assert set(kwargs) <= {"verify", "retries"}  # no proxy, no custom context or cert
        assert http.follow_redirects is False
        assert http.trust_env is False
        for phase in ("connect", "read", "write", "pool"):
            assert 0 < getattr(http.timeout, phase) <= 20
    finally:
        client.close()


def test_proxy_settings_in_the_environment_are_ignored(monkeypatch):
    monkeypatch.setenv("HTTPS_PROXY", "http://127.0.0.1:9")
    monkeypatch.setenv("ALL_PROXY", "http://127.0.0.1:9")
    client = LastfmClient(make_config())
    try:
        assert client._client._mounts == {}
    finally:
        client.close()


def test_limits_leave_no_secret_in_the_answer():
    clock = FakeClock()
    stream = ChunkStream(_chunks(TOKEN_XML, 4), on_chunk=lambda _: clock.advance(10))

    result, _ = _get_token(httpx.Response(200, stream=stream), clock)

    planted.assert_no_secret(repr(result), "the answer")


def test_a_nonsense_declared_length_never_escapes_the_client():
    for declared in (b"9" * 5000, "²".encode(), b"-1", b"1e9", b" 12 "):
        stream = ChunkStream([TOKEN_XML])
        reply = httpx.Response(200, headers={"Content-Length": declared}, stream=stream)

        result, _ = _get_token(reply)

        assert result.answer.kind in (AnswerKind.OK, AnswerKind.TRY_LATER)
