"""9D.1c: classifying Last.fm's answers into the five kinds of spec §7.9.

"HTTP 200 is not success; the body is always parsed."
2. Try later: "Error 8, 11, 16 or 29; HTTP 429, 5xx or 3xx; a 4xx with no
   Last.fm reply in it; a network error; a timeout; a body that cannot be read."
   "A failure to connect at all, where the request never left the server, does
   not count as an attempt."
3. Reconnect: error 9.  4. Stop: error 10 or 26.  5. Rejected: any other code.
Redirects are not followed (§7.8).
"""

import httpx
import pytest

from app.services.lastfm_client import AnswerKind, LastfmClient
from tests import lastfm_secrets as planted
from tests.lastfm_fake import FakeLastfm, failed, make_config, xml_reply

ROW = {"artist": "A", "track": "T", "timestamp": 1700000000}


def _calls(client: LastfmClient):
    return {
        "getToken": lambda: client.get_token().answer,
        "getSession": lambda: client.get_session(planted.TOKEN).answer,
        "scrobble": lambda: client.scrobble(planted.SESSION_KEY, [ROW]).answer,
        "nowPlaying": lambda: client.update_now_playing(planted.SESSION_KEY, {"artist": "A", "track": "T"}),
    }


CALLS = ["getToken", "getSession", "scrobble", "nowPlaying"]


def _answer(call: str, *replies):
    fake = FakeLastfm(*replies)
    answer = _calls(LastfmClient(make_config(), transport=fake.transport))[call]()
    return answer, fake


@pytest.mark.parametrize("call", CALLS)
@pytest.mark.parametrize(
    ("code", "kind"),
    [
        (8, AnswerKind.TRY_LATER),
        (11, AnswerKind.TRY_LATER),
        (16, AnswerKind.TRY_LATER),
        (29, AnswerKind.TRY_LATER),
        (9, AnswerKind.RECONNECT),
        (10, AnswerKind.STOP),
        (26, AnswerKind.STOP),
        (13, AnswerKind.REJECTED),
        (4, AnswerKind.REJECTED),
        (6, AnswerKind.REJECTED),
        (14, AnswerKind.REJECTED),
        (15, AnswerKind.REJECTED),
        (99, AnswerKind.REJECTED),
    ],
)
def test_last_fm_error_codes_map_to_the_five_kinds(call, code, kind):
    answer, _ = _answer(call, failed(code))

    assert answer.kind is kind
    assert answer.error_code == code
    assert answer.http_status == 200
    assert answer.connect_failed is False


@pytest.mark.parametrize(("code", "status", "kind"), [(9, 403, AnswerKind.RECONNECT), (10, 403, AnswerKind.STOP), (13, 400, AnswerKind.REJECTED), (29, 400, AnswerKind.TRY_LATER)])
def test_a_4xx_carrying_a_last_fm_reply_is_read_by_its_code(code, status, kind):
    answer, _ = _answer("scrobble", failed(code, status=status))

    assert answer.kind is kind
    assert answer.error_code == code
    assert answer.http_status == status


@pytest.mark.parametrize("call", CALLS)
@pytest.mark.parametrize("status", [429, 500, 502, 503, 504])
def test_429_and_5xx_are_try_later_whatever_the_body(call, status):
    for body in (failed(10, status=status), xml_reply("<html>Bad gateway</html>", status=status), xml_reply("", status=status)):
        answer, _ = _answer(call, body)

        assert answer.kind is AnswerKind.TRY_LATER
        assert answer.http_status == status


@pytest.mark.parametrize("status", [400, 401, 403, 404, 405, 413])
def test_a_4xx_with_no_last_fm_reply_is_try_later(status):
    for body in ("", "<html><body>Forbidden</body></html>", '<lfm status="failed"></lfm>', '<lfm status="ok"><token>abc</token></lfm>'):
        answer, _ = _answer("getToken", xml_reply(body, status=status))

        assert answer.kind is AnswerKind.TRY_LATER
        assert answer.http_status == status


@pytest.mark.parametrize("call", CALLS)
@pytest.mark.parametrize("status", [301, 302, 303, 307, 308])
def test_a_redirect_is_not_followed_and_is_try_later(call, status):
    redirect = httpx.Response(status, headers={"Location": "https://evil.example/steal"})

    answer, fake = _answer(call, redirect)

    assert answer.kind is AnswerKind.TRY_LATER
    assert answer.http_status == status
    assert len(fake.requests) == 1


@pytest.mark.parametrize(
    "body",
    [
        '<lfm status="failed"><error>no code</error></lfm>',
        '<lfm status="failed"><error code="x9">odd</error></lfm>',
        '<lfm status="failed"><error code="">empty</error></lfm>',
        '<lfm status="failed"></lfm>',
    ],
    ids=["no code", "non-numeric", "empty code", "no error"],
)
def test_a_failed_reply_without_a_readable_code_is_try_later(body):
    answer, _ = _answer("getToken", xml_reply(body))

    assert answer.kind is AnswerKind.TRY_LATER
    assert answer.error_code is None


def test_an_error_code_is_read_case_insensitively():
    answer, _ = _answer("getToken", xml_reply('<LFM STATUS="FAILED"><ERROR CODE="9">x</ERROR></LFM>'))

    assert answer.kind is AnswerKind.RECONNECT
    assert answer.error_code == 9


@pytest.mark.parametrize("call", CALLS)
@pytest.mark.parametrize(
    "error",
    [httpx.ConnectError, httpx.ConnectTimeout],
    ids=["connect error", "connect timeout"],
)
def test_a_failure_to_connect_is_try_later_and_marked_as_never_sent(call, error):
    request = httpx.Request("POST", "https://ws.audioscrobbler.com/2.0/")

    answer, _ = _answer(call, error("no route to host", request=request))

    assert answer.kind is AnswerKind.TRY_LATER
    assert answer.connect_failed is True
    assert answer.http_status is None and answer.error_code is None


@pytest.mark.parametrize("call", CALLS)
@pytest.mark.parametrize(
    "error",
    [httpx.ReadTimeout, httpx.WriteTimeout, httpx.ReadError, httpx.RemoteProtocolError, httpx.PoolTimeout],
)
def test_a_network_error_after_connecting_is_try_later_and_counts(call, error):
    request = httpx.Request("POST", "https://ws.audioscrobbler.com/2.0/")

    answer, _ = _answer(call, error("boom", request=request))

    assert answer.kind is AnswerKind.TRY_LATER
    assert answer.connect_failed is False
    assert answer.http_status is None


def test_a_non_ok_scrobble_answer_carries_no_row_outcomes():
    fake = FakeLastfm(failed(13))
    result = LastfmClient(make_config(), transport=fake.transport).scrobble(planted.SESSION_KEY, [ROW])

    assert result.answer.kind is AnswerKind.REJECTED
    assert result.rows is None


def test_a_rejected_get_session_carries_no_session():
    fake = FakeLastfm(failed(14))
    result = LastfmClient(make_config(), transport=fake.transport).get_session(planted.TOKEN)

    assert result.answer.kind is AnswerKind.REJECTED
    assert result.answer.error_code == 14
    assert result.session_key is None and result.account_name is None


def test_the_client_makes_exactly_one_request_per_call_even_on_failure():
    for reply in (failed(16), xml_reply("", status=503), httpx.ReadTimeout("x")):
        answer, fake = _answer("nowPlaying", reply)
        assert answer.kind is AnswerKind.TRY_LATER
        assert len(fake.requests) == 1
