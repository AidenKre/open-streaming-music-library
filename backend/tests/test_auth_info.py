"""Phase M.1a (M-U11, spec §5.2, SC-03): the signup settings and the public
``auth`` block of ``/app/info``.

Signup is open by default with removable switches ``OSML_SIGNUP_ENABLED`` and
``OSML_MAX_USERS`` (default 25). ``/app/info`` advertises
``auth: {version: 1, signup_enabled}`` and nothing per user.
"""

import pytest

from app.config import Settings


@pytest.fixture
def no_signup_env(monkeypatch):
    monkeypatch.delenv("OSML_SIGNUP_ENABLED", raising=False)
    monkeypatch.delenv("OSML_MAX_USERS", raising=False)


def test_signup_is_open_for_25_users_by_default(no_signup_env):
    settings = Settings(_env_file=None)
    assert settings.osml_signup_enabled is True
    assert settings.osml_max_users == 25


def test_the_signup_switches_come_from_the_environment(no_signup_env, monkeypatch):
    monkeypatch.setenv("OSML_SIGNUP_ENABLED", "false")
    monkeypatch.setenv("OSML_MAX_USERS", "3")
    settings = Settings(_env_file=None)
    assert settings.osml_signup_enabled is False
    assert settings.osml_max_users == 3


def test_app_info_advertises_open_signup(open_app_client):
    with open_app_client() as client:
        response = client.get("/app/info")
    assert response.status_code == 200
    assert response.json()["auth"] == {"version": 1, "signup_enabled": True}


def test_app_info_advertises_closed_signup(open_app_client):
    with open_app_client(env={"OSML_SIGNUP_ENABLED": "false"}) as client:
        auth = client.get("/app/info").json()["auth"]
    assert auth == {"version": 1, "signup_enabled": False}
