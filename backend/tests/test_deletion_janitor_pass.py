"""Phase 8A.3d S7 (spec §5 step 5 "Cache/cleanup failure keeps a retryable
journal/task"; plan row "committed journals whose clean-up is pending are
retried"): while the server runs, the deletion worker itself retries pending
committed clean-ups when it is idle and a pass is due (every
``DELETION_JANITOR_INTERVAL_S`` seconds; startup already ran one). It is a
pass of the one deletion worker thread on the shared base, so it never runs
beside the executor's own clean-up. A failing pass is logged by type name only
and the worker goes on. Clocks are fakes; nothing sleeps.
"""

import logging

from fastapi.testclient import TestClient

from app.services.deletion_recovery import DeletionJanitor
from app.services.deletion_worker import DeletionWorker, RunResult


class _Executor:
    def __init__(self, answers=()):
        self.answers = list(answers)

    def run_one(self):
        return self.answers.pop(0) if self.answers else RunResult.IDLE


class _Janitor:
    def __init__(self, fail=False):
        self.passes = 0
        self.fail = fail

    def retry_cleanups(self):
        self.passes += 1
        if self.fail:
            raise RuntimeError("/music/.deleting/1/op/secret.flac")


class _Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def _worker(executor, janitor, clock, interval=60):
    return DeletionWorker(
        executor, idle_poll_s=5, janitor=janitor, janitor_interval_s=interval, clock=clock
    )


def test_an_idle_worker_runs_a_pass_only_once_one_is_due():
    janitor, clock = _Janitor(), _Clock()
    worker = _worker(_Executor(), janitor, clock)

    assert worker.process_one() == "idle"
    assert janitor.passes == 0  # startup ran one: the first is one interval later
    clock.now += 59
    worker.process_one()
    assert janitor.passes == 0
    clock.now += 1
    worker.process_one()
    assert janitor.passes == 1
    worker.process_one()
    assert janitor.passes == 1
    clock.now += 60
    worker.process_one()
    assert janitor.passes == 2


def test_a_busy_worker_runs_targets_before_any_pass():
    janitor, clock = _Janitor(), _Clock()
    worker = _worker(_Executor([RunResult.DONE, RunResult.DONE]), janitor, clock)
    clock.now += 600

    assert worker.process_one() == "done"
    assert worker.process_one() == "done"
    assert janitor.passes == 0
    assert worker.process_one() == "idle"
    assert janitor.passes == 1


def test_a_failing_pass_is_logged_by_type_and_the_worker_goes_on(caplog):
    janitor, clock = _Janitor(fail=True), _Clock()
    worker = _worker(_Executor(), janitor, clock)
    clock.now += 60

    with caplog.at_level(logging.WARNING):
        assert worker.process_one() == "idle"

    assert janitor.passes == 1
    assert "RuntimeError" in caplog.text and "secret" not in caplog.text
    clock.now += 60
    worker.process_one()
    assert janitor.passes == 2


class _Raising:
    def run_one(self):
        raise RuntimeError("database disk image is malformed")


# Audit V-332-BE "Janitor stop": a step that answers "error" (its item was
# released, or the step itself failed) waits like an idle one, so a due pass
# still runs; a fault that never clears does not stop the janitor until restart.
def test_a_step_that_released_its_item_still_runs_a_due_pass():
    janitor, clock = _Janitor(), _Clock()
    worker = _worker(_Executor([RunResult.RELEASED, RunResult.RELEASED]), janitor, clock)

    assert worker.process_one() == "error"
    assert janitor.passes == 0  # not due yet
    clock.now += 60
    assert worker.process_one() == "error"
    assert janitor.passes == 1


def test_a_step_that_keeps_failing_still_runs_a_due_pass():
    janitor, clock = _Janitor(), _Clock()
    worker = _worker(_Raising(), janitor, clock)
    clock.now += 60

    assert worker.process_one() == "error"
    assert janitor.passes == 1
    assert worker.process_one() == "error"
    assert janitor.passes == 1  # once per interval


def test_a_worker_without_a_janitor_behaves_as_before():
    worker = DeletionWorker(_Executor([RunResult.DONE]), idle_poll_s=5)

    assert worker.process_one() == "done"
    assert worker.process_one() == "idle"


def test_the_app_worker_carries_a_janitor_over_its_own_executor(configure_app):
    main = configure_app(
        env={"ENABLE_DELETION_WORKER": "true", "DELETION_JANITOR_INTERVAL_S": "77"}
    )

    with TestClient(main.app):
        worker = main.app.state.deletion_worker
        assert isinstance(worker._janitor, DeletionJanitor)
        assert worker._janitor._executor is worker._executor
        assert worker._janitor_interval_s == 77
        assert main.app.state.settings.deletion_janitor_interval_s == 77
