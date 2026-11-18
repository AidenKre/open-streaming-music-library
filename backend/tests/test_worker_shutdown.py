"""Review r1 7-R1-33 and 7-R1-06: shutdown (and startup's failure path) keeps
the instance lock exactly while anything it stopped is still running — every
background worker in the app's one worker list and every import the file
watchers left — and releases it once the last of them ends, in any order.

The workers are the fakes of their own app tests; a fake's join does not end
it (``join_ends_thread = False``) until the test calls ``finish()``."""

import threading
from concurrent.futures import Future

import pytest
from fastapi.testclient import TestClient

from app.services import identity_worker as identity_worker_mod
from app.services import upload_commit as upload_commit_mod
from app.services import upload_validation as upload_validation_mod
from tests.test_identity_worker_app import FakeWorker
from tests.worker_app_fixtures import _lock_is_held
from tests.test_upload_commit_app import FakeCommit
from tests.test_upload_validation_app import FakeValidation

ALL_ON = {
    "ENABLE_UPLOAD_COMMIT_WORKER": "true",
    "ENABLE_UPLOAD_VALIDATION_WORKER": "true",
    "ENABLE_IDENTITY_WORKER": "true",
}


@pytest.fixture
def fakes(monkeypatch):
    FakeCommit.instances, FakeCommit.events = [], []
    FakeValidation.instances, FakeValidation.events = [], []
    FakeWorker.instances = []
    monkeypatch.setattr(upload_commit_mod, "UploadCommitWorker", FakeCommit)
    monkeypatch.setattr(upload_validation_mod, "UploadValidationWorker", FakeValidation)
    monkeypatch.setattr(identity_worker_mod, "AudioIdentityWorker", FakeWorker)


class Watchers:
    """``stop_watchers`` stand-in: an import that outlives its bound."""

    def __init__(self):
        self.import_done = Future()

    def __call__(self, watchers, timeout):
        return [self.import_done]

    def finish(self):
        self.import_done.set_result(None)


def _slow_workers():
    [commit] = FakeCommit.instances
    [validation] = FakeValidation.instances
    [identity] = FakeWorker.instances
    workers = {"commit": commit, "validation": validation, "identity": identity}
    for worker in workers.values():
        worker.join_ends_thread = False  # each join times out: the thread still writes
    return workers


@pytest.mark.parametrize("last", ["commit", "validation", "identity", "import"])
def test_the_lock_is_kept_until_the_last_worker_or_import_ends(configure_app, fakes, monkeypatch, tmp_path, last):
    """7-R1-33: no live worker is dropped from shutdown's wait because an
    import outlived its bound too (and the other way round)."""
    main = configure_app(env=ALL_ON)
    watchers = Watchers()
    monkeypatch.setattr(main, "stop_watchers", watchers)
    data_dir = tmp_path / "data"

    with TestClient(main.app):
        running = _slow_workers()

    running["import"] = watchers
    for name, task in running.items():
        if name != last:
            assert _lock_is_held(data_dir), f"released while {last} still runs"
            task.finish()
    assert _lock_is_held(data_dir), f"released while {last} still runs"

    running[last].finish()
    assert not _lock_is_held(data_dir)


def test_shutdown_waits_on_every_listed_worker(configure_app, fakes, tmp_path):
    """Every worker of the list is asked to stop and joined."""
    with TestClient(configure_app(env=ALL_ON).app):
        workers = _slow_workers()
        for worker in workers.values():
            worker.join_ends_thread = True

    assert "commit request_stop" in FakeCommit.events and "commit join" in FakeCommit.events
    assert "validation request_stop" in FakeValidation.events
    assert "validation join" in FakeValidation.events
    assert {"request_stop", "join"} <= set(workers["identity"].events)
    assert not _lock_is_held(tmp_path / "data")


@pytest.mark.parametrize("last", ["commit", "validation"])
def test_a_failing_startup_keeps_the_lock_until_the_last_started_worker_ends(
        configure_app, fakes, monkeypatch, tmp_path, last):
    """Startup's failure path stops the same list and keeps the lock the same way."""
    def failing_start(self):
        # The upload workers started first; neither ends at its join.
        for worker in (*FakeCommit.instances, *FakeValidation.instances):
            worker.join_ends_thread = False
        raise RuntimeError("identity worker could not start")

    monkeypatch.setattr(FakeWorker, "start", failing_start)
    data_dir = tmp_path / "data"

    with pytest.raises(RuntimeError, match="could not start"):
        with TestClient(configure_app(env=ALL_ON).app):
            pass

    [commit] = FakeCommit.instances
    [validation] = FakeValidation.instances
    assert "commit request_stop" in FakeCommit.events
    assert "validation request_stop" in FakeValidation.events
    running = {"commit": commit, "validation": validation}
    first = running.pop("validation" if last == "commit" else "commit")
    assert _lock_is_held(data_dir)
    first.finish()
    assert _lock_is_held(data_dir), f"released while {last} still runs"
    running[last].finish()
    assert not _lock_is_held(data_dir)


def test_a_worker_whose_stop_request_raises_does_not_keep_the_others_running(
        configure_app, fakes, monkeypatch, tmp_path, caplog):
    """Review of 7-fix-r1-workers C3: one worker failing to take its stop
    request is logged; every other worker is still asked to stop and joined."""
    def broken_request_stop(self):
        FakeCommit.events.append("commit request_stop")
        raise RuntimeError("could not signal")

    monkeypatch.setattr(FakeCommit, "request_stop", broken_request_stop)

    with TestClient(configure_app(env=ALL_ON).app):
        [identity] = FakeWorker.instances

    assert "validation request_stop" in FakeValidation.events
    assert "validation join" in FakeValidation.events
    assert {"request_stop", "join"} <= set(identity.events)
    assert "commit join" in FakeCommit.events
    assert any("RuntimeError" in r.getMessage() for r in caplog.records if r.levelname == "WARNING")
    assert not _lock_is_held(tmp_path / "data")


def test_a_failing_startup_asks_a_worker_to_stop_before_closing_its_registry(
        configure_app, fakes, monkeypatch):
    """L8 / DEV-r1w-3: startup's failure path uses shutdown's order, so a killed
    process reads as a stop, not as a failure."""
    from app.main import FfmpegProcessRegistry

    real_close = FfmpegProcessRegistry.close

    def close(self):
        FakeCommit.events.append("registry close")
        return real_close(self)

    def failing_start(self):
        raise RuntimeError("identity worker could not start")

    monkeypatch.setattr(FfmpegProcessRegistry, "close", close)
    monkeypatch.setattr(FakeWorker, "start", failing_start)

    with pytest.raises(RuntimeError, match="could not start"):
        with TestClient(configure_app(env=ALL_ON).app):
            pass

    events = FakeCommit.events
    assert "registry close" in events
    assert events.index("commit request_stop") < events.index("registry close")


def test_a_worker_whose_join_raises_does_not_cut_the_shutdown_short(
        configure_app, fakes, monkeypatch, tmp_path, caplog):
    """Review r2 7-R2-14: one failing join is logged; every later worker is still
    joined, conversions are still shut down (the encoder pool was asked to stop
    first), and the lock is kept until the worker whose join failed has ended."""
    def broken_join(self, timeout=None):
        FakeCommit.events.append("commit join")
        raise RuntimeError("join failed")

    monkeypatch.setattr(FakeCommit, "join", broken_join)
    shut = []
    data_dir = tmp_path / "data"

    with TestClient(configure_app(env=ALL_ON).app) as client:
        state = client.app.state
        for name in ("conversion_orchestrator", "encoder_coordinator"):
            target = getattr(state, name)
            real = target.shutdown
            monkeypatch.setattr(target, "shutdown", lambda real=real, name=name: (shut.append(name), real()))
        [commit] = FakeCommit.instances
        [identity] = FakeWorker.instances

    assert "validation join" in FakeValidation.events
    assert "join" in identity.events
    # The encoder pool is asked to stop first (U06-B-01); conversions are still
    # shut down after the failing join.
    assert shut == ["encoder_coordinator", "conversion_orchestrator"]
    assert any("RuntimeError" in r.getMessage() for r in caplog.records if r.levelname == "WARNING")
    assert _lock_is_held(data_dir)  # the commit worker never ended
    commit.finish()
    assert not _lock_is_held(data_dir)


def test_no_queued_encode_starts_while_the_watchers_stop(configure_app, monkeypatch):
    """U06-B-01 / BE-B review #1: the encoder pool is asked to stop before the
    server waits for the watchers, so an encode that was only queued never
    starts in that window (a warm or prefetch resumes at the next start; a
    queued conversion stays queued)."""
    main = configure_app(env={"ENCODED_CACHE_PREFETCH_WORKERS": "1"})
    running, release, settled = threading.Event(), threading.Event(), threading.Event()
    started_late = []
    helpers = []

    def slow_watcher_stop(watchers, timeout):
        # The running encode ends while the server waits for the watchers;
        # then the pool thread either exits or takes the next queued task.
        [thread] = main.app.state.encoder_coordinator._executor._threads
        helper = threading.Thread(target=lambda: (thread.join(), settled.set()), daemon=True)
        helper.start()
        helpers.append(helper)
        release.set()
        assert settled.wait(10)
        return []

    monkeypatch.setattr(main, "stop_watchers", slow_watcher_stop)

    def held_encode():
        running.set()
        release.wait(10)

    def queued_encode(name):
        started_late.append(name)
        settled.set()

    with TestClient(main.app):
        coordinator = main.app.state.encoder_coordinator
        coordinator._executor.submit(held_encode, priority=0)
        assert running.wait(10)
        coordinator._executor.submit(queued_encode, "prefetch", priority=0)
        coordinator._executor.submit(queued_encode, "warm", priority=1)
        coordinator.submit_conversion(queued_encode, "conversion")

    for helper in helpers:
        helper.join(10)
    assert started_late == []


def test_a_raising_encoder_stop_does_not_cut_the_shutdown_short(configure_app, fakes, monkeypatch, tmp_path):
    """The encoder pool is asked to stop first; if that raises, every worker is
    still asked to stop and joined, the watchers are stopped, conversions are
    shut down, the lock is released, and the error still surfaces."""
    main = configure_app(env=ALL_ON)
    stopped_watchers = []
    monkeypatch.setattr(main, "stop_watchers", lambda watchers, timeout: stopped_watchers.append(timeout) or [])
    shut = []

    client = TestClient(main.app)
    client.__enter__()
    state = main.app.state

    def broken_shutdown():
        raise RuntimeError("encoder stop failed")

    monkeypatch.setattr(state.encoder_coordinator, "shutdown", broken_shutdown)
    real = state.conversion_orchestrator.shutdown
    monkeypatch.setattr(state.conversion_orchestrator, "shutdown", lambda: (shut.append("conversions"), real()))
    [identity] = FakeWorker.instances
    with pytest.raises(RuntimeError, match="encoder stop failed"):
        client.__exit__(None, None, None)

    assert {"commit request_stop", "commit join"} <= set(FakeCommit.events)
    assert {"validation request_stop", "validation join"} <= set(FakeValidation.events)
    assert {"request_stop", "join"} <= set(identity.events)
    assert stopped_watchers and shut == ["conversions"]
    assert not _lock_is_held(tmp_path / "data")
    # The pool's own threads: the test stops them, since the raise skipped that.
    state.encoder_coordinator._executor.shutdown(wait=True, cancel_pending=True)
