"""Refactor piece BE-LIFE (guide A.6): the order of every stop step at shutdown.

A normal shutdown stops things in one fixed order, and that order is what keeps
a killed process reading as a stop (not a failure), keeps the encoder pool from
starting queued work while the server waits, and keeps the instance lock while
anything that may still write is alive:

1. the encoder pool is asked to stop (an error from it is raised only at the end);
2. the import stop flag is set;
3. every listed worker is asked to stop, each followed by closing its own kill
   registry (sender, deletion, janitor, commit, validation, identity);
4. the identity registry (shared with imports) is closed;
5. the watchers are stopped and their running imports drained;
6. the settle check is joined;
7. every listed worker is joined, in list order;
8. the conversion orchestrator is shut down;
9. the Last.fm client is closed, or, while the sender still runs, when it ends;
10. the database's held connection is closed (after
    everything that was asked to stop, so that its close is the last one and
    checkpoints; a worker that outlived its join only makes a later close the last);
11. the history hook is removed;
12. the instance lock is released, or kept until the last worker or import ends.

Every worker is a recording fake; everything else is the real object with a
recording wrapper installed after start-up. Nothing contacts Last.fm: the
sender is a fake and the client is never used.
"""

import logging
import time
from concurrent.futures import Future
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.services import deletion_worker as deletion_worker_mod
from app.services import identity_worker as identity_worker_mod
from app.services import lastfm_sender as lastfm_sender_mod
from app.services import upload_commit as upload_commit_mod
from app.services import upload_janitor as upload_janitor_mod
from app.services import upload_validation as upload_validation_mod
from tests.lastfm_routes import clean_env
from tests.lastfm_secrets import valid_env
from tests.worker_app_fixtures import _lock_is_held

ALL_ON = valid_env(
    ENABLE_FILE_WATCHER="true",
    ENABLE_UPLOAD_VALIDATION_WORKER="true",
    ENABLE_UPLOAD_COMMIT_WORKER="true",
    ENABLE_UPLOAD_JANITOR="true",
    ENABLE_DELETION_WORKER="true",
    ENABLE_IDENTITY_WORKER="true",
    ENABLE_LASTFM_SENDER="true",
    ENCODED_CACHE_PREFETCH_WORKERS="1",
)

# Worker names in the order of the one worker list (= stop order).
WORKERS = ("sender", "deletion", "janitor", "commit", "validation", "identity")

NORMAL_SHUTDOWN = [
    "encoder pool stop",
    "import stop flag",
    "sender request_stop",
    "deletion request_stop",
    "janitor request_stop",
    "commit request_stop",
    "commit registry close",
    "validation request_stop",
    "validation registry close",
    "identity request_stop",
    "identity registry close",
    "watchers stop",
    "settle check join",
    "sender join",
    "deletion join",
    "janitor join",
    "commit join",
    "validation join",
    "identity join",
    "conversion stop",
    "lastfm client close",
    "database connection close",
    "history hook removed",
    "instance lock release",
]


class Recorder:
    def __init__(self):
        self.calls: list[str] = []
        self.workers: dict[str, "RecordingWorker"] = {}


def _worker_class(recorder: Recorder, name: str):
    class Worker(RecordingWorker):
        pass

    Worker.recorder, Worker.name = recorder, name
    return Worker


class RecordingWorker:
    """A listed background worker: records its stop request and join. Its join
    ends the thread unless ``join_ends_thread`` is False (it then runs until
    ``finish()``)."""

    recorder: Recorder
    name: str

    def __init__(self, *args, **kwargs):
        self.done: Future = Future()
        self.alive = False
        self.join_ends_thread = True
        self.recorder.workers[self.name] = self

    def start(self):
        self.alive = True

    def request_stop(self):
        self.recorder.calls.append(f"{self.name} request_stop")

    def join(self, timeout=None):
        self.recorder.calls.append(f"{self.name} join")
        if self.join_ends_thread:
            self.finish()
        return not self.alive

    def finish(self):
        self.alive = False
        if not self.done.done():
            self.done.set_result(None)

    def is_alive(self):
        return self.alive


@pytest.fixture
def recorder(monkeypatch):
    """Every listed worker is a recording fake (patched before the app module
    is loaded, so its by-name imports see the fakes)."""
    clean_env(monkeypatch)
    rec = Recorder()
    for module, attr, name in (
        (lastfm_sender_mod, "ScrobbleSender", "sender"),
        (deletion_worker_mod, "DeletionWorker", "deletion"),
        (upload_janitor_mod, "UploadJanitorThread", "janitor"),
        (upload_commit_mod, "UploadCommitWorker", "commit"),
        (upload_validation_mod, "UploadValidationWorker", "validation"),
        (identity_worker_mod, "AudioIdentityWorker", "identity"),
    ):
        monkeypatch.setattr(module, attr, _worker_class(rec, name))
    return rec


def _spy(calls, label, real):
    def wrapper(*args, **kwargs):
        calls.append(label)
        return real(*args, **kwargs)

    return wrapper


def install_stop_spies(main, state, recorder: Recorder, monkeypatch) -> None:
    """Wrap every non-worker stop step of a started app with a recorder."""
    calls = recorder.calls
    flag = state.import_stop
    real_set = flag.set

    def first_set():
        # The watchers share this flag and set it again when they stop: only
        # the moment it is first set is part of the order.
        if not flag.is_set():
            calls.append("import stop flag")
        real_set()

    monkeypatch.setattr(flag, "set", first_set)
    for target, attr, label in (
        (state.encoder_coordinator, "shutdown", "encoder pool stop"),
        (state.upload_commit_registry, "close", "commit registry close"),
        (state.upload_validation_registry, "close", "validation registry close"),
        (state.identity_registry, "close", "identity registry close"),
        (state.settle_check, "join", "settle check join"),
        (state.conversion_orchestrator, "shutdown", "conversion stop"),
        (state.lastfm_accounts.client, "close", "lastfm client close"),
        (state.database, "close", "database connection close"),
        (state.instance_lock, "release", "instance lock release"),
        (main, "stop_watchers", "watchers stop"),
        (main, "uninstall_scrobble_outbox", "history hook removed"),
    ):
        monkeypatch.setattr(target, attr, _spy(calls, label, getattr(target, attr)))


def test_every_worker_of_the_list_is_built_and_started(configure_app, recorder):
    """The fixture's premise: all six listed workers run, so the order below
    covers every one of them."""
    with TestClient(configure_app(env=ALL_ON).app):
        assert sorted(recorder.workers) == sorted(WORKERS)
        assert all(w.alive for w in recorder.workers.values())


def test_a_normal_shutdown_stops_everything_in_the_fixed_order(configure_app, recorder, monkeypatch, tmp_path):
    main = configure_app(env=ALL_ON)

    with TestClient(main.app):
        install_stop_spies(main, main.app.state, recorder, monkeypatch)

    assert recorder.calls == NORMAL_SHUTDOWN
    assert not _lock_is_held(tmp_path / "data")


def test_a_sender_outliving_its_join_defers_the_client_close_and_the_lock(
        configure_app, recorder, monkeypatch, tmp_path):
    """The same order; the Last.fm client closes when the sender ends, and only
    then is the instance lock released."""
    main = configure_app(env=ALL_ON)

    with TestClient(main.app):
        install_stop_spies(main, main.app.state, recorder, monkeypatch)
        recorder.workers["sender"].join_ends_thread = False  # a request still in flight

    deferred = ["lastfm client close", "instance lock release"]
    assert recorder.calls == [c for c in NORMAL_SHUTDOWN if c not in deferred]
    assert _lock_is_held(tmp_path / "data")

    recorder.workers["sender"].finish()

    assert recorder.calls[-2:] == deferred
    assert not _lock_is_held(tmp_path / "data")


# ── a failed start-up ───────────────────────────────────────────────────────


class StartupFailed(RuntimeError):
    pass


def fail_after_startup(main, monkeypatch, then=None):
    """Start-up builds and starts everything, then a later step fails (no such
    step exists today; Phase 10 adds start-up steps). ``then(state)`` runs
    after the real start-up, before the failure."""
    real = main._startup_locked

    def startup_then_fail():
        real()
        if then is not None:
            then(main.app.state)
        raise StartupFailed("a later start-up step failed")

    monkeypatch.setattr(main, "_startup_locked", startup_then_fail)


def test_a_failed_startup_closes_the_lastfm_client_only_when_the_sender_ends(
        configure_app, recorder, monkeypatch, tmp_path):
    """B-332-07: the failed start-up uses shutdown's rule; a request still in
    flight keeps the client open until the sender ends."""
    main = configure_app(env=ALL_ON)
    seen = {}

    def sender_outlives_its_join(state):
        recorder.workers["sender"].join_ends_thread = False
        seen["client"] = state.lastfm_accounts.client._client

    fail_after_startup(main, monkeypatch, sender_outlives_its_join)

    with pytest.raises(StartupFailed):
        with TestClient(main.app):
            pass

    assert "sender request_stop" in recorder.calls
    assert not seen["client"].is_closed, "closed under a sender that still runs"
    assert _lock_is_held(tmp_path / "data")

    recorder.workers["sender"].finish()

    assert seen["client"].is_closed
    assert not _lock_is_held(tmp_path / "data")


class _Client:
    def __init__(self):
        self.closed = 0

    def close(self):
        self.closed += 1


def test_a_deferred_client_close_closes_the_client_of_the_state_it_was_given(configure_app, monkeypatch):
    """Pre-merge D1-04: the close deferred until the sender ends closes the
    client of the teardown's own ``state``, as it was when the close was
    deferred, never whatever ``app.state`` (or the state) holds by then."""
    main = configure_app()
    sender = RecordingWorker.__new__(_worker_class(Recorder(), "sender"))
    RecordingWorker.__init__(sender)
    sender.start()
    own, global_client, later = _Client(), _Client(), _Client()
    state = SimpleNamespace(lastfm_sender=sender, lastfm_accounts=SimpleNamespace(client=own))
    monkeypatch.setattr(main.app.state, "lastfm_accounts", SimpleNamespace(client=global_client), raising=False)

    main._close_lastfm_client_when_sender_ends(state)
    assert own.closed == 0, "closed under a sender that still runs"
    state.lastfm_accounts = SimpleNamespace(client=later)  # a later start's client
    sender.finish()

    assert (own.closed, global_client.closed, later.closed) == (1, 0, 0)


def test_a_failed_startup_stops_everything_a_shutdown_stops_in_the_same_order(
        configure_app, recorder, monkeypatch, tmp_path):
    """U01-B-01: the failed start-up runs shutdown's teardown. The history hook
    is installed only once start-up succeeded, so there is none to remove."""
    main = configure_app(env=ALL_ON)
    fail_after_startup(main, monkeypatch, lambda state: install_stop_spies(main, state, recorder, monkeypatch))

    with pytest.raises(StartupFailed):
        with TestClient(main.app):
            pass

    assert recorder.calls == [c for c in NORMAL_SHUTDOWN if c != "history hook removed"]
    assert not _lock_is_held(tmp_path / "data")


def test_a_failed_startup_leaves_nothing_running_and_keeps_the_lock_while_an_import_runs(
        configure_app, recorder, monkeypatch, tmp_path):
    """U01-B-01: after a failed start-up the watchers, the settle check and the
    encoder pool have ended, the identity and conversion registries are closed
    (a hash or conversion starting later is killed on arrival), and the
    instance lock is kept until an import that outlived the watchers' bound ends."""
    main = configure_app(env=ALL_ON)
    data_dir = tmp_path / "data"
    import_done = Future()
    real_stop_watchers = main.stop_watchers

    def an_import_outlives_the_bound(watchers, timeout):
        return set(real_stop_watchers(watchers, timeout)) | {import_done}

    monkeypatch.setattr(main, "stop_watchers", an_import_outlives_the_bound)
    built = {}

    def remember(state):
        built.update(
            stop=state.import_stop,
            watchers=[state.file_watcher, state.user_file_watcher],
            settle=state.settle_check,
            pool=list(state.encoder_coordinator._executor._threads),
            coordinator=state.encoder_coordinator,
            identity=state.identity_registry,
            conversions=state.conversion_orchestrator._registry,
        )

    fail_after_startup(main, monkeypatch, remember)

    with pytest.raises(StartupFailed):
        with TestClient(main.app):
            pass

    try:
        for thread in built["pool"]:
            thread.join(2)  # the pool's stop does not wait; its thread ends right after
        stopped = {
            "import stop flag set": built["stop"].is_set(),
            "both watchers stopped": all(w.observer is None for w in built["watchers"]),
            "settle check ended": not built["settle"].is_running(),
            "encoder pool ended": not any(t.is_alive() for t in built["pool"]),
            "identity registry closed": built["identity"].closed,
            "conversion registry closed": built["conversions"].closed,
            "lock kept while the import runs": _lock_is_held(data_dir),
        }
        assert stopped == dict.fromkeys(stopped, True)

        import_done.set_result(None)
        assert not _lock_is_held(data_dir)
    finally:
        # Nothing of this test outlives it, whatever the start-up path left.
        if not import_done.done():
            import_done.set_result(None)
        built["stop"].set()
        real_stop_watchers(built["watchers"], 1)
        built["coordinator"].shutdown()


# ── the join deadline ───────────────────────────────────────────────────────


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def monotonic(self):
        return self.now


def test_shutdown_waits_for_all_workers_against_one_deadline(configure_app, recorder, monkeypatch, tmp_path):
    """U01-B-08: every worker is still asked to join, but all of them share one
    deadline of ``IDENTITY_JOIN_TIMEOUT_S`` (10 s), not 10 s each. A worker
    still running at the deadline is left running, as before: shutdown goes
    on, and the instance lock is kept until it ends."""
    main = configure_app(env=ALL_ON)
    clock = FakeClock()
    timeouts = []

    def never_ends_in_time(worker):
        def join(timeout=None):
            recorder.calls.append(f"{worker.name} join")
            timeouts.append(timeout)
            clock.now += timeout  # it uses its whole bound and still runs
            return False

        return join

    with TestClient(main.app):
        for worker in recorder.workers.values():
            monkeypatch.setattr(worker, "join", never_ends_in_time(worker))
        # The shutdown reads its clock as ``main.time.monotonic``.
        monkeypatch.setattr(main, "time", SimpleNamespace(monotonic=clock.monotonic, time=time.time))

    assert [c for c in recorder.calls if c.endswith(" join")] == [f"{name} join" for name in WORKERS]
    # The first worker gets the whole deadline and uses it; every later one
    # gets what is left of it: nothing. Shutdown waits exactly the deadline.
    assert timeouts == [main.IDENTITY_JOIN_TIMEOUT_S] + [0.0] * (len(WORKERS) - 1)
    assert clock.now - 1000.0 == main.IDENTITY_JOIN_TIMEOUT_S

    data_dir = tmp_path / "data"
    for name in WORKERS:
        assert _lock_is_held(data_dir), f"released while {name} still runs"
        recorder.workers[name].finish()
    assert not _lock_is_held(data_dir)


# ── a raising stop step skips no later step (coordinator, round 2) ─────────


class StepFailed(RuntimeError):
    pass


# Every non-worker stop step that can raise (a worker's stop request and join
# are already caught one by one), as (target, attribute) of a started app.
RAISING_STEPS = {
    "encoder pool stop": lambda main, state: (state.encoder_coordinator, "shutdown"),
    "identity registry close": lambda main, state: (state.identity_registry, "close"),
    "watchers stop": lambda main, state: (main, "stop_watchers"),
    "settle check join": lambda main, state: (state.settle_check, "join"),
    "conversion stop": lambda main, state: (state.conversion_orchestrator, "shutdown"),
    "lastfm client close": lambda main, state: (state.lastfm_accounts.client, "close"),
    "database connection close": lambda main, state: (state.database, "close"),
}


def make_step_raise(main, state, monkeypatch, label, error):
    """The step does its work (its recording spy and the real call run), then raises."""
    target, attr = RAISING_STEPS[label](main, state)
    done = getattr(target, attr)

    def raising(*args, **kwargs):
        done(*args, **kwargs)
        raise error

    monkeypatch.setattr(target, attr, raising)


@pytest.mark.parametrize("failing", list(RAISING_STEPS))
def test_a_raising_shutdown_step_skips_no_later_step(
        configure_app, recorder, monkeypatch, tmp_path, caplog, failing):
    """Every later step still runs, in the same order, and the step's error is
    raised once everything was stopped."""
    main = configure_app(env=ALL_ON)
    error = StepFailed(failing)
    client = TestClient(main.app)
    client.__enter__()
    install_stop_spies(main, main.app.state, recorder, monkeypatch)
    make_step_raise(main, main.app.state, monkeypatch, failing, error)

    with pytest.raises(StepFailed) as raised:
        client.__exit__(None, None, None)

    assert raised.value is error
    assert recorder.calls == NORMAL_SHUTDOWN
    assert not _lock_is_held(tmp_path / "data")


def test_when_several_shutdown_steps_raise_the_first_error_is_raised_and_the_later_logged(
        configure_app, recorder, monkeypatch, tmp_path, caplog):
    main = configure_app(env=ALL_ON)
    first, later = StepFailed("encoder pool"), StepFailed("conversions")
    client = TestClient(main.app)
    client.__enter__()
    state = main.app.state
    install_stop_spies(main, state, recorder, monkeypatch)
    make_step_raise(main, state, monkeypatch, "encoder pool stop", first)
    make_step_raise(main, state, monkeypatch, "conversion stop", later)

    with pytest.raises(StepFailed) as raised:
        client.__exit__(None, None, None)

    assert raised.value is first
    assert recorder.calls == NORMAL_SHUTDOWN
    assert any("StepFailed" in r.getMessage() for r in caplog.records if r.levelno == logging.WARNING)
    assert not _lock_is_held(tmp_path / "data")


@pytest.mark.parametrize("failing", list(RAISING_STEPS))
def test_a_raising_step_of_a_failed_startup_skips_no_later_step(
        configure_app, recorder, monkeypatch, tmp_path, failing):
    """The failed start-up's teardown likewise runs every later step (the
    Last.fm client is closed, B-332-07); the start-up error stays the one raised."""
    main = configure_app(env=ALL_ON)

    def spies_and_a_raising_step(state):
        install_stop_spies(main, state, recorder, monkeypatch)
        make_step_raise(main, state, monkeypatch, failing, StepFailed(failing))

    fail_after_startup(main, monkeypatch, spies_and_a_raising_step)

    with pytest.raises(StartupFailed):
        with TestClient(main.app):
            pass

    assert recorder.calls == [c for c in NORMAL_SHUTDOWN if c != "history hook removed"]
    assert not _lock_is_held(tmp_path / "data")


# ── a watcher that cannot start (review F1) ─────────────────────────────────


def test_a_watcher_that_cannot_start_fails_the_startup_and_the_teardown_completes(
        configure_app, recorder, monkeypatch, tmp_path, caplog):
    """The second watcher's observer cannot start (say, the system's watch
    limit). Start-up fails with that error; the teardown completes without an
    error of its own (it does not try to stop an observer that never ran): the
    first watcher, the settle check and the encoder pool have ended, the
    conversion orchestrator is stopped, and the lock is released."""
    from app.services import file_watcher as file_watcher_mod

    started = []

    class SecondCannotStart(file_watcher_mod.Observer):
        def start(self):
            started.append(self)
            if len(started) == 2:
                raise OSError("watch limit reached")
            return super().start()

    monkeypatch.setattr(file_watcher_mod, "Observer", SecondCannotStart)
    main = configure_app(env=ALL_ON)

    with caplog.at_level(logging.WARNING):
        with pytest.raises(OSError, match="watch limit"):
            with TestClient(main.app):
                pass

    state = main.app.state
    for thread in state.encoder_coordinator._executor._threads:
        thread.join(2)  # the pool's stop does not wait; its thread ends right after
    teardown_errors = [r.getMessage() for r in caplog.records if "failed" in r.getMessage()
                       and r.levelno == logging.WARNING and r.name == "app.main"]
    assert teardown_errors == []
    stopped = {
        "first watcher's observer ended": not started[0].is_alive(),
        "import stop flag set": state.import_stop.is_set(),
        "settle check ended": not state.settle_check.is_running(),
        "encoder pool ended": not any(t.is_alive() for t in state.encoder_coordinator._executor._threads),
        "conversion registry closed": state.conversion_orchestrator._registry.closed,
        "identity registry closed": state.identity_registry.closed,
    }
    assert stopped == dict.fromkeys(stopped, True)
    assert not _lock_is_held(tmp_path / "data")


class Interrupted(BaseException):
    """Not an Exception: the stop-step guard does not catch it."""


def test_a_teardown_cut_short_before_the_joins_keeps_the_lock_while_a_worker_lives(
        configure_app, recorder, monkeypatch, tmp_path):
    """Review R1-14 / R2-1: only the teardown's final check can keep the lock
    when the joins are never reached; it sits where nothing can skip it."""
    main = configure_app(env=ALL_ON)

    def interrupted(watchers, timeout):
        raise Interrupted()

    client = TestClient(main.app)
    client.__enter__()
    try:
        recorder.workers["identity"].join_ends_thread = False
        monkeypatch.setattr(main, "stop_watchers", interrupted)

        with pytest.raises(Interrupted):
            client.__exit__(None, None, None)

        assert not any(c.endswith(" join") for c in recorder.calls)
        assert _lock_is_held(tmp_path / "data")
    finally:
        for worker in recorder.workers.values():
            worker.finish()
        # The steps the interruption skipped, so no thread outlives the test.
        main.app.state.import_stop.set()
        main.app.state.encoder_coordinator.shutdown()
        main.app.state.conversion_orchestrator.shutdown()
    assert not _lock_is_held(tmp_path / "data")
