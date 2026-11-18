"""Review r1 R1-13: the identity worker and a fingerprinter together in the
app's lifespan (spec §4.1 "Selection", §6.4 worker; review 6.5-U06, 6.5-U07).

- The worker fingerprints real rows with the fingerprinter the app detected,
  through the app's identity registry, and the library converges: two tracks
  with the same audio but different exact digests become one fingerprint pair.
- Shutdown kills a fingerprint in flight instead of waiting it out; the kill
  is not an attempt, and the instance lock is free once the app has stopped.

``configure_app`` keeps both the worker and the fingerprinter off; these tests
turn them on. The exact layer is already current on every row, so no ffmpeg
runs except in the ``requires_fpcalc`` variant, which builds its audio.
"""

import os
import shutil
import stat
import subprocess
import threading
import time

import pytest
from fastapi.testclient import TestClient

from app.core.instance_lock import acquire_instance_lock
from app.database.database import Database
from app.services import fingerprinter as fingerprinter_mod
from app.services.ffmpeg_runner import FfmpegProcessRegistry
from tests.audio_fixtures import FP_SECONDS, _melody
from tests.identity_worker_fakes import FakeFingerprinter
from tests.identity_worker_fixtures import DIGEST_A, DIGEST_B, add_track, identity, sql

WORKER_ON = {"ENABLE_IDENTITY_WORKER": "true"}


def _settled(db, path, owner, digest):
    """A track whose exact layer is current and whose fingerprint is pending."""
    return add_track(db, path, owner_id=owner, identity={
        "exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": digest,
        "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16,
        "fp_state": "pending", "match_state": "current",
    })


def _first_start(configure_app):
    with TestClient(configure_app().app) as c:
        return c.app.state.database, c.app.state.admin_user_id


def _converge_two(configure_app, monkeypatch, db, uuids, env):
    """Start the app with the worker on and wait (bounded) until both rows
    have a current print and a current match."""
    settled = threading.Event()
    real_store = Database.store_duplicate_candidates

    def store(self, *args, **kwargs):
        stored = real_store(self, *args, **kwargs)
        rows = [identity(db, u) for u in uuids]
        if all((r["fp_state"], r["match_state"]) == ("current", "current") for r in rows):
            settled.set()
        return stored

    monkeypatch.setattr(Database, "store_duplicate_candidates", store)
    with TestClient(configure_app(env={**WORKER_ON, **env}).app) as c:
        assert settled.wait(30), [identity(db, u) for u in uuids]
        return c.app.state


def test_the_worker_fingerprints_with_the_apps_fingerprinter_and_the_library_converges(
        configure_app, monkeypatch, tmp_path):
    db, owner = _first_start(configure_app)
    music = tmp_path / "music" / "admin"
    music.mkdir(parents=True)
    paths = [music / "a.flac", music / "b.flac"]
    for path, content in zip(paths, (b"one encoding", b"another encoding")):
        path.write_bytes(content)
    uuids = [_settled(db, paths[0], owner, DIGEST_A), _settled(db, paths[1], owner, DIGEST_B)]

    found = FakeFingerprinter()  # the same print for both files
    monkeypatch.setattr(fingerprinter_mod, "detect_fingerprinter", lambda settings: found)
    state = _converge_two(configure_app, monkeypatch, db, uuids, env={})

    assert state.fingerprinter is found
    assert sorted(found.paths()) == sorted(str(p) for p in paths)
    assert all(call["registry"] is state.identity_registry and call["low_priority"] for call in found.calls)
    [pair] = sql(db, "SELECT owner_id, uuid_a, uuid_b, kind, status FROM track_duplicate_candidates")
    assert pair == {"owner_id": owner, "uuid_a": min(uuids), "uuid_b": max(uuids),
                    "kind": "fingerprint", "status": "open"}


@pytest.mark.requires_fpcalc
@pytest.mark.requires_ffmpeg
def test_with_real_fpcalc_two_copies_of_a_melody_become_a_fingerprint_pair(configure_app, monkeypatch, tmp_path):
    db, owner = _first_start(configure_app)
    music = tmp_path / "music" / "admin"
    music.mkdir(parents=True)
    a, b = music / "a.flac", music / "b.flac"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", _melody(FP_SECONDS),
                    "-c:a", "flac", str(a)], check=True)
    shutil.copyfile(a, b)
    uuids = [_settled(db, a, owner, DIGEST_A), _settled(db, b, owner, DIGEST_B)]

    state = _converge_two(configure_app, monkeypatch, db, uuids, env={"AUDIO_FINGERPRINT_BACKEND": "fpcalc"})

    assert state.fingerprinter.name == "fpcalc"
    assert {identity(db, u)["fp_algorithm"] for u in uuids} == {"chromaprint-2"}
    [pair] = sql(db, "SELECT uuid_a, uuid_b, kind FROM track_duplicate_candidates")
    assert pair == {"uuid_a": min(uuids), "uuid_b": max(uuids), "kind": "fingerprint"}


def _slow_fpcalc(path):
    """An executable that answers the version probe like fpcalc 1.6.2 and
    otherwise never finishes (it stands in for a very long file)."""
    path.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = "-version" ]; then echo "fpcalc version 1.6.2"; exit 0; fi\n'
        "exec sleep 120\n"
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


@pytest.mark.integration
def test_shutdown_kills_a_fingerprint_in_flight_and_it_is_not_an_attempt(configure_app, monkeypatch, tmp_path):
    db, owner = _first_start(configure_app)
    master = tmp_path / "music" / "admin" / "a.flac"
    master.parent.mkdir(parents=True)
    master.write_bytes(b"audio")
    uuid_id = _settled(db, master, owner, DIGEST_A)
    stub = _slow_fpcalc(tmp_path / "fpcalc-stub")

    fingerprinting = threading.Event()
    children = []
    real_register = FfmpegProcessRegistry.register

    def register(self, job_id, proc):
        if isinstance(job_id, tuple) and job_id[0] == "identity" and str(stub) in proc.args:
            children.append(proc)
            fingerprinting.set()
        return real_register(self, job_id, proc)

    monkeypatch.setattr(FfmpegProcessRegistry, "register", register)
    env = {**WORKER_ON, "AUDIO_FINGERPRINT_BACKEND": "fpcalc", "FPCALC_PATH": str(stub)}
    try:
        with TestClient(configure_app(env=env).app) as c:
            assert c.app.state.fingerprinter.executable == str(stub)
            assert fingerprinting.wait(30)
            worker = c.app.state.identity_worker
            stop_started = time.monotonic()
        stop_took = time.monotonic() - stop_started
        [child] = children
        killed = child.returncode  # reaped by the run the shutdown ended
    finally:
        for proc in children:
            if proc.poll() is None:
                os.killpg(proc.pid, 9)
                proc.wait()

    assert killed is not None and killed < 0  # killed by a signal, not finished
    assert stop_took < 20  # the two-minute run was killed, not waited out
    assert not worker.is_alive()
    acquire_instance_lock(tmp_path / "data").release()
    row = identity(db, uuid_id)
    assert (row["fp_state"], row["attempts"], row["failure_reason"]) == ("pending", 0, None)
