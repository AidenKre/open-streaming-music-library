"""Review r1 m-R1-02, decision DEV-M-10: an imported archive is set aside.

Changed by the sign-off of DEV-M-10 (2026-11-17): an archive whose every audio
file was imported is deleted; ``.imported/`` keeps an archive with a refused
track. These live-server tests use one-track archives, so they now see the
deletion; the restart test still proves nothing is extracted twice.

After an archive dropped in ``IMPORT_DIR`` or ``USER_IMPORT_DIR/<folder>/`` has
been extracted and handled, it moves to that import folder's ``.imported/``
and its extraction directory leaves the workspace. ``.imported/`` (like any
dot-folder) is never scanned, watched or dispatched, so a restart neither
re-extracts the archive nor imports a duplicate once the original track's
path has been vacated (by a relocation, a conversion or a hand move).
"""

import contextlib
import errno
import logging
import pathlib
import sqlite3
import zipfile
from unittest.mock import patch

from fastapi.testclient import TestClient

from app.database.database import Database
from app.library import Library
from tests.owned_database import add_test_user
from tests.test_import_startup import WATCH, _drain_imports, _tone, requires_ffmpeg


import pytest

pytestmark = pytest.mark.usefixtures("fast_stability_poll")


def _zip_of_tone(path, title, tmp_path):
    song = tmp_path / "src" / f"{title}.mp3"
    _tone(song, title)
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as z:
        z.write(song, f"{title}.mp3")
    return path


def _workspace_files(tmp_path):
    root = tmp_path / "data" / "workspace"
    return sorted(str(p.relative_to(root)) for p in root.rglob("*")) if root.exists() else []


def _boot_and_drain(configure_app):
    with TestClient(configure_app(env=WATCH).app) as c:
        _drain_imports(c)
        db = c.app.state.database
        return db, c.app.state.admin_user_id


@requires_ffmpeg
def test_imported_archives_are_deleted_and_the_workspace_is_left_empty(
    configure_app, tmp_path
):
    with TestClient(configure_app().app) as c:
        sam_id = add_test_user(c.app.state.database, "sam")
    admin_zip = _zip_of_tone(tmp_path / "import" / "admin-album.zip", "Airbag", tmp_path)
    sam_zip = _zip_of_tone(tmp_path / "import-users" / "sam" / "Albums" / "album.zip", "Lucky", tmp_path)

    db, admin_id = _boot_and_drain(configure_app)

    assert [t.metadata.title for t in Library(db, sam_id).get_tracks()] == ["Lucky"]
    assert [t.metadata.title for t in Library(db, admin_id).get_tracks()] == ["Airbag"]
    assert not sam_zip.exists() and not admin_zip.exists()
    assert not (tmp_path / "import-users" / "sam" / ".imported").exists()
    assert not (tmp_path / "import" / ".imported").exists()
    # Only the per-user workspace roots (``u<id>``) remain, and they are empty.
    assert [f for f in _workspace_files(tmp_path) if "/" in f] == []


@requires_ffmpeg
def test_a_restart_neither_re_extracts_nor_duplicates_a_vacated_track(configure_app, tmp_path):
    """The reviewer's reproduction: import a zip, vacate the track's original
    path (what a conversion or a relocating edit does), restart."""
    with TestClient(configure_app().app) as c:
        sam_id = add_test_user(c.app.state.database, "sam")
    _zip_of_tone(tmp_path / "import-users" / "sam" / "album.zip", "Lucky", tmp_path)
    db, _ = _boot_and_drain(configure_app)
    (track,) = Library(db, sam_id).get_tracks()
    track.file_path.rename(track.file_path.with_suffix(".m4a"))

    for _ in range(2):
        db, _ = _boot_and_drain(configure_app)

        assert len(Library(db, sam_id).get_tracks()) == 1
        assert [p for p in (tmp_path / "import-users" / "sam").rglob("*") if p.is_file()] == []
        assert [f for f in _workspace_files(tmp_path) if "/" in f] == []


def _sam_zip_kept_then_imported(configure_app, tmp_path, caplog, inject):
    """Boot once with ``inject`` active: the zip must stay in sam's folder
    with nothing imported and nothing left in the workspace, logged once.
    Boot again without it: the next scan imports it and sets it aside."""
    with TestClient(configure_app().app) as c:
        sam_id = add_test_user(c.app.state.database, "sam")
    sam_zip = _zip_of_tone(tmp_path / "import-users" / "sam" / "album.zip", "Lucky", tmp_path)
    before = sam_zip.read_bytes()

    with inject(), caplog.at_level(logging.INFO):
        db, _ = _boot_and_drain(configure_app)

    assert Library(db, sam_id).get_tracks() == []
    assert sam_zip.read_bytes() == before
    assert not (tmp_path / "import-users" / "sam" / ".imported").exists()
    assert [f for f in _workspace_files(tmp_path) if "/" in f] == []
    assert [p for p in (tmp_path / "music").rglob("*") if p.is_file()] == []
    warnings = [
        r for r in caplog.records
        if r.levelno >= logging.WARNING and "album.zip" in r.getMessage()
    ]
    assert len(warnings) == 1, [r.getMessage() for r in warnings]

    db, _ = _boot_and_drain(configure_app)

    assert [t.metadata.title for t in Library(db, sam_id).get_tracks()] == ["Lucky"]
    assert not sam_zip.exists()
    assert not (tmp_path / "import-users" / "sam" / ".imported").exists()  # all imported: deleted


@requires_ffmpeg
def test_an_archive_whose_track_hits_a_locked_database_stays_for_the_next_scan(
    configure_app, tmp_path, caplog
):
    """Review r2 m-R2-01: ``add_track`` gives up on ``database is locked``."""
    real_add_track = Database.add_track

    def add_track_on_a_locked_database(self, track, timeout=5, *, owner_id, **kwargs):
        real_connection = self._connection

        @contextlib.contextmanager
        def locked(*args, **kwargs):
            if kwargs.get("commit"):
                raise sqlite3.OperationalError("database is locked")
            with real_connection(*args, **kwargs) as conn:
                yield conn

        with patch.object(self, "_connection", side_effect=locked):
            return real_add_track(self, track, timeout, owner_id=owner_id, **kwargs)

    _sam_zip_kept_then_imported(
        configure_app, tmp_path, caplog,
        lambda: patch.object(Database, "add_track", add_track_on_a_locked_database),
    )


@requires_ffmpeg
def test_an_archive_whose_tracks_cannot_be_renamed_across_mounts_stays_for_the_next_scan(
    configure_app, tmp_path, caplog
):
    """Review r2 m-R2-01: the extraction workspace sits under APP_DATA_DIR;
    a library on another mount refuses the rename with EXDEV."""
    workspace = (tmp_path / "data" / "workspace").resolve()
    real_replace = pathlib.Path.replace

    def cross_device(self, target):
        if pathlib.Path(self).resolve().is_relative_to(workspace):
            raise OSError(errno.EXDEV, "Invalid cross-device link")
        return real_replace(self, target)

    _sam_zip_kept_then_imported(
        configure_app, tmp_path, caplog,
        lambda: patch.object(pathlib.Path, "replace", cross_device),
    )
