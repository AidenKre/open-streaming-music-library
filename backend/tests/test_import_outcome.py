"""Review r2 m-R2-01: the organizer says why a file was not imported.

``Organizer.organize(path)`` returns an ``ImportOutcome``. A duplicate, a file
without usable metadata or with an unusable name is refused for a reason of
its own. ``add_track`` giving up (``database is locked``) and a rename that the
filesystem refuses (a library on another mount: ``EXDEV``) are environmental:
the same bytes may import on a later attempt, so an archive holding such a
member must not be set aside.
"""

import contextlib
import errno
import pathlib
import sqlite3
from unittest.mock import patch

import pytest

from app.database import DatabaseContext
from app.models import TrackMetaData
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.import_outcome import ImportOutcome
from app.services.pipeline import make_pipeline
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL

FILES_OWN = {ImportOutcome.DUPLICATE, ImportOutcome.NOT_AUDIO, ImportOutcome.FAILS_CHECK}
ENVIRONMENTAL = {
    ImportOutcome.TOOL_UNAVAILABLE,
    ImportOutcome.DATABASE_ERROR,
    ImportOutcome.MOVE_FAILED,
    # Sign-off DEV-7-14 point 1: an archive not unpacked for lack of space or
    # a failed write is retried later.
    ImportOutcome.NO_SPACE,
    ImportOutcome.UNPACK_FAILED,
}


@pytest.fixture
def env(tmp_path):
    db = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert db.initialize()
    manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
    sam = add_test_user(db, "Sam")
    organizer, _ = make_pipeline(
        db.get_user(sam),
        database=db,
        cover_art_manager=manager,
        music_library_dir=tmp_path / "music",
        workspace_root=tmp_path / "data" / "workspace",
    )
    return db, sam, organizer, tmp_path


def _source(tmp, name="song.mp3", data=b"audio"):
    source = tmp / "import" / name
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(data)
    return source


@contextlib.contextmanager
def _tags(title="Song", artist="Radiohead"):
    with (
        patch("app.services.organizer.get_track_metadata") as get_track_metadata,
        patch("app.services.organizer.extract_cover_art_bytes", return_value=None),
    ):
        get_track_metadata.return_value = (
            None if title is None else TrackMetaData(title=title, artist=artist, duration=1.0)
        )
        yield


def _library_files(tmp):
    root = tmp / "music"
    return sorted(p for p in root.rglob("*") if p.is_file()) if root.exists() else []


def test_the_classes_are_disjoint_and_cover_every_failure():
    for outcome in ImportOutcome:
        assert not (outcome.belongs_to_file and outcome.environmental), outcome
    assert {o for o in ImportOutcome if o.belongs_to_file} == FILES_OWN
    assert {o for o in ImportOutcome if o.environmental} == ENVIRONMENTAL
    assert not ImportOutcome.IMPORTED.belongs_to_file
    assert not ImportOutcome.IMPORTED.environmental
    # REFUSED is an archive's outcome, never a member's: the archive stays in
    # place (not set aside like a member's own refusal, not retried like an
    # environmental one).
    for abandoned in (ImportOutcome.CHANGED, ImportOutcome.STOPPED, ImportOutcome.REFUSED):
        assert not abandoned.belongs_to_file and not abandoned.environmental


def test_an_imported_file_says_so(env):
    db, sam, organizer, tmp = env
    with _tags():
        assert organizer.organize(_source(tmp)) is ImportOutcome.IMPORTED
    assert len(db.get_tracks(owner_id=sam)) == 1


def test_a_duplicate_destination_is_the_files_own_refusal(env):
    db, sam, organizer, tmp = env
    with _tags():
        assert organizer.organize(_source(tmp)) is ImportOutcome.IMPORTED
        again = _source(tmp)
        assert organizer.organize(again) is ImportOutcome.DUPLICATE
    assert again.read_bytes() == b"audio"
    assert len(db.get_tracks(owner_id=sam)) == 1


def test_a_file_without_metadata_is_the_files_own_refusal(env):
    db, sam, organizer, tmp = env
    with _tags(title=None):
        assert organizer.organize(_source(tmp)) is ImportOutcome.FAILS_CHECK
    assert db.get_tracks(owner_id=sam) == []


def test_add_track_giving_up_on_a_locked_database_is_environmental(env):
    db, sam, organizer, tmp = env
    source = _source(tmp)
    real_connection = db._connection

    @contextlib.contextmanager
    def locked(*args, **kwargs):
        if kwargs.get("commit"):
            raise sqlite3.OperationalError("database is locked")
        with real_connection(*args, **kwargs) as conn:
            yield conn

    with _tags(), patch.object(db, "_connection", side_effect=locked):
        outcome = organizer.organize(source)

    assert outcome is ImportOutcome.DATABASE_ERROR
    assert outcome.environmental
    # Rolled back: the file is where it was and nothing is left in the library.
    assert source.read_bytes() == b"audio"
    assert _library_files(tmp) == []
    assert db.get_tracks(owner_id=sam) == []


def test_a_rename_refused_across_mounts_is_environmental(env, monkeypatch):
    db, sam, organizer, tmp = env
    source = _source(tmp)
    real_replace = pathlib.Path.replace

    def cross_device(self, target):
        if pathlib.Path(self) == source:
            raise OSError(errno.EXDEV, "Invalid cross-device link")
        return real_replace(self, target)

    monkeypatch.setattr(pathlib.Path, "replace", cross_device)
    with _tags():
        outcome = organizer.organize(source)

    assert outcome is ImportOutcome.MOVE_FAILED
    assert outcome.environmental
    assert source.read_bytes() == b"audio"
    assert _library_files(tmp) == []
    assert db.get_tracks(owner_id=sam) == []


def test_organize_file_stays_a_boolean(env):
    _, _, organizer, tmp = env
    with _tags():
        assert organizer.organize_file(_source(tmp)) is True
        assert organizer.organize_file(_source(tmp)) is False


def test_a_file_that_changes_after_it_was_read_is_left_untouched(tmp_path):
    """Review r2 m-R2-02 (DEV-M-14): size and modification time are re-checked
    right before the move. A file a writer is still appending to is abandoned
    without being touched: no row, no pre-warm, or anything in the library."""
    db = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert db.initialize()
    manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
    sam = add_test_user(db, "Sam")
    warmed = []
    organizer, _ = make_pipeline(
        db.get_user(sam),
        database=db,
        cover_art_manager=manager,
        music_library_dir=tmp_path / "music",
        workspace_root=tmp_path / "data" / "workspace",
        on_track_added=lambda uuid, owner: warmed.append(uuid),
    )
    source = _source(tmp_path)

    def read_while_the_copy_goes_on(file_path):
        with open(source, "ab") as f:
            f.write(b" more audio")
        return TrackMetaData(title="Song", artist="Radiohead", duration=1.0)

    with (
        patch("app.services.organizer.get_track_metadata", side_effect=read_while_the_copy_goes_on),
        patch("app.services.organizer.extract_cover_art_bytes", return_value=None),
    ):
        outcome = organizer.organize(source)

    assert outcome is ImportOutcome.CHANGED
    assert source.read_bytes() == b"audio more audio"
    assert _library_files(tmp_path) == []
    assert db.get_tracks(owner_id=sam) == []
    assert warmed == []
