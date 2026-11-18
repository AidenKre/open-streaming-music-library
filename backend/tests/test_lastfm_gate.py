"""9D.1c: the gate (spec §7.8 "The gate", §7.9 kind 2 waits; 9-U09b), on an injected clock.

"One lock and one time, shared by every request to Last.fm of every kind."
- One request at a time.
- "No request before the gate's next allowed time: the end of the last request
  plus LASTFM_MIN_REQUEST_GAP_S, or plus the current try-later wait when the
  last answer to any call was a try-later answer. The first request after
  startup waits one gap."
- "After taking the lock, the gate checks that the server is still `running`
  and refuses the request otherwise."
- connect/complete wait up to 10 s, a Now Playing notice is discarded after
  10 s, the sender waits as long as it takes.
§7.9: "the gate then lets nothing out for 1 minute, then 5, then 30, then an
hour each time; any answer that is not a try-later answer resets that."

No test sleeps: time moves only on the fake clock; tests with threads block
on real conditions and events and join with a timeout.
"""

import itertools
import logging
import threading

import pytest

from app.services.lastfm_client import Answer, AnswerKind
from app.services.lastfm_gate import (
    TRY_LATER_WAITS_S,
    GateBusy,
    GateCancelled,
    GateStopped,
    LastfmGate,
)
from app.services.lastfm_state import LastfmService, LastfmState
from tests import lastfm_secrets as planted
from tests.lastfm_fake import FakeClock, make_config

GAP = 5
OK = Answer(AnswerKind.OK, http_status=200)
LATER = Answer(AnswerKind.TRY_LATER, http_status=503)

# Each kind of request with the bound its caller puts on the wait (§7.8).
KINDS = {"scrobble": None, "nowPlaying": 10.0, "connect": 10.0, "complete": 10.0}


def _gate(gap=GAP, clock=None, state=None):
    clock = clock or FakeClock()
    state = state or LastfmState(LastfmService.RUNNING, make_config())
    return LastfmGate(state, gap_s=gap, clock=clock, wait=clock.wait), clock, state


def _request(gate, clock, *, answer=OK, duration=2.0, max_wait_s=None):
    """One request through the gate; returns (start, end) on the fake clock."""
    with gate.enter(max_wait_s=max_wait_s) as slot:
        start = clock.now
        clock.advance(duration)
        slot.record(answer)
        end = clock.now
    return start, end


# --- spacing (step 8) --------------------------------------------------------


def test_the_first_request_after_startup_waits_one_gap():
    gate, clock, _ = _gate()
    created = clock.now

    start, _ = _request(gate, clock)

    assert start >= created + GAP


def test_a_request_long_after_startup_does_not_wait():
    gate, clock, _ = _gate()
    clock.advance(GAP + 100)
    before = clock.now

    start, _ = _request(gate, clock)

    assert start == before


@pytest.mark.parametrize(("first", "second"), list(itertools.product(KINDS, KINDS)))
def test_every_pair_of_kinds_is_spaced_by_the_gap_from_end_to_start(first, second):
    gate, clock, _ = _gate()

    _, end = _request(gate, clock, duration=7.0, max_wait_s=KINDS[first])
    start, _ = _request(gate, clock, max_wait_s=KINDS[second])

    # At least the gap after the END of the previous request, and no more.
    assert start - end == pytest.approx(GAP)


def test_the_gap_is_the_configured_one():
    gate, clock, _ = _gate(gap=17)

    _, end = _request(gate, clock)
    start, _ = _request(gate, clock)

    assert start - end == pytest.approx(17)


def test_a_slot_that_sent_nothing_does_not_delay_the_next_request():
    # The sender takes the gate, reads, and finds nothing to send.
    gate, clock, _ = _gate()
    _, end = _request(gate, clock)
    clock.advance(GAP)
    with gate.enter():
        clock.advance(1)
    before = clock.now

    start, _ = _request(gate, clock)

    assert start == before


def test_a_slot_that_raised_counts_as_a_request():
    gate, clock, _ = _gate()
    clock.advance(GAP)
    with pytest.raises(RuntimeError):
        with gate.enter():
            clock.advance(3)
            raise RuntimeError("boom")
    failed_at = clock.now

    start, _ = _request(gate, clock)

    assert start - failed_at == pytest.approx(GAP)


# --- try-later waits (step 9) -------------------------------------------------


def test_try_later_answers_hold_every_request_on_the_ladder():
    gate, clock, _ = _gate()
    _, end = _request(gate, clock, answer=LATER)
    gaps = []
    for _ in range(5):
        start, end_next = _request(gate, clock, answer=LATER)
        gaps.append(start - end)
        end = end_next

    assert gaps == pytest.approx([60, 300, 1800, 3600, 3600])
    assert TRY_LATER_WAITS_S == (60, 300, 1800, 3600)


@pytest.mark.parametrize(
    "kind", [AnswerKind.OK, AnswerKind.REJECTED, AnswerKind.RECONNECT]
)
def test_any_answer_that_is_not_try_later_resets_the_ladder(kind):
    gate, clock, _ = _gate()
    _request(gate, clock, answer=LATER)
    _, end_second = _request(gate, clock, answer=LATER)  # the ladder is now at 5 minutes
    start, end = _request(gate, clock, answer=Answer(kind, error_code=13))
    assert start - end_second == pytest.approx(300)  # third request went out after 5 minutes

    start_after_reset, end2 = _request(gate, clock, answer=LATER)
    assert start_after_reset - end == pytest.approx(GAP)
    start_next, _ = _request(gate, clock)
    assert start_next - end2 == pytest.approx(60)


def test_a_try_later_to_a_now_playing_notice_holds_a_scrobble():
    gate, clock, _ = _gate()
    _, end = _request(gate, clock, answer=LATER, max_wait_s=10.0)

    start, _ = _request(gate, clock, max_wait_s=None)

    assert start - end == pytest.approx(60)


def test_a_failure_to_connect_also_starts_the_wait():
    gate, clock, _ = _gate()
    _, end = _request(gate, clock, answer=Answer(AnswerKind.TRY_LATER, connect_failed=True))

    start, _ = _request(gate, clock)

    assert start - end == pytest.approx(60)


def test_a_clock_going_backwards_never_stretches_the_wait():
    gate, clock, _ = _gate()
    _request(gate, clock)
    clock.advance(-10_000)
    clock.waits.clear()

    _request(gate, clock)

    assert sum(w for w in clock.waits if w is not None) <= GAP + 1e-9


def test_a_clock_going_backwards_never_stretches_a_try_later_wait():
    gate, clock, _ = _gate()
    _request(gate, clock, answer=LATER)
    clock.advance(-10_000)
    clock.waits.clear()

    _request(gate, clock)

    assert sum(w for w in clock.waits if w is not None) <= 60 + 1e-9


@pytest.mark.parametrize("code", [10, 26])
def test_a_stop_answer_stops_the_server_and_nothing_more_goes_out(caplog, code):
    caplog.set_level(logging.DEBUG)
    gate, clock, state = _gate()

    _request(gate, clock, answer=Answer(AnswerKind.STOP, http_status=403, error_code=code))

    assert state.service is LastfmService.STOPPED
    errors = [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert len(errors) == 1 and str(code) in errors[0].getMessage()
    planted.assert_no_secret(caplog.text, "captured logs")
    with pytest.raises(GateStopped):
        with gate.enter():
            pytest.fail("a request went out after a stop answer")


# --- refusals and waiting (step 10) -----------------------------------------------


def test_a_waiter_that_sees_stopped_after_its_wait_sends_nothing():
    gate, clock, state = _gate()
    clock.on_wait.append(lambda _timeout: state.stop("test stop"))
    sent = []

    with pytest.raises(GateStopped):
        with gate.enter():
            sent.append("request")

    assert sent == []


def test_a_stopped_server_refuses_at_once():
    state = LastfmState(LastfmService.STOPPED, None)
    gate, clock, _ = _gate(state=state)
    clock.advance(1000)

    with pytest.raises(GateStopped):
        with gate.enter():
            pytest.fail("sent while stopped")


def test_the_stopped_check_is_made_after_taking_the_lock():
    # B waits for A's request to finish; the server stops while A holds the
    # gate; B then takes the lock and must refuse, never send.
    gate, clock, state = _gate()
    clock.advance(GAP)
    a_inside, a_release, b_waiting = threading.Event(), threading.Event(), threading.Event()
    outcome = {}
    clock.on_wait.append(lambda timeout: b_waiting.set() if timeout is None else None)

    def a():
        with gate.enter() as slot:
            a_inside.set()
            a_release.wait(5)
            slot.record(OK)

    def b():
        try:
            with gate.enter():
                outcome["b"] = "sent"
        except GateStopped:
            outcome["b"] = "stopped"

    ta = threading.Thread(target=a)
    ta.start()
    assert a_inside.wait(5)
    tb = threading.Thread(target=b)
    tb.start()
    assert b_waiting.wait(5)
    state.stop("test stop")
    a_release.set()
    ta.join(5)
    tb.join(5)

    assert not ta.is_alive() and not tb.is_alive()
    assert outcome == {"b": "stopped"}


def test_one_request_at_a_time_and_a_bounded_waiter_gives_up():
    gate, clock, _ = _gate()
    clock.advance(GAP)
    a_inside, a_release = threading.Event(), threading.Event()
    outcome = {}

    def a():
        with gate.enter() as slot:
            a_inside.set()
            a_release.wait(5)
            slot.record(OK)

    ta = threading.Thread(target=a)
    ta.start()
    assert a_inside.wait(5)
    try:
        with gate.enter(max_wait_s=10.0):
            outcome["b"] = "sent while another request was in flight"
    except GateBusy:
        outcome["b"] = "busy"
    a_release.set()
    ta.join(5)

    assert outcome == {"b": "busy"}
    assert sum(w for w in clock.waits if w is not None) <= 10 + 1e-9


def test_a_bounded_waiter_gives_up_when_the_gap_is_longer_than_its_bound():
    gate, clock, _ = _gate(gap=30)
    clock.advance(30)
    _, end = _request(gate, clock)

    with pytest.raises(GateBusy):
        with gate.enter(max_wait_s=10.0):
            pytest.fail("sent before the gap")

    # The refusal sent nothing and moved nothing: the next request keeps the gap.
    start, _ = _request(gate, clock)
    assert start - end >= 30 - 1e-9


def test_a_bounded_waiter_gives_up_during_a_try_later_wait():
    gate, clock, _ = _gate()
    _request(gate, clock, answer=LATER)

    with pytest.raises(GateBusy):
        with gate.enter(max_wait_s=10.0):
            pytest.fail("sent during the try-later wait")


def test_a_bounded_waiter_inside_its_bound_goes_through():
    gate, clock, _ = _gate()
    _, end = _request(gate, clock)

    start, _ = _request(gate, clock, max_wait_s=10.0)

    assert start - end == pytest.approx(GAP)


def test_an_unbounded_waiter_waits_out_the_whole_try_later_wait():
    gate, clock, _ = _gate()
    _request(gate, clock, answer=LATER)
    _request(gate, clock, answer=LATER)
    _, end = _request(gate, clock, answer=LATER)  # the next wait is 30 minutes

    start, _ = _request(gate, clock, max_wait_s=None)

    assert start - end == pytest.approx(1800)


def test_a_cancelled_waiter_sends_nothing():
    gate, clock, _ = _gate()
    cancel = threading.Event()
    clock.on_wait.append(lambda _timeout: cancel.set())

    with pytest.raises(GateCancelled):
        with gate.enter(cancel=cancel):
            pytest.fail("sent after a cancel")


def test_wake_releases_a_waiter_blocked_behind_a_request_so_it_can_cancel():
    gate, clock, _ = _gate()
    clock.advance(GAP)
    a_inside, a_release, b_waiting = threading.Event(), threading.Event(), threading.Event()
    cancel = threading.Event()
    outcome = {}
    clock.on_wait.append(lambda timeout: b_waiting.set() if timeout is None else None)

    def a():
        with gate.enter() as slot:
            a_inside.set()
            a_release.wait(5)
            slot.record(OK)

    def b():
        try:
            with gate.enter(cancel=cancel):
                outcome["b"] = "sent"
        except GateCancelled:
            outcome["b"] = "cancelled"

    ta = threading.Thread(target=a)
    ta.start()
    assert a_inside.wait(5)
    tb = threading.Thread(target=b)
    tb.start()
    assert b_waiting.wait(5)
    cancel.set()
    gate.wake()
    tb.join(5)
    a_release.set()
    ta.join(5)

    assert not tb.is_alive() and not ta.is_alive()
    assert outcome == {"b": "cancelled"}


@pytest.mark.parametrize("refusal", ["busy", "cancelled"])
def test_the_gate_is_usable_after_a_refusal(refusal):
    gate, clock, state = _gate()
    _, end = _request(gate, clock)
    clock.advance(2)  # refused mid-gap, so a refusal that took a slot would move the next start
    if refusal == "busy":
        with pytest.raises(GateBusy):
            with gate.enter(max_wait_s=1.0):
                pass
    else:
        cancel = threading.Event()
        cancel.set()
        with pytest.raises(GateCancelled):
            with gate.enter(cancel=cancel):
                pass

    start, _ = _request(gate, clock, max_wait_s=None)

    # The refused attempt took no slot: the next request keeps the one gap.
    assert start - end == pytest.approx(GAP)


def test_a_thread_waiting_behind_a_request_goes_next_once_it_ends():
    gate, clock, _ = _gate()
    clock.advance(GAP)
    a_inside, a_release, b_waiting = threading.Event(), threading.Event(), threading.Event()
    times = {}
    clock.on_wait.append(lambda timeout: b_waiting.set() if timeout is None else None)

    def a():
        with gate.enter() as slot:
            a_inside.set()
            a_release.wait(5)
            clock.advance(2)
            slot.record(OK)
            times["a_end"] = clock.now

    def b():
        with gate.enter() as slot:
            times["b_start"] = clock.now
            slot.record(OK)

    ta = threading.Thread(target=a)
    ta.start()
    assert a_inside.wait(5)
    tb = threading.Thread(target=b)
    tb.start()
    assert b_waiting.wait(5)
    a_release.set()
    ta.join(5)
    tb.join(5)

    assert times["b_start"] - times["a_end"] == pytest.approx(GAP)


def test_the_gate_never_shows_a_secret():
    gate, _, state = _gate()

    planted.assert_no_secret(repr(gate) + str(gate), "the gate's repr")


# --- review r1 (C4, S6) ------------------------------------------------------------


@pytest.mark.parametrize("bound", [0.0, -0.5, -100.0])
def test_a_waiter_whose_budget_is_already_spent_sends_nothing(bound):
    # A Now Playing notice already 10 s old has max_wait_s = 10 - age <= 0.
    gate, clock, _ = _gate()
    clock.advance(GAP + 100)  # the gate itself is free and due

    with pytest.raises(GateBusy):
        with gate.enter(max_wait_s=bound):
            pytest.fail("sent with no time left")

    due = clock.now
    start, _ = _request(gate, clock, max_wait_s=10.0)
    assert start == due  # the gate stayed free: the next request goes out at once


class _BrokenStop(LastfmState):
    def stop(self, cause):
        raise RuntimeError("stop failed")


def test_the_gate_is_released_even_when_stopping_the_server_fails():
    clock = FakeClock()
    state = _BrokenStop(LastfmService.RUNNING, make_config())
    gate = LastfmGate(state, gap_s=GAP, clock=clock, wait=clock.wait)
    clock.advance(GAP)

    with pytest.raises(RuntimeError):
        with gate.enter() as slot:
            slot.record(Answer(AnswerKind.STOP, error_code=10))

    # The slot was freed: the next caller gets through (not GateBusy, not a hang).
    clock.advance(GAP)
    with gate.enter(max_wait_s=1.0) as slot:
        slot.record(OK)
