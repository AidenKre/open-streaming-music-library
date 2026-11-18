"""Phase 7A.1a (SC-16f + its Phase M note, 7-U11, plan drift D6): one module
lists the internal dot-directories under ``MUSIC_LIBRARY_DIR`` (``.staging``
today, ``.uploads`` for Phase 7; Phase 8 appends ``.deleting``). Startup
creates them and refuses, before any write, an internal directory on another
filesystem than the library or overlapping an import tree or another internal
directory."""

import logging
import os

import pytest
from fastapi.testclient import TestClient

from app.core import internal_dirs
from app.core.internal_dirs import INTERNAL_DIRS, InternalDirRefused, internal_dirs as dirs_of


# ── the registry ───────────────────────────────────────────────────────────

def test_the_registry_lists_staging_then_uploads_then_deleting():
    # Phase 8A.3c (drift D7, decision O2): the deletion quarantine.
    assert INTERNAL_DIRS == (".staging", ".uploads", ".deleting")


def test_the_dirs_live_directly_under_the_music_library(tmp_path):
    music = tmp_path / "music"

    assert dirs_of(music) == (music / ".staging", music / ".uploads", music / ".deleting")


def test_a_refusal_is_a_runtime_error():
    # Startup refusals share the existing "fail startup" type.
    assert issubclass(InternalDirRefused, RuntimeError)


# ── startup creates them ───────────────────────────────────────────────────

def test_startup_creates_every_internal_dir(app_client, tmp_path):
    assert (tmp_path / "music" / ".staging").is_dir()
    assert (tmp_path / "music" / ".uploads").is_dir()
    assert (tmp_path / "music" / ".deleting").is_dir()


def test_a_restart_keeps_existing_internal_dirs_and_their_contents(open_app_client, tmp_path):
    with open_app_client():
        pass
    staged = tmp_path / "music" / ".uploads" / "batch" / "item" / "source.flac"
    staged.parent.mkdir(parents=True)
    staged.write_bytes(b"staged")

    with open_app_client() as client:
        assert client.get("/").status_code == 200

    assert staged.read_bytes() == b"staged"


def test_a_symlinked_internal_dir_on_the_library_filesystem_still_starts(
    configure_app, tmp_path
):
    # A layout that worked before 7A.1a: .staging redirected elsewhere on the
    # same filesystem, outside every import tree.
    elsewhere = tmp_path / "scratch" / "staging"
    elsewhere.mkdir(parents=True)
    (tmp_path / "music").mkdir()
    (tmp_path / "music" / ".staging").symlink_to(elsewhere, target_is_directory=True)
    main = configure_app()

    with TestClient(main.app) as client:
        assert client.get("/").status_code == 200


# ── startup refuses, before any write ──────────────────────────────────────

def _refuses_before_any_write(main, tmp_path, caplog, match):
    with caplog.at_level(logging.INFO, logger="uvicorn.error"):
        with pytest.raises(RuntimeError, match=match):
            with TestClient(main.app):
                pass
    # Nothing was written: no database, no other internal dir created.
    assert not (tmp_path / "data" / "database" / "database.db").exists()
    assert not os.path.lexists(tmp_path / "music" / ".staging")
    # The operator sees why, without a path.
    lines = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    assert any(".uploads" in line for line in lines), lines
    assert not any(str(tmp_path) in line for line in lines), lines


def _uploads(tmp_path):
    (tmp_path / "music").mkdir(exist_ok=True)
    return tmp_path / "music" / ".uploads"


@pytest.mark.parametrize("tree", ["import", "import-users"])
def test_an_internal_dir_inside_an_import_tree_refuses_to_start(
    configure_app, tmp_path, caplog, tree
):
    target = tmp_path / tree / "uploads"
    target.mkdir(parents=True)
    _uploads(tmp_path).symlink_to(target, target_is_directory=True)
    main = configure_app()

    _refuses_before_any_write(main, tmp_path, caplog, r"\.uploads.*import")


def test_an_internal_dir_that_is_an_import_tree_refuses_to_start(
    configure_app, tmp_path, caplog
):
    (tmp_path / "import").mkdir()
    _uploads(tmp_path).symlink_to(tmp_path / "import", target_is_directory=True)
    main = configure_app()

    _refuses_before_any_write(main, tmp_path, caplog, r"\.uploads.*import")


def test_an_internal_dir_on_another_filesystem_refuses_to_start(
    configure_app, tmp_path, caplog, monkeypatch
):
    real = internal_dirs.filesystem_id

    def fake(path):
        device = real(path)
        return device + 1 if os.path.basename(os.path.normpath(path)) == ".uploads" else device

    _uploads(tmp_path).mkdir()
    main = configure_app()
    monkeypatch.setattr(internal_dirs, "filesystem_id", fake)

    _refuses_before_any_write(main, tmp_path, caplog, r"\.uploads.*filesystem")


def test_internal_dirs_overlapping_each_other_refuse_to_start(configure_app, tmp_path, caplog):
    # .uploads redirected into .staging would put upload stages in reach of the
    # staging sweep. (.staging is created here, so check the db only.)
    staging = tmp_path / "music" / ".staging"
    staging.mkdir(parents=True)
    _uploads(tmp_path).symlink_to(staging, target_is_directory=True)
    main = configure_app()

    with caplog.at_level(logging.INFO, logger="uvicorn.error"):
        with pytest.raises(RuntimeError, match=r"\.uploads.*\.staging|\.staging.*\.uploads"):
            with TestClient(main.app):
                pass
    assert not (tmp_path / "data" / "database" / "database.db").exists()


@pytest.mark.parametrize("kind", ["file", "dangling-symlink"])
def test_an_internal_dir_that_is_not_a_directory_refuses_to_start(
    configure_app, tmp_path, caplog, kind
):
    uploads = _uploads(tmp_path)
    if kind == "file":
        uploads.write_bytes(b"not a dir")
    else:
        uploads.symlink_to(tmp_path / "gone", target_is_directory=True)
    main = configure_app()

    _refuses_before_any_write(main, tmp_path, caplog, r"\.uploads.*directory")


# ── the validator on its own ───────────────────────────────────────────────

def test_ensure_creates_and_returns_every_dir(tmp_path):
    music = tmp_path / "music"
    music.mkdir()

    created = internal_dirs.ensure_internal_dirs(music, import_trees=(tmp_path / "import",))

    assert created == dirs_of(music)
    assert all(d.is_dir() for d in created)
    # Idempotent.
    assert internal_dirs.ensure_internal_dirs(music, import_trees=()) == created


@pytest.mark.parametrize("tree, setting", [("import", "IMPORT_DIR"), ("import-users", "USER_IMPORT_DIR")])
def test_an_import_overlap_refusal_names_the_setting_to_fix(
    configure_app, tmp_path, caplog, tree, setting
):
    # The operator has to act on it, so name the setting (never the path).
    target = tmp_path / tree / "uploads"
    target.mkdir(parents=True)
    _uploads(tmp_path).symlink_to(target, target_is_directory=True)
    main = configure_app()

    _refuses_before_any_write(main, tmp_path, caplog, rf"\.uploads.*\b{setting}\b")


# ── prune_empty_dirs never touches an internal dir (S5) ────────────────────

def test_prune_never_removes_an_empty_internal_dir_or_its_stages(tmp_path):
    from app.services.organizer import prune_empty_dirs

    music = tmp_path / "music"
    item = music / ".uploads" / "batch" / "item"
    item.mkdir(parents=True)
    (music / ".staging").mkdir()

    prune_empty_dirs(item, music)
    prune_empty_dirs(music / ".uploads", music)
    prune_empty_dirs(music / ".staging", music)

    assert item.is_dir()
    assert (music / ".staging").is_dir()


def test_prune_keeps_a_staged_file_and_its_directories(tmp_path):
    from app.services.organizer import prune_empty_dirs

    music = tmp_path / "music"
    staged = music / ".uploads" / "batch" / "item" / "source.flac"
    staged.parent.mkdir(parents=True)
    staged.write_bytes(b"staged")
    empty_sibling = music / ".uploads" / "batch" / "other"
    empty_sibling.mkdir()

    prune_empty_dirs(empty_sibling, music)

    assert staged.read_bytes() == b"staged"
    assert empty_sibling.is_dir()


def test_prune_never_removes_an_empty_quarantine_folder(tmp_path):
    # Phase 8A.3c: .deleting/<owner>/<op>/ is pruned by the deletion worker's own
    # rmdir only, never by the library prune walking up from a track's folder.
    from app.services.organizer import prune_empty_dirs

    music = tmp_path / "music"
    op = music / ".deleting" / "1" / "op"
    op.mkdir(parents=True)

    prune_empty_dirs(op, music)

    assert op.is_dir()


def test_prune_still_removes_ordinary_empty_library_dirs(tmp_path):
    from app.services.organizer import prune_empty_dirs

    music = tmp_path / "music"
    album = music / "Radiohead" / "OK Computer"
    album.mkdir(parents=True)
    (music / ".uploads").mkdir()

    prune_empty_dirs(album, music)

    assert not (music / "Radiohead").exists()
    assert (music / ".uploads").is_dir()


# ── the organizer never places a track in an internal dir (S6) ─────────────

@pytest.mark.parametrize("name", [".staging", ".uploads", ".deleting"])
def test_an_artist_named_like_an_internal_dir_is_foldered_beside_it(tmp_path, name):
    # 7-fix-r0 F0-2 (was: refused as FAILS_CHECK): the shared sanitizer folders
    # a component named exactly like an internal dir as "<name>_", so the track
    # is imported and the real internal dir stays untouched.
    from unittest.mock import Mock, patch

    from app.models.track_meta_data import TrackMetaData
    from app.services import organizer
    from app.services.import_outcome import ImportOutcome

    music = tmp_path / "music"
    (music / name).mkdir(parents=True)
    add_to_database = Mock(return_value=True)
    org = organizer.Organizer(organizer.OrganizerContext(
        music_library_dir=music, should_organize_files=True, should_copy_files=False,
        add_to_database=add_to_database,
    ))
    source = tmp_path / "input" / "file.mp3"
    source.parent.mkdir()
    source.write_bytes(b"audio")
    # The artist folder name collapses onto the internal dir's name.
    meta = TrackMetaData(duration=1.0, artist=name, album="album")

    with patch("app.services.organizer.get_track_metadata", return_value=meta):
        outcome = org.organize(source)

    assert outcome is ImportOutcome.IMPORTED
    assert (music / f"{name}_" / "album" / "file.mp3").read_bytes() == b"audio"
    assert list((music / name).iterdir()) == []
    add_to_database.assert_called_once()


def _organize(root, source, meta):
    from unittest.mock import Mock, patch

    from app.services import organizer

    add_to_database = Mock(return_value=True)
    org = organizer.Organizer(organizer.OrganizerContext(
        music_library_dir=root, should_organize_files=True, should_copy_files=False,
        add_to_database=add_to_database,
    ))
    with patch("app.services.organizer.get_track_metadata", return_value=meta):
        return org.organize(source), add_to_database


def _source(tmp_path):
    source = tmp_path / "input" / "file.mp3"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"audio")
    return source


def test_a_user_folder_named_like_an_internal_dir_is_suffixed_deeper_in_the_tree(tmp_path):
    # 7-fix-r0 F0-2 (was 7A.1a S6: refused as FAILS_CHECK): a metadata-derived
    # folder named exactly like an internal dir is foldered as "<name>_", the
    # same rule as Windows device names, so the track imports.
    from app.models.track_meta_data import TrackMetaData
    from app.services.import_outcome import ImportOutcome

    root = tmp_path / "music" / "alice"
    source = _source(tmp_path)

    outcome, add = _organize(
        root, source, TrackMetaData(duration=1.0, artist="Radiohead", album=".uploads")
    )

    assert outcome is ImportOutcome.IMPORTED
    assert (root / "Radiohead" / ".uploads_" / "file.mp3").exists()
    assert not (root / "Radiohead" / ".uploads").exists()
    add.assert_called_once()


def test_other_dot_folders_are_still_organized(tmp_path):
    from app.models.track_meta_data import TrackMetaData
    from app.services.import_outcome import ImportOutcome

    root = tmp_path / "music" / "alice"
    source = _source(tmp_path)

    outcome, _ = _organize(
        root, source, TrackMetaData(duration=1.0, artist="Radiohead", album=".hidden")
    )

    assert outcome is ImportOutcome.IMPORTED
    assert (root / "Radiohead" / ".hidden" / "file.mp3").exists()


def test_internal_names_above_the_library_root_do_not_count(tmp_path):
    # Only components below the root matter: a library that itself lives under
    # a folder called .uploads still imports.
    from app.models.track_meta_data import TrackMetaData
    from app.services.import_outcome import ImportOutcome

    root = tmp_path / ".uploads" / "music" / "alice"
    source = _source(tmp_path)

    outcome, _ = _organize(root, source, TrackMetaData(duration=1.0, artist="Radiohead"))

    assert outcome is ImportOutcome.IMPORTED
    assert (root / "Radiohead" / "file.mp3").exists()


# ── orphaned ffmpeg in every internal dir is killed at startup (S7) ────────

def test_startup_kills_orphaned_ffmpeg_in_every_internal_dir(configure_app, tmp_path, monkeypatch):
    from app.services import ffmpeg_runner

    music = tmp_path / "music"
    procs = [
        (900001, "/usr/bin/ffmpeg", f"ffmpeg -i x -y {music / '.staging'}/u.1.convert.m4a"),
        (900002, "/usr/bin/ffmpeg", f"ffmpeg -i x -y {music / '.uploads'}/b/i/work.flac"),
        (900003, "/usr/bin/ffmpeg", f"ffmpeg -i x -y {music / 'admin'}/song.flac"),
        (900004, "/usr/bin/python", f"python {music / '.uploads'}/b/i/work.flac"),
    ]
    killed = []
    monkeypatch.setattr(ffmpeg_runner, "_list_processes", lambda: list(procs))
    monkeypatch.setattr(ffmpeg_runner.os, "getpgid", lambda pid: pid)
    monkeypatch.setattr(ffmpeg_runner.os, "killpg", lambda pid, sig: killed.append(pid))
    monkeypatch.setattr(ffmpeg_runner.os, "kill", lambda pid, sig: killed.append(pid))
    main = configure_app()

    with TestClient(main.app):
        pass

    # Only ffmpeg writing into an internal dir; .staging may be listed twice
    # (the conversion reconcile keeps its own kill before its sweep).
    assert set(killed) == {900001, 900002}


# ── the .staging sweep cannot reach .uploads ───────────────────────────────

def _upload_stage_files(music):
    names = [
        "u.1.convert.m4a", "u.1.tagged.m4a", "u.abc.edit.flac",
        "batch/item/u.1.convert.m4a", "batch/item/source.flac",
    ]
    files = []
    for name in names:
        path = music / ".uploads" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"staged")
        files.append(path)
    return files


def test_the_staging_sweep_never_touches_uploads(tmp_path):
    from app.services.conversion import reconcile_conversion_jobs

    music = tmp_path / "music"
    (music / ".staging").mkdir(parents=True)
    swept = music / ".staging" / "u.1.convert.m4a"
    swept.write_bytes(b"orphan")
    files = _upload_stage_files(music)

    class _NoJobs:
        def list_conversion_jobs_with_status(self, status, *, owner_id):
            return []

        def list_journal_entries(self, *, owner_id):
            return []

    reconcile_conversion_jobs(_NoJobs(), music / ".staging")

    assert not swept.exists()  # the sweep did run
    assert all(f.read_bytes() == b"staged" for f in files)


def test_a_full_startup_leaves_upload_stages_alone(open_app_client, tmp_path):
    files = _upload_stage_files(tmp_path / "music")

    with open_app_client() as client:
        assert client.get("/").status_code == 200

    assert all(f.read_bytes() == b"staged" for f in files)
