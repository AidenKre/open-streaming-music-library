"""9D.1d (spec §7.4 Disconnect, §7.11, 9-U08c, 9-U10): ``DELETE
/settings/integrations/lastfm`` answers 204 in every server state, also when
not connected; it deletes the caller's connection row and all of their outbox
rows and nothing of anyone else's, and drops the caller's waiting Now Playing
notice through the seam the sender piece fills."""

import pytest

from tests.lastfm_routes import (
    BASE,
    admin_id,
    clean_env,
    open_rig,
    rows,
    second_user,
    seed_connection,
    seed_outbox,
    seed_token,
)


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


def _seed_everything(rig, owner):
    seed_connection(rig, owner, opted_in=True)
    seed_token(rig, owner)
    seed_outbox(rig, owner, status="pending")
    seed_outbox(rig, owner, status="sent", done_at=rig.wall.ms - 1)
    seed_outbox(rig, owner, status="failed", code="13", done_at=rig.wall.ms - 1)
    seed_outbox(rig, owner, status="dropped", code="too_old", done_at=rig.wall.ms - 1)


def _counts(rig, owner):
    [connections] = rows(rig, "SELECT count(*) FROM lastfm_connections WHERE owner_id = ?", (owner,))
    [outbox] = rows(rig, "SELECT count(*) FROM scrobble_outbox WHERE owner_id = ?", (owner,))
    return connections[0], outbox[0]


@pytest.mark.parametrize("server_state", ["off", "running", "stopped"])
def test_disconnect_deletes_the_row_and_every_outbox_row_in_every_server_state(open_app_client, server_state):
    with open_rig(open_app_client, server_state) as rig:
        owner = admin_id(rig)
        _seed_everything(rig, owner)
        assert _counts(rig, owner) == (1, 4)

        response = rig.client.delete(BASE)

        assert response.status_code == 204
        assert response.content == b""
        assert _counts(rig, owner) == (0, 0)


def test_disconnect_after_a_run_time_stop_works(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _seed_everything(rig, owner)
        rig.state.stop("a fixed test cause")

        assert rig.client.delete(BASE).status_code == 204
        assert _counts(rig, owner) == (0, 0)


@pytest.mark.parametrize("server_state", ["off", "running", "stopped"])
def test_disconnect_when_not_connected_is_204(open_app_client, server_state):
    with open_rig(open_app_client, server_state) as rig:
        response = rig.client.delete(BASE)

        assert response.status_code == 204
        assert _counts(rig, admin_id(rig)) == (0, 0)


def test_disconnect_twice_is_harmless(open_app_client):
    with open_rig(open_app_client) as rig:
        _seed_everything(rig, admin_id(rig))

        assert [rig.client.delete(BASE).status_code for _ in range(2)] == [204, 204]


def test_an_awaiting_token_is_removed_too(open_app_client):
    with open_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_token(rig, owner)

        assert rig.client.delete(BASE).status_code == 204
        assert rig.db.get_lastfm_connection(owner_id=owner) is None


def test_the_status_after_disconnect_is_not_connected_with_zero_counts(open_app_client):
    with open_rig(open_app_client) as rig:
        _seed_everything(rig, admin_id(rig))

        rig.client.delete(BASE)
        body = rig.client.get(BASE).json()

        assert (body["state"], body["account_name"], body["connection_id"]) == ("not_connected", None, None)
        assert body["counts"] == {"pending": 0, "sent": 0, "ignored": 0, "failed": 0, "dropped": 0}
        assert body["recent_problems"] == []
        assert body["last_success_at"] is None


@pytest.mark.parametrize("server_state", ["off", "running", "stopped"])
def test_disconnect_drops_the_callers_waiting_now_playing_notice(open_app_client, server_state):
    with open_rig(open_app_client, server_state) as rig:
        owner = admin_id(rig)
        _seed_everything(rig, owner)

        rig.client.delete(BASE)

        assert rig.dropped == [owner]


def test_disconnect_drops_the_notice_also_when_not_connected(open_app_client):
    with open_rig(open_app_client) as rig:
        rig.client.delete(BASE)

        assert rig.dropped == [admin_id(rig)]


def test_user_bs_disconnect_leaves_user_as_connection_and_outbox(open_app_client):
    with open_rig(open_app_client) as rig:
        a = admin_id(rig)
        _seed_everything(rig, a)
        b, b_headers = second_user(rig)
        _seed_everything(rig, b)
        a_before = rows(rig, "SELECT * FROM lastfm_connections WHERE owner_id = ?", (a,))
        a_outbox = rows(rig, "SELECT * FROM scrobble_outbox WHERE owner_id = ? ORDER BY event_uuid", (a,))

        response = rig.client.delete(BASE, headers=b_headers)

        assert response.status_code == 204
        assert _counts(rig, b) == (0, 0)
        assert rows(rig, "SELECT * FROM lastfm_connections WHERE owner_id = ?", (a,)) == a_before
        assert rows(rig, "SELECT * FROM scrobble_outbox WHERE owner_id = ? ORDER BY event_uuid", (a,)) == a_outbox
        assert rig.dropped == [b]


def test_the_default_now_playing_seam_is_a_harmless_no_op(open_app_client):
    """The real startup holder (no install()): disconnect works before 9D.2c fills the seam."""
    with open_app_client(env={}) as client:
        assert client.delete(BASE).status_code == 204
