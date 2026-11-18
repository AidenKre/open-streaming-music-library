"""The gate: the one place that decides whether a request may go to Last.fm (spec §7.8)."""

import threading
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager

from app.services.lastfm_client import Answer, AnswerKind
from app.services.lastfm_state import LastfmState

TRY_LATER_WAITS_S = (60, 300, 1800, 3600)


class GateStopped(Exception):
    """The server is not running: nothing may be sent."""


class GateBusy(Exception):
    """The caller's bounded wait ran out before the gate let it through."""


class GateCancelled(Exception):
    """The caller's cancel event was set while it waited."""


def _condition_wait(condition: threading.Condition, timeout: float | None) -> None:
    condition.wait(timeout)


class GateSlot:
    def __init__(self) -> None:
        self.answer: Answer | None = None

    def record(self, answer: Answer) -> None:
        """Say that a request was made and how Last.fm answered it."""
        self.answer = answer


class LastfmGate:
    def __init__(
        self,
        state: LastfmState,
        *,
        gap_s: float,
        clock: Callable[[], float] = time.monotonic,
        wait: Callable[[threading.Condition, float | None], None] = _condition_wait,
    ):
        self._state = state
        self._gap_s = gap_s
        self._clock = clock
        self._wait = wait
        self._condition = threading.Condition()
        self._busy = False
        self._next_allowed = clock() + gap_s
        self._hold = gap_s
        self._ladder_index = 0

    @property
    def gap_s(self) -> float:
        """The configured gap between two requests."""
        return self._gap_s

    def _take(self, max_wait_s: float | None, cancel: threading.Event | None) -> None:
        """Block until the slot is ours; raise instead when the request must not go out."""
        if max_wait_s is not None and max_wait_s <= 0:
            raise GateBusy
        deadline = None if max_wait_s is None else self._clock() + max_wait_s
        with self._condition:
            while True:
                if cancel is not None and cancel.is_set():
                    raise GateCancelled
                if not self._state.is_running:
                    raise GateStopped
                now = self._clock()
                remaining = None if deadline is None else deadline - now
                if self._busy:
                    if remaining is not None and remaining <= 0:
                        raise GateBusy
                    self._wait(self._condition, remaining)
                    continue
                wait_for = self._next_allowed - now
                if wait_for > self._hold:  # the clock went backwards: never wait longer than the hold
                    wait_for = self._hold
                    self._next_allowed = now + wait_for
                if wait_for <= 0:
                    self._busy = True
                    return
                if remaining is not None and wait_for > remaining:
                    raise GateBusy
                self._wait(self._condition, wait_for)

    def _release(self, slot: GateSlot, failed: bool) -> None:
        with self._condition:
            try:
                end = self._clock()
                answer = slot.answer
                if answer is not None:
                    if answer.kind is AnswerKind.TRY_LATER:
                        self._hold = TRY_LATER_WAITS_S[min(self._ladder_index, len(TRY_LATER_WAITS_S) - 1)]
                        self._ladder_index += 1
                    else:
                        self._ladder_index = 0
                        self._hold = self._gap_s
                    self._next_allowed = end + self._hold
                    if answer.kind is AnswerKind.STOP:
                        self._state.stop(f"Last.fm answered error {answer.error_code}")
                elif failed:
                    self._hold = self._gap_s
                    self._next_allowed = end + self._gap_s
            finally:
                self._busy = False
                self._condition.notify_all()

    @contextmanager
    def enter(
        self, *, max_wait_s: float | None = None, cancel: threading.Event | None = None
    ) -> Iterator[GateSlot]:
        self._take(max_wait_s, cancel)
        slot = GateSlot()
        failed = False
        try:
            if not self._state.is_running:
                raise GateStopped
            try:
                yield slot
            except BaseException:
                failed = True
                raise
        finally:
            self._release(slot, failed)

    def wake(self) -> None:
        with self._condition:
            self._condition.notify_all()
