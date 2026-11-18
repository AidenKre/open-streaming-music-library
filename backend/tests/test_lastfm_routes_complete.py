"""9D.1d (spec §7.4 Complete, 9-U10 complete, 9-U08b/c): ``POST
/settings/integrations/lastfm/complete`` calls ``auth.getSession`` with the
caller's stored token and applies every row of the spec's table; it binds only
if the row still holds the token it sent; no live token or an undecryptable
one is 410; an unusable account name is 503 and binds nothing."""

import logging
import uuid

import httpx
import pytest

from app.services.lastfm_crypto import decrypt, encrypt
from tests import lastfm_secrets as planted
from tests.lastfm_fake import FakeLastfm, failed, ok_session, xml_reply
from tests.lastfm_routes import (
    BASE,
    admin_id,
    clean_env,
    connection_row,
    install,
    open_rig,
    second_user,
    seed_connection,
    seed_token,
)
from tests.lastfm_secrets import assert_no_secret, assert_secret_equal, valid_env

COMPLETE = f"{BASE}/complete"
NEW_KEY = "planted-NEW-session-key-0001"
SECRETS = [*planted.ALL, NEW_KEY]


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


def _error(response):
    detail = response.json()["detail"]
    return response.status_code, detail["error"], detail["retryable"]


def _key(row):
    return decrypt(planted.CREDENTIAL_KEY, row["session_key_enc"])


def _token(row):
    return None if row["pending_token_enc"] is None else decrypt(planted.CREDENTIAL_KEY, row["pending_token_enc"])


# ── per server state ─────────────────────────────────────────────────────────


def test_complete_while_off_is_403(open_app_client):
    with open_rig(open_app_client, "off") as rig:
        seed_token(rig, admin_id(rig))

        assert _error(rig.client.post(COMPLETE, json={})) == (403, "lastfm_disabled", False)
        assert rig.fake.requests == []


def test_complete_while_stopped_at_startup_is_503_stopped(open_app_client):
    with open_rig(open_app_client, "stopped") as rig:
        seed_token(rig, admin_id(rig))

        assert _error(rig.client.post(COMPLETE, json={})) == (503, "lastfm_stopped", False)


def test_complete_after_a_run_time_stop_is_503_stopped_and_sends_nothing(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)
        rig.state.stop("a fixed test cause")

        assert _error(rig.client.post(COMPLETE, json={})) == (503, "lastfm_stopped", False)
        assert rig.fake.requests == []
        assert_secret_equal(_token(connection_row(rig, owner)), planted.TOKEN, "the kept token")


# ── the table: success rows ──────────────────────────────────────────────────


def test_a_first_binding_stores_the_key_encrypted_and_mints_a_connection_id(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", planted.SESSION_KEY))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)

        response = rig.client.post(COMPLETE, json={})

        assert response.status_code == 200
        body = response.json()
        assert set(body) == {"connection_id", "account_name", "state"}
        assert (body["account_name"], body["state"]) == ("alpha", "connected_disabled")
        uuid.UUID(body["connection_id"])
        row = connection_row(rig, owner)
        assert row["connection_id"] == body["connection_id"]
        assert (row["account_name"], row["opted_in"], row["needs_reconnect"]) == ("alpha", False, False)
        assert_no_secret(row["session_key_enc"], "the stored key column")
        assert_secret_equal(_key(row), planted.SESSION_KEY, "the stored session key")
        assert (row["pending_token_enc"], row["pending_token_expires_at"]) == (None, None)


def test_complete_sends_the_stored_token_to_auth_get_session(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", planted.SESSION_KEY))) as rig:
        seed_token(rig, admin_id(rig))

        rig.client.post(COMPLETE, json={})

        form = dict(rig.fake.form(0))
        assert form["method"] == "auth.getSession"
        assert_secret_equal(form["token"], planted.TOKEN, "the token sent")


def test_each_binding_gets_a_new_connection_id(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(*[ok_session("alpha", planted.SESSION_KEY)] * 2)) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)
        first = rig.client.post(COMPLETE, json={}).json()["connection_id"]
        rig.client.delete(BASE)
        seed_token(rig, owner)
        rig.cooldown_clock.advance(rig.state.config.min_request_gap_s)  # OPEN-9-03: past Finish's limit

        second = rig.client.post(COMPLETE, json={}).json()["connection_id"]

        assert first != second


@pytest.mark.parametrize("opted_in, state", [(True, "enabled"), (False, "connected_disabled")])
def test_the_same_account_repairs_the_connection_and_keeps_id_and_opt_in(open_app_client, opted_in, state):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", NEW_KEY))) as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner, account="alpha", opted_in=opted_in, needs_reconnect=True)
        seed_token(rig, owner)

        response = rig.client.post(COMPLETE, json={})

        assert response.status_code == 200
        assert response.json() == {"connection_id": connection_id, "account_name": "alpha", "state": state}
        row = connection_row(rig, owner)
        assert (row["connection_id"], row["opted_in"], row["needs_reconnect"]) == (connection_id, opted_in, False)
        assert_secret_equal(_key(row), NEW_KEY, "the replaced session key")
        assert row["pending_token_enc"] is None


def test_a_different_account_is_409_mismatch_and_binds_nothing(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("beta", NEW_KEY))) as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner, account="alpha", opted_in=True)
        seed_token(rig, owner)

        response = rig.client.post(COMPLETE, json={})

        assert _error(response) == (409, "lastfm_account_mismatch", False)
        detail = response.json()["detail"]
        assert (detail["stored_account"], detail["approved_account"]) == ("alpha", "beta")
        row = connection_row(rig, owner)
        assert (row["connection_id"], row["account_name"], row["opted_in"]) == (connection_id, "alpha", True)
        assert_secret_equal(_key(row), planted.SESSION_KEY, "the kept session key")
        assert row["pending_token_enc"] is None
        assert_no_secret(response.text, "the mismatch body", secrets=SECRETS)


# ── the table: Last.fm errors ────────────────────────────────────────────────


def test_error_14_is_not_authorized_yet_and_keeps_the_token(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(failed(14))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)
        before = connection_row(rig, owner)

        assert _error(rig.client.post(COMPLETE, json={})) == (409, "lastfm_not_authorized_yet", True)
        assert connection_row(rig, owner) == before


@pytest.mark.parametrize("code", [15, 4])
def test_error_15_or_4_is_approval_expired_and_clears_the_token(open_app_client, code):
    with open_rig(open_app_client, fake=FakeLastfm(failed(code))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)

        assert _error(rig.client.post(COMPLETE, json={})) == (410, "lastfm_approval_expired", False)
        row = connection_row(rig, owner)
        assert row is None or (row["pending_token_enc"], row["session_key_enc"]) == (None, None)
        assert rig.client.get(BASE).json()["state"] == "not_connected"


def test_error_15_during_a_reconnect_keeps_the_binding(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(failed(15))) as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner, opted_in=True, needs_reconnect=True)
        seed_token(rig, owner)

        rig.client.post(COMPLETE, json={})

        row = connection_row(rig, owner)
        assert (row["connection_id"], row["opted_in"], row["needs_reconnect"], row["pending_token_enc"]) == (
            connection_id, True, True, None,
        )


TRY_LATER = {
    "8": failed(8),
    "11": failed(11),
    "16": failed(16),
    "29": failed(29),
    "http 500": xml_reply("x", status=500),
    "http 429": xml_reply("x", status=429),
    "network": httpx.ConnectError("no route"),
    "timeout": httpx.ReadTimeout("slow"),
    "unreadable": xml_reply("<lfm"),
}


@pytest.mark.parametrize("name", sorted(TRY_LATER))
def test_a_try_later_answer_is_unavailable_and_keeps_the_token(open_app_client, name):
    with open_rig(open_app_client, fake=FakeLastfm(TRY_LATER[name])) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)
        before = connection_row(rig, owner)

        assert _error(rig.client.post(COMPLETE, json={})) == (503, "lastfm_unavailable", True)
        assert connection_row(rig, owner) == before


@pytest.mark.parametrize("code", [10, 26])
def test_error_10_or_26_stops_the_server(open_app_client, code):
    with open_rig(open_app_client, fake=FakeLastfm(failed(code))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)

        assert _error(rig.client.post(COMPLETE, json={})) == (503, "lastfm_stopped", False)
        assert rig.state.service.value == "stopped"
        assert connection_row(rig, owner)["session_key_enc"] is None


@pytest.mark.parametrize("code", [9, 13, 6])
def test_an_answer_not_in_the_table_is_unavailable_and_binds_nothing(open_app_client, code):
    with open_rig(open_app_client, fake=FakeLastfm(failed(code))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)

        assert _error(rig.client.post(COMPLETE, json={})) == (503, "lastfm_unavailable", True)
        assert connection_row(rig, owner)["session_key_enc"] is None
        assert rig.state.service.value == "running"


# ── no live token, undecryptable, replaced ───────────────────────────────────


def test_no_row_is_410_and_sends_nothing(open_app_client):
    with open_rig(open_app_client) as rig:
        assert _error(rig.client.post(COMPLETE, json={})) == (410, "lastfm_approval_expired", False)
        assert rig.fake.requests == []


def test_a_connected_row_without_a_token_is_410_and_keeps_the_binding(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, opted_in=True)
        before = connection_row(rig, owner)

        assert _error(rig.client.post(COMPLETE, json={}))[:2] == (410, "lastfm_approval_expired")
        assert rig.fake.requests == []
        assert connection_row(rig, owner) == before


@pytest.mark.parametrize("offset_ms", [0, -1])
def test_an_expired_token_is_410_sends_nothing_and_is_cleared(open_app_client, offset_ms):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner, expires_at=rig.wall.ms + offset_ms)

        assert _error(rig.client.post(COMPLETE, json={}))[:2] == (410, "lastfm_approval_expired")
        assert rig.fake.requests == []
        row = connection_row(rig, owner)
        assert row is None or row["pending_token_enc"] is None


def test_a_token_that_will_not_decrypt_is_410_sends_nothing_and_binds_nothing(open_app_client, caplog):
    caplog.set_level(logging.DEBUG)
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        other_key = encrypt(
            __import__("base64").urlsafe_b64encode(b"another-planted-key-of-32-bytes!").decode(), planted.TOKEN
        )
        rig.db.store_lastfm_pending_token(other_key, rig.wall.ms + 60_000, rig.wall.ms, owner_id=owner)

        response = rig.client.post(COMPLETE, json={})

        assert _error(response)[:2] == (410, "lastfm_approval_expired")
        assert rig.fake.requests == []
        row = connection_row(rig, owner)
        assert row is None or (row["session_key_enc"], row["pending_token_enc"]) == (None, None)
        assert_no_secret(caplog.text, "the captured logs", secrets=[*SECRETS, other_key])
        assert_no_secret(response.text, "the 410 body", secrets=[*SECRETS, other_key])


def test_a_token_replaced_by_a_newer_connect_meanwhile_is_410_and_binds_nothing(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", NEW_KEY))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)
        newer = encrypt(planted.CREDENTIAL_KEY, "plantedNewerToken-0123456789abc")

        def replace(_timeout):
            rig.db.store_lastfm_pending_token(newer, rig.wall.ms + 600_000, rig.wall.ms, owner_id=owner)

        rig.gate_clock.on_wait.append(replace)

        assert _error(rig.client.post(COMPLETE, json={}))[:2] == (410, "lastfm_approval_expired")
        row = connection_row(rig, owner)
        assert (row["session_key_enc"], row["pending_token_enc"]) == (None, newer)


def test_a_disconnect_meanwhile_is_410_and_leaves_no_row(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", NEW_KEY))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)
        rig.gate_clock.on_wait.append(lambda _t: rig.db.disconnect_lastfm(owner_id=owner))

        assert _error(rig.client.post(COMPLETE, json={}))[:2] == (410, "lastfm_approval_expired")
        assert connection_row(rig, owner) is None


def test_a_second_complete_after_success_is_410(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", planted.SESSION_KEY))) as rig:
        seed_token(rig, admin_id(rig))
        assert rig.client.post(COMPLETE, json={}).status_code == 200
        rig.cooldown_clock.advance(rig.state.config.min_request_gap_s)  # OPEN-9-03: past Finish's limit

        assert _error(rig.client.post(COMPLETE, json={}))[:2] == (410, "lastfm_approval_expired")
        assert len(rig.fake.requests) == 1


# ── the account name ─────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "name",
    ["a" * 65, "tab\there", "del\x7fname", "nel\u0085name"],
    ids=["65 chars", "tab", "DEL", "NEL"],
)
def test_an_unusable_account_name_is_503_and_binds_nothing(open_app_client, name):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session(name, NEW_KEY))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)

        response = rig.client.post(COMPLETE, json={})

        assert _error(response) == (503, "lastfm_unavailable", True)
        assert connection_row(rig, owner)["session_key_enc"] is None
        assert_no_secret(response.text, "the 503 body", secrets=SECRETS)


def test_a_64_character_account_name_binds(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("n" * 64, NEW_KEY))) as rig:
        seed_token(rig, admin_id(rig))

        assert rig.client.post(COMPLETE, json={}).json()["account_name"] == "n" * 64


# ── the gate, the body, secrets, ownership ───────────────────────────────────


def test_a_gate_busy_past_ten_seconds_is_unavailable_and_keeps_the_token(open_app_client):
    with open_app_client(env=valid_env(LASTFM_MIN_REQUEST_GAP_S="11")) as client:
        rig = install(client, FakeLastfm(ok_session("alpha", NEW_KEY)))
        owner = admin_id(rig)
        seed_token(rig, owner)

        assert _error(client.post(COMPLETE, json={})) == (503, "lastfm_unavailable", True)
        assert rig.fake.requests == []
        assert_secret_equal(_token(connection_row(rig, owner)), planted.TOKEN, "the kept token")


@pytest.mark.parametrize("raw", [b"nope", b"[]"])
def test_a_body_that_is_not_a_json_object_is_422(open_app_client, raw):
    with open_rig(open_app_client) as rig:
        seed_token(rig, admin_id(rig))

        response = rig.client.post(COMPLETE, content=raw, headers={"Content-Type": "application/json"})

        assert response.status_code == 422
        assert rig.fake.requests == []


def test_an_oversized_body_is_413(open_app_client):
    with open_rig(open_app_client) as rig:
        raw = b'{"x": "' + b"a" * 65_536 + b'"}'

        response = rig.client.post(COMPLETE, content=raw, headers={"Content-Type": "application/json"})

        assert response.status_code == 413


@pytest.mark.parametrize(
    "reply",
    [ok_session("alpha", NEW_KEY), failed(14), failed(15), failed(11), failed(10), ok_session("a" * 65, NEW_KEY)],
    ids=["ok", "14", "15", "11", "10", "bad name"],
)
def test_no_complete_answer_or_log_carries_a_secret(open_app_client, caplog, reply):
    caplog.set_level(logging.DEBUG)
    with open_rig(open_app_client, fake=FakeLastfm(reply)) as rig:
        seed_token(rig, admin_id(rig))

        response = rig.client.post(COMPLETE, json={})

        assert len(rig.fake.requests) == 1
        assert response.status_code in (200, 409, 410, 503)
        stored = connection_row(rig, admin_id(rig))
        ciphertexts = [v for v in (stored["session_key_enc"], stored["pending_token_enc"]) if v]
        assert_no_secret(response.text, "the complete body", secrets=[*SECRETS, *ciphertexts])
        assert_no_secret(str(response.headers), "the complete headers", secrets=SECRETS)
        assert_no_secret(caplog.text, "the captured logs", secrets=SECRETS)


def test_user_b_cannot_complete_with_user_as_token(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", NEW_KEY))) as rig:
        a = admin_id(rig)
        seed_token(rig, a)
        before = connection_row(rig, a)
        b, b_headers = second_user(rig)

        response = rig.client.post(COMPLETE, json={}, headers=b_headers)

        assert _error(response)[:2] == (410, "lastfm_approval_expired")
        assert rig.fake.requests == []
        assert connection_row(rig, a) == before
        assert connection_row(rig, b) is None


def test_two_users_completing_each_bind_only_their_own_account(open_app_client):
    fake = FakeLastfm(ok_session("alpha", planted.SESSION_KEY), ok_session("beta", NEW_KEY))
    with open_rig(open_app_client, fake=fake) as rig:
        a = admin_id(rig)
        b, b_headers = second_user(rig)
        seed_token(rig, a, token="plantedTokenOfA-0123456789abcdef")
        seed_token(rig, b, token="plantedTokenOfB-0123456789abcdef")

        assert rig.client.post(COMPLETE, json={}).json()["account_name"] == "alpha"
        assert rig.client.post(COMPLETE, json={}, headers=b_headers).json()["account_name"] == "beta"

        assert_secret_equal(dict(fake.form(0))["token"], "plantedTokenOfA-0123456789abcdef", "A's token sent")
        assert_secret_equal(dict(fake.form(1))["token"], "plantedTokenOfB-0123456789abcdef", "B's token sent")
        assert_secret_equal(_key(connection_row(rig, a)), planted.SESSION_KEY, "A's session key")
        assert_secret_equal(_key(connection_row(rig, b)), NEW_KEY, "B's session key")


# ── review r1 ────────────────────────────────────────────────────────────────


def test_r1_a_second_complete_while_one_is_in_flight_is_refused_at_once(open_app_client):
    """One complete per user at a time: a second one never queues at the gate."""
    from app.library import Library
    from app.services.lastfm_errors import LastfmError

    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", NEW_KEY))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)
        seen = []

        def racing(_timeout):
            if not seen:
                # OPEN-9-03: past Finish's per-user limit, so the in-flight rule decides.
                rig.cooldown_clock.advance(rig.state.config.min_request_gap_s)
                try:
                    rig.accounts.complete(Library(rig.db, owner))
                except LastfmError as error:
                    seen.append((error.status, error.code))
                else:
                    seen.append("accepted")

        rig.gate_clock.on_wait.append(racing)

        assert rig.client.post(COMPLETE, json={}).status_code == 200
        assert seen == [(503, "lastfm_unavailable")]
        assert len(rig.fake.requests) == 1


def test_r1_a_finished_complete_frees_the_next_one_also_after_an_error(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(failed(14), failed(14))) as rig:
        seed_token(rig, admin_id(rig))

        codes = []
        for _ in range(2):
            codes.append(_error(rig.client.post(COMPLETE, json={}))[1])
            rig.cooldown_clock.advance(rig.state.config.min_request_gap_s)  # OPEN-9-03

        assert codes == ["lastfm_not_authorized_yet"] * 2


@pytest.mark.parametrize(
    "name",
    ["rlo‮name", "zw​sp", "ls sep", "ps sep", "bom﻿name"],
    ids=["bidi override", "zero width space", "line separator", "paragraph separator", "BOM"],
)
def test_r1_invisible_or_reordering_characters_make_a_name_unusable(open_app_client, name):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session(name, NEW_KEY))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)

        assert _error(rig.client.post(COMPLETE, json={})) == (503, "lastfm_unavailable", True)
        assert connection_row(rig, owner)["session_key_enc"] is None


# ── 9-fix-r1: the session key's shape (9-R1-05), the token re-read in the gate (9-R1-20)


@pytest.mark.parametrize(
    "key",
    ["k" * 257, "k" * 900_000, "space in key", "tab\tkey", "non-ascii-é-key"],
    ids=["257 chars", "900 KB", "space", "tab", "non-ASCII"],
)
def test_r1_an_implausible_session_key_is_503_and_binds_nothing(open_app_client, key):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", key))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)

        response = rig.client.post(COMPLETE, json={})

        assert response.status_code == 503
        assert _error(response) == (503, "lastfm_unavailable", True)
        assert connection_row(rig, owner)["session_key_enc"] is None
        assert_no_secret(response.text, "the 503 body", secrets=SECRETS)


def test_r1_a_256_character_session_key_binds(open_app_client):
    key = "K" * 256
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", key))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)

        assert rig.client.post(COMPLETE, json={}).status_code == 200
        assert_secret_equal(_key(connection_row(rig, owner)), key, "the stored session key")


def test_r1_a_disconnect_during_the_gate_wait_sends_nothing(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", NEW_KEY))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)
        rig.gate_clock.on_wait.append(lambda _t: rig.db.disconnect_lastfm(owner_id=owner))

        assert _error(rig.client.post(COMPLETE, json={}))[:2] == (410, "lastfm_approval_expired")
        assert rig.fake.requests == []
        assert connection_row(rig, owner) is None


def test_r1_a_newer_connect_during_the_gate_wait_sends_nothing_and_keeps_the_newer_token(
    open_app_client,
):
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", NEW_KEY))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)
        newer = encrypt(planted.CREDENTIAL_KEY, "plantedNewerToken-0123456789abc")

        def replace(_timeout):
            rig.db.store_lastfm_pending_token(newer, rig.wall.ms + 600_000, rig.wall.ms, owner_id=owner)

        rig.gate_clock.on_wait.append(replace)

        assert _error(rig.client.post(COMPLETE, json={}))[:2] == (410, "lastfm_approval_expired")
        assert rig.fake.requests == []
        assert connection_row(rig, owner)["pending_token_enc"] == newer
