"""Phase M.1b (M-U12, SC-28 rule 3, spec §5.3): ``current_library()`` binds
the request principal's ``Library``, not the master admin's."""

import pytest
from fastapi import Depends, HTTPException
from fastapi.testclient import TestClient
from starlette.requests import Request

from app.auth.principal import Principal
from app.database.database import Database
from app.library import Library, current_library
from app.services.path_sanitize import PathEscapesRoot
from tests.auth_helpers import flac_track
from tests.conftest import bearer
from tests.sqlite_helpers import sql_rows


def _register(client, username):
    response = client.post(
        "/auth/register", json={"username": username, "password": "correct horse battery"}
    )
    assert response.status_code == 201, response.text
    return response.json()


def _request_as(client, user_id):
    """A request as the auth middleware leaves it: the principal, and beside it
    the library folder its session read found."""
    principal = Principal(
        user_id=user_id, is_admin=False, is_master_admin=False, session_hash="00" * 32
    )
    folder = client.app.state.database.get_user(user_id)["library_folder"]
    return Request({
        "type": "http", "app": client.app,
        "state": {"principal": principal, "library_folder": folder},
    })


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


# ── One read of the user row per request. The sign-in query already joins ``users``; the
# library folder travels with the session instead of a second read.


def _add_root_route(app):
    """A route that reports the Library its request got, through the real
    auth middleware and the real ``current_library`` dependency."""

    @app.get("/test-only/library")
    def library_seen(library: Library = Depends(current_library)):
        return {"owner_id": library.owner_id, "root": str(library.root)}


def _no_user_reads(monkeypatch):
    calls = []

    def refuse(self, user_id):
        calls.append(user_id)
        raise AssertionError("current_library read the user row a second time")

    monkeypatch.setattr(Database, "get_user", refuse)
    return calls


def test_a_signed_in_request_reads_the_user_row_once(app_client, tmp_path, monkeypatch):
    body = _register(app_client, "Sam")
    sam = body["user"]["id"]
    folder = app_client.app.state.database.get_user(sam)["library_folder"]
    _add_root_route(app_client.app)
    calls = _no_user_reads(monkeypatch)

    response = app_client.get("/test-only/library", headers=bearer(body["token"]))

    assert response.status_code == 200, response.text
    assert response.json() == {"owner_id": sam, "root": str(tmp_path / "music" / folder)}
    assert calls == []


def test_a_media_token_request_gets_its_folder_from_the_same_read(
    app_client, tmp_path, monkeypatch
):
    body = _register(app_client, "Sam")
    sam = body["user"]["id"]
    db = app_client.app.state.database
    folder = db.get_user(sam)["library_folder"]
    track = flac_track(tmp_path / "music" / folder / "Lucky.flac", "Lucky")
    assert Library(db, sam).add_track(track)
    calls = _no_user_reads(monkeypatch)

    # A client with no Authorization header: only the media token signs in.
    # No ``with``: the app is already started, a second lifespan would refuse.
    media_only = TestClient(app_client.app)

    response = media_only.get(
        f"/tracks/{track.uuid_id}/stream",
        params={"quality": "original", "access_token": body["media_token"]},
    )

    assert response.status_code == 200, response.text
    assert response.content == b"not really flac"
    assert calls == []


def test_the_folder_is_the_one_the_users_row_names_at_each_request(app_client, tmp_path):
    body = _register(app_client, "Sam")
    sam = body["user"]["id"]
    _add_root_route(app_client.app)
    first = app_client.get("/test-only/library", headers=bearer(body["token"])).json()

    sql_rows(app_client, "UPDATE users SET library_folder = 'sam-moved' WHERE id = ?", (sam,))
    second = app_client.get("/test-only/library", headers=bearer(body["token"])).json()

    assert first["root"] != second["root"]
    assert second["root"] == str(tmp_path / "music" / "sam-moved")


@pytest.mark.parametrize("folder", ["..", ".", "a/b", "/abs"])
def test_a_user_whose_folder_name_is_invalid_is_still_refused(app_client, folder):
    body = _register(app_client, "Sam")
    sam = body["user"]["id"]
    _add_root_route(app_client.app)
    sql_rows(app_client, "UPDATE users SET library_folder = ? WHERE id = ?", (folder, sam))

    with pytest.raises(PathEscapesRoot):
        app_client.get("/test-only/library", headers=bearer(body["token"]))


def test_a_principal_without_a_session_folder_is_refused(app_client):
    principal = Principal(
        user_id=app_client.app.state.admin_user_id, is_admin=True,
        is_master_admin=True, session_hash="00" * 32,
    )
    request = Request({"type": "http", "app": app_client.app, "state": {"principal": principal}})

    with pytest.raises(HTTPException) as caught:
        current_library(request)
    assert caught.value.status_code == 401
