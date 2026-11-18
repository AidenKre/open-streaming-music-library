"""Phase 6.5A.2b: the identity writers wired into the real app (plan D12, D14).

An archive dropped while ffmpeg cannot hash it is still imported and set
aside in ``.imported/`` (DEV-M-10: never an environmental outcome, never a
re-import loop), and the app's wake-up signal fires for an ingest. Shutdown
kills a running ingest hash through the ingest registry.
"""

import sqlite3
import subprocess
import zipfile
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from app.services.ffmpeg_runner import CaptureTimeout, FfmpegError
from app.services.identity_wakeup import IdentityWakeup
from tests.test_import_startup import WATCH, _drain_imports, _tone

pytestmark = pytest.mark.usefixtures("fast_stability_poll")


def _identity_rows(db):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return conn.execute(
            "SELECT t.file_path, i.exact_state, i.exact_digest, i.priority "
            "FROM track_audio_identity i JOIN tracks t ON t.uuid_id = i.uuid_id"
        ).fetchall()
    finally:
        conn.close()


def _zip_of_tone(path, title, tmp_path):
    song = tmp_path / "src" / f"{title}.mp3"
    _tone(song, title)
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as z:
        z.write(song, f"{title}.mp3")
    return path


@pytest.mark.requires_ffmpeg
def test_an_ingest_through_the_app_hashes_and_wakes_the_worker(configure_app, tmp_path):
    _tone(tmp_path / "import" / "airbag.mp3", "Airbag")

    with TestClient(configure_app(env=WATCH).app) as c:
        _drain_imports(c)
        wakeup = c.app.state.identity_wakeup
        rows = _identity_rows(c.app.state.database)

    assert isinstance(wakeup, IdentityWakeup)
    assert wakeup.wait(0) is True
    [(path, state, digest, priority)] = rows
    assert path.endswith("airbag.mp3")
    assert (state, priority) == ("current", 0) and len(digest) == 64


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("failure", [FfmpegError("ffmpeg not found"), CaptureTimeout("slow")])
def test_an_archive_that_cannot_be_hashed_is_imported_and_set_aside(configure_app, tmp_path, failure):
    """Exit proof / plan D12 (binding): ffmpeg missing or timing out at hash
    time keeps the import IMPORTED with the exact layer pending, and the
    archive is still handled (since the sign-off of DEV-M-10: deleted, its
    only track imported)."""
    archive = _zip_of_tone(tmp_path / "import" / "album.zip", "Lucky", tmp_path)

    with patch("app.services.audio_identity.run_capture", side_effect=failure):
        with TestClient(configure_app(env=WATCH).app) as c:
            _drain_imports(c)
            rows = _identity_rows(c.app.state.database)

    [(path, state, digest, priority)] = rows
    assert path.endswith("Lucky.mp3")
    assert (state, digest, priority) == ("pending", None, 0)
    assert not archive.exists()
    assert not (tmp_path / "import" / ".imported").exists()


@pytest.mark.integration
def test_shutdown_kills_a_running_ingest_hash(configure_app):
    """Plan D14: the ingest hash runs under a registry that shutdown kills, so
    a stop never waits out a long hash."""
    with TestClient(configure_app(env=WATCH).app) as c:
        registry = c.app.state.identity_registry
        child = subprocess.Popen(["sleep", "30"], start_new_session=True)
        registry.register("ingest-hash", child)

    try:
        assert child.wait(timeout=5) < 0
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()


@pytest.mark.integration
def test_a_hash_that_starts_after_shutdown_is_killed_on_arrival(configure_app):
    """Review F1: an ingest hash that registers after shutdown's kill (it
    passed the stop check just before) is killed at once, never run out to its
    timeout while the instance lock is held."""
    with TestClient(configure_app(env=WATCH).app) as c:
        registry = c.app.state.identity_registry

    child = subprocess.Popen(["sleep", "30"], start_new_session=True)
    try:
        registry.register("late-ingest-hash", child)
        assert child.wait(timeout=5) < 0
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
