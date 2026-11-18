"""SC-16d: single-instance guard.

The backend takes an exclusive ``flock`` on ``APP_DATA_DIR/osml.lock`` before
any migration runs and holds it for the process lifetime. A second process
(or a second ``uvicorn --workers N`` worker) must refuse to start instead of
running startup/migrations concurrently.

flock locks belong to the open file description, so two independent opens in
one test process conflict exactly like two processes would.
"""

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


def test_startup_refuses_while_another_instance_holds_the_lock(tmp_path, configure_app):
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    other_instance = acquire_instance_lock(data_dir)
    try:
        main = configure_app()
        with pytest.raises(InstanceLockHeld):
            with TestClient(main.app):
                pass
        # Refused BEFORE migrations: the database was never created.
        assert not (data_dir / "database" / "database.db").exists()
    finally:
        other_instance.release()


def test_running_instance_holds_the_lock_and_shutdown_releases_it(tmp_path, configure_app):
    main = configure_app()
    data_dir = tmp_path / "data"
    with TestClient(main.app):
        with pytest.raises(InstanceLockHeld):
            acquire_instance_lock(data_dir)
    # After shutdown the lock is free again (restart in the same data dir).
    acquire_instance_lock(data_dir).release()


def test_restart_in_same_data_dir_succeeds(tmp_path, configure_app):
    main = configure_app()
    with TestClient(main.app) as c:
        assert c.get("/").status_code == 200
    with TestClient(main.app) as c:
        assert c.get("/").status_code == 200


@pytest.mark.integration
def test_the_lock_is_free_once_a_killed_holder_is_gone(tmp_path):
    # Review r1 N08 (6.5-U00 "released after a crash"): the kernel drops the
    # flock when the holder dies; nothing has to clean up after it. The child
    # reports "locked" once it holds the lock, then blocks on stdin forever.
    import signal
    import subprocess
    import sys
    from pathlib import Path

    code = (
        "import sys\n"
        "from pathlib import Path\n"
        "from app.core.instance_lock import acquire_instance_lock\n"
        "lock = acquire_instance_lock(Path(sys.argv[1]))\n"
        "print('locked', flush=True)\n"
        "sys.stdin.read()\n"
    )
    holder = subprocess.Popen(
        [sys.executable, "-c", code, str(tmp_path)],
        cwd=Path(__file__).resolve().parents[1],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    )
    try:
        assert holder.stdout.readline().strip() == "locked"
        with pytest.raises(InstanceLockHeld):
            acquire_instance_lock(tmp_path)

        holder.send_signal(signal.SIGKILL)
        assert holder.wait(timeout=30) == -signal.SIGKILL
    finally:
        if holder.poll() is None:
            holder.kill()
            holder.wait()
        holder.stdin.close()
        holder.stdout.close()

    acquire_instance_lock(tmp_path).release()  # no stale lock left behind
