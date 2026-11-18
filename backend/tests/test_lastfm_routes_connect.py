"""9D.1d (spec §7.4 Connect, §7.8 gate, 9-U10 connect, 9-U08b): ``POST
/settings/integrations/lastfm/connect`` works while ``running``: it calls
``auth.getToken`` through the gate (waiting at most 10 s), stores the token
encrypted with a 10-minute expiry (replacing any earlier one) and returns
Last.fm's fixed authorization URL carrying only ``api_key`` and ``token``.
Error 10 or 26 stops the server; any other failure is 503
``lastfm_unavailable`` and stores no token. ``off`` answers 403."""

import logging
from urllib.parse import parse_qsl, urlsplit

import httpx
import pytest

from app.services.lastfm_crypto import decrypt
from tests import lastfm_secrets as planted
from tests.lastfm_fake import FakeLastfm, failed, ok_token, xml_reply
from tests.lastfm_routes import (
    BASE,
    TOKEN_LIFETIME_MS,
    admin_id,
    clean_env,
    connection_row,
    install,
    open_rig,
    rows,
    seed_connection,
    second_user,
    seed_token,
)
from tests.lastfm_secrets import assert_no_secret, assert_secret_equal, valid_env

CONNECT = f"{BASE}/connect"


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


def _error(response):
    return response.status_code, response.json()["detail"]["error"]


def _stored_token(rig, owner):
    row = connection_row(rig, owner)
    if row is None or row["pending_token_enc"] is None:
        return None
    return decrypt(planted.CREDENTIAL_KEY, row["pending_token_enc"])


# ── per server state ─────────────────────────────────────────────────────────


def test_connect_while_off_is_403_and_sends_nothing(open_app_client):
    with open_rig(open_app_client, "off") as rig:
        response = rig.client.post(CONNECT, json={})

        assert _error(response) == (403, "lastfm_disabled")
        assert response.json()["detail"]["retryable"] is False
        assert rig.fake.requests == []
        assert connection_row(rig, admin_id(rig)) is None


def test_connect_while_stopped_at_startup_is_503_stopped(open_app_client):
    with open_rig(open_app_client, "stopped") as rig:
        response = rig.client.post(CONNECT, json={})

        assert _error(response) == (503, "lastfm_stopped")
        assert connection_row(rig, admin_id(rig)) is None


def test_connect_after_a_run_time_stop_is_503_stopped_and_sends_nothing(open_app_client):
    with open_rig(open_app_client) as rig:
        rig.state.stop("a fixed test cause")

        response = rig.client.post(CONNECT, json={})

        assert _error(response) == (503, "lastfm_stopped")
        assert rig.fake.requests == []


# ── success ──────────────────────────────────────────────────────────────────


def test_connect_returns_lastfms_authorization_url_with_only_key_and_token(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_token(planted.TOKEN))) as rig:
        response = rig.client.post(CONNECT, json={})

        assert response.status_code == 200
        body = response.json()
        assert set(body) == {"authorization_url", "expires_at"}
        url = body["authorization_url"]
        parts = urlsplit(url)
        assert (parts.scheme, parts.netloc, parts.path, parts.fragment) == ("https", "www.last.fm", "/api/auth/", "")
        assert url.startswith("https://www.last.fm/api/auth/?")
        query = parse_qsl(parts.query, keep_blank_values=True, strict_parsing=True)
        assert [name for name, _ in query] == ["api_key", "token"]
        assert_secret_equal(query[0][1], planted.API_KEY, "the URL's api_key")
        assert_secret_equal(query[1][1], planted.TOKEN, "the URL's token")


def test_connect_asks_lastfm_for_a_token(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_token(planted.TOKEN))) as rig:
        rig.client.post(CONNECT, json={})

        assert len(rig.fake.requests) == 1
        assert ("method", "auth.getToken") in rig.fake.form(0)


def test_connect_stores_the_token_encrypted_with_a_ten_minute_expiry(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_token(planted.TOKEN))) as rig:
        owner = admin_id(rig)

        body = rig.client.post(CONNECT, json={}).json()

        row = connection_row(rig, owner)
        assert body["expires_at"] == rig.wall.ms + TOKEN_LIFETIME_MS
        assert row["pending_token_expires_at"] == body["expires_at"]
        assert_no_secret(row["pending_token_enc"], "the stored token column")
        assert_secret_equal(_stored_token(rig, owner), planted.TOKEN, "the stored token")
        status = rig.client.get(BASE).json()
        assert (status["state"], status["approval_expires_at"]) == ("awaiting_authorization", body["expires_at"])


def test_the_database_file_holds_no_plaintext_token(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_token(planted.TOKEN))) as rig:
        assert rig.client.post(CONNECT, json={}).status_code == 200
        assert connection_row(rig, admin_id(rig))["pending_token_enc"] is not None
        rows(rig, "PRAGMA wal_checkpoint(TRUNCATE)")

        from pathlib import Path

        path = Path(rig.db.context.database_path)
        for candidate in (path, path.with_name(path.name + "-wal")):
            if candidate.exists():
                if planted.TOKEN.encode() in candidate.read_bytes():
                    raise AssertionError("plaintext token in the db file")


def test_a_new_connect_replaces_the_earlier_token(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_token("plantedSecondToken-abcdef0123456"))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner, token=planted.TOKEN)

        assert rig.client.post(CONNECT, json={}).status_code == 200

        assert_secret_equal(_stored_token(rig, owner), "plantedSecondToken-abcdef0123456", "the stored token")


def test_connect_while_connected_keeps_the_binding_and_the_opt_in(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_token(planted.TOKEN))) as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner, account="alpha", opted_in=True, needs_reconnect=True)

        assert rig.client.post(CONNECT, json={}).status_code == 200

        status = rig.client.get(BASE).json()
        assert (status["state"], status["connection_id"], status["needs_reconnect"]) == ("enabled", connection_id, True)


def test_a_token_with_url_characters_cannot_add_parameters_or_a_fragment(open_app_client):
    hostile = "tok&api_key=x&evil=1#frag?/../@h"
    escaped = hostile.replace("&", "&amp;")
    reply = xml_reply(f'<lfm status="ok"><token>{escaped}</token></lfm>')
    with open_rig(open_app_client, fake=FakeLastfm(reply)) as rig:
        url = rig.client.post(CONNECT, json={}).json()["authorization_url"]

        parts = urlsplit(url)
        assert (parts.scheme, parts.netloc, parts.path, parts.fragment) == ("https", "www.last.fm", "/api/auth/", "")
        query = parse_qsl(parts.query, keep_blank_values=True, strict_parsing=True)
        assert [name for name, _ in query] == ["api_key", "token"]
        assert_secret_equal(query[1][1], hostile, "the URL's token")


# ── failures ─────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("code", [10, 26])
def test_error_10_or_26_stops_the_server(open_app_client, code):
    with open_rig(open_app_client, fake=FakeLastfm(failed(code))) as rig:
        response = rig.client.post(CONNECT, json={})

        assert _error(response) == (503, "lastfm_stopped")
        assert rig.state.service.value == "stopped"
        assert connection_row(rig, admin_id(rig)) is None
        assert rig.client.get(BASE).json()["service"] == "stopped"


FAILURES = {
    "try later 8": failed(8),
    "try later 11": failed(11),
    "reconnect 9": failed(9),
    "rejected 13": failed(13),
    "rejected 4": failed(4),
    "http 500": xml_reply("oops", status=500),
    "http 429": xml_reply("slow down", status=429),
    "unreadable body": xml_reply("<not xml"),
    "network error": httpx.ConnectError("no route"),
    "read timeout": httpx.ReadTimeout("slow"),
}


@pytest.mark.parametrize("name", sorted(FAILURES))
def test_any_other_failure_is_503_unavailable_and_stores_no_token(open_app_client, name):
    with open_rig(open_app_client, fake=FakeLastfm(FAILURES[name])) as rig:
        response = rig.client.post(CONNECT, json={})

        assert _error(response) == (503, "lastfm_unavailable")
        assert response.json()["detail"]["retryable"] is True
        assert connection_row(rig, admin_id(rig)) is None
        assert rig.state.service.value == "running"


def test_a_failure_leaves_an_earlier_token_as_it_was(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(failed(11))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)
        before = connection_row(rig, owner)

        assert rig.client.post(CONNECT, json={}).status_code == 503

        assert connection_row(rig, owner) == before


def test_connect_waits_up_to_ten_seconds_for_the_gate(open_app_client):
    with open_app_client(env=valid_env(LASTFM_MIN_REQUEST_GAP_S="10")) as client:
        rig = install(client, FakeLastfm(ok_token(planted.TOKEN)))

        assert client.post(CONNECT, json={}).status_code == 200
        assert rig.gate_clock.waits == [10]


def test_a_gate_that_stays_busy_past_ten_seconds_is_503_unavailable_and_sends_nothing(open_app_client):
    with open_app_client(env=valid_env(LASTFM_MIN_REQUEST_GAP_S="11")) as client:
        rig = install(client, FakeLastfm(ok_token(planted.TOKEN)))

        response = client.post(CONNECT, json={})

        assert _error(response) == (503, "lastfm_unavailable")
        assert rig.fake.requests == []
        assert connection_row(rig, admin_id(rig)) is None


# ── the request body ─────────────────────────────────────────────────────────


@pytest.mark.parametrize("raw", [b"not json", b"[]", b'"x"'])
def test_a_body_that_is_not_a_json_object_is_422(open_app_client, raw):
    with open_rig(open_app_client, fake=FakeLastfm(ok_token(planted.TOKEN))) as rig:
        response = rig.client.post(CONNECT, content=raw, headers={"Content-Type": "application/json"})

        assert response.status_code == 422
        assert rig.fake.requests == []


def test_an_oversized_body_is_413(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_token(planted.TOKEN))) as rig:
        raw = b'{"x": "' + b"a" * 65_536 + b'"}'

        response = rig.client.post(CONNECT, content=raw, headers={"Content-Type": "application/json"})

        assert _error(response) == (413, "request_too_large")
        assert rig.fake.requests == []


# ── secrets ──────────────────────────────────────────────────────────────────


def test_the_key_and_token_appear_only_inside_the_authorization_url(open_app_client, caplog):
    caplog.set_level(logging.DEBUG)
    with open_rig(open_app_client, fake=FakeLastfm(ok_token(planted.TOKEN))) as rig:
        response = rig.client.post(CONNECT, json={})

        body = response.json()
        rest = response.text.replace(body["authorization_url"], "")
        assert_no_secret(rest, "the connect body outside the URL")
        assert_no_secret(str(response.headers), "the connect headers")
        assert_no_secret(caplog.text, "the captured logs")


@pytest.mark.parametrize("reply", [failed(10), failed(13), failed(11), xml_reply("x", status=502)])
def test_a_failed_connect_leaks_nothing(open_app_client, caplog, reply):
    caplog.set_level(logging.DEBUG)
    with open_rig(open_app_client, fake=FakeLastfm(reply)) as rig:
        response = rig.client.post(CONNECT, json={})

        assert response.status_code == 503
        assert_no_secret(response.text, "the error body")
        assert_no_secret(str(response.headers), "the error headers")
        assert_no_secret(caplog.text, "the captured logs")


# ── review r1 ────────────────────────────────────────────────────────────────


def test_r1_a_disconnect_while_connect_waits_on_lastfm_leaves_no_row(open_app_client):
    """Spec §7.4: a request in flight during a disconnect "finds no rows and changes nothing"."""
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)

        def reply(_request):
            assert rig.client.delete(BASE).status_code == 204
            return ok_token(planted.TOKEN)

        rig.fake.queue(reply)

        response = rig.client.post(CONNECT, json={})

        assert _error(response) == (410, "lastfm_approval_expired")
        assert connection_row(rig, owner) is None
        assert rig.client.get(BASE).json()["state"] == "not_connected"


def test_r1_another_users_disconnect_meanwhile_does_not_stop_my_connect(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _, b_headers = second_user(rig)

        def reply(_request):
            assert rig.client.delete(BASE, headers=b_headers).status_code == 204
            return ok_token(planted.TOKEN)

        rig.fake.queue(reply)

        assert rig.client.post(CONNECT, json={}).status_code == 200
        assert connection_row(rig, owner)["pending_token_enc"] is not None


def test_r1_a_disconnect_before_a_connect_does_not_stop_it(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_token(planted.TOKEN))) as rig:
        assert rig.client.delete(BASE).status_code == 204

        assert rig.client.post(CONNECT, json={}).status_code == 200


@pytest.mark.parametrize(
    "token",
    ["t" * 257, "has space-0123456789abcdef012345", "nl\n0123456789abcdef0123456789ab", "é0123456789abcdef0123456789abcd"],
    ids=["257 chars", "space", "newline", "non-ascii"],
)
def test_r1_an_implausible_token_is_unavailable_and_not_stored(open_app_client, token):
    reply = xml_reply(f'<lfm status="ok"><token>{token}</token></lfm>')
    with open_rig(open_app_client, fake=FakeLastfm(reply)) as rig:
        response = rig.client.post(CONNECT, json={})

        assert _error(response) == (503, "lastfm_unavailable")
        assert connection_row(rig, admin_id(rig)) is None


def test_r1_a_256_character_token_is_accepted(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_token("k" * 256))) as rig:
        assert rig.client.post(CONNECT, json={}).status_code == 200
