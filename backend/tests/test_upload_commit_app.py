"""7A.3a S10 (spec §3 "one validation/commit worker"; §4 "Durable row/state is
written before returning 202 ... Worker startup resumes/reconciles queued
work"; SC-16d boot ids and the instance lock): the commit worker's thread and
its place in the app's lifespan — started after the recovery registry, given
the app's ledger, cover-art manager, boot id and its own kill registry,
stopped before the identity worker, and the instance lock kept while it lives.

No sleeps: a thread test waits on an event (bounded)."""

import threading
from concurrent.futures import Future

import pytest
from fastapi.testclient import TestClient

from app.services import identity_worker as identity_worker_mod
from app.services import upload_commit as upload_commit_mod
from app.services.upload_commit import UploadCommitWorker
from app.services.upload_limits import effective_upload_limits
from tests.identity_worker_fixtures import make_db
from tests.test_identity_worker_app import _lock_is_held
from tests.upload_commit_fixtures import accept, journal, make_commit_worker, ready_item

WAIT_S = 10  # an upper bound only; every wait ends on an event
ON = {"ENABLE_UPLOAD_COMMIT_WORKER": "true"}


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


# ── the thread ──────────────────────────────────────────────────────────────

def test_the_thread_prepares_what_is_queued_and_stops_on_request(db, music):
    commit = accept(db, ready_item(db, music / ".uploads"))
    finished = threading.Event()
    real_prepare = db.prepare_upload_commit

    def prepare(**kwargs):
        try:
            return real_prepare(**kwargs)
        finally:
            finished.set()

    db.prepare_upload_commit = prepare
    worker = make_commit_worker(db, music, idle_poll_s=60)

    worker.start()
    try:
        assert finished.wait(WAIT_S)
    finally:
        assert worker.stop(timeout=WAIT_S)

    assert not worker.is_alive() and worker.done.done()
    assert journal(db, commit)["state"] == "prepared"


def test_a_worker_never_started_joins_at_once(db, music):
    worker = make_commit_worker(db, music)
    assert worker.join(timeout=0)
    assert worker.done.done()


def test_a_second_start_is_an_error(db, music):
    worker = make_commit_worker(db, music, idle_poll_s=3600)
    worker.start()
    try:
        with pytest.raises(RuntimeError):
            worker.start()
    finally:
        assert worker.stop(timeout=WAIT_S)


# ── the app's lifespan ──────────────────────────────────────────────────────

def test_the_worker_is_off_unless_enabled(configure_app):
    with TestClient(configure_app().app) as c:
        assert c.app.state.upload_commit_worker is None


def test_the_enabled_worker_runs_while_the_app_runs_and_stops_with_it(configure_app, tmp_path):
    with TestClient(configure_app(env=ON).app) as c:
        worker = c.app.state.upload_commit_worker
        assert isinstance(worker, UploadCommitWorker)
        assert worker.is_alive()

    assert not worker.is_alive()
    assert not _lock_is_held(tmp_path / "data")


class FakeCommit:
    instances: list["FakeCommit"] = []
    events: list[str] = []

    def __init__(self, database, **kwargs):
        self.kwargs = kwargs
        self.done: Future = Future()
        self.alive = False
        self.join_ends_thread = True
        FakeCommit.instances.append(self)

    def start(self):
        FakeCommit.events.append("commit start")
        self.alive = True

    def request_stop(self):
        FakeCommit.events.append("commit request_stop")

    def wake(self):
        pass

    def join(self, timeout=None):
        FakeCommit.events.append("commit join")
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
def fake_commit(monkeypatch):
    FakeCommit.instances, FakeCommit.events = [], []
    monkeypatch.setattr(upload_commit_mod, "UploadCommitWorker", FakeCommit)
    return FakeCommit


def test_the_worker_gets_the_apps_shared_parts_and_its_own_registry(configure_app, fake_commit):
    with TestClient(configure_app(env=ON).app) as c:
        [worker] = fake_commit.instances
        state = c.app.state
        assert state.upload_commit_worker is worker
        k = worker.kwargs
        assert k["boot_id"] == state.boot_id
        assert k["ledger"] is state.storage_ledger
        assert k["cover_art"] is state.cover_art_manager
        assert k["uploads_root"] == state.upload_receipt.uploads_root
        assert k["music_library_dir"] == state.settings.music_library_dir.resolve()
        limits = effective_upload_limits(state.settings)
        assert (k["quota"].user_bytes, k["quota"].total_bytes) == (
            limits.user_staged_quota_bytes, limits.staged_quota_bytes)
        assert k["registry"] is not state.identity_registry
        assert k["registry"] is not getattr(state, "upload_validation_registry", None)


def test_the_worker_starts_after_recovery_and_stops_before_the_identity_worker(
        configure_app, fake_commit, monkeypatch):
    main = configure_app(env={**ON, "ENABLE_IDENTITY_WORKER": "true"})
    real_recovery = main.run_startup_recovery
    real = {name: getattr(identity_worker_mod.AudioIdentityWorker, name)
            for name in ("start", "request_stop", "join")}

    def recovery(steps):
        fake_commit.events.append("recovery")
        return real_recovery(steps)

    def spy(name):
        def wrapper(self, *args, **kwargs):
            fake_commit.events.append(f"identity {name}")
            return real[name](self, *args, **kwargs)
        return wrapper

    monkeypatch.setattr(main, "run_startup_recovery", recovery)
    for name in real:
        monkeypatch.setattr(identity_worker_mod.AudioIdentityWorker, name, spy(name))

    with TestClient(main.app):
        pass

    events = fake_commit.events
    assert events.index("recovery") < events.index("commit start")
    assert events.index("commit request_stop") < events.index("identity request_stop")
    assert events.index("commit join") < events.index("identity join")


def test_the_instance_lock_is_kept_until_a_slow_commit_worker_ends(configure_app, fake_commit, tmp_path):
    with TestClient(configure_app(env=ON).app):
        [worker] = fake_commit.instances
        worker.join_ends_thread = False

    assert worker.is_alive()
    assert _lock_is_held(tmp_path / "data")
    worker.finish()
    assert not _lock_is_held(tmp_path / "data")


def test_a_failing_startup_after_the_worker_started_stops_it_and_frees_the_lock(
        configure_app, fake_commit, monkeypatch, tmp_path):
    def failing_start(self):
        raise RuntimeError("identity worker could not start")

    monkeypatch.setattr(identity_worker_mod.AudioIdentityWorker, "start", failing_start)

    with pytest.raises(RuntimeError):
        with TestClient(configure_app(env={**ON, "ENABLE_IDENTITY_WORKER": "true"}).app):
            pass

    [worker] = fake_commit.instances
    assert "commit join" in fake_commit.events and not worker.is_alive()
    assert not _lock_is_held(tmp_path / "data")
