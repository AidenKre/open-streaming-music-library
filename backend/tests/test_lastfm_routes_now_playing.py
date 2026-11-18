"""9D.2c (spec §7.4, §7.10, review 9-U10): ``POST
/settings/integrations/lastfm/now-playing`` with ``{"track_uuid": "<uuid>"}``
answers 202 at once in every server state except ``off`` (403
``lastfm_disabled``), and never says whether a notice will be sent: an
unknown or another user's track, a user who is not connected or not opted in
all get the same 202. While running it hands the notice to the sender's
holder (newest wins, wakes the sender); while stopped it keeps nothing.
Startup wires the route and disconnect to the sender's notices. The route
itself never contacts Last.fm (the fake has no reply queued)."""

import uuid

import pytest

from app.services import lastfm_sender
from tests.lastfm_routes import (
    BASE,
    admin_id,
    clean_env,
    open_rig,
    second_user,
    seed_connection,
)
from tests.lastfm_secrets import valid_env
from tests.test_lastfm_now_playing import add_track
from tests.test_lastfm_sender_app import SENDER_ON, FakeSender

PATH = f"{BASE}/now-playing"


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


@pytest.mark.parametrize("server_state", ["running", "stopped"])
def test_the_route_answers_202_with_no_body(open_app_client, server_state):
    with open_rig(open_app_client, server_state) as rig:
        response = rig.client.post(PATH, json={"track_uuid": str(uuid.uuid4())})

        assert response.status_code == 202
        assert response.content == b""
        assert rig.fake.requests == []


def test_while_running_the_notice_is_handed_to_the_sender_for_the_caller(open_app_client):
    with open_rig(open_app_client) as rig:
        track = str(uuid.uuid4())
        bea, headers = second_user(rig)

        rig.client.post(PATH, json={"track_uuid": track})
        rig.client.post(PATH, json={"track_uuid": track}, headers=headers)

        assert rig.noticed == [(admin_id(rig), track), (bea, track)]


def test_the_uuid_is_kept_in_its_canonical_form(open_app_client):
    with open_rig(open_app_client) as rig:
        track = uuid.uuid4()

        rig.client.post(PATH, json={"track_uuid": str(track).upper()})

        assert rig.noticed == [(admin_id(rig), str(track))]


def test_while_stopped_nothing_is_kept(open_app_client):
    with open_rig(open_app_client, "stopped") as rig:
        assert rig.client.post(PATH, json={"track_uuid": str(uuid.uuid4())}).status_code == 202
        assert rig.noticed == []


def test_after_a_run_time_stop_nothing_is_kept(open_app_client):
    with open_rig(open_app_client) as rig:
        rig.state.stop("test")

        assert rig.client.post(PATH, json={"track_uuid": str(uuid.uuid4())}).status_code == 202
        assert rig.noticed == []


def test_while_off_the_route_is_403_lastfm_disabled(open_app_client):
    with open_rig(open_app_client, "off") as rig:
        response = rig.client.post(PATH, json={"track_uuid": str(uuid.uuid4())})

        assert response.status_code == 403
        detail = response.json()["detail"]
        assert (detail["error"], detail["retryable"]) == ("lastfm_disabled", False)
        assert rig.noticed == []


def test_the_answer_never_says_whether_anything_will_be_sent(open_app_client, tmp_path):
    with open_rig(open_app_client) as rig:
        admin = admin_id(rig)
        bea, bea_headers = second_user(rig)
        anas_track = add_track(rig, tmp_path, admin)
        bea_track = add_track(rig, tmp_path, bea)
        answers = []

        def ask(track, headers=None):
            response = rig.client.post(PATH, json={"track_uuid": track}, headers=headers)
            answers.append((response.status_code, response.content))

        # Not connected yet; own track, unknown track, another user's track.
        for track in (anas_track, str(uuid.uuid4()), bea_track):
            ask(track)
        seed_connection(rig, admin, opted_in=False)
        ask(anas_track)
        seed_connection(rig, bea, opted_in=True, needs_reconnect=True)
        ask(bea_track, bea_headers)
        ask(anas_track, bea_headers)  # B names A's track
        seed_connection(rig, admin, opted_in=True)
        ask(anas_track)

        assert set(answers) == {(202, b"")}
        assert rig.fake.requests == []


@pytest.mark.parametrize(
    "body",
    [
        b"[]",
        b"{}",
        b'{"track_uuid": 5}',
        b'{"track_uuid": null}',
        b'{"track_uuid": "not-a-uuid"}',
        b'{"track_uuid": ""}',
        b"not json",
    ],
    ids=["array", "missing", "number", "null", "not-a-uuid", "empty", "not-json"],
)
def test_a_body_that_is_not_a_track_uuid_is_422_and_keeps_nothing(open_app_client, body):
    with open_rig(open_app_client) as rig:
        response = rig.client.post(PATH, content=body, headers={"Content-Type": "application/json"})

        assert response.status_code == 422
        assert b"not-a-uuid" not in response.content  # no input echoed
        assert rig.noticed == []


def test_an_oversized_body_is_413(open_app_client):
    with open_rig(open_app_client) as rig:
        body = b'{"track_uuid": "%s", "pad": "%s"}' % (str(uuid.uuid4()).encode(), b"x" * 5000)

        response = rig.client.post(PATH, content=body, headers={"Content-Type": "application/json"})

        assert response.status_code == 413
        assert rig.noticed == []


def test_unknown_keys_are_ignored(open_app_client):
    with open_rig(open_app_client) as rig:
        track = str(uuid.uuid4())

        response = rig.client.post(PATH, json={"track_uuid": track, "position_ms": 5000})

        assert response.status_code == 202
        assert rig.noticed == [(admin_id(rig), track)]


def test_without_a_session_the_route_is_401(open_app_client):
    with open_rig(open_app_client) as rig:
        rig.client.headers.pop("Authorization")

        response = rig.client.post(PATH, json={"track_uuid": str(uuid.uuid4())})

        assert response.status_code == 401
        assert rig.noticed == []


# --- startup wiring --------------------------------------------------------------------------


@pytest.fixture
def fake_sender(monkeypatch):
    FakeSender.instances = []
    monkeypatch.setattr(lastfm_sender, "ScrobbleSender", FakeSender)
    return FakeSender


def test_startup_hands_the_route_and_disconnect_to_the_senders_notices(open_app_client, fake_sender):
    with open_app_client(env=valid_env(**SENDER_ON)) as client:
        [sender] = fake_sender.instances
        track = str(uuid.uuid4())

        assert client.post(PATH, json={"track_uuid": track}).status_code == 202
        [notice] = sender.notices.waiting()
        assert notice.track_uuid == track
        assert "wake" in sender.events  # the put woke the sender

        assert client.delete(BASE).status_code == 204
        assert len(sender.notices) == 0  # disconnect dropped it


def test_without_a_sender_the_route_still_answers_202_and_keeps_nothing(open_app_client, fake_sender):
    with open_app_client(env=valid_env()) as client:  # the sender is switched off
        assert client.post(PATH, json={"track_uuid": str(uuid.uuid4())}).status_code == 202
        assert fake_sender.instances == []
        assert client.app.state.lastfm_sender is None
        assert len(client.app.state.lastfm_accounts.notices) == 0  # nobody listens: nothing kept
