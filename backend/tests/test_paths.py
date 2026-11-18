"""Phase M.0c (SC-28 rule 5, spec §4.2 "Library roots and paths", review M-U08).

``library_root(music_library_dir, user)`` is ``music_library_dir /
user.library_folder``; ``assert_within(path, root)`` refuses any path that is
not strictly inside ``root`` once symlinks are resolved.
"""

from pathlib import Path

import pytest

from app.database import DatabaseContext
from app.library import library_root
from app.services.path_sanitize import PathEscapesRoot, assert_within
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL


# ── assert_within ───────────────────────────────────────────────────────────

def test_a_path_inside_the_root_passes(tmp_path):
    root = tmp_path / "music" / "sam"

    assert_within(root / "Artist" / "Album" / "a.flac", root)  # need not exist


def test_the_root_itself_is_not_inside(tmp_path):
    root = tmp_path / "music" / "sam"

    with pytest.raises(PathEscapesRoot):
        assert_within(root, root)


@pytest.mark.parametrize(
    "relative", ["../alex/a.flac", "../../a.flac", "Artist/../../alex/a.flac"]
)
def test_dot_dot_out_of_the_root_is_refused(tmp_path, relative):
    root = tmp_path / "music" / "sam"

    with pytest.raises(PathEscapesRoot):
        assert_within(root / relative, root)


def test_a_sibling_whose_name_extends_the_root_is_refused(tmp_path):
    # A string-prefix check would wrongly accept music/sam-2 under music/sam.
    root = tmp_path / "music" / "sam"

    with pytest.raises(PathEscapesRoot):
        assert_within(tmp_path / "music" / "sam-2" / "a.flac", root)


def test_a_symlinked_folder_that_points_outside_is_refused(tmp_path):
    root = tmp_path / "music" / "sam"
    root.mkdir(parents=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    (root / "Evil").symlink_to(outside, target_is_directory=True)

    with pytest.raises(PathEscapesRoot):
        assert_within(root / "Evil" / "a.flac", root)


def test_a_root_reached_through_a_symlink_still_contains_its_files(tmp_path):
    real = tmp_path / "real"
    (real / "sam").mkdir(parents=True)
    link = tmp_path / "link"
    link.symlink_to(real, target_is_directory=True)

    assert_within(link / "sam" / "a.flac", link / "sam")
    assert_within(real / "sam" / "a.flac", link / "sam")


# ── library_root ────────────────────────────────────────────────────────────

def test_library_root_is_the_users_folder_under_the_music_dir(tmp_path):
    music = tmp_path / "music"

    assert library_root(music, {"library_folder": "sam-2"}) == music / "sam-2"


@pytest.mark.parametrize("folder", ["", ".", "..", "a/b", "../x", "/abs"])
def test_library_root_refuses_a_folder_that_is_not_one_plain_component(tmp_path, folder):
    with pytest.raises(PathEscapesRoot):
        library_root(tmp_path / "music", {"library_folder": folder})


# ── users lookups (server-wide) ─────────────────────────────────────────────

@pytest.fixture
def db(tmp_path):
    database = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    return database


def test_get_user_returns_the_row_or_none(db):
    sam = add_test_user(db, "Sam")

    user = db.get_user(sam)

    assert user["id"] == sam
    assert user["library_folder"] == "sam"
    assert user["username"] == "Sam"
    assert db.get_user(9999) is None


def test_get_library_folders_lists_every_users_folder(db):
    add_test_user(db, "Sam")
    add_test_user(db, "Alex")

    assert sorted(db.get_library_folders()) == ["alex", "owner", "sam"]


def test_a_user_folder_that_is_a_symlink_out_of_the_music_dir_is_refused(tmp_path):
    """Review r1 m-R1-27: ``library_root`` itself refuses a symlinked folder."""
    music = tmp_path / "music"
    outside = tmp_path / "outside"
    music.mkdir()
    outside.mkdir()
    (music / "sam").symlink_to(outside, target_is_directory=True)

    with pytest.raises(PathEscapesRoot):
        library_root(music, {"library_folder": "sam"})
