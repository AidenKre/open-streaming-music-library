"""9D.2a (spec §7.4 Enable, §7.3 "two separate facts", 9-U10 enable):
``POST /settings/integrations/lastfm/enable`` with ``{connection_id}`` is the
opt-in. It is one conditional update: ``opted_in = 1`` where the caller's row
has this ``connection_id``, a session key and ``needs_reconnect = 0``. It works
while ``running`` or ``stopped`` and answers 403 ``lastfm_disabled`` while
``off``; repeating it is harmless; a stale, unknown or another user's
``connection_id`` answers the same 409 ``lastfm_connection_changed``; it never
touches ``needs_reconnect`` and sends nothing to Last.fm."""

import logging

import pytest

from tests import lastfm_secrets as planted
from tests.lastfm_routes import (
    BASE,
    admin_id,
    clean_env,
    connection_row,
    open_rig,
    rows,
    second_user,
    seed_connection,
    seed_token,
)

ENABLE = f"{BASE}/enable"


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


def _error(response):
    return response.status_code, response.json()["detail"]["error"]


def _flags(rig, owner):
    row = connection_row(rig, owner)
    return row["opted_in"], row["needs_reconnect"]


# ── success, per server state ────────────────────────────────────────────────


@pytest.mark.parametrize("server_state", ["running", "stopped"])
def test_enable_opts_in_the_callers_current_connection(open_app_client, server_state):
    with open_rig(open_app_client, server_state) as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner)
        rig.wall.ms += 5_000

        response = rig.client.post(ENABLE, json={"connection_id": connection_id})

        assert response.status_code == 200, response.text
        assert response.json() == {"connection_id": connection_id, "state": "enabled"}
        row = connection_row(rig, owner)
        assert (row["opted_in"], row["needs_reconnect"]) == (True, False)
        assert row["connection_id"] == connection_id
        assert row["updated_at"] == rig.wall.ms
        assert rig.client.get(BASE).json()["state"] == "enabled"
        assert rig.fake.requests == []


def test_enable_works_after_a_run_time_stop(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner)
        rig.state.stop("a fixed test cause")

        response = rig.client.post(ENABLE, json={"connection_id": connection_id})

        assert response.status_code == 200, response.text
        assert _flags(rig, owner) == (True, False)


def test_enable_while_off_is_403_and_changes_nothing(open_app_client):
    with open_rig(open_app_client, "off") as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner)
        before = connection_row(rig, owner)

        response = rig.client.post(ENABLE, json={"connection_id": connection_id})

        assert _error(response) == (403, "lastfm_disabled")
        assert response.json()["detail"]["retryable"] is False
        assert connection_row(rig, owner) == before


def test_enabling_twice_is_harmless(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner)

        first = rig.client.post(ENABLE, json={"connection_id": connection_id})
        after_first = connection_row(rig, owner)
        second = rig.client.post(ENABLE, json={"connection_id": connection_id})

        assert (first.status_code, second.status_code) == (200, 200)
        assert first.json() == second.json()
        assert connection_row(rig, owner)["opted_in"] is True
        assert {k: v for k, v in connection_row(rig, owner).items() if k != "updated_at"} == {
            k: v for k, v in after_first.items() if k != "updated_at"
        }


# ── refusals ─────────────────────────────────────────────────────────────────


def test_enable_with_no_connection_is_409_not_connected(open_app_client):
    with open_rig(open_app_client) as rig:
        response = rig.client.post(ENABLE, json={"connection_id": "a1000000-0000-4000-8000-000000000001"})

        assert _error(response) == (409, "lastfm_not_connected")
        assert response.json()["detail"]["retryable"] is False
        assert connection_row(rig, admin_id(rig)) is None


def test_enable_while_only_awaiting_authorization_is_409_not_connected(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        token_enc = seed_token(rig, owner)

        response = rig.client.post(ENABLE, json={"connection_id": "a1000000-0000-4000-8000-000000000001"})

        assert _error(response) == (409, "lastfm_not_connected")
        row = connection_row(rig, owner)
        assert row["pending_token_enc"] == token_enc
        assert row["opted_in"] is False


def test_a_stale_enable_after_disconnect_and_reconnect_is_refused(open_app_client):
    # An opt-in request stuck on a device since the old connection cannot opt in the new one.
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        old_id = seed_connection(rig, owner)
        assert rig.client.delete(BASE).status_code == 204
        new_id = seed_connection(rig, owner)
        assert new_id != old_id

        stale = rig.client.post(ENABLE, json={"connection_id": old_id})

        assert _error(stale) == (409, "lastfm_connection_changed")
        assert stale.json()["detail"]["retryable"] is False
        assert connection_row(rig, owner)["opted_in"] is False
        assert rig.client.post(ENABLE, json={"connection_id": new_id}).status_code == 200  # control


def test_an_unknown_and_another_users_connection_id_answer_alike(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner)
        bea, _ = second_user(rig)
        beas_id = seed_connection(rig, bea, account="beta")
        beas_before = connection_row(rig, bea)

        foreign = rig.client.post(ENABLE, json={"connection_id": beas_id})
        unknown = rig.client.post(ENABLE, json={"connection_id": "a1000000-0000-4000-8000-0000000000ff"})
        not_a_uuid = rig.client.post(ENABLE, json={"connection_id": "anything"})

        assert _error(foreign) == (409, "lastfm_connection_changed")
        assert foreign.content == unknown.content == not_a_uuid.content
        assert connection_row(rig, owner)["opted_in"] is False
        assert connection_row(rig, bea) == beas_before


@pytest.mark.parametrize("opted_in", [False, True])
def test_enable_while_needs_reconnect_is_409_and_neither_flag_changes(open_app_client, opted_in):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner, opted_in=opted_in, needs_reconnect=True)

        response = rig.client.post(ENABLE, json={"connection_id": connection_id})

        assert _error(response) == (409, "lastfm_reconnect_required")
        assert response.json()["detail"]["retryable"] is False
        assert _flags(rig, owner) == (opted_in, True)


def test_enable_never_touches_needs_reconnect_of_an_opted_in_connection(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner, opted_in=True)

        assert rig.client.post(ENABLE, json={"connection_id": connection_id}).status_code == 200
        assert _flags(rig, owner) == (True, False)


def test_another_users_enable_never_touches_my_row(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        my_id = seed_connection(rig, owner)
        bea, bea_headers = second_user(rig)
        beas_id = seed_connection(rig, bea, account="beta")

        assert rig.client.post(ENABLE, json={"connection_id": my_id}, headers=bea_headers).status_code == 409
        assert rig.client.post(ENABLE, json={"connection_id": beas_id}, headers=bea_headers).status_code == 200
        assert connection_row(rig, owner)["opted_in"] is False
        assert connection_row(rig, bea)["opted_in"] is True


# ── the request body ─────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "raw",
    [b"not json", b"[]", b'"x"', b"{}", b'{"connection_id": null}', b'{"connection_id": 7}',
     b'{"connection_id": ["a"]}'],
)
def test_a_body_without_a_connection_id_string_is_422_and_changes_nothing(open_app_client, raw):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner)

        response = rig.client.post(ENABLE, content=raw, headers={"Content-Type": "application/json"})

        assert response.status_code == 422
        assert connection_row(rig, owner)["opted_in"] is False


def test_unknown_body_fields_are_ignored(open_app_client):
    with open_rig(open_app_client) as rig:
        connection_id = seed_connection(rig, admin_id(rig))

        response = rig.client.post(ENABLE, json={"connection_id": connection_id, "extra": 1})

        assert response.status_code == 200, response.text


def test_an_oversized_body_is_413(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner)
        raw = b'{"connection_id": "' + connection_id.encode() + b'", "x": "' + b"a" * 65_536 + b'"}'

        response = rig.client.post(ENABLE, content=raw, headers={"Content-Type": "application/json"})

        assert _error(response) == (413, "request_too_large")
        assert connection_row(rig, owner)["opted_in"] is False


def test_enable_needs_a_signed_in_user(open_app_client):
    with open_rig(open_app_client) as rig:
        connection_id = seed_connection(rig, admin_id(rig))
        headers = dict(rig.client.headers)
        del rig.client.headers["Authorization"]

        response = rig.client.post(ENABLE, json={"connection_id": connection_id})

        assert response.status_code == 401
        assert connection_row(rig, admin_id(rig))["opted_in"] is False
        control = rig.client.post(ENABLE, json={"connection_id": connection_id}, headers=headers)
        assert control.status_code == 200


# ── secrets ──────────────────────────────────────────────────────────────────


def test_no_enable_answer_or_log_carries_a_secret_or_ciphertext(open_app_client, caplog):
    caplog.set_level(logging.DEBUG)
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner)
        [(session_key_enc,)] = rows(
            rig, "SELECT session_key_enc FROM lastfm_connections WHERE owner_id = ?", (owner,)
        )
        answers = [
            rig.client.post(ENABLE, json={"connection_id": "a1000000-0000-4000-8000-0000000000ff"}),
            rig.client.post(ENABLE, json={"connection_id": connection_id}),
            rig.client.post(ENABLE, content=b"{}", headers={"Content-Type": "application/json"}),
        ]

        assert [r.status_code for r in answers] == [409, 200, 422]
        for index, response in enumerate(answers):
            text = response.text + str(dict(response.headers))
            planted.assert_no_secret(text, f"enable answer {index}", (*planted.ALL, session_key_enc))
        planted.assert_no_secret(caplog.text, "the captured log", (*planted.ALL, session_key_enc))
