"""SC-16e startup recovery registry (Phase 7A.1b, review case 7-U07).

The registry runs an ordered list of named recovery steps before serving. A
failing step logs and the later steps still run, unless the step is marked
fatal: then startup stops there.
"""

import logging

import pytest

from app.services.startup_recovery import StartupStep, run_startup_recovery

OPERATOR = "uvicorn.error"


def _recorder(calls, name, error=None):
    def fn():
        calls.append(name)
        if error is not None:
            raise error

    return fn


def test_the_steps_run_once_each_in_the_listed_order():
    calls = []
    steps = [StartupStep(n, _recorder(calls, n)) for n in ("first", "second", "third")]

    run_startup_recovery(steps)

    assert calls == ["first", "second", "third"]


def test_running_the_list_twice_runs_every_step_again_in_order():
    calls = []
    steps = [StartupStep(n, _recorder(calls, n)) for n in ("a", "b")]

    run_startup_recovery(steps)
    run_startup_recovery(steps)

    assert calls == ["a", "b", "a", "b"]


def test_a_failing_non_fatal_step_is_logged_and_the_later_steps_still_run(caplog):
    calls = []
    secret_detail = "/private/library/Some Artist/track.flac"
    steps = [
        StartupStep("first", _recorder(calls, "first")),
        StartupStep("broken", _recorder(calls, "broken", OSError(secret_detail))),
        StartupStep("last", _recorder(calls, "last")),
    ]

    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        run_startup_recovery(steps)

    assert calls == ["first", "broken", "last"]
    lines = [r.getMessage() for r in caplog.records if r.name == OPERATOR and r.levelno >= logging.WARNING]
    assert len(lines) == 1
    assert "broken" in lines[0] and "OSError" in lines[0]
    # The exception text may carry a path: it never reaches the operator line.
    assert secret_detail not in lines[0]


def test_a_failing_fatal_step_stops_startup_and_no_later_step_runs():
    calls = []
    boom = RuntimeError("database unreadable")
    steps = [
        StartupStep("first", _recorder(calls, "first")),
        StartupStep("fatal one", _recorder(calls, "fatal one", boom), fatal=True),
        StartupStep("never", _recorder(calls, "never")),
    ]

    with pytest.raises(RuntimeError) as raised:
        run_startup_recovery(steps)

    assert raised.value is boom
    assert calls == ["first", "fatal one"]


def test_a_fatal_step_that_succeeds_does_not_stop_the_later_steps():
    calls = []
    steps = [
        StartupStep("fatal ok", _recorder(calls, "fatal ok"), fatal=True),
        StartupStep("after", _recorder(calls, "after")),
    ]

    run_startup_recovery(steps)

    assert calls == ["fatal ok", "after"]


def test_two_steps_with_the_same_name_are_refused_before_any_step_runs():
    calls = []
    steps = [
        StartupStep("same", _recorder(calls, "one")),
        StartupStep("same", _recorder(calls, "two")),
    ]

    with pytest.raises(ValueError):
        run_startup_recovery(steps)

    assert calls == []
