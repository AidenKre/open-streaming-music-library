"""Phase M.1b (spec §5.4 "Lifecycle"; consumed by M.2b's CLI): a session dies
on the very next request when its user is disabled or marked deleting, or when
the master admin's ``.env`` password changes. There is no cache to expire.

The CLI arrives in M.2b; here the flags are written from another connection,
exactly as an out-of-process CLI would.
"""

import sqlite3

import pytest

from app.library import Library
from app.models import Track, TrackMetaData
from tests.conftest import TEST_ADMIN_PASSWORD, TEST_ADMIN_USERNAME, bearer, log_in

PASSWORD = "correct horse battery"


def _sql(client, statement, params=()):
    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        conn.execute(statement, params)
        conn.commit()
    finally:
        conn.close()


def _track(source):
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"not really flac")
    return Track(
        file_path=source,
        metadata=TrackMetaData(
            title="Lucky", artist="Radiohead", album="OK Computer", codec="flac",
            duration=1.0, bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
            track_number=1, disc_number=1,
        ),
    )


def _error(response):
    return response.status_code, response.json()["detail"]["error"]


@pytest.mark.parametrize("column", ["disabled_at", "deleting_at"])
def test_a_flagged_user_is_refused_on_the_next_request(app_client, tmp_path, column):
    db = app_client.app.state.database
    response = app_client.post("/auth/register", json={"username": "Sam", "password": PASSWORD})
    sam = response.json()
    folder = db.get_user(sam["user"]["id"])["library_folder"]
    track = _track(tmp_path / "music" / folder / "Lucky.flac")
    assert Library(db, sam["user"]["id"]).add_track(track)
    stream = (f"/tracks/{track.uuid_id}/stream",
              {"quality": "original", "access_token": sam["media_token"]})
    assert app_client.get("/tracks", headers=bearer(sam["token"])).status_code == 200

    _sql(app_client, f"UPDATE users SET {column} = 1 WHERE id = ?", (sam["user"]["id"],))

    assert _error(app_client.get("/tracks", headers=bearer(sam["token"]))) == (401, "invalid_token")
    app_client.headers.pop("Authorization")
    assert _error(app_client.get(stream[0], params=stream[1])) == (401, "invalid_token")


def test_flagging_one_user_leaves_the_others_signed_in(app_client):
    sam = app_client.post("/auth/register", json={"username": "Sam", "password": PASSWORD}).json()
    alex = app_client.post("/auth/register", json={"username": "Alex", "password": PASSWORD}).json()

    _sql(app_client, "UPDATE users SET disabled_at = 1 WHERE id = ?", (sam["user"]["id"],))

    assert app_client.get("/tracks", headers=bearer(alex["token"])).status_code == 200
    assert app_client.get("/tracks").status_code == 200  # the admin


def test_an_env_password_change_signs_the_admin_out(open_app_client):
    with open_app_client() as client:
        old = log_in(client)
        assert client.get("/tracks", headers=bearer(old["token"])).status_code == 200

    new_password = "a-brand-new-admin-password"
    with open_app_client(env={"OSML_ADMIN_PASSWORD": new_password}) as client:
        refused = client.get("/tracks", headers=bearer(old["token"]))
        assert _error(refused) == (401, "invalid_token")
        client.headers.pop("Authorization")
        media = client.get(
            "/tracks/00000000-0000-4000-8000-000000000000/stream",
            params={"access_token": old["media_token"]},
        )
        assert _error(media) == (401, "invalid_token")
        fresh = client.post(
            "/auth/login", json={"username": TEST_ADMIN_USERNAME, "password": new_password}
        )
        assert fresh.status_code == 200
        stale = client.post(
            "/auth/login", json={"username": TEST_ADMIN_USERNAME, "password": TEST_ADMIN_PASSWORD}
        )
        assert _error(stale) == (401, "invalid_credentials")


# M.2b: the same lifecycle driven through the admin CLI against the running
# app's data dir (``configure_app`` uses tmp_path/data, music, import, import-users).


def _cli(tmp_path, *argv, prompt=None):
    from tests.cli_fixtures import cli_settings, run_cli

    return run_cli(cli_settings(tmp_path), tmp_path, *argv, prompt=prompt)


def test_cli_disable_and_enable_take_effect_on_the_next_request(app_client, tmp_path):
    sam = app_client.post("/auth/register", json={"username": "Sam", "password": PASSWORD}).json()
    assert app_client.get("/tracks", headers=bearer(sam["token"])).status_code == 200

    assert _cli(tmp_path, "users", "disable", "Sam").code == 0

    assert _error(app_client.get("/tracks", headers=bearer(sam["token"]))) == (401, "invalid_token")
    refused = app_client.post("/auth/login", json={"username": "Sam", "password": PASSWORD})
    assert refused.status_code == 401

    assert _cli(tmp_path, "users", "enable", "Sam").code == 0

    assert _error(app_client.get("/tracks", headers=bearer(sam["token"]))) == (401, "invalid_token")
    fresh = log_in(app_client, "Sam", PASSWORD)
    assert app_client.get("/tracks", headers=bearer(fresh["token"])).status_code == 200


def test_cli_reset_password_signs_the_user_out_and_the_new_password_works(app_client, tmp_path):
    sam = app_client.post("/auth/register", json={"username": "Sam", "password": PASSWORD}).json()
    new_password = "a-reset-password"
    answers = iter([new_password, new_password])

    result = _cli(tmp_path, "users", "reset-password", "Sam", prompt=lambda _: next(answers))

    assert result.code == 0, result.err
    assert _error(app_client.get("/tracks", headers=bearer(sam["token"]))) == (401, "invalid_token")
    stale = app_client.post("/auth/login", json={"username": "Sam", "password": PASSWORD})
    assert stale.status_code == 401
    log_in(app_client, "Sam", new_password)
