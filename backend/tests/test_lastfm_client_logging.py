"""9D.1c: what the client logs, and that no secret reaches a log (spec §7.6, §7.9; 9-U08b).

"Failed requests are logged with the HTTP status, the Last.fm error code and
at most 4 KiB of the reply, through the redaction helper." "Bodies of
`auth.getToken` and `auth.getSession` replies are never logged. The message of
an HTTP-client exception is never logged, only its class, because it can
contain a URL." Operator-visible lines go through `operator_logger` (O12).

Replies here echo the request's own credentials back, the worst case for a leak.
"""

import itertools
import logging
from urllib.parse import parse_qsl, quote, quote_plus

import httpx
import pytest

from app.services.lastfm_client import AnswerKind, LastfmClient
from tests import lastfm_secrets as planted
from tests.lastfm_fake import ChunkStream, FakeLastfm, make_config, ok_now_playing, ok_scrobbles, ok_session, ok_token, scrobble_result, xml_reply

ROW = {"artist": "A", "track": "T", "timestamp": 1700000000}


def _secret_forms(values):
    forms = set()
    for value in values:
        forms |= {value, quote(value, safe=""), quote_plus(value)}
    return forms


def _echo(status: int, code: int | None):
    """A reply that repeats every credential of the request it answers."""

    def reply(request: httpx.Request) -> httpx.Response:
        form = dict(parse_qsl(request.content.decode("utf-8")))
        echoed = " ".join(form.get(k, "") for k in ("api_key", "sk", "token", "api_sig"))
        echoed += " " + request.content.decode("utf-8")
        inner = f'<error code="{code}">echo {echoed}</error>' if code is not None else f"<x>{echoed}</x>"
        status_attr = "failed" if code is not None else "ok"
        return xml_reply(f'<lfm status="{status_attr}">{inner}</lfm>'.replace("&", "&amp;"), status=status)

    return reply


def _run(call: str, *replies):
    fake = FakeLastfm(*replies)
    client = LastfmClient(make_config(), transport=fake.transport)
    calls = {
        "getToken": lambda: client.get_token().answer,
        "getSession": lambda: client.get_session(planted.TOKEN).answer,
        "scrobble": lambda: client.scrobble(planted.SESSION_KEY, [ROW]).answer,
        "nowPlaying": lambda: client.update_now_playing(planted.SESSION_KEY, {"artist": "A", "track": "T"}),
    }
    answer = calls[call]()
    sig = dict(fake.form(-1))["api_sig"] if fake.requests else None
    return answer, sig


CALLS = ["getToken", "getSession", "scrobble", "nowPlaying"]


def _ours(caplog):
    """The client's own lines (httpx adds its own INFO line per request, scanned too)."""
    return [r for r in caplog.records if r.name == "uvicorn.error"]


def _assert_clean(caplog, sig):
    secrets = list(planted.ALL) + ([sig] if sig else [])
    planted.assert_no_secret(caplog.text, "captured logs", secrets=_secret_forms(secrets))
    for record in caplog.records:
        planted.assert_no_secret(str(record.args), "log record args", secrets=_secret_forms(secrets))
        assert record.exc_info is None


@pytest.mark.parametrize("call", ["scrobble", "nowPlaying"])
def test_a_rejected_track_call_is_logged_once_with_status_code_and_a_redacted_reply(caplog, call):
    caplog.set_level(logging.DEBUG)

    answer, sig = _run(call, _echo(400, 13))

    assert answer.kind is AnswerKind.REJECTED
    assert len(_ours(caplog)) == 1
    record = _ours(caplog)[0]
    assert record.name == "uvicorn.error"
    assert record.levelno >= logging.WARNING
    message = record.getMessage()
    assert "400" in message and "13" in message
    assert "echo" in message  # an excerpt of the reply is there
    assert "[redacted]" in message
    _assert_clean(caplog, sig)


@pytest.mark.parametrize("call", ["getToken", "getSession"])
def test_an_auth_reply_body_is_never_logged(caplog, call):
    caplog.set_level(logging.DEBUG)

    answer, sig = _run(call, _echo(403, 13))

    assert answer.kind is AnswerKind.REJECTED
    assert len(_ours(caplog)) == 1
    assert "echo" not in caplog.text
    _assert_clean(caplog, sig)


@pytest.mark.parametrize("call", CALLS)
@pytest.mark.parametrize("code", [8, 9, 10, 26, 29, 99])
def test_every_failed_answer_is_logged_without_a_secret(caplog, call, code):
    caplog.set_level(logging.DEBUG)

    answer, sig = _run(call, _echo(200, code))

    assert answer.kind is not AnswerKind.OK
    assert len(_ours(caplog)) == 1
    assert str(code) in _ours(caplog)[0].getMessage()
    _assert_clean(caplog, sig)


@pytest.mark.parametrize("call", CALLS)
@pytest.mark.parametrize("status", [302, 429, 502])
def test_a_status_try_later_is_logged_without_a_secret(caplog, call, status):
    caplog.set_level(logging.DEBUG)

    answer, sig = _run(call, _echo(status, None))

    assert answer.kind is AnswerKind.TRY_LATER
    assert len(_ours(caplog)) == 1
    assert str(status) in _ours(caplog)[0].getMessage()
    _assert_clean(caplog, sig)


@pytest.mark.parametrize("call", CALLS)
@pytest.mark.parametrize("error", [httpx.ConnectError, httpx.ReadTimeout, httpx.RemoteProtocolError])
def test_an_exception_is_logged_by_its_class_only(caplog, call, error):
    caplog.set_level(logging.DEBUG)
    message = (
        f"failed https://ws.audioscrobbler.com/2.0/?api_key={planted.API_KEY}&sk={planted.SESSION_KEY}"
        f"&token={planted.TOKEN} secret={planted.API_SECRET} marker-text"
    )

    answer, sig = _run(call, error(message))

    assert answer.kind is AnswerKind.TRY_LATER
    assert len(_ours(caplog)) == 1
    assert error.__name__ in caplog.text
    assert "marker-text" not in caplog.text
    assert "audioscrobbler" not in caplog.text
    _assert_clean(caplog, sig)


def test_an_unreadable_reply_is_logged_without_a_secret(caplog):
    caplog.set_level(logging.DEBUG)

    def garbage(request):
        return xml_reply(b"\xff\xfe not xml " + request.content)

    answer, sig = _run("scrobble", garbage)

    assert answer.kind is AnswerKind.TRY_LATER
    assert len(_ours(caplog)) == 1
    _assert_clean(caplog, sig)


def test_an_abandoned_reply_is_logged_without_a_secret(caplog):
    caplog.set_level(logging.DEBUG)

    def huge(request):
        return httpx.Response(200, stream=ChunkStream(itertools.repeat(request.content * 64, 4096)))

    answer, sig = _run("nowPlaying", huge)

    assert answer.kind is AnswerKind.TRY_LATER
    assert len(_ours(caplog)) == 1
    _assert_clean(caplog, sig)


@pytest.mark.parametrize(
    ("call", "reply"),
    [
        ("getToken", ok_token(planted.TOKEN)),
        ("getSession", ok_session("someone", planted.SESSION_KEY)),
        ("scrobble", ok_scrobbles(1, 0, [scrobble_result(ROW["timestamp"])])),
        ("nowPlaying", ok_now_playing()),
    ],
)
def test_an_ok_answer_logs_nothing(caplog, call, reply):
    caplog.set_level(logging.DEBUG)

    answer, _ = _run(call, reply)

    assert answer.kind is AnswerKind.OK
    assert _ours(caplog) == []
