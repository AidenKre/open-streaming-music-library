"""7A.2c S8 (spec §3 "one validation/commit worker"; §4 "Worker startup
resumes/reconciles queued work through the shared startup recovery registry
(SC-16e)"; SC-16d boot ids and the instance lock; plan row: own stop event,
started after the registry, stopped before the identity worker at shutdown,
the instance lock kept while it is alive): the validation worker's thread, its
place in the app's lifespan, and its startup reclaim step.

No sleeps: a thread test waits on an event the fake probe sets (bounded)."""

import threading
from concurrent.futures import Future

import pytest
from fastapi.testclient import TestClient

from app.services import identity_worker as identity_worker_mod
from app.services import upload_validation as upload_validation_mod
from app.services.upload_validation import UploadValidationWorker, reconcile_upload_validation
from tests.recovery_steps import capture_steps, named
from tests.worker_app_fixtures import _lock_is_held
from tests.upload_validation_fixtures import (
    BOOT,
    DEAD_BOOT,
    FakeProbe,
    FakeRegistry,
    item_row,
    make_worker,
    stage_item,
)

WAIT_S = 10  # an upper bound only; every wait ends on an event
ON = {"ENABLE_UPLOAD_VALIDATION_WORKER": "true"}


@pytest.fixture
def root(tmp_path):
    path = tmp_path / "music" / ".uploads"
    path.mkdir(parents=True)
    return path


class SignalProbe(FakeProbe):
    def __init__(self):
        super().__init__()
        self.called = threading.Event()

    def __call__(self, path, **kwargs):
        try:
            return super().__call__(path, **kwargs)
        finally:
            self.called.set()


# ── the thread ────────────────────────────────────────────────────────────

def test_the_thread_validates_what_is_queued_and_stops_on_request(db, root):
    staged = stage_item(db, root)
    finished = threading.Event()
    real_finish = db.finish_upload_validation

    def finish(**kwargs):
        try:
            return real_finish(**kwargs)
        finally:
            finished.set()

    db.finish_upload_validation = finish  # signals once the step has written its result
    worker = make_worker(db, root, idle_poll_s=60)

    worker.start()
    try:
        assert finished.wait(WAIT_S)
    finally:
        assert worker.stop(timeout=WAIT_S)

    assert not worker.is_alive()
    assert worker.done.done()
    assert item_row(db, staged)["state"] == "review_ready"


def test_an_idle_thread_wakes_for_new_work_without_waiting_out_its_poll(db, root):
    probe = SignalProbe()
    worker = make_worker(db, root, probe=probe, idle_poll_s=3600)
    worker.start()
    try:
        stage_item(db, root)
        worker.wake()
        assert probe.called.wait(WAIT_S)
    finally:
        assert worker.stop(timeout=WAIT_S)


def test_a_stop_during_a_process_step_kills_it_and_writes_nothing(db, root):
    staged = stage_item(db, root)
    registry = FakeRegistry()
    probe = FakeProbe()
    worker = make_worker(db, root, probe=probe, registry=registry)
    probe.mid = worker.request_stop

    outcome = worker.process_one()

    [call] = probe.calls
    assert registry.killed == [call["job_id"]]
    assert outcome == "interrupted"
    row = item_row(db, staged)
    assert (row["state"], row["duplicate_report"], row["detected_metadata"]) == ("validating", None, None)


def test_a_worker_never_started_joins_at_once(db, root):
    worker = make_worker(db, root)

    assert worker.join(timeout=0)
    assert worker.done.done()


def test_a_second_start_is_an_error(db, root):
    worker = make_worker(db, root, idle_poll_s=3600)
    worker.start()
    try:
        with pytest.raises(RuntimeError):
            worker.start()
    finally:
        assert worker.stop(timeout=WAIT_S)


# ── the startup reclaim step ──────────────────────────────────────────────

def test_the_reclaim_step_requeues_only_items_left_by_a_dead_process(db, root):
    dead = stage_item(db, root, lease=DEAD_BOOT)
    mine = stage_item(db, root, lease=BOOT)
    other_state = stage_item(db, root, state="review_ready", lease=DEAD_BOOT)

    first = reconcile_upload_validation(db, boot_id=BOOT)
    after_first = [item_row(db, s) for s in (dead, mine, other_state)]
    second = reconcile_upload_validation(db, boot_id=BOOT)

    assert (first, second) == (1, 0)
    assert [r["lease_boot_id"] for r in after_first] == [None, BOOT, DEAD_BOOT]
    assert [r["state"] for r in after_first] == ["validating", "validating", "review_ready"]
    assert [item_row(db, s) for s in (dead, mine, other_state)] == after_first


# ── the app's lifespan ────────────────────────────────────────────────────

def test_the_worker_is_off_unless_enabled(configure_app):
    with TestClient(configure_app().app) as c:
        assert c.app.state.upload_validation_worker is None


def test_the_enabled_worker_runs_while_the_app_runs_and_stops_with_it(configure_app, tmp_path):
    with TestClient(configure_app(env=ON).app) as c:
        worker = c.app.state.upload_validation_worker
        assert isinstance(worker, UploadValidationWorker)
        assert worker.is_alive()

    assert not worker.is_alive()
    assert not _lock_is_held(tmp_path / "data")


def test_the_reclaim_step_runs_after_the_receipts_and_before_the_reservations(configure_app, monkeypatch):
    main = configure_app()
    captured = capture_steps(main, monkeypatch)
    with TestClient(main.app):
        pass

    [steps] = captured
    names = named(steps)
    at = names.index(("upload validation", False))
    assert names[at - 1] == ("upload receipts", False)
    # 8A.3d: deletion job reclaim follows it, then the reservations.
    assert names[at + 1 : at + 3] == [("deletion jobs", False), ("storage reservations", False)]


class FakeValidation:
    instances: list["FakeValidation"] = []
    events: list[str] = []

    def __init__(self, database, **kwargs):
        self.kwargs = kwargs
        self.done: Future = Future()
        self.alive = False
        self.join_ends_thread = True
        self.wakes = 0
        FakeValidation.instances.append(self)

    def start(self):
        FakeValidation.events.append("validation start")
        self.alive = True

    def request_stop(self):
        FakeValidation.events.append("validation request_stop")

    def wake(self):
        self.wakes += 1

    def join(self, timeout=None):
        FakeValidation.events.append("validation join")
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
def fake_validation(monkeypatch):
    FakeValidation.instances, FakeValidation.events = [], []
    monkeypatch.setattr(upload_validation_mod, "UploadValidationWorker", FakeValidation)
    return FakeValidation


def test_the_worker_starts_after_recovery_and_stops_before_the_identity_worker(
        configure_app, fake_validation, monkeypatch):
    main = configure_app(env={**ON, "ENABLE_IDENTITY_WORKER": "true"})
    real_recovery = main.run_startup_recovery
    real = {name: getattr(identity_worker_mod.AudioIdentityWorker, name)
            for name in ("start", "request_stop", "join")}

    def recovery(steps):
        fake_validation.events.append("recovery")
        return real_recovery(steps)

    def spy(name):
        def wrapper(self, *args, **kwargs):
            fake_validation.events.append(f"identity {name}")
            return real[name](self, *args, **kwargs)
        return wrapper

    monkeypatch.setattr(main, "run_startup_recovery", recovery)
    for name in real:
        monkeypatch.setattr(identity_worker_mod.AudioIdentityWorker, name, spy(name))

    with TestClient(main.app) as c:
        [worker] = fake_validation.instances
        assert c.app.state.upload_validation_worker is worker
        assert worker.kwargs["boot_id"] == c.app.state.boot_id
        assert worker.kwargs["tokens"] is c.app.state.upload_cancel_tokens
        assert worker.kwargs["fingerprinter"] is c.app.state.fingerprinter
        assert worker.kwargs["registry"] is not c.app.state.identity_registry  # its own kill registry

    events = fake_validation.events
    assert events.index("recovery") < events.index("validation start")
    assert events.index("validation request_stop") < events.index("identity request_stop")
    assert events.index("validation join") < events.index("identity join")


def test_the_instance_lock_is_kept_until_a_slow_validation_worker_ends(configure_app, fake_validation, tmp_path):
    with TestClient(configure_app(env=ON).app):
        [worker] = fake_validation.instances
        worker.join_ends_thread = False

    assert worker.is_alive()
    assert _lock_is_held(tmp_path / "data")
    worker.finish()
    assert not _lock_is_held(tmp_path / "data")


def test_a_failing_startup_after_the_worker_started_stops_it_and_frees_the_lock(
        configure_app, fake_validation, monkeypatch, tmp_path):
    def failing_start(self):
        raise RuntimeError("identity worker could not start")

    monkeypatch.setattr(identity_worker_mod.AudioIdentityWorker, "start", failing_start)

    with pytest.raises(RuntimeError):
        with TestClient(configure_app(env={**ON, "ENABLE_IDENTITY_WORKER": "true"}).app):
            pass

    [worker] = fake_validation.instances
    assert "validation join" in fake_validation.events and not worker.is_alive()
    assert not _lock_is_held(tmp_path / "data")


def test_a_completed_transfer_wakes_the_worker(configure_app, fake_validation):
    import hashlib

    from tests.upload_stream import put

    data = b"0123456789"
    body = {"batch_uuid": "b1000000-0000-4000-8000-000000000001", "items": [{
        "item_uuid": "b1000000-0000-4000-8000-000000000002", "filename": "a.flac",
        "byte_length": len(data), "sha256": hashlib.sha256(data).hexdigest()}]}
    from tests.conftest import bearer, log_in

    with TestClient(configure_app(env=ON).app) as c:
        c.headers.update(bearer(log_in(c)["token"]))
        assert c.post("/tracks/uploads", json=body).status_code == 201
        [worker] = fake_validation.instances
        assert worker.wakes == 0

        sent = put(c, body["items"][0]["item_uuid"], [data])

        assert (sent.status, sent.json()["state"]) == (200, "validating")
        assert worker.wakes == 1
