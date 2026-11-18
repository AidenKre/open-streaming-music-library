"""Phase M.0b (SC-28 rule 3): ``Library(db, owner_id)`` binds one owner over an
explicit allow-list of owned ``Database`` methods, and ``current_library``
returns the master admin's ``Library`` until M.1 adds a principal."""

import sqlite3
from pathlib import Path

import pytest

from app.database import ANY_OWNER, Database, DatabaseContext
from app.library import Library, current_library
from app.models import Track, TrackMetaData
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL


@pytest.fixture
def db(tmp_path):
    database = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    return database


def _track(title="Airbag"):
    return Track(
        file_path=f"/music/{title}.flac",
        metadata=TrackMetaData(
            title=title, artist="Radiohead", album="OK Computer", codec="flac",
            duration=1.0, bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
        ),
    )


def _track_owner(db, uuid_id):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return conn.execute(
            "SELECT owner_id FROM tracks WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()[0]
    finally:
        conn.close()


def test_a_library_writes_under_its_own_owner(db):
    sam = add_test_user(db, "sam")
    track = _track()

    assert Library(db, sam).add_track(track)

    assert _track_owner(db, track.uuid_id) == sam


def test_a_bound_method_refuses_a_caller_supplied_owner(db):
    sam, alex = add_test_user(db, "sam"), add_test_user(db, "alex")

    with pytest.raises(TypeError):
        Library(db, sam).add_track(_track(), owner_id=alex)


@pytest.mark.parametrize(
    "name",
    [
        "get_setting",
        "set_setting",
        "get_server_instance_id",
        "create_master_admin",
        "initialize",
        "context",
        "_connection",
        "_upsert_artist",
        "no_such_method",
    ],
)
def test_a_library_exposes_nothing_outside_its_allow_list(db, name):
    with pytest.raises(AttributeError):
        getattr(Library(db, 1), name)


def test_a_library_exposes_its_owner_and_root(db, tmp_path):
    library = Library(db, 7, root=tmp_path / "music" / "sam")

    assert library.owner_id == 7
    assert library.root == tmp_path / "music" / "sam"
    assert Library(db, 7).root is None


def test_a_library_is_a_binding_not_a_database(db):
    assert not isinstance(Library(db, 1), Database)


@pytest.mark.parametrize("owner", [None, ANY_OWNER, True, "1", 1.0])
def test_a_library_needs_a_real_owner_id(db, owner):
    with pytest.raises(TypeError):
        Library(db, owner)


def test_the_app_exposes_the_master_admins_library(app_client):
    library = app_client.app.state.admin_library

    assert isinstance(library, Library)
    assert library.owner_id == app_client.app.state.admin_user_id


def test_current_library_without_a_principal_is_refused_not_the_admins(app_client):
    # M.0 returned the admin's Library for every request; from M.1b it binds
    # the principal's (tests/test_current_library.py) and fails closed here.
    from fastapi import HTTPException
    from starlette.requests import Request

    request = Request({"type": "http", "app": app_client.app})

    with pytest.raises(HTTPException) as caught:
        current_library(request)
    assert caught.value.status_code == 401
