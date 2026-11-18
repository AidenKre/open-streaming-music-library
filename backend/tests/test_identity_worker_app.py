"""Phase 6.5A.2d: the identity reconcile and worker in the app's lifespan
(spec §6.4; plan D10; review 6.5-U00 (lock), 6.5-U06).

- The reconcile runs at startup after the conversion-job reconcile; the
  worker starts after every reconcile, with the file watcher on or off.
- Shutdown asks the worker to stop (killing its child) first, joins it
  before the conversion orchestrator shuts down, and never releases the
  instance lock while the worker thread is alive.
- A start that fails leaves no thread behind and releases the lock.

``configure_app`` keeps the worker off by default (``ENABLE_IDENTITY_WORKER``)
so other app tests never race a background writer; these tests turn it on.
"""

import sqlite3
import threading
import uuid as uuid_mod
from concurrent.futures import Future

import pytest
from fastapi.testclient import TestClient

from app.core.instance_lock import InstanceLockHeld, acquire_instance_lock
from app.services import identity_worker as identity_worker_mod

ON = {"ENABLE_IDENTITY_WORKER": "true"}
ON_WATCH = {**ON, "ENABLE_FILE_WATCHER": "true"}


def _lock_is_held(data_dir) -> bool:
    try:
        acquire_instance_lock(data_dir).release()
    except InstanceLockHeld:
        return True
    return False


def _add_track_without_identity(db_path, file_path, owner_id) -> str:
    uuid_id = str(uuid_mod.uuid4())
    conn = sqlite3.connect(db_path)
    try:
        track_id = conn.execute(
            "INSERT INTO tracks (uuid_id, file_path, owner_id) VALUES (?, ?, ?)",
            (uuid_id, str(file_path), owner_id),
        ).lastrowid
        conn.execute(
            "INSERT INTO trackmetadata (track_id, uuid_id, codec, has_album_art) VALUES (?, ?, 'flac', 0)",
            (track_id, uuid_id),
        )
        conn.commit()
    finally:
        conn.close()
    return uuid_id


def _identity(db_path, uuid_id):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute("SELECT * FROM track_audio_identity WHERE uuid_id = ?", (uuid_id,)).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


@pytest.mark.parametrize("env", [ON, ON_WATCH], ids=["watcher-off", "watcher-on"])
def test_the_worker_runs_while_the_app_runs_and_stops_with_it(configure_app, tmp_path, env):
    with TestClient(configure_app(env=env).app) as c:
        worker = c.app.state.identity_worker
        assert worker.is_alive()
        assert worker.registry is c.app.state.identity_registry
        assert worker.wakeup is c.app.state.identity_wakeup

    assert not worker.is_alive()
    assert not _lock_is_held(tmp_path / "data")


def test_the_worker_is_off_when_disabled(configure_app):
    with TestClient(configure_app().app) as c:
        assert getattr(c.app.state, "identity_worker", None) is None


def test_startup_gives_a_track_without_an_identity_row_one(configure_app, tmp_path):
    with TestClient(configure_app().app) as c:
        db_path = c.app.state.database.context.database_path
        owner = c.app.state.admin_user_id
    uuid_id = _add_track_without_identity(db_path, tmp_path / "music" / "gone.flac", owner)

    with TestClient(configure_app().app):
        pass

    row = _identity(db_path, uuid_id)
    assert (row["exact_state"], row["priority"], row["fp_state"]) == ("pending", 0, "unavailable")


def test_the_reconcile_follows_the_conversion_reconcile_and_precedes_the_worker(configure_app, monkeypatch):
    # Review r1 R1-13: journal recovery comes first, so the identity reconcile
    # sees the marks an interrupted edit or conversion leaves.
    calls = []
    import app.services.conversion as conversion_mod
    import app.services.track_editor as track_editor_mod

    real_journal = track_editor_mod.reconcile_journal
    real_conversion = conversion_mod.reconcile_conversion_jobs
    real_identity = identity_worker_mod.reconcile_audio_identity
    real_start = identity_worker_mod.AudioIdentityWorker.start

    def journal(*args, **kwargs):
        calls.append("journal reconcile")
        return real_journal(*args, **kwargs)

    def conversion(*args, **kwargs):
        calls.append("conversion reconcile")
        return real_conversion(*args, **kwargs)

    def identity(*args, **kwargs):
        calls.append("identity reconcile")
        return real_identity(*args, **kwargs)

    def start(self):
        calls.append("worker start")
        return real_start(self)

    monkeypatch.setattr(track_editor_mod, "reconcile_journal", journal)
    monkeypatch.setattr(conversion_mod, "reconcile_conversion_jobs", conversion)
    monkeypatch.setattr(identity_worker_mod, "reconcile_audio_identity", identity)
    monkeypatch.setattr(identity_worker_mod.AudioIdentityWorker, "start", start)

    with TestClient(configure_app(env=ON_WATCH).app) as c:
        resumed = c.app.state.conversion_orchestrator is not None

    assert resumed
    assert calls == ["journal reconcile", "conversion reconcile", "identity reconcile", "worker start"]


class FakeWorker:
    """Stands in for the worker thread so shutdown can be observed step by step."""

    instances: list["FakeWorker"] = []

    def __init__(self, database, *, wakeup, registry, **kwargs):
        self.wakeup, self.registry = wakeup, registry
        self.events: list[str] = []
        self.done: Future = Future()
        self.alive = False
        self.join_ends_thread = True
        FakeWorker.instances.append(self)

    def start(self):
        self.events.append("start")
        self.alive = True

    def request_stop(self):
        self.events.append("request_stop")

    def join(self, timeout=None):
        self.events.append("join")
        if self.join_ends_thread:
            self.finish()
        return not self.alive

    def finish(self):
        self.alive = False
        if not self.done.done():
            self.done.set_result(None)

    def stop(self, timeout=None):
        self.request_stop()
        return self.join(timeout)

    def is_alive(self):
        return self.alive


@pytest.fixture
def fake_worker(monkeypatch):
    FakeWorker.instances = []
    monkeypatch.setattr(identity_worker_mod, "AudioIdentityWorker", FakeWorker)
    return FakeWorker


def test_shutdown_stops_the_worker_before_the_orchestrator(configure_app, fake_worker):
    with TestClient(configure_app(env=ON_WATCH).app) as c:
        [worker] = fake_worker.instances
        orchestrator = c.app.state.conversion_orchestrator
        registry = c.app.state.identity_registry
        real_shutdown, real_close = orchestrator.shutdown, registry.close

        def shutdown(*args, **kwargs):
            worker.events.append("orchestrator shutdown")
            return real_shutdown(*args, **kwargs)

        def close():
            worker.events.append("registry close")
            return real_close()

        orchestrator.shutdown = shutdown
        registry.close = close

    assert worker.events[0] == "start"
    assert worker.events.index("request_stop") < worker.events.index("registry close")
    assert worker.events.index("join") < worker.events.index("orchestrator shutdown")


def test_the_instance_lock_is_kept_until_a_slow_worker_ends(configure_app, fake_worker, tmp_path):
    data_dir = tmp_path / "data"
    with TestClient(configure_app(env=ON).app):
        [worker] = fake_worker.instances
        worker.join_ends_thread = False  # the join times out: the thread is still writing

    assert worker.is_alive()
    assert _lock_is_held(data_dir)

    worker.finish()
    assert not _lock_is_held(data_dir)


def test_a_shutdown_step_that_raises_before_the_join_still_keeps_the_lock_while_the_worker_lives(
        configure_app, fake_worker, monkeypatch, tmp_path):
    # Review r1 R1-14: the join is never reached, so only shutdown's final
    # "is the worker still alive" check can keep the lock.
    main = configure_app(env=ON)

    def broken_stop_watchers(*args, **kwargs):
        raise RuntimeError("a watcher would not stop")

    with pytest.raises(RuntimeError, match="would not stop"):
        with TestClient(main.app):
            [worker] = fake_worker.instances
            monkeypatch.setattr(main, "stop_watchers", broken_stop_watchers)

    assert "join" not in worker.events and worker.is_alive()
    assert _lock_is_held(tmp_path / "data")

    worker.finish()
    assert not _lock_is_held(tmp_path / "data")
    # The steps the raise skipped, so no executor thread outlives the test.
    for name in ("conversion_orchestrator", "encoder_coordinator"):
        service = getattr(main.app.state, name, None)
        if service is not None:
            service.shutdown()


def test_a_failed_worker_start_leaves_no_thread_and_frees_the_lock(configure_app, monkeypatch, tmp_path):
    started = []
    real_start = identity_worker_mod.AudioIdentityWorker.start

    def failing_start(self):
        real_start(self)
        started.append(self)
        raise RuntimeError("could not start")

    monkeypatch.setattr(identity_worker_mod.AudioIdentityWorker, "start", failing_start)

    with pytest.raises(RuntimeError):
        with TestClient(configure_app(env=ON).app):
            pass

    [worker] = started
    assert not worker.is_alive()  # startup's failure path stopped and joined it
    assert not _lock_is_held(tmp_path / "data")
    assert not any(t.name.startswith("audio-identity") and t.is_alive() for t in threading.enumerate())
