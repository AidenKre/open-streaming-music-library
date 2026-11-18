"""Phase 7A.1d (7-U11 block, SC-03): ``/app/info`` carries one optional
``uploads: {version: 1, limits: {...}}`` feature block whose limits are the
effective values the server enforces, never the raw settings."""

from tests.test_upload_limits import EFFECTIVE_DEFAULTS


def _uploads(open_app_client, **env):
    with open_app_client(env={k.upper(): str(v) for k, v in env.items()}) as client:
        response = client.get("/app/info")
    assert response.status_code == 200, response.text
    return response.json()["uploads"]


def test_the_block_advertises_the_effective_defaults(open_app_client):
    assert _uploads(open_app_client) == {"version": 1, "limits": EFFECTIVE_DEFAULTS}


def test_the_block_advertises_capped_values_not_the_raw_settings(open_app_client):
    uploads = _uploads(
        open_app_client,
        upload_max_file_bytes=9001,
        upload_max_batch_bytes=8001,
        upload_max_expanded_bytes_per_batch=7001,
        upload_max_expanded_member_bytes=9002,
        upload_staged_quota_bytes=3001,
    )

    limits = uploads["limits"]
    assert limits["max_file_bytes"] == 3001
    assert limits["max_batch_bytes"] == 3001
    assert limits["max_expanded_bytes_per_batch"] == 3001
    assert limits["max_expanded_member_bytes"] == 3001
    assert not {9001, 8001, 7001, 9002} & set(limits.values())


def test_the_block_never_advertises_the_free_space_floor(open_app_client):
    with open_app_client(env={"STORAGE_FREE_SPACE_FLOOR_BYTES": "123457"}) as client:
        response = client.get("/app/info")

    assert "123457" not in response.text
    assert set(response.json()["uploads"]["limits"]) == set(EFFECTIVE_DEFAULTS)


def test_the_block_is_served_without_a_token(app_client):
    app_client.headers.pop("Authorization")

    response = app_client.get("/app/info")

    assert response.status_code == 200
    assert response.json()["uploads"]["version"] == 1
