"""Review r1 7-R1-06: the one background worker thread lifecycle every worker
shares (``app.services.worker_thread``): start once, ``done`` resolved when the
thread has ended (or for a worker never started), stop and join, ``is_alive``,
the wake-up, a stop during a process step (killed) or during plain work
(waited for), and a crash in the loop (reported, never looking alive).

No sleeps: every wait ends on an event; joins are bounded."""

import logging
import threading

import pytest

from app.services.worker_thread import PollingWorkerThread, WorkerThread

WAIT_S = 10  # an upper bound only; every wait ends on an event


class Steps(WorkerThread):
    """Runs ``body()`` once per step; the step's return value is the wait."""

    thread_name = "test-worker"

    def __init__(self, body=None, *, first_wait_s=None, kill_registry=None):
        super().__init__(kill_registry=kill_registry)
        self.body = body or (lambda: 3600)
        self.steps = 0
        self.stepped = threading.Event()
        self._first = first_wait_s

    def _first_wait_s(self):
        return self._first

    def run_step(self):
        self.steps += 1
        try:
            return self.body()
        finally:
            self.stepped.set()


def _threads(name):
    return [t for t in threading.enumerate() if t.name == name and t.is_alive()]


# ── start ───────────────────────────────────────────────────────────────────

def test_start_runs_one_named_daemon_thread_and_a_second_start_starts_no_other():
    worker = Steps()
    worker.start()
    try:
        assert worker.stepped.wait(WAIT_S)
        with pytest.raises(RuntimeError):
            worker.start()
        [thread] = _threads("test-worker")
        assert thread.daemon
        assert worker.steps == 1
    finally:
        assert worker.stop(timeout=WAIT_S)


def test_a_failed_thread_start_leaves_a_worker_that_is_not_alive_and_joins_at_once(monkeypatch):
    worker = Steps()

    def failing_start(self):
        raise RuntimeError("no thread")

    monkeypatch.setattr(threading.Thread, "start", failing_start)
    with pytest.raises(RuntimeError, match="no thread"):
        worker.start()
    monkeypatch.undo()

    assert not worker.is_alive()
    assert worker.join(timeout=0)
    assert worker.done.done()


def test_a_worker_never_started_is_done_once_joined_or_stopped():
    joined, stopped = Steps(), Steps()

    assert not joined.is_alive() and not joined.done.done()
    assert joined.join(timeout=0)
    assert joined.done.done()
    assert stopped.stop(timeout=0)
    assert stopped.done.done()
    assert joined.steps == stopped.steps == 0


# ── stop, join, is_alive ────────────────────────────────────────────────────

def test_stop_ends_a_waiting_worker_and_joins_it():
    worker = Steps(lambda: 3600)  # waits an hour after its step
    worker.start()
    assert worker.stepped.wait(WAIT_S)
    assert worker.is_alive()

    assert worker.stop(timeout=WAIT_S)

    assert not worker.is_alive()
    assert worker.done.done() and worker.done.result() is None
    assert worker.steps == 1


def test_done_is_resolved_only_when_the_thread_has_ended():
    entered, release = threading.Event(), threading.Event()

    def busy():
        entered.set()
        release.wait(WAIT_S)
        return 3600

    worker = Steps(busy)
    worker.start()
    assert entered.wait(WAIT_S)

    assert worker.stop(timeout=0) is False  # plain work is waited for, not interrupted
    assert worker.is_alive() and not worker.done.done()

    release.set()
    worker.done.result(timeout=WAIT_S)
    assert worker.join(timeout=WAIT_S)
    assert not worker.is_alive()
    assert worker.steps == 1  # the stop held: no step after the one in flight


class KillRegistry:
    """Records kills; a killed job's process returns at once."""

    def __init__(self):
        self.killed = []
        self.events = {}

    def run(self, job_id):
        self.events[job_id] = threading.Event()
        return self.events[job_id]

    def kill(self, job_id):
        self.killed.append(job_id)
        if job_id in self.events:
            self.events[job_id].set()


def test_a_stop_during_a_process_step_kills_that_step_and_the_step_knows():
    registry = KillRegistry()
    started = threading.Event()
    seen = {}

    def process(job_id):
        done = registry.run(job_id)
        started.set()
        return done.wait(WAIT_S)

    worker = Steps(kill_registry=registry)

    def body():
        seen["killed"] = worker._process_step(process, ("test", 1))
        seen["stop_hit_step"] = worker._stop_hit_step
        return 3600

    worker.body = body
    worker.start()
    assert started.wait(WAIT_S)

    assert worker.stop(timeout=WAIT_S)

    assert registry.killed == [("test", 1)]
    assert seen == {"killed": True, "stop_hit_step": True}
    assert worker._current_job is None


def test_a_stop_outside_a_process_step_kills_nothing():
    registry = KillRegistry()
    worker = Steps(lambda: 3600, kill_registry=registry)
    worker.start()
    assert worker.stepped.wait(WAIT_S)

    assert worker.stop(timeout=WAIT_S)

    assert registry.killed == []
    assert worker._stop_hit_step is False


def test_the_process_step_takes_its_job_id_by_keyword_too():
    registry = KillRegistry()
    worker = Steps(kill_registry=registry)
    seen = []

    def process(path, *, job_id):
        seen.append(worker._current_job)
        return path

    assert worker._process_step(process, "a.flac", job_id=("test", 7)) == "a.flac"
    assert seen == [("test", 7)]
    assert worker._current_job is None


# ── wake-up and waits ───────────────────────────────────────────────────────

def test_wake_ends_the_wait_and_runs_the_next_step_at_once():
    second = threading.Event()

    def body():
        if worker.steps == 2:
            second.set()
        return 3600

    worker = Steps(body)
    worker.start()
    try:
        assert worker.stepped.wait(WAIT_S)
        worker.wake()
        assert second.wait(WAIT_S)
    finally:
        assert worker.stop(timeout=WAIT_S)
    assert worker.steps == 2


def test_a_step_that_asks_for_no_wait_is_followed_by_the_next_at_once():
    waits = []

    class Recording(Steps):
        def _wait(self, timeout):
            waits.append(timeout)
            self.request_stop()

    def body():
        return None if worker.steps < 3 else 42

    worker = Recording(body)
    worker._run_loop()  # in this thread: the loop alone

    assert worker.steps == 3
    assert waits == [42]


def test_a_first_wait_comes_before_the_first_step():
    worker = Steps(first_wait_s=3600)
    worker.start()

    assert worker.stop(timeout=WAIT_S)
    assert worker.steps == 0


def test_a_stop_during_a_step_ends_the_loop_without_another_wait():
    waits = []

    class Recording(Steps):
        def _wait(self, timeout):
            waits.append(timeout)

    def body():
        worker.request_stop()
        return 5

    worker = Recording(body)
    worker._run_loop()

    assert worker.steps == 1
    assert waits == []


# ── a crash in the loop ─────────────────────────────────────────────────────

def test_a_crash_in_the_loop_is_reported_and_the_worker_is_not_alive(caplog):
    def body():
        raise ValueError("secret /path/in/message")

    worker = Steps(body)
    with caplog.at_level(logging.ERROR, logger="app.services.worker_thread"):
        worker.start()
        worker.done.result(timeout=WAIT_S)
        assert worker.join(timeout=WAIT_S)

    assert not worker.is_alive()
    [record] = [r for r in caplog.records if r.name == "app.services.worker_thread"]
    assert record.levelno == logging.ERROR
    message = record.getMessage()
    assert "test-worker" in message and "ValueError" in message
    assert "/path" not in message  # the type name only, never the message
    assert worker.stop(timeout=0)  # stopping a crashed worker is harmless


# ── the polling variant ─────────────────────────────────────────────────────

class Polling(PollingWorkerThread):
    thread_name = "test-polling-worker"

    def __init__(self, outcomes, *, idle_poll_s):
        super().__init__(idle_poll_s=idle_poll_s)
        self.outcomes = list(outcomes)

    def process_one(self):
        return self.outcomes.pop(0)


@pytest.mark.parametrize("outcome, wait", [
    ("idle", 7), ("error", 7), ("prepared", None), ("review_ready", None), ("failed", None),
])
def test_a_polling_worker_waits_its_poll_only_after_idle_or_error(outcome, wait):
    worker = Polling([outcome], idle_poll_s=7)

    assert worker.run_step() == wait


def test_a_polling_worker_runs_until_idle_then_waits_its_poll():
    waits = []

    class Recording(Polling):
        def _wait(self, timeout):
            waits.append(timeout)
            self.request_stop()

    worker = Recording(["prepared", "prepared", "idle"], idle_poll_s=123)
    worker._run_loop()

    assert worker.outcomes == []
    assert waits == [123]
