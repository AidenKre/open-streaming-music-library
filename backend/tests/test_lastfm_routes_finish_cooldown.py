"""OPEN-9-03 (owner's decision 2026-11-17): "Finish connecting" has a per-user
limit like Connect's, one gate gap long. A second ``complete`` of the same user
within one gap of the last one is refused with the same 429
``lastfm_too_soon`` and ``Retry-After`` Connect gives, and takes no turn at
the gate. The period is the gate's own gap (``LASTFM_MIN_REQUEST_GAP_S``), so
a real second tap just after approving, one gap later, goes through. The time
is claimed before the gate wait, like Connect's (DEV-9-15 row 53). Users are
independent, and Connect's 30-second cooldown is a separate limit."""

import pytest

from app.library import Library
from app.services.lastfm_errors import LastfmError
from tests import lastfm_secrets as planted
from tests.lastfm_fake import FakeLastfm, failed, ok_session, ok_token
from tests.lastfm_routes import (
    BASE,
    admin_id,
    clean_env,
    connection_row,
    install,
    open_rig,
    second_user,
    seed_token,
)
from tests.lastfm_secrets import valid_env

COMPLETE = f"{BASE}/complete"
CONNECT = f"{BASE}/connect"
NEW_KEY = "planted-NEW-session-key-0001"


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


def _gate_turns(rig, monkeypatch) -> list:
    """Records every entry into the gate (one entry = one turn)."""
    turns = []
    gate = rig.accounts.gate
    real_enter = gate.enter

    def enter(**kwargs):
        turns.append(kwargs)
        return real_enter(**kwargs)

    monkeypatch.setattr(gate, "enter", enter)
    return turns


def _error(response):
    detail = response.json()["detail"]
    return response.status_code, detail["error"], detail["retryable"]


def _too_soon(response):
    assert _error(response) == (429, "lastfm_too_soon", True)
    return response.headers["Retry-After"]


def _gap(rig) -> int:
    return rig.state.config.min_request_gap_s


# ── the period is one gate gap ──────────────────────────────────────────────


@pytest.mark.parametrize("gap", ["5", "7"])
def test_a_second_finish_within_one_gate_gap_is_refused_and_takes_no_gate_turn(
    open_app_client, monkeypatch, gap
):
    with open_app_client(env=valid_env(LASTFM_MIN_REQUEST_GAP_S=gap)) as client:
        rig = install(client, FakeLastfm(failed(14), failed(14)))
        seed_token(rig, admin_id(rig))
        turns = _gate_turns(rig, monkeypatch)
        assert _error(client.post(COMPLETE, json={}))[1] == "lastfm_not_authorized_yet"
        rig.cooldown_clock.advance(int(gap) - 1)

        assert _too_soon(client.post(COMPLETE, json={})) == "1"
        assert len(turns) == 1
        assert len(rig.fake.requests) == 1


def test_retry_after_counts_the_whole_gap_right_after_a_finish(open_app_client, monkeypatch):
    with open_rig(open_app_client, fake=FakeLastfm(failed(14))) as rig:
        seed_token(rig, admin_id(rig))
        turns = _gate_turns(rig, monkeypatch)
        rig.client.post(COMPLETE, json={})

        assert _too_soon(rig.client.post(COMPLETE, json={})) == str(_gap(rig))
        assert len(turns) == 1


@pytest.mark.parametrize("gap", ["5", "7"])
def test_a_real_second_tap_one_gate_gap_later_binds(open_app_client, gap):
    """The user taps Finish before approving, approves, and taps again one gap
    later: the second tap is not refused."""
    with open_app_client(env=valid_env(LASTFM_MIN_REQUEST_GAP_S=gap)) as client:
        rig = install(client, FakeLastfm(failed(14), ok_session("alpha", NEW_KEY)))
        owner = admin_id(rig)
        seed_token(rig, owner)
        assert _error(client.post(COMPLETE, json={}))[1] == "lastfm_not_authorized_yet"
        rig.cooldown_clock.advance(int(gap))
        rig.gate_clock.advance(int(gap))

        response = client.post(COMPLETE, json={})

        assert response.status_code == 200
        assert response.json()["account_name"] == "alpha"
        assert connection_row(rig, owner)["account_name"] == "alpha"
        assert len(rig.fake.requests) == 2


def test_retry_after_rounds_the_time_left_up(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(failed(14))) as rig:
        seed_token(rig, admin_id(rig))
        rig.client.post(COMPLETE, json={})
        rig.cooldown_clock.advance(_gap(rig) - 3.5)

        assert _too_soon(rig.client.post(COMPLETE, json={})) == "4"


def test_half_a_second_before_the_gap_ends_is_still_refused(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(failed(14), failed(14))) as rig:
        seed_token(rig, admin_id(rig))
        rig.client.post(COMPLETE, json={})
        rig.cooldown_clock.advance(_gap(rig) - 0.5)

        assert _too_soon(rig.client.post(COMPLETE, json={})) == "1"
        assert len(rig.fake.requests) == 1


def test_a_refused_finish_does_not_extend_the_period(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(failed(14), failed(14))) as rig:
        seed_token(rig, admin_id(rig))
        rig.client.post(COMPLETE, json={})
        rig.cooldown_clock.advance(_gap(rig) - 1)
        _too_soon(rig.client.post(COMPLETE, json={}))
        rig.cooldown_clock.advance(1)

        assert _error(rig.client.post(COMPLETE, json={}))[1] == "lastfm_not_authorized_yet"
        assert len(rig.fake.requests) == 2


# ── per user ─────────────────────────────────────────────────────────────────


def test_one_users_finish_never_holds_back_anothers(open_app_client, monkeypatch):
    fake = FakeLastfm(failed(14), ok_session("beta", NEW_KEY))
    with open_rig(open_app_client, fake=fake) as rig:
        a = admin_id(rig)
        b, b_headers = second_user(rig)
        seed_token(rig, a)
        seed_token(rig, b, token="plantedTokenOfB-0123456789abcdef")
        turns = _gate_turns(rig, monkeypatch)
        assert _error(rig.client.post(COMPLETE, json={}))[1] == "lastfm_not_authorized_yet"

        response = rig.client.post(COMPLETE, json={}, headers=b_headers)

        assert response.status_code == 200
        assert connection_row(rig, b)["account_name"] == "beta"
        assert len(turns) == 2


def test_another_users_refused_finishes_do_not_touch_mine(open_app_client):
    fake = FakeLastfm(failed(14), failed(14))
    with open_rig(open_app_client, fake=fake) as rig:
        a = admin_id(rig)
        b, b_headers = second_user(rig)
        seed_token(rig, a)
        seed_token(rig, b, token="plantedTokenOfB-0123456789abcdef")
        assert rig.client.post(COMPLETE, json={}, headers=b_headers).status_code == 409
        for _ in range(3):
            _too_soon(rig.client.post(COMPLETE, json={}, headers=b_headers))

        assert _error(rig.client.post(COMPLETE, json={}))[1] == "lastfm_not_authorized_yet"


# ── Connect's limit is separate and unchanged ───────────────────────────────


def test_a_finish_right_after_a_connect_is_not_refused(open_app_client):
    fake = FakeLastfm(ok_token(planted.TOKEN), ok_session("alpha", NEW_KEY))
    with open_rig(open_app_client, fake=fake) as rig:
        assert rig.client.post(CONNECT, json={}).status_code == 200

        assert rig.client.post(COMPLETE, json={}).status_code == 200


def test_a_connect_right_after_a_finish_is_not_refused(open_app_client):
    fake = FakeLastfm(failed(14), ok_token(planted.TOKEN))
    with open_rig(open_app_client, fake=fake) as rig:
        seed_token(rig, admin_id(rig))
        assert rig.client.post(COMPLETE, json={}).status_code == 409

        assert rig.client.post(CONNECT, json={}).status_code == 200


def test_connect_still_waits_30_seconds_after_finishes(open_app_client):
    fake = FakeLastfm(ok_token(planted.TOKEN), failed(14), failed(14), ok_token(planted.TOKEN))
    with open_rig(open_app_client, fake=fake) as rig:
        assert rig.client.post(CONNECT, json={}).status_code == 200
        rig.client.post(COMPLETE, json={})
        rig.cooldown_clock.advance(_gap(rig))
        rig.client.post(COMPLETE, json={})
        rig.cooldown_clock.advance(29 - _gap(rig))

        assert _too_soon(rig.client.post(CONNECT, json={})) == "1"
        rig.cooldown_clock.advance(1)
        assert rig.client.post(CONNECT, json={}).status_code == 200


# ── attempts that sent nothing ──────────────────────────────────────────────


def test_a_finish_the_gate_refused_sends_nothing_and_does_not_count(open_app_client):
    with open_app_client(env=valid_env(LASTFM_MIN_REQUEST_GAP_S="11")) as client:
        rig = install(client, FakeLastfm(failed(14)))
        seed_token(rig, admin_id(rig))
        assert _error(client.post(COMPLETE, json={})) == (503, "lastfm_unavailable", True)
        assert rig.fake.requests == []
        rig.gate_clock.advance(11)

        assert _error(client.post(COMPLETE, json={}))[1] == "lastfm_not_authorized_yet"


@pytest.mark.parametrize(
    ("server_state", "refusal"),
    [("off", (403, "lastfm_disabled", False)), ("stopped", (503, "lastfm_stopped", False))],
)
def test_refusals_for_the_server_state_do_not_count(open_app_client, server_state, refusal):
    with open_rig(open_app_client, server_state) as rig:
        seed_token(rig, admin_id(rig))
        first = _error(rig.client.post(COMPLETE, json={}))
        second = _error(rig.client.post(COMPLETE, json={}))

        assert first == second == refusal


# ── racing the one in flight ────────────────────────────────────────────────


def test_a_finish_racing_one_in_flight_is_too_soon_and_takes_no_turn(open_app_client, monkeypatch):
    """The period is claimed before the gate wait (like Connect, DEV-9-15 row 53):
    a second Finish while the first waits at the gate is told to wait."""
    with open_rig(open_app_client, fake=FakeLastfm(ok_session("alpha", NEW_KEY))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)
        turns = _gate_turns(rig, monkeypatch)
        seen = []

        def racing(_timeout):
            if not seen:
                try:
                    rig.accounts.complete(Library(rig.db, owner))
                except LastfmError as error:
                    seen.append((error.status, error.code))
                else:
                    seen.append("accepted")

        rig.gate_clock.on_wait.append(racing)

        assert rig.client.post(COMPLETE, json={}).status_code == 200
        assert seen == [(429, "lastfm_too_soon")]
        assert len(turns) == 1
        assert len(rig.fake.requests) == 1


def test_one_finish_at_a_time_still_holds_after_the_period(open_app_client, monkeypatch):
    """A first Finish still waiting at the gate one gap later: a second one is
    refused at once as before (503), takes no turn, and does not start a new
    period."""
    with open_rig(open_app_client, fake=FakeLastfm(failed(14), failed(14))) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)
        turns = _gate_turns(rig, monkeypatch)
        seen = []

        def racing(_timeout):
            if not seen:
                rig.cooldown_clock.advance(_gap(rig))
                try:
                    rig.accounts.complete(Library(rig.db, owner))
                except LastfmError as error:
                    seen.append((error.status, error.code))
                else:
                    seen.append("accepted")

        rig.gate_clock.on_wait.append(racing)

        assert _error(rig.client.post(COMPLETE, json={}))[1] == "lastfm_not_authorized_yet"
        assert seen == [(503, "lastfm_unavailable")]
        assert len(turns) == 1
        # The refused one did not start a period: the first one's has passed.
        assert _error(rig.client.post(COMPLETE, json={}))[1] == "lastfm_not_authorized_yet"
