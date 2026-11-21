"""Phase M.0c (spec §6.3 "make_pipeline(owner)", M.0 part).

``make_pipeline(owner)`` builds today's Organizer and Ingestor for one owner:
the owner's library root, ``Library(db, owner).add_track`` and a workspace
``workspace/u<user_id>/``. In M.0 the server builds only the admin's pipeline,
for ``IMPORT_DIR``.
"""

from unittest.mock import patch

import pytest

from app.database import DatabaseContext
from app.models import TrackMetaData
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.import_outcome import ImportOutcome
from app.services.pipeline import make_pipeline
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL


@pytest.fixture
def env(tmp_path):
    db = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert db.initialize()
    manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
    return db, manager, tmp_path


def _pipeline(env, user_id):
    db, manager, tmp = env
    return make_pipeline(
        db.get_user(user_id),
        database=db,
        cover_art_manager=manager,
        music_library_dir=tmp / "music",
        workspace_root=tmp / "data" / "workspace",
    )


def test_the_pipeline_uses_the_owners_root_and_numeric_workspace(env):
    db, _, tmp = env
    sam = add_test_user(db, "Sam")

    organizer, ingestor = _pipeline(env, sam)

    assert organizer.ctx.music_library_dir == tmp / "music" / "sam"
    assert ingestor.ctx.workspace_dir == tmp / "data" / "workspace" / f"u{sam}"


def _organize(organizer, tmp, name):
    source = tmp / "import" / name
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"audio")
    with (
        patch("app.services.organizer.get_track_metadata") as get_track_metadata,
        patch("app.services.organizer.extract_cover_art_bytes", return_value=None),
    ):
        get_track_metadata.return_value = TrackMetaData(
            title=name, artist="Radiohead", duration=1.0,
        )
        return organizer.organize(file_path=source) is ImportOutcome.IMPORTED


def test_an_ingested_file_lands_in_the_owners_library_and_root(env):
    db, _, tmp = env
    sam = add_test_user(db, "Sam")
    organizer, _ = _pipeline(env, sam)

    assert _organize(organizer, tmp, "song.mp3") is True

    [track] = db.get_tracks(owner_id=sam)
    assert track.file_path == tmp / "music" / "sam" / "Radiohead" / "song.mp3"
    assert track.file_path.is_file()
    assert db.get_tracks(owner_id=db.owner_id) == []


def test_two_owners_pipelines_stay_apart(env):
    db, _, tmp = env
    sam = add_test_user(db, "Sam")
    sam_organizer, _ = _pipeline(env, sam)
    own_organizer, _ = _pipeline(env, db.owner_id)

    assert _organize(sam_organizer, tmp, "a.mp3")
    assert _organize(own_organizer, tmp, "b.mp3")

    assert [t.file_path.name for t in db.get_tracks(owner_id=sam)] == ["a.mp3"]
    assert [t.file_path.name for t in db.get_tracks(owner_id=db.owner_id)] == ["b.mp3"]
    assert (tmp / "music" / "owner" / "Radiohead" / "b.mp3").is_file()


def test_the_server_builds_the_admins_pipeline_for_the_import_dir(configure_app, tmp_path):
    from fastapi.testclient import TestClient

    main = configure_app(env={"ENABLE_FILE_WATCHER": "true"})
    with TestClient(main.app) as client:
        state = client.app.state
        admin = state.database.get_user(state.admin_user_id)

        assert state.organizer.ctx.music_library_dir == tmp_path / "music" / admin["library_folder"]
        assert state.ingestor.ctx.workspace_dir == (
            tmp_path / "data" / "workspace" / f"u{state.admin_user_id}"
        )
        assert state.file_watcher.import_dir == tmp_path / "import"
