"""SF-BE-1c: a real app start-up with the real process listing.

``configure_app`` gives app starts an empty foreign-process list by default.
This file keeps the composition "real start-up + real listing" an explicit
check. It lists processes for real (``ps -axww`` on macOS, ``/proc`` on
Linux) and uses a fake ffmpeg: a ``/bin/sh`` symlink named ``ffmpeg``, the
technique from ``test_ffmpeg_runner.py``. It needs no ffmpeg binary, so it
carries no ``requires_ffmpeg`` marker.
"""

import signal
import subprocess

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def orphan(tmp_path):
    """A long-lived "ffmpeg" whose command line writes into the library's
    ``.staging``, like a conversion ffmpeg left by a hard-killed server.
    ``; :`` stops sh from exec-ing sleep, which would replace the command line."""
    binary = tmp_path / "bin" / "ffmpeg"
    binary.parent.mkdir()
    binary.symlink_to("/bin/sh")
    target = tmp_path / "music" / ".staging" / "u.1.convert.m4a.partial"
    proc = subprocess.Popen(
        [str(binary), "-c", "sleep 30; :", str(target)], start_new_session=True
    )
    yield proc
    proc.kill()
    proc.wait()


def _wait_dead(proc: subprocess.Popen, timeout: float = 5.0) -> bool:
    try:
        proc.wait(timeout=timeout)
        return True
    except subprocess.TimeoutExpired:
        return False


@pytest.mark.integration
def test_a_real_start_up_kills_an_orphaned_ffmpeg_in_its_staging_dir(configure_app, orphan):
    main = configure_app(real_process_list=True)

    with TestClient(main.app):
        pass

    assert _wait_dead(orphan)
    assert orphan.returncode == -signal.SIGKILL


def test_by_default_a_start_up_sees_no_foreign_processes(configure_app, orphan):
    main = configure_app()

    with TestClient(main.app):
        pass

    assert orphan.poll() is None
