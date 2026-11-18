"""Phase 8A.1 (8-U01, spec §3, SC-03, plan O6): the operator switch
``LIBRARY_DELETE_ENABLED`` is off by default, and ``/app/info`` always carries
one ``library_tools: {version: 1, server_delete, duplicate_review}`` feature
block whose ``server_delete`` mirrors the switch. ``duplicate_review`` is
true since 8A.4 built the duplicates endpoints (O6), whatever the switch."""

import pytest


def _library_tools(open_app_client, env=None):
    with open_app_client(env=env) as client:
        response = client.get("/app/info")
    assert response.status_code == 200, response.text
    return response.json()["library_tools"]


def test_the_switch_is_off_by_default(configure_app):
    main = configure_app()

    assert main.settings.library_delete_enabled is False


def test_the_block_is_present_with_server_delete_off_by_default(open_app_client):
    assert _library_tools(open_app_client) == {
        "version": 1,
        "server_delete": False,
        "duplicate_review": True,
    }


@pytest.mark.parametrize(
    ("value", "expected"), [("true", True), ("false", False), ("1", True), ("0", False)]
)
def test_server_delete_mirrors_the_switch(open_app_client, value, expected):
    block = _library_tools(open_app_client, env={"LIBRARY_DELETE_ENABLED": value})

    assert block["server_delete"] is expected
    assert block["duplicate_review"] is True
    assert block["version"] == 1


def test_the_block_is_served_without_a_token(app_client):
    app_client.headers.pop("Authorization")

    response = app_client.get("/app/info")

    assert response.status_code == 200
    assert response.json()["library_tools"]["version"] == 1
