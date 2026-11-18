"""Phase 6.5A.2d: the identity worker's thread (spec §6.4; plan D10; review 6.5-U06).

One daemon thread with its own stop flag. It waits on the writers'
``IdentityWakeup`` with a bounded idle poll, wakes on a post-commit notify,
and on stop kills its running child process and is joined. Waits use events
and gates, never wall-clock sleeps.
"""

import subprocess
import threading

import pytest

from app.services.audio_identity import ExactUnavailable
from app.services.identity_wakeup import IdentityWakeup
from tests.identity_worker_fakes import FakeCompute, bytes_digest, make_worker
from tests.identity_worker_fixtures import add_track, identity, make_db

WAIT = 10  # generous upper bound for an event; a passing run never waits this long


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


class RecordingWakeup(IdentityWakeup):
    """Records each wait's timeout and signals when the worker is idle."""

    def __init__(self):
        super().__init__()
        self.timeouts = []
        self.waiting = threading.Event()

    def wait(self, timeout=None):
        self.timeouts.append(timeout)
        self.waiting.set()
        return super().wait(timeout)


@pytest.fixture
def stop_after():
    workers = []
    yield workers.append
    for w in workers:
        w.stop(timeout=WAIT)


def test_the_worker_runs_on_one_daemon_thread_and_stops(db, stop_after):
    worker = make_worker(db)
    stop_after(worker)
    worker.start()
    assert worker.is_alive()

    assert worker.stop(timeout=WAIT) is True
    assert not worker.is_alive()
    assert worker.done.done()


def test_an_idle_worker_waits_with_a_bounded_poll(db, stop_after):
    wakeup = RecordingWakeup()
    worker = make_worker(db, wakeup=wakeup, idle_poll_s=42.0)
    stop_after(worker)
    worker.start()

    assert wakeup.waiting.wait(WAIT)
    assert wakeup.timeouts[0] == 42.0


def test_a_notify_after_a_commit_wakes_the_idle_worker(db, music, stop_after):
    wakeup = RecordingWakeup()
    computed = threading.Event()
    compute = FakeCompute()
    real_call = compute.__call__

    def call(*args, **kwargs):
        result = real_call(*args, **kwargs)
        computed.set()
        return result

    worker = make_worker(db, wakeup=wakeup, compute=call, idle_poll_s=3600.0)
    stop_after(worker)
    worker.start()
    assert wakeup.waiting.wait(WAIT)  # idle, waiting up to an hour

    path = music / "a.flac"
    path.write_bytes(b"new track")
    uuid_id = add_track(db, path, identity={"priority": 0})  # the writer committed …
    wakeup.notify()                                          # … then signalled

    assert computed.wait(WAIT)
    assert worker.stop(timeout=WAIT)
    assert identity(db, uuid_id)["exact_digest"] == bytes_digest(path)


@pytest.mark.integration
def test_stop_kills_the_running_child_and_joins(db, music, stop_after):
    path = music / "a.flac"
    path.write_bytes(b"slow")
    uuid_id = add_track(db, path)
    started = threading.Event()
    children = []

    def slow_compute(path, codec_hint, *, registry, job_id, low_priority):
        child = subprocess.Popen(["sleep", "30"], start_new_session=True)
        children.append(child)
        registry.register(job_id, child)
        started.set()
        try:
            child.wait()
        finally:
            registry.discard(job_id)
        return ExactUnavailable("failed", "killed")

    worker = make_worker(db, compute=slow_compute)
    stop_after(worker)
    worker.start()
    assert started.wait(WAIT)

    try:
        assert worker.stop(timeout=WAIT) is True
        assert children[0].poll() is not None and children[0].returncode < 0
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
                child.wait()
    row = identity(db, uuid_id)
    assert (row["exact_state"], row["attempts"]) == ("pending", 0)  # a shutdown kill is no attempt


def test_a_join_that_times_out_reports_the_thread_alive(db, music):
    path = music / "a.flac"
    path.write_bytes(b"x")
    add_track(db, path)
    release = threading.Event()
    started = threading.Event()

    def stuck(path, codec_hint, **kwargs):  # ignores the kill
        started.set()
        release.wait(WAIT)
        return ExactUnavailable("failed", "killed")

    worker = make_worker(db, compute=stuck)
    worker.start()
    assert started.wait(WAIT)
    try:
        worker.request_stop()
        assert worker.join(timeout=0.05) is False
        assert worker.is_alive() and not worker.done.done()
    finally:
        release.set()
        assert worker.join(timeout=WAIT) is True
    assert worker.done.done()


def test_stop_before_start_and_a_second_stop_are_harmless(db):
    worker = make_worker(db)
    assert worker.stop(timeout=1) is True
    worker2 = make_worker(db)
    worker2.start()
    assert worker2.stop(timeout=WAIT) is True
    assert worker2.stop(timeout=WAIT) is True


def test_a_stopped_worker_does_not_take_more_work(db, music, stop_after):
    path = music / "a.flac"
    path.write_bytes(b"x")
    uuid_id = add_track(db, path)
    compute = FakeCompute()
    worker = make_worker(db, compute=compute)
    worker.request_stop()
    worker.start()
    assert worker.join(timeout=WAIT) is True
    assert compute.calls == []
    assert identity(db, uuid_id)["exact_state"] == "pending"
