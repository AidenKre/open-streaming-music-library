"""9D.1d (spec §7.3 state derivation, §7.4 status body, 9-U08, 9-U10):
``GET /settings/integrations/lastfm`` answers 200 with the caller's status in
every server state. Fields that do not apply are null; counts cover 30 days
and are 0 for a user who never connected; ``recent_problems`` holds the 20
newest problems; user B never sees user A's status."""

import pytest

from app.services.lastfm_accounts import lastfm_available
from app.services.lastfm_state import LastfmService
from tests.lastfm_routes import (
    BASE,
    install,
    DAY_MS,
    admin_id,
    clean_env,
    open_rig,
    rows,
    second_user,
    seed_connection,
    seed_outbox,
    seed_token,
)
from tests.lastfm_secrets import assert_no_secret, valid_env

ZERO = {"pending": 0, "sent": 0, "ignored": 0, "failed": 0, "dropped": 0}
KEYS = {
    "service", "state", "needs_reconnect", "account_name", "connection_id",
    "approval_expires_at", "counts", "recent_problems", "last_success_at",
    "app_name",  # signoff-9-lastfm-app-name (DEV-9-06)
}


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


def _never_connected(service):
    return {
        "service": service,
        "state": "not_connected",
        "needs_reconnect": None,
        "account_name": None,
        "connection_id": None,
        "approval_expires_at": None,
        "counts": ZERO,
        "recent_problems": [],
        "last_success_at": None,
        "app_name": None,
    }


def _status(rig, headers=None):
    response = rig.client.get(BASE, headers=headers)
    assert response.status_code == 200, response.text
    return response.json()


# ── server state ─────────────────────────────────────────────────────────────


@pytest.mark.parametrize("server_state", ["off", "running", "stopped"])
def test_a_user_who_never_connected_gets_the_null_body_in_every_server_state(open_app_client, server_state):
    with open_rig(open_app_client, server_state) as rig:
        assert _status(rig) == _never_connected(server_state)


def test_a_run_time_stop_is_reported_as_stopped(open_app_client):
    with open_rig(open_app_client) as rig:
        rig.state.stop("a fixed test cause")

        assert _status(rig)["service"] == "stopped"


def test_the_status_reads_the_stored_connection_while_off(open_app_client):
    with open_rig(open_app_client, "off") as rig:
        seed_connection(rig, admin_id(rig), account="alpha", opted_in=True)

        body = _status(rig)

        assert (body["service"], body["state"], body["account_name"]) == ("off", "enabled", "alpha")


@pytest.mark.parametrize(
    "server_state, available",
    [("off", False), ("running", True), ("stopped", False)],  # stopped = invalid config at startup
)
def test_last_fm_is_available_when_enabled_and_validly_configured(open_app_client, server_state, available):
    with open_rig(open_app_client, server_state) as rig:
        assert lastfm_available(rig.state) is available


def test_a_run_time_stop_keeps_last_fm_available(open_app_client):
    # 9D.2a DEV-9D2a-02, resolved for spec §7.2: "available" means configured.
    with open_rig(open_app_client) as rig:
        rig.state.stop("a fixed test cause")

        assert rig.state.service is LastfmService.STOPPED
        assert lastfm_available(rig.state) is True


# ── the derived state ────────────────────────────────────────────────────────


def test_a_live_token_is_awaiting_authorization(open_app_client):
    with open_rig(open_app_client) as rig:
        expires = rig.wall.ms + 1
        seed_token(rig, admin_id(rig), expires_at=expires)

        body = _status(rig)

        assert body == {
            **_never_connected("running"),
            "state": "awaiting_authorization",
            "approval_expires_at": expires,
        }


@pytest.mark.parametrize("offset_ms", [0, -1, -60_000])
def test_an_expired_token_is_not_connected(open_app_client, offset_ms):
    with open_rig(open_app_client) as rig:
        seed_token(rig, admin_id(rig), expires_at=rig.wall.ms + offset_ms)

        assert _status(rig) == _never_connected("running")


def test_a_bound_account_not_opted_in_is_connected_disabled(open_app_client):
    with open_rig(open_app_client) as rig:
        connection_id = seed_connection(rig, admin_id(rig), account="alpha")

        assert _status(rig) == {
            **_never_connected("running"),
            "state": "connected_disabled",
            "needs_reconnect": False,
            "account_name": "alpha",
            "connection_id": connection_id,
        }


def test_an_opted_in_account_is_enabled(open_app_client):
    with open_rig(open_app_client) as rig:
        connection_id = seed_connection(rig, admin_id(rig), account="alpha", opted_in=True)

        body = _status(rig)

        assert (body["state"], body["connection_id"], body["needs_reconnect"]) == (
            "enabled", connection_id, False,
        )


@pytest.mark.parametrize("opted_in, state", [(True, "enabled"), (False, "connected_disabled")])
def test_needs_reconnect_is_shown_and_leaves_the_state_alone(open_app_client, opted_in, state):
    with open_rig(open_app_client) as rig:
        seed_connection(rig, admin_id(rig), opted_in=opted_in, needs_reconnect=True)

        body = _status(rig)

        assert (body["state"], body["needs_reconnect"]) == (state, True)


def test_a_reconnect_in_progress_keeps_the_connected_state_and_shows_the_approval_expiry(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, opted_in=True, needs_reconnect=True)
        expires = rig.wall.ms + 300_000
        seed_token(rig, owner, expires_at=expires)

        body = _status(rig)

        assert (body["state"], body["needs_reconnect"], body["approval_expires_at"]) == (
            "enabled", True, expires,
        )


# ── counts, problems, last success ───────────────────────────────────────────


def test_counts_cover_pending_rows_and_terminal_rows_of_the_last_30_days(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, opted_in=True)
        now = rig.wall.ms
        recent, old = now - 29 * DAY_MS, now - 31 * DAY_MS
        seed_outbox(rig, owner, status="pending")
        seed_outbox(rig, owner, status="pending", listened_at_s=1_000)
        for _ in range(3):
            seed_outbox(rig, owner, status="sent", done_at=recent)
        seed_outbox(rig, owner, status="sent", done_at=old)
        seed_outbox(rig, owner, status="ignored", code="1", done_at=recent)
        seed_outbox(rig, owner, status="failed", code="13", done_at=recent)
        seed_outbox(rig, owner, status="failed", code="13", done_at=old)
        seed_outbox(rig, owner, status="dropped", code="too_old", done_at=recent)
        seed_outbox(rig, owner, status="dropped", code="no_answer", done_at=recent)

        assert _status(rig)["counts"] == {"pending": 2, "sent": 3, "ignored": 1, "failed": 1, "dropped": 2}


def test_recent_problems_are_the_20_newest_problems_with_ms_listen_times(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, opted_in=True)
        now = rig.wall.ms
        statuses = [("ignored", "1"), ("failed", "13"), ("dropped", "too_many_tries")]
        expected = []
        for i in range(22):  # i = 0 is the newest
            status, code = statuses[i % 3]
            seed_outbox(
                rig, owner, status=status, code=code, done_at=now - 1_000 * (i + 1),
                listened_at_s=1_799_000_000 + i, artist=f"Artist {i}", track=f"Track {i}",
            )
            expected.append({
                "artist": f"Artist {i}",
                "track": f"Track {i}",
                "listened_at": (1_799_000_000 + i) * 1000,
                "status": status,
                "code": code,
            })
        seed_outbox(rig, owner, status="sent", done_at=now - 10)
        seed_outbox(rig, owner, status="pending")

        assert _status(rig)["recent_problems"] == expected[:20]


def test_problems_older_than_30_days_are_not_listed(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner)
        seed_outbox(rig, owner, status="failed", code="13", done_at=rig.wall.ms - 31 * DAY_MS)

        assert _status(rig)["recent_problems"] == []


def test_last_success_is_the_newest_sent_time(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, opted_in=True)
        now = rig.wall.ms
        seed_outbox(rig, owner, status="sent", done_at=now - 5_000)
        seed_outbox(rig, owner, status="sent", done_at=now - 2_000)
        seed_outbox(rig, owner, status="failed", code="13", done_at=now - 1_000)

        assert _status(rig)["last_success_at"] == now - 2_000


def test_no_sent_row_means_an_unknown_last_success(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, opted_in=True)
        seed_outbox(rig, owner, status="pending")
        seed_outbox(rig, owner, status="failed", code="13", done_at=rig.wall.ms - 1)

        assert _status(rig)["last_success_at"] is None


# ── ownership and secrets ────────────────────────────────────────────────────


def test_user_b_never_sees_user_as_status(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, account="alpha", opted_in=True)
        seed_token(rig, owner)
        seed_outbox(rig, owner, status="pending")
        seed_outbox(rig, owner, status="sent", done_at=rig.wall.ms - 1)
        seed_outbox(rig, owner, status="failed", code="13", done_at=rig.wall.ms - 1)
        _, b_headers = second_user(rig)

        response = rig.client.get(BASE, headers=b_headers)

        assert response.status_code == 200
        assert response.json() == _never_connected("running")
        assert "alpha" not in response.text


def test_user_b_sees_their_own_connection_not_as(open_app_client):
    with open_rig(open_app_client) as rig:
        seed_connection(rig, admin_id(rig), account="alpha")
        b, b_headers = second_user(rig)
        b_connection = seed_connection(rig, b, account="beta", opted_in=True)

        body = _status(rig, b_headers)

        assert (body["account_name"], body["connection_id"], body["state"]) == ("beta", b_connection, "enabled")


def test_the_status_carries_no_secret_and_no_ciphertext(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, opted_in=True)
        seed_token(rig, owner)
        stored = rows(rig, "SELECT session_key_enc, pending_token_enc FROM lastfm_connections")

        response = rig.client.get(BASE)

        assert response.status_code == 200
        assert response.json()["account_name"] == "alpha"
        assert_no_secret(response.text, "the status body")
        assert_no_secret(str(response.headers), "the status headers")
        for session_key_enc, token_enc in stored:
            assert_no_secret(response.text, "the status body", secrets=[session_key_enc, token_enc])


def test_the_status_body_has_exactly_the_specs_fields(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, opted_in=True)
        seed_outbox(rig, owner, status="failed", code="13", done_at=rig.wall.ms - 1)

        body = _status(rig)

        assert set(body) == KEYS
        assert set(body["counts"]) == set(ZERO)
        assert set(body["recent_problems"][0]) == {"artist", "track", "listened_at", "status", "code"}


def test_the_startup_holder_shares_the_servers_state(open_app_client):
    """Without the test's install(): the real startup holder serves the route."""
    with open_app_client(env={}) as client:
        response = client.get(BASE)

        assert response.status_code == 200
        assert response.json()["service"] == "off"
        assert client.app.state.lastfm_accounts.state is client.app.state.lastfm



def test_r1_the_startup_holder_uses_the_configured_gap_and_closes_its_client(open_app_client):
    from tests.lastfm_secrets import valid_env

    with open_app_client(env=valid_env(LASTFM_MIN_REQUEST_GAP_S="7")) as client:
        accounts = client.app.state.lastfm_accounts
        assert accounts.gate is not None and accounts.gate._gap_s == 7
        http = accounts.client._client
        assert not http.is_closed

    assert http.is_closed


@pytest.mark.parametrize("env", [{}, {"LASTFM_ENABLED": "true"}], ids=["off", "stopped"])
def test_r1_without_a_config_the_holder_has_no_client_or_gate(open_app_client, env):
    with open_app_client(env=env) as client:
        accounts = client.app.state.lastfm_accounts

        assert (accounts.client, accounts.gate) == (None, None)


# ── signoff-9-lastfm-app-name (DEV-9-06; spec §7.5): ``app_name`` ───────────
# The operator's LASTFM_APP_NAME, trimmed, for the consent screen; null when it
# is not provided or when no valid configuration is held.

NAME = "OSML at Home"


def test_the_app_name_is_sent_to_a_user_who_never_connected(open_app_client):
    with open_app_client(env=valid_env(LASTFM_APP_NAME=f"  {NAME} ")) as client:
        rig = install(client)

        assert _status(rig) == {**_never_connected("running"), "app_name": NAME}


def test_the_app_name_is_sent_beside_a_connected_account(open_app_client):
    with open_app_client(env=valid_env(LASTFM_APP_NAME=NAME)) as client:
        rig = install(client)
        seed_connection(rig, admin_id(rig), account="alpha")

        body = _status(rig)

        assert (body["state"], body["account_name"], body["app_name"]) == (
            "connected_disabled", "alpha", NAME,
        )


def test_the_app_name_is_sent_to_every_user(open_app_client):
    with open_app_client(env=valid_env(LASTFM_APP_NAME=NAME)) as client:
        rig = install(client)
        _, headers = second_user(rig)

        assert _status(rig, headers)["app_name"] == NAME


@pytest.mark.parametrize("value", [None, "", "   "])
def test_an_unset_or_blank_app_name_is_null(open_app_client, value):
    env = valid_env() if value is None else valid_env(LASTFM_APP_NAME=value)
    with open_app_client(env=env) as client:
        rig = install(client)

        body = _status(rig)

        assert "app_name" in body
        assert body["app_name"] is None


def test_the_app_name_survives_a_run_time_stop(open_app_client):
    with open_app_client(env=valid_env(LASTFM_APP_NAME=NAME)) as client:
        rig = install(client)
        rig.state.stop("a fixed test cause")

        body = _status(rig)

        assert (body["service"], body["app_name"]) == ("stopped", NAME)


@pytest.mark.parametrize(
    "env",
    [
        {"LASTFM_ENABLED": "false", "LASTFM_APP_NAME": NAME},
        valid_env(LASTFM_APP_NAME=NAME, LASTFM_MIN_REQUEST_GAP_S="0"),
    ],
    ids=["off", "stopped-by-another-setting"],
)
def test_no_app_name_is_sent_without_a_valid_configuration(open_app_client, env):
    with open_app_client(env=env) as client:
        body = client.get(BASE).json()

        assert body["app_name"] is None


def test_an_invalid_app_name_is_null_and_last_fm_keeps_running(open_app_client):
    # User decision 2026-11-14 (DEV-s9an-01): ignored with a warning.
    with open_app_client(env=valid_env(LASTFM_APP_NAME="x" * 101)) as client:
        response = client.get(BASE)

        body = response.json()
        assert (body["service"], body["app_name"]) == ("running", None)
        assert "x" * 101 not in response.text
