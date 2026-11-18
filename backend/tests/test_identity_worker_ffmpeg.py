"""Phase 6.5A.2d with real ffmpeg (spec §6.4; review 6.5-U06; plan exit proof).

Shutdown kills the worker's running hash (a slow, real-time lavfi source
stands in for a long file) instead of waiting it out, a shutdown kill is not
an attempt, and the next start finishes the track: a kill and a restart leave
nothing stuck. The expected digest is computed here with a plain ffmpeg call,
independently of the worker.
"""

import subprocess
import threading
import time

import pytest
from fastapi.testclient import TestClient

from app.core.instance_lock import acquire_instance_lock
from app.database.database import Database
from app.services import audio_identity
from app.services.ffmpeg_runner import FfmpegProcessRegistry
from tests.test_identity_worker_app import ON, _add_track_without_identity, _identity

pytestmark = pytest.mark.requires_ffmpeg

SLOW_HASH = ["ffmpeg", "-v", "error", "-re", "-f", "lavfi", "-i", "sine=frequency=440:duration=120",
             "-f", "hash", "-hash", "sha256", "-"]


def _flac(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=330:duration=1",
         "-c:a", "flac", str(path)],
        check=True,
    )


def _expected_digest(path):
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-map", "0:a:0", "-c:a", "pcm_s32le",
         "-f", "hash", "-hash", "sha256", "-"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    assert out.startswith("SHA256=")
    return out.removeprefix("SHA256=").lower()


def test_shutdown_kills_the_running_hash_and_a_restart_finishes_the_track(configure_app, tmp_path, monkeypatch):
    with TestClient(configure_app().app) as c:
        db_path = c.app.state.database.context.database_path
        owner = c.app.state.admin_user_id
    master = tmp_path / "music" / "admin" / "tone.flac"
    _flac(master)
    uuid_id = _add_track_without_identity(db_path, master, owner)

    # Second start: the hash is slow (real-time, two minutes).
    real_run_capture = audio_identity.run_capture
    real_register = FfmpegProcessRegistry.register
    hashing = threading.Event()
    children = []

    def slow_run_capture(cmd, **kwargs):
        if cmd[0] == "ffmpeg" and "hash" in cmd:
            cmd = SLOW_HASH
        return real_run_capture(cmd, **kwargs)

    def register(self, job_id, proc):
        if isinstance(job_id, tuple) and job_id[0] == "identity":
            children.append(proc)
            if any("sine=frequency=440" in str(a) for a in proc.args):
                hashing.set()
        return real_register(self, job_id, proc)

    monkeypatch.setattr(audio_identity, "run_capture", slow_run_capture)
    monkeypatch.setattr(FfmpegProcessRegistry, "register", register)
    try:
        with TestClient(configure_app(env=ON).app) as c:
            assert hashing.wait(30)
            worker = c.app.state.identity_worker
            started_stop = time.monotonic()
        stop_took = time.monotonic() - started_stop
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
                child.wait()

    assert stop_took < 20  # the two-minute hash was killed, not waited out
    assert not worker.is_alive()
    assert all(child.returncode is not None for child in children)
    acquire_instance_lock(tmp_path / "data").release()  # released after the join
    row = _identity(db_path, uuid_id)
    assert (row["exact_state"], row["attempts"], row["failure_reason"]) == ("pending", 0, None)

    # Third start, real hashing: the track that was interrupted completes.
    monkeypatch.setattr(audio_identity, "run_capture", real_run_capture)
    monkeypatch.setattr(FfmpegProcessRegistry, "register", real_register)
    written = threading.Event()
    real_update = Database.update_identity_if_unchanged

    def update(self, uuid, **kwargs):
        ok = real_update(self, uuid, **kwargs)
        if ok and uuid == uuid_id:
            written.set()
        return ok

    monkeypatch.setattr(Database, "update_identity_if_unchanged", update)
    with TestClient(configure_app(env=ON).app):
        assert written.wait(30)

    row = _identity(db_path, uuid_id)
    assert (row["exact_state"], row["exact_kind"], row["exact_digest"]) == (
        "current", "pcm_sha256", _expected_digest(master))
    acquire_instance_lock(tmp_path / "data").release()
