"""9D.1d exit proof (9-U08b, 9-U08c, plan §5): over a whole connect →
complete → status → disconnect flow of two users, the API key and the token
appear only inside ``connect``'s authorization URL; no other response, header
or captured log line carries a secret; the database file holds no plaintext
token or session key; and each user's calls touch only their own row."""

import logging
from pathlib import Path

import pytest

from tests import lastfm_secrets as planted
from tests.lastfm_fake import FakeLastfm, ok_session, ok_token
from tests.lastfm_routes import BASE, admin_id, clean_env, connection_row, open_rig, rows, second_user
from tests.lastfm_secrets import assert_no_secret, assert_secret_equal

TOKEN_B = "plantedTokenOfUserB-0123456789ab"
KEY_B = "planted-session-key-of-user-B-00"
SECRETS = [*planted.ALL, TOKEN_B, KEY_B]


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


def _flow(rig, headers):
    responses = [rig.client.post(f"{BASE}/connect", json={}, headers=headers)]
    responses.append(rig.client.post(f"{BASE}/complete", json={}, headers=headers))
    responses.append(rig.client.get(BASE, headers=headers))
    return responses


def test_a_two_user_flow_keeps_every_secret_where_it_belongs(open_app_client, caplog):
    caplog.set_level(logging.DEBUG)
    fake = FakeLastfm(
        ok_token(planted.TOKEN),
        ok_session("alpha", planted.SESSION_KEY),
        ok_token(TOKEN_B),
        ok_session("beta", KEY_B),
    )
    with open_rig(open_app_client, fake=fake) as rig:
        a = admin_id(rig)
        b, b_headers = second_user(rig)

        a_responses = _flow(rig, None)
        b_responses = _flow(rig, b_headers)

        assert [r.status_code for r in a_responses + b_responses] == [200] * 6
        for response in a_responses + b_responses:
            text = response.text
            if response.request.url.path.endswith("/connect"):
                text = text.replace(response.json()["authorization_url"], "")
            assert_no_secret(text, "a response body outside the URL", secrets=SECRETS)
            assert_no_secret(str(response.headers), "response headers", secrets=SECRETS)
        assert (a_responses[2].json()["account_name"], b_responses[2].json()["account_name"]) == ("alpha", "beta")

        rows(rig, "PRAGMA wal_checkpoint(TRUNCATE)")
        path = Path(rig.db.context.database_path)
        for candidate in (path, path.with_name(path.name + "-wal")):
            if candidate.exists():
                data = candidate.read_bytes()
                for index, secret in enumerate(SECRETS):
                    if secret.encode() in data:
                        raise AssertionError(f"secret #{index} in plaintext in {candidate.name}")

        assert rig.client.delete(BASE, headers=b_headers).status_code == 204
        assert connection_row(rig, b) is None
        assert connection_row(rig, a)["account_name"] == "alpha"
        assert_no_secret(caplog.text, "the captured logs", secrets=SECRETS)


def test_the_api_key_never_appears_in_status_complete_or_disconnect(open_app_client):
    fake = FakeLastfm(ok_token(planted.TOKEN), ok_session("alpha", planted.SESSION_KEY))
    with open_rig(open_app_client, fake=fake) as rig:
        rig.client.post(f"{BASE}/connect", json={})
        others = [
            rig.client.get(BASE),
            rig.client.post(f"{BASE}/complete", json={}),
            rig.client.get(BASE),
            rig.client.delete(BASE),
        ]

        for response in others:
            assert_no_secret(response.text, "a non-connect body", secrets=[planted.API_KEY, planted.TOKEN])


def test_racing_connects_of_two_users_bind_each_to_their_own_token(open_app_client):
    """A connects, B connects, then both complete in the other order: each
    complete sends only its caller's token and binds only its caller's row."""
    fake = FakeLastfm(
        ok_token(planted.TOKEN),
        ok_token(TOKEN_B),
        ok_session("beta", KEY_B),
        ok_session("alpha", planted.SESSION_KEY),
    )
    with open_rig(open_app_client, fake=fake) as rig:
        a = admin_id(rig)
        b, b_headers = second_user(rig)
        rig.client.post(f"{BASE}/connect", json={})
        rig.client.post(f"{BASE}/connect", json={}, headers=b_headers)

        assert rig.client.post(f"{BASE}/complete", json={}, headers=b_headers).json()["account_name"] == "beta"
        assert rig.client.post(f"{BASE}/complete", json={}).json()["account_name"] == "alpha"

        sent = [dict(fake.form(i))["token"] for i in (2, 3)]
        assert_secret_equal(sent[0], TOKEN_B, "the token B's complete sent")
        assert_secret_equal(sent[1], planted.TOKEN, "the token A's complete sent")
        assert connection_row(rig, a)["account_name"] == "alpha"
        assert connection_row(rig, b)["account_name"] == "beta"
