"""Phase M.2b (spec §6.4 "Resume at boot", SC-16e Phase M, M-U17): the server
finishes an interrupted ``users delete`` in ``_startup_locked`` right after the
master-admin bootstrap, before the reconciles, the cover-art backfill, the
encoder startup and the watchers.

``configure_app`` points the app at tmp_path/data, music, import and
import-users, the same directories ``cli_settings`` uses.
"""

import logging
import shutil

import pytest
from fastapi.testclient import TestClient

from app.services import user_delete
from app.services.user_delete import DeletePaths, run_user_delete
from tests.cli_fixtures import cli_settings, sql
from tests.crash import Crash
from tests.user_delete_world import build_world, exists


pytestmark = pytest.mark.usefixtures("fast_stability_poll")


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    return build_world(cli_settings(tmp_path))


def _no_watcher_thread_left(main):
    """Review r1 m-R1-03/35: the lifespan's shutdown drains both watchers'
    executors, so no ingest thread outlives the app (or its instance lock)."""
    for name in ("file_watcher", "user_file_watcher"):
        watcher = getattr(main.app.state, name)
        assert [t for t in watcher.executor._threads if t.is_alive()] == [], name


def _crash_after(world, monkeypatch, step):
    original = list(user_delete.STEPS)

    def crashing(*args, **kwargs):
        original[step - 1](*args, **kwargs)
        raise Crash()

    patched = list(original)
    patched[step - 1] = crashing
    monkeypatch.setattr(user_delete, "STEPS", patched)
    with pytest.raises(Crash):
        run_user_delete(world.db, world.sam, DeletePaths.from_settings(world.settings))
    monkeypatch.setattr(user_delete, "STEPS", original)


@pytest.mark.parametrize("step", [1, 2, 3, 4])
def test_a_boot_finishes_a_delete_interrupted_after_any_step(world, configure_app, monkeypatch, step):
    _crash_after(world, monkeypatch, step)
    assert world.db.get_user(world.sam)["deleting_at"] is not None

    main = configure_app()
    with TestClient(main.app):
        pass

    assert world.db.get_user(world.sam) is None
    assert world.db.get_user(world.alex) is not None
    assert sql(world.db, "SELECT count(*) FROM tracks WHERE owner_id = ?", (world.sam,)) == [(0,)]
    assert sql(world.db, "SELECT count(*) FROM tracks WHERE owner_id = ?", (world.alex,)) == [(2,)]
    assert not world.art["b"][1].exists()
    assert world.art["a"][1].exists() and world.art["c"][1].exists()
    assert not exists(world.files["sam_music"])
    assert world.files["alex_master"].exists()


def test_the_boot_resume_runs_right_after_bootstrap_and_before_the_reconciles(
    world, configure_app, monkeypatch
):
    _crash_after(world, monkeypatch, 1)
    main = configure_app()
    calls = []
    real_resume = main.resume_user_deletes
    real_bootstrap = main.bootstrap_master_admin
    real_reconcile = main.reconcile_journal

    def bootstrap(*args, **kwargs):
        calls.append("bootstrap")
        return real_bootstrap(*args, **kwargs)

    def resume(*args, **kwargs):
        calls.append("resume")
        return real_resume(*args, **kwargs)

    def reconcile(*args, **kwargs):
        calls.append(("reconcile", world.db.get_user(world.sam) is None))
        return real_reconcile(*args, **kwargs)

    monkeypatch.setattr(main, "bootstrap_master_admin", bootstrap)
    monkeypatch.setattr(main, "resume_user_deletes", resume)
    monkeypatch.setattr(main, "reconcile_journal", reconcile)

    with TestClient(main.app):
        pass

    assert calls == ["bootstrap", "resume", ("reconcile", True)]


def test_a_boot_with_nothing_to_resume_changes_nothing(world, configure_app):
    main = configure_app()
    with TestClient(main.app):
        pass

    assert world.db.get_user(world.sam) is not None
    assert world.files["sam_music"].is_dir()


def test_a_resume_refused_by_the_guards_is_logged_and_the_boot_continues(
    world, configure_app, monkeypatch, caplog
):
    _crash_after(world, monkeypatch, 1)
    shutil.rmtree(world.files["sam_music"])
    world.files["sam_music"].symlink_to(world.files["alex_music"], target_is_directory=True)
    caplog.set_level(logging.ERROR)

    main = configure_app()
    with TestClient(main.app) as client:
        assert client.get("/app/info").status_code == 200

    assert world.db.get_user(world.sam)["deleting_at"] is not None
    assert world.files["alex_master"].exists()
    assert "Sam" in caplog.text and "delete" in caplog.text.lower()


def test_a_refused_resume_does_not_recreate_or_scan_the_users_import_folder(
    world, configure_app, monkeypatch
):
    """M.2b review #8: a user left ``deleting`` by a refused resume gets no import
    folder recreated and none of their drops imported at startup."""
    _crash_after(world, monkeypatch, 1)
    shutil.rmtree(world.files["sam_music"])
    world.files["sam_music"].symlink_to(world.files["alex_music"], target_is_directory=True)
    sam_import = world.settings.user_import_dir / "Sam"
    shutil.rmtree(sam_import)
    tracks_before = sql(world.db, "SELECT count(*) FROM tracks")

    main = configure_app(env={"ENABLE_FILE_WATCHER": "true"})
    with TestClient(main.app):
        pass

    _no_watcher_thread_left(main)
    assert not exists(sam_import)
    assert (world.settings.user_import_dir / "Alex").is_dir()
    assert sql(world.db, "SELECT count(*) FROM tracks") == tracks_before


def test_a_resumed_delete_is_finished_before_the_import_folders_and_scans(
    world, configure_app, monkeypatch
):
    """Item 4: the boot resume runs before startup creates import folders and
    scans them, so the deleted user's folder is neither recreated nor scanned."""
    _crash_after(world, monkeypatch, 1)  # Sam's import folder still holds a drop
    main = configure_app(env={"ENABLE_FILE_WATCHER": "true"})
    folders_seen = []
    real_ensure = main.ensure_user_import_folders

    def ensure(root, users):
        folders_seen.extend(u["library_folder"] for u in users)
        return real_ensure(root, users)

    monkeypatch.setattr(main, "ensure_user_import_folders", ensure)
    with TestClient(main.app):
        pass

    _no_watcher_thread_left(main)

    assert "Sam" not in folders_seen and "Alex" in folders_seen
    assert world.db.get_user(world.sam) is None
    assert not exists(world.settings.user_import_dir / "Sam")
