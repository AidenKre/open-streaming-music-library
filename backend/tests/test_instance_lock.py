"""SC-16d: single-instance guard.

The backend takes an exclusive ``flock`` on ``APP_DATA_DIR/osml.lock`` before
any migration runs and holds it for the process lifetime. A second process
(or a second ``uvicorn --workers N`` worker) must refuse to start instead of
running startup/migrations concurrently.

flock locks belong to the open file description, so two independent opens in
one test process conflict exactly like two processes would.
"""

import importlib
import sys

import pytest
from fastapi.testclient import TestClient

from app.core.instance_lock import InstanceLockHeld, acquire_instance_lock


def test_acquire_creates_lock_file_and_second_acquire_is_refused(tmp_path):
    first = acquire_instance_lock(tmp_path)
    try:
        assert (tmp_path / "osml.lock").exists()
        with pytest.raises(InstanceLockHeld) as excinfo:
            acquire_instance_lock(tmp_path)
        # The refusal names the lock path so an operator can find it.
        assert str(tmp_path / "osml.lock") in str(excinfo.value)
    finally:
        first.release()


def test_release_allows_reacquire(tmp_path):
    first = acquire_instance_lock(tmp_path)
    first.release()
    second = acquire_instance_lock(tmp_path)
    second.release()


def test_release_is_idempotent(tmp_path):
    lock = acquire_instance_lock(tmp_path)
    lock.release()
    lock.release()  # must not raise
    acquire_instance_lock(tmp_path).release()


def _reload_main(tmp_path, monkeypatch):
    monkeypatch.setenv("APP_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("MUSIC_LIBRARY_DIR", str(tmp_path / "music"))
    monkeypatch.setenv("IMPORT_DIR", str(tmp_path / "import"))
    monkeypatch.setenv("ENABLE_FILE_WATCHER", "false")
    sys.modules.pop("app.main", None)
    sys.modules.pop("app.config", None)
    import app.main

    importlib.reload(app.main)
    return app.main


def test_startup_refuses_while_another_instance_holds_the_lock(tmp_path, monkeypatch):
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    other_instance = acquire_instance_lock(data_dir)
    try:
        main = _reload_main(tmp_path, monkeypatch)
        with pytest.raises(InstanceLockHeld):
            with TestClient(main.app):
                pass
        # Refused BEFORE migrations: the database was never created.
        assert not (data_dir / "database" / "database.db").exists()
    finally:
        other_instance.release()


def test_running_instance_holds_the_lock_and_shutdown_releases_it(tmp_path, monkeypatch):
    main = _reload_main(tmp_path, monkeypatch)
    data_dir = tmp_path / "data"
    with TestClient(main.app):
        with pytest.raises(InstanceLockHeld):
            acquire_instance_lock(data_dir)
    # After shutdown the lock is free again (restart in the same data dir).
    acquire_instance_lock(data_dir).release()


def test_restart_in_same_data_dir_succeeds(tmp_path, monkeypatch):
    main = _reload_main(tmp_path, monkeypatch)
    with TestClient(main.app) as c:
        assert c.get("/").status_code == 200
    with TestClient(main.app) as c:
        assert c.get("/").status_code == 200
