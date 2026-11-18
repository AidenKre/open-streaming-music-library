"""9D.2b (spec §7.8, plan D19): the sender is one thread on the shared worker
base. A step survives its own errors (logged by class only), runs the next
pass at once after it sent something and waits the pass interval otherwise,
and a stop ends a wait inside the gate. The one real-thread test joins with a
bound and asserts on state, never on elapsed time."""

import logging
import threading

import pytest

from app.services import lastfm_sender
from tests.lastfm_fake import ok_scrobbles, scrobble_result
from tests.lastfm_sender_rig import NOW_S, connect_user, make_rig, queue_row

JOIN_BOUND_S = 10


@pytest.fixture
def rig(tmp_path):
    return make_rig(tmp_path)


def test_the_sender_is_a_thread_on_the_shared_base():
    from app.services.worker_thread import WorkerThread

    assert issubclass(lastfm_sender.ScrobbleSender, WorkerThread)
    assert lastfm_sender.ScrobbleSender.thread_name == "lastfm-sender"
    assert lastfm_sender.PASS_INTERVAL_S == 15


def test_a_step_that_sent_nothing_waits_the_pass_interval(rig):
    assert rig.sender.run_step() == lastfm_sender.PASS_INTERVAL_S


def test_a_step_that_sent_something_runs_the_next_pass_at_once(rig):
    ana = connect_user(rig, "ana")
    queue_row(rig, ana, listened_at_s=NOW_S - 100)
    rig.fake.queue(ok_scrobbles(1, 0, [scrobble_result(NOW_S - 100)]))

    assert rig.sender.run_step() is None


def test_a_step_survives_an_error_and_logs_only_its_class(rig, caplog, monkeypatch):
    def broken(*args, **kwargs):
        raise RuntimeError("/private/path/that/must/not/be/logged")

    monkeypatch.setattr(rig.db, "list_due_lastfm_owners", broken)
    caplog.set_level(logging.DEBUG)

    assert rig.sender.run_step() == lastfm_sender.PASS_INTERVAL_S

    errors = [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert len(errors) == 1
    assert "RuntimeError" in errors[0].getMessage()
    assert "/private/path" not in caplog.text
    assert all(r.exc_info is None for r in caplog.records)


def test_a_stop_ends_a_wait_inside_the_gate_and_nothing_is_sent(rig):
    ana = connect_user(rig, "ana")
    queue_row(rig, ana)
    blocked = threading.Event()
    rig.gate_clock.on_wait.append(lambda timeout: blocked.set() if timeout is None else None)

    with rig.gate.enter():  # someone else holds the gate: the sender must wait without a bound
        rig.sender.start()
        try:
            assert blocked.wait(JOIN_BOUND_S), "the sender never waited in the gate"
            rig.sender.request_stop()
            assert rig.sender.join(JOIN_BOUND_S)
        finally:
            rig.sender.request_stop()

    assert not rig.sender.is_alive()
    assert rig.sender.done.done()
    assert rig.fake.requests == []
