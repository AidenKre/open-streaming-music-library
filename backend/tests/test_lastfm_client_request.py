"""9D.1c step 1: how every Last.fm request leaves the server (spec §7.8, 9-U09 client).

Every request is a POST with a form-encoded UTF-8 body to the configured base
URL, so no key, token or signature travels in a URL; `User-Agent: OSML/<version>`;
`format` is never sent.
"""

import hashlib
import tomllib
from pathlib import Path

import pytest

from app.services.lastfm_client import LastfmClient
from tests import lastfm_secrets as planted
from tests.lastfm_fake import (
    FakeLastfm,
    make_config,
    ok_now_playing,
    ok_scrobbles,
    ok_session,
    ok_token,
    scrobble_result,
)

PYPROJECT = Path(__file__).resolve().parents[1] / "pyproject.toml"


def _calls(client: LastfmClient):
    """Each of the four calls, with a matching ok reply."""
    return [
        (lambda: client.get_token(), ok_token("tok")),
        (lambda: client.get_session(planted.TOKEN), ok_session("someone", "k")),
        (
            lambda: client.scrobble(
                planted.SESSION_KEY, [{"artist": "A", "track": "T", "timestamp": 1700000000}]
            ),
            ok_scrobbles(1, 0, [scrobble_result(1700000000)]),
        ),
        (
            lambda: client.update_now_playing(planted.SESSION_KEY, {"artist": "A", "track": "T"}),
            ok_now_playing(),
        ),
    ]


@pytest.mark.parametrize("which", range(4), ids=["getToken", "getSession", "scrobble", "nowPlaying"])
def test_every_call_is_a_form_post_to_the_configured_url(which):
    fake = FakeLastfm()
    client = LastfmClient(make_config(), transport=fake.transport)
    call, reply = _calls(client)[which]
    fake.queue(reply)

    call()

    assert len(fake.requests) == 1
    request = fake.requests[0]
    assert request.method == "POST"
    assert str(request.url) == "https://ws.audioscrobbler.com/2.0/"
    assert request.url.query == b""
    assert request.headers["content-type"].startswith("application/x-www-form-urlencoded")
    names = [name for name, _ in fake.form()]
    assert "format" not in names
    assert "api_key" in names and "api_sig" in names and "method" in names


@pytest.mark.parametrize("which", range(4), ids=["getToken", "getSession", "scrobble", "nowPlaying"])
def test_no_credential_travels_in_the_url(which):
    fake = FakeLastfm()
    client = LastfmClient(make_config(), transport=fake.transport)
    call, reply = _calls(client)[which]
    fake.queue(reply)

    call()

    planted.assert_no_secret(str(fake.requests[0].url), "the request URL")
    sig = dict(fake.form())["api_sig"]
    assert sig not in str(fake.requests[0].url)


def test_the_user_agent_names_osml_and_its_version():
    fake = FakeLastfm(ok_token("tok"))
    client = LastfmClient(make_config(), transport=fake.transport)

    client.get_token()

    version = tomllib.loads(PYPROJECT.read_text())["project"]["version"]
    assert fake.requests[0].headers["user-agent"] == f"OSML/{version}"


def test_the_simulator_url_from_the_config_is_used_as_is():
    fake = FakeLastfm(ok_token("tok"))
    config = make_config(api_url="http://127.0.0.1:8765/2.0/", insecure_api_url=True)
    client = LastfmClient(config, transport=fake.transport)

    client.get_token()

    assert str(fake.requests[0].url) == "http://127.0.0.1:8765/2.0/"


def test_get_token_sends_exactly_method_api_key_and_signature():
    fake = FakeLastfm(ok_token("tok"))
    client = LastfmClient(make_config(), transport=fake.transport)

    client.get_token()

    form = fake.form()
    assert sorted(name for name, _ in form) == ["api_key", "api_sig", "method"]
    values = dict(form)
    assert values["method"] == "auth.getToken"
    planted.assert_secret_equal(values["api_key"], planted.API_KEY, "api_key")
    # Signature written out from the spec (authentication spec §8), not the client's code.
    expected = hashlib.md5(
        ("api_key" + planted.API_KEY + "method" + "auth.getToken" + planted.API_SECRET).encode("utf-8")
    ).hexdigest()
    assert values["api_sig"] == expected


def test_the_shared_secret_is_never_sent():
    fake = FakeLastfm(ok_token("tok"))
    client = LastfmClient(make_config(), transport=fake.transport)

    client.get_token()

    planted.assert_no_secret(
        fake.requests[0].content.decode("utf-8"), "the request body", [planted.API_SECRET]
    )
    planted.assert_no_secret(
        str(dict(fake.requests[0].headers)), "the request headers", [planted.API_SECRET]
    )


def test_the_body_is_utf8():
    fake = FakeLastfm(ok_now_playing())
    client = LastfmClient(make_config(), transport=fake.transport)

    client.update_now_playing(planted.SESSION_KEY, {"artist": "Björk", "track": "Jóga"})

    body = fake.requests[0].content
    assert "Bj%C3%B6rk".encode() in body
    assert dict(fake.form())["artist"] == "Björk"
