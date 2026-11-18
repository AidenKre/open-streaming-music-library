"""Phase M.2a (M-U16, spec §6.3 "The dispatcher"): files under
``USER_IMPORT_DIR/<folder>/`` are ingested by that folder's owner.

- The first path component is compared by ``casefold()`` with
  ``users.library_folder``; the owner's pipeline is built lazily and cached.
- Files directly in ``USER_IMPORT_DIR`` or under an unknown folder are logged
  and ignored.
- The owner is fixed by which pipeline handles the file, before any archive
  extraction (a zip under ``sam/`` lands only in sam's library).
- A disabled user's drops are still imported.
- Decision O2 / DEV-M-02: the master admin's folder is mapped like any other.
"""

import logging
import sqlite3
import subprocess
import zipfile
from functools import partial

import pytest

from app.database import DatabaseContext
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.import_folders import ImportDispatcher
from app.services.pipeline import make_pipeline
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL

# Registered marker (plan D16): tests/conftest.py skips without ffmpeg/ffprobe.
requires_ffmpeg = pytest.mark.requires_ffmpeg


class _FakeIngestor:
    def __init__(self, owner_id, seen):
        self.owner_id = owner_id
        self.seen = seen
        self.imported_dirs: list = []

    def ingest_file(self, path, *, imported_dir=None):
        self.seen.append((self.owner_id, path))
        self.imported_dirs.append(imported_dir)
        return True


@pytest.fixture
def ingestors():
    """Every ``_FakeIngestor`` the test's dispatcher built, in order."""
    return []


@pytest.fixture
def env(tmp_path, ingestors):
    db = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert db.initialize()
    root = tmp_path / "import-users"
    root.mkdir()
    seen, built = [], []

    def factory(user):
        built.append(user["id"])
        ingestor = _FakeIngestor(user["id"], seen)
        ingestors.append(ingestor)
        return None, ingestor

    dispatcher = ImportDispatcher(user_import_dir=root, database=db, make_pipeline=factory)
    return db, root, dispatcher, seen, built


def _drop(root, relative, data=b"audio"):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def test_a_file_under_a_users_folder_goes_to_that_users_pipeline(env):
    db, root, dispatcher, seen, _ = env
    sam = add_test_user(db, "sam")
    alex = add_test_user(db, "alex")
    song = _drop(root, "sam/album/song.mp3")

    assert dispatcher.dispatch(song) is True

    assert seen == [(sam, song)]
    assert alex not in {owner for owner, _ in seen}


def test_a_handled_archive_is_set_aside_in_its_own_import_folder(env, ingestors):
    """Review r1 m-R1-02 / DEV-M-10: the dispatcher hands the ingestor the
    ``.imported/`` of the folder the file was dropped in (its on-disk name)."""
    db, root, dispatcher, seen, _ = env
    add_test_user(db, "sam")
    drop = _drop(root, "Sam/Albums/album.zip")

    dispatcher.dispatch(drop)

    assert [d for ingestor in ingestors for d in ingestor.imported_dirs] == [root / "Sam" / ".imported"]


def test_folders_match_by_casefold(env):
    db, root, dispatcher, seen, _ = env
    sam = add_test_user(db, "sam")  # library_folder "sam"
    song = _drop(root, "SAM/song.mp3")

    dispatcher.dispatch(song)

    assert seen == [(sam, song)]


def test_the_pipeline_is_built_once_per_owner(env):
    db, root, dispatcher, _, built = env
    sam = add_test_user(db, "sam")
    alex = add_test_user(db, "alex")

    for relative in ("sam/a.mp3", "Sam/b.mp3", "alex/c.mp3", "sam/d/e.mp3"):
        dispatcher.dispatch(_drop(root, relative))

    assert sorted(built) == sorted([sam, alex])


@pytest.mark.parametrize("relative", ["loose.mp3", "nobody/song.mp3"])
def test_root_and_unknown_folder_files_are_logged_and_ignored(env, caplog, relative):
    db, root, dispatcher, seen, built = env
    add_test_user(db, "sam")
    path = _drop(root, relative)

    with caplog.at_level(logging.INFO, logger="app.services.import_folders"):
        assert dispatcher.dispatch(path) is False

    assert seen == [] and built == []
    assert str(path) in caplog.text
    assert path.exists()  # ignored, not deleted


def test_a_path_outside_the_user_import_dir_is_ignored(env, tmp_path):
    db, _, dispatcher, seen, _ = env
    add_test_user(db, "sam")
    outside = _drop(tmp_path / "elsewhere", "sam/song.mp3")

    assert dispatcher.dispatch(outside) is False
    assert seen == []


def test_a_disabled_users_drops_are_still_imported(env):
    db, root, dispatcher, seen, _ = env
    sam = add_test_user(db, "sam")
    conn = sqlite3.connect(db.context.database_path)
    conn.execute("UPDATE users SET disabled_at = 1 WHERE id = ?", (sam,))
    conn.commit()
    conn.close()
    song = _drop(root, "sam/song.mp3")

    assert dispatcher.dispatch(song) is True
    assert seen == [(sam, song)]


def test_the_master_admins_folder_is_mapped_too(env):
    """O2 / DEV-M-02: no special case for the admin."""
    db, root, dispatcher, seen, _ = env
    admin_folder = db.get_user(db.owner_id)["library_folder"]
    song = _drop(root, f"{admin_folder}/song.mp3")

    dispatcher.dispatch(song)

    assert seen == [(db.owner_id, song)]


def test_a_user_created_after_the_dispatcher_is_mapped(env):
    db, root, dispatcher, seen, _ = env
    dispatcher.dispatch(_drop(root, "late/early.mp3"))  # unknown yet: ignored
    late = add_test_user(db, "late")
    song = _drop(root, "late/song.mp3")

    dispatcher.dispatch(song)

    assert seen == [(late, song)]


# ── real pipeline: the owner is fixed before extraction ──────────────────────

def _tone(path):
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3",
         "-metadata", f"title={path.stem}", "-metadata", "artist=Radiohead",
         "-c:a", "libmp3lame", str(path)],
        check=True,
    )


@requires_ffmpeg
def test_a_zip_under_sams_folder_lands_only_in_sams_library(tmp_path):
    db = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert db.initialize()
    sam = add_test_user(db, "sam")
    alex = add_test_user(db, "alex")
    manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
    music = tmp_path / "music"
    workspace = tmp_path / "data" / "workspace"
    root = tmp_path / "import-users"
    sources = tmp_path / "sources"
    sources.mkdir()
    for name in ("Airbag", "Lucky"):
        _tone(sources / f"{name}.mp3")
    archive = root / "Sam" / "ok-computer.zip"
    archive.parent.mkdir(parents=True)
    with zipfile.ZipFile(archive, "w") as z:
        for name in ("Airbag", "Lucky"):
            z.write(sources / f"{name}.mp3", arcname=f"OK Computer/{name}.mp3")
    dispatcher = ImportDispatcher(
        user_import_dir=root,
        database=db,
        make_pipeline=partial(
            make_pipeline,
            database=db,
            cover_art_manager=manager,
            music_library_dir=music,
            workspace_root=workspace,
        ),
    )

    assert dispatcher.dispatch(archive) is True

    sams = db.get_tracks(owner_id=sam)
    assert sorted(t.metadata.title for t in sams) == ["Airbag", "Lucky"]
    assert all(t.file_path.is_relative_to(music / "sam") for t in sams)
    assert db.get_tracks(owner_id=alex) == []
    assert db.get_tracks(owner_id=db.owner_id) == []
    # Extracted under sam's numeric workspace, never another owner's.
    assert [p.name for p in workspace.iterdir()] == [f"u{sam}"]


def test_a_user_being_deleted_gets_no_imports(env, caplog):
    """M.2b review #8: after ``users delete`` step 1 captured the user's art, no
    new track (or art) may be added for them. A disabled user still imports."""
    db, root, dispatcher, seen, built = env
    sam = add_test_user(db, "sam")
    conn = sqlite3.connect(db.context.database_path)
    conn.execute("UPDATE users SET deleting_at = 1, disabled_at = 1 WHERE id = ?", (sam,))
    conn.commit()
    conn.close()
    song = _drop(root, "sam/song.mp3")
    caplog.set_level(logging.INFO)

    assert dispatcher.dispatch(song) is False
    assert seen == [] and built == []
    assert "being deleted" in caplog.text


def test_a_file_under_a_dot_folder_is_never_dispatched(env):
    """Review r1 m-R1-02 / DEV-M-10: archives already set aside in
    ``.imported/`` are not imported again."""
    db, root, dispatcher, seen, _ = env
    add_test_user(db, "sam")

    for relative in ("sam/.imported/album.zip", "sam/Albums/.imported/x.mp3"):
        assert dispatcher.dispatch(_drop(root, relative)) is False

    assert seen == []
