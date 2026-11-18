"""9D.2a (spec §7.2 "Capability block", SC-03, 9-U11): ``/app/info`` is public,
so the ``integrations`` block carries one server-level fact and nothing else:
``{version: 1, lastfm: {available: <bool>}}``. ``available`` is "configured":
true when ``LASTFM_ENABLED`` is true and the configuration is valid (spec §7.2
literally; coordinator decision 2026-11-13 on DEV-9D2a-02), so it stays true
through a run-time stop, when ``enable`` still works and listens still queue.
It is false only when the feature is off: switched off, or switched on with an
invalid configuration (which leaves the service stopped at startup). Whether
Last.fm is being sent to right now is the status route's ``service``, never the
block. No secret, account name or per-user status ever appears in it."""

import logging

import pytest

from tests import lastfm_secrets as planted
from tests.lastfm_routes import admin_id, clean_env, open_rig, seed_connection


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


@pytest.mark.parametrize(
    ("server_state", "available"),
    [
        ("off", False),        # LASTFM_ENABLED false
        ("running", True),
        ("stopped", False),    # enabled with an invalid configuration (stopped at startup)
    ],
)
def test_the_block_says_whether_last_fm_is_configured(open_app_client, server_state, available):
    with open_rig(open_app_client, server_state) as rig:
        info = rig.client.get("/app/info").json()

        assert info["integrations"] == {"version": 1, "lastfm": {"available": available}}


def test_a_run_time_stop_keeps_the_block_available(open_app_client):
    # DEV-9D2a-02 resolved for the spec: a stop (error 10/26, ten rejections) is shown
    # by the status route's ``service``, while the page keeps offering opt-in.
    with open_rig(open_app_client) as rig:
        assert rig.client.get("/app/info").json()["integrations"]["lastfm"]["available"] is True

        rig.state.stop("a fixed test cause")

        assert rig.client.get("/app/info").json()["integrations"] == {
            "version": 1, "lastfm": {"available": True},
        }
        assert rig.client.get("/settings/integrations/lastfm").json()["service"] == "stopped"


def test_the_block_is_public_and_carries_no_account_or_secret(open_app_client, caplog):
    caplog.set_level(logging.DEBUG)
    with open_rig(open_app_client) as rig:
        seed_connection(rig, admin_id(rig), account="visible-account-name", opted_in=True)
        signed_in = rig.client.get("/app/info")
        del rig.client.headers["Authorization"]
        public = rig.client.get("/app/info")

        assert public.status_code == 200
        assert public.json()["integrations"] == signed_in.json()["integrations"]
        for response in (signed_in, public):
            planted.assert_no_secret(response.text, "/app/info")
            assert "visible-account-name" not in response.text
        planted.assert_no_secret(caplog.text, "the captured log")


def test_the_other_feature_blocks_are_unchanged(open_app_client):
    with open_rig(open_app_client) as rig:
        info = rig.client.get("/app/info").json()

        assert info["history"] == {"version": 1}
        assert info["library_tools"]["version"] == 1
        assert {"entities", "conversion", "server", "history", "auth", "uploads",
                "library_tools", "integrations"} == set(info)
