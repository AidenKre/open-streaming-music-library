"""9D.1d (spec §7.4 Connect, 9-U10 connect): ``connect`` is refused with 429
``lastfm_too_soon`` and ``Retry-After`` when the caller sent a connect request
to Last.fm less than 30 seconds ago. The time is kept in memory per user, so
disconnecting does not reset it, one user's connects never hold back
another's, and an attempt that sent nothing to Last.fm does not count."""

import pytest

from app.library import Library
from app.services.lastfm_errors import LastfmError
from tests import lastfm_secrets as planted
from tests.lastfm_fake import FakeLastfm, failed, ok_token
from tests.lastfm_routes import BASE, admin_id, clean_env, install, open_rig, second_user
from tests.lastfm_secrets import assert_no_secret, valid_env

CONNECT = f"{BASE}/connect"


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


def _tokens(n):
    return [ok_token(f"plantedToken{i:02d}-abcdefghijklmnopq") for i in range(n)]


def _too_soon(response):
    assert response.status_code == 429, f"expected 429, got {response.status_code}"
    detail = response.json()["detail"]
    assert (detail["error"], detail["retryable"]) == ("lastfm_too_soon", True)
    return response.headers["Retry-After"]


def test_a_second_connect_within_30_seconds_is_refused_with_retry_after(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(*_tokens(2))) as rig:
        assert rig.client.post(CONNECT, json={}).status_code == 200
        rig.cooldown_clock.advance(5)

        assert _too_soon(rig.client.post(CONNECT, json={})) == "25"
        assert len(rig.fake.requests) == 1


def test_retry_after_rounds_up_to_a_whole_second(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(*_tokens(2))) as rig:
        rig.client.post(CONNECT, json={})
        rig.cooldown_clock.advance(29.5)

        assert _too_soon(rig.client.post(CONNECT, json={})) == "1"


def test_a_connect_30_seconds_later_is_allowed(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(*_tokens(2))) as rig:
        rig.client.post(CONNECT, json={})
        rig.cooldown_clock.advance(30)

        assert rig.client.post(CONNECT, json={}).status_code == 200
        assert len(rig.fake.requests) == 2


def test_a_refused_connect_does_not_extend_the_cooldown(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(*_tokens(2))) as rig:
        rig.client.post(CONNECT, json={})
        rig.cooldown_clock.advance(20)
        _too_soon(rig.client.post(CONNECT, json={}))
        rig.cooldown_clock.advance(10)

        assert rig.client.post(CONNECT, json={}).status_code == 200


def test_disconnecting_does_not_reset_the_cooldown(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(*_tokens(2))) as rig:
        rig.client.post(CONNECT, json={})
        assert rig.client.delete(BASE).status_code == 204

        assert _too_soon(rig.client.post(CONNECT, json={})) == "30"


def test_a_connect_that_lastfm_answered_with_a_failure_still_counts(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(failed(13), *_tokens(1))) as rig:
        assert rig.client.post(CONNECT, json={}).status_code == 503

        _too_soon(rig.client.post(CONNECT, json={}))


def test_one_users_connect_never_holds_back_anothers(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(*_tokens(2))) as rig:
        _, b_headers = second_user(rig)
        assert rig.client.post(CONNECT, json={}).status_code == 200

        assert rig.client.post(CONNECT, json={}, headers=b_headers).status_code == 200


def test_another_users_refused_connects_do_not_touch_mine(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(*_tokens(2))) as rig:
        _, b_headers = second_user(rig)
        assert rig.client.post(CONNECT, json={}, headers=b_headers).status_code == 200
        for _ in range(3):
            _too_soon(rig.client.post(CONNECT, json={}, headers=b_headers))

        assert rig.client.post(CONNECT, json={}).status_code == 200


def test_an_attempt_the_gate_refused_sends_nothing_and_does_not_count(open_app_client):
    with open_app_client(env=valid_env(LASTFM_MIN_REQUEST_GAP_S="11")) as client:
        rig = install(client, FakeLastfm(*_tokens(1)))
        assert client.post(CONNECT, json={}).status_code == 503  # the gate is busy for 11 s
        assert rig.fake.requests == []
        rig.gate_clock.advance(11)

        assert client.post(CONNECT, json={}).status_code == 200


@pytest.mark.parametrize("server_state", ["off", "stopped"])
def test_refusals_for_the_server_state_do_not_count(open_app_client, server_state):
    with open_rig(open_app_client, server_state) as rig:
        first = rig.client.post(CONNECT, json={}).status_code
        second = rig.client.post(CONNECT, json={}).status_code

        assert first == second != 429


def test_a_connect_racing_one_in_flight_for_the_same_user_is_refused(open_app_client):
    """While the first connect waits in the gate, a second one of the same user
    is already too soon: the cooldown is claimed before the wait."""
    with open_rig(open_app_client, fake=FakeLastfm(*_tokens(2))) as rig:
        library = Library(rig.db, admin_id(rig))
        seen = []

        def racing(_timeout):
            if not seen:
                try:
                    rig.accounts.connect(library)
                except LastfmError as error:
                    seen.append(error.code)
                else:
                    seen.append("accepted")

        rig.gate_clock.on_wait.append(racing)

        assert rig.client.post(CONNECT, json={}).status_code == 200
        assert seen == ["lastfm_too_soon"]
        assert len(rig.fake.requests) == 1


def test_the_planted_token_is_not_in_the_retry_after_answer(open_app_client):
    with open_rig(open_app_client, fake=FakeLastfm(ok_token(planted.TOKEN))) as rig:
        rig.client.post(CONNECT, json={})

        response = rig.client.post(CONNECT, json={})

        assert response.status_code == 429
        assert_no_secret(response.text, "the 429 body")
        assert_no_secret(str(response.headers), "the 429 headers")
