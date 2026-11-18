"""Phase M.1b (M-U12, SC-28 rule 3, spec §5.3): ``current_library()`` binds
the request principal's ``Library``, not the master admin's."""

from starlette.requests import Request

from app.auth.principal import Principal
from app.library import Library, current_library
from tests.auth_helpers import flac_track
from tests.conftest import bearer


def _register(client, username):
    response = client.post(
        "/auth/register", json={"username": username, "password": "correct horse battery"}
    )
    assert response.status_code == 201, response.text
    return response.json()


def _request_as(client, user_id):
    principal = Principal(
        user_id=user_id, is_admin=False, is_master_admin=False, session_hash="00" * 32
    )
    return Request({"type": "http", "app": client.app, "state": {"principal": principal}})


def test_the_library_is_the_principals_with_the_principals_root(app_client, tmp_path):
    sam = _register(app_client, "Sam")["user"]["id"]

    library = current_library(_request_as(app_client, sam))

    assert isinstance(library, Library)
    assert library.owner_id == sam
    folder = app_client.app.state.database.get_user(sam)["library_folder"]
    assert library.root == tmp_path / "music" / folder


def test_the_master_admin_gets_the_admins_library(app_client, tmp_path):
    admin = app_client.app.state.admin_user_id

    library = current_library(_request_as(app_client, admin))

    assert library.owner_id == admin
    assert library.root == app_client.app.state.admin_library.root


def test_each_caller_browses_only_their_own_tracks(app_client, tmp_path):
    db = app_client.app.state.database
    body = _register(app_client, "Sam")
    sam = body["user"]["id"]
    sam_folder = db.get_user(sam)["library_folder"]
    mine = flac_track(tmp_path / "music" / "admin" / "Airbag.flac", "Airbag")
    theirs = flac_track(tmp_path / "music" / sam_folder / "Lucky.flac", "Lucky")
    assert app_client.app.state.admin_library.add_track(mine)
    assert Library(db, sam).add_track(theirs)

    as_sam = app_client.get("/tracks", headers=bearer(body["token"])).json()
    as_admin = app_client.get("/tracks").json()

    assert [t["uuid_id"] for t in as_sam["data"]] == [theirs.uuid_id]
    assert [t["uuid_id"] for t in as_admin["data"]] == [mine.uuid_id]
